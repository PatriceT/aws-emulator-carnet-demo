#!/usr/bin/env bash
# Rejoue l'infrastructure de l'app « Carnet » avec Terraform contre AWS Emulator
# et écrit rapport-terraform.md : ce qui se crée, ce qui échoue, et si le plan est stable.
#
# Prérequis : aws-emulator démarré, terraform >= 1.6.
# Usage     : ./scripts/test-terraform.sh
#
# Déroulé : 1) apply complet  2) si des groupes de sécurité échouent, apply du reste sans eux
#           3) plan de contrôle (il doit être vide)  4) destroy

set -u
cd "$(dirname "$0")/.."
ROOT="$PWD"
source scripts/env.sh
REPORT="$ROOT/rapport-terraform.md"

# On travaille dans un dossier temporaire : ni état ni provider dans le projet.
WORK="$(mktemp -d)"; cp terraform/*.tf "$WORK/"; cd "$WORK"
export TF_IN_AUTOMATION=1 TF_INPUT=0
tf() { terraform "$@" -no-color; }

echo "Initialisation de Terraform…"
tf init > init.log 2>&1 || { cat init.log; exit 1; }

{
  echo "# Rapport Terraform, app fictive « Carnet » sur AWS Emulator"
  echo
  echo "- Date : $(date '+%Y-%m-%d %H:%M')"
  echo "- Émulateur : $(aws-emulator -v 2>/dev/null | tr '\n' ' ')"
  echo "- Terraform : $(terraform version | head -1), provider AWS $(grep -o 'Installed hashicorp/aws v[0-9.]*' init.log | head -1 | cut -d' ' -f3)"
} > "$REPORT"

# resume <fichier de sortie d'un apply> : une ligne de tableau par ressource
resume() {
  printf '\n| Ressource | Résultat | Détail |\n| --- | --- | --- |\n' >> "$REPORT"
  grep -E '^aws_[^:]+: Creation complete' "$1" | sed -E 's/^([^:]+): Creation complete after ([0-9a-z]+).*/| \1 | OK | \2 |/' >> "$REPORT"
  awk '/^Error: /{err=substr($0,8); gsub(/operation error [A-Za-z0-9 ]+: [A-Za-z]+, https response error StatusCode: [0-9]+, RequestID: [^,]+, /,"",err)} /^  with aws_/{gsub(/^  with |,$/,""); gsub(/\|/,"/",err); printf "| %s | ÉCHEC | %s |\n",$0,substr(err,1,220)}' "$1" >> "$REPORT"
}
compte() { grep -cE "$2" "$1" || true; }

echo "1/4 apply complet…"
printf '\n## 1. Apply complet\n' >> "$REPORT"
tf apply -auto-approve > apply1.log 2>&1; RC1=$?
resume apply1.log
echo "    $(compte apply1.log 'Creation complete') ressources créées, $(compte apply1.log '^Error: ') erreurs"

SG_VAR=()
if [ $RC1 -ne 0 ] && grep -q 'with aws_security_group' apply1.log; then
  echo "2/4 les groupes de sécurité échouent : apply du reste sans eux…"
  printf '\n## 2. Apply du reste, sans les groupes de sécurité\n' >> "$REPORT"
  SG_VAR=(-var groupes_de_securite=false)
  tf apply -auto-approve "${SG_VAR[@]}" > apply2.log 2>&1
  resume apply2.log
  echo "    $(compte apply2.log 'Creation complete') ressources de plus, $(compte apply2.log '^Error: ') erreurs"
else
  echo "2/4 sans objet"
fi

echo "3/4 plan de contrôle…"
printf '\n## 3. Plan de contrôle\n\n' >> "$REPORT"
tf plan -detailed-exitcode "${SG_VAR[@]}" > plan.log 2>&1; RCP=$?
case $RCP in
  0) echo "Plan vide : Terraform relit toutes les ressources créées sans voir de dérive." >> "$REPORT"; echo "    plan vide" ;;
  2) { echo "Le plan n'est pas vide : la relecture diffère de ce qui a été créé."; echo; echo '```text'; grep -E '^  # |^Plan:' plan.log; echo '```'; } >> "$REPORT"; echo "    plan NON vide : $(grep '^Plan:' plan.log)" ;;
  *) { echo "Le plan a échoué."; echo; echo '```text'; grep -A3 '^Error: ' plan.log | head -20; echo '```'; } >> "$REPORT"; echo "    plan en erreur" ;;
esac

echo "4/4 destroy…"
printf '\n## 4. Destroy\n\n' >> "$REPORT"
tf destroy -auto-approve "${SG_VAR[@]}" > destroy.log 2>&1; RCD=$?
if [ $RCD -eq 0 ]; then echo "$(grep -E '^Destroy complete' destroy.log)" >> "$REPORT"
else { echo "Le destroy a échoué."; echo; echo '```text'; grep -A2 '^Error: ' destroy.log | head -20; echo '```'; } >> "$REPORT"; fi
echo "    $(grep -E '^Destroy complete|^Error: ' destroy.log | head -1)"

echo "Rapport : $REPORT   (journaux complets : $WORK)"
