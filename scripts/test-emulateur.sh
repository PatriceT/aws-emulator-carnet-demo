#!/usr/bin/env bash
# Crée l'infrastructure de l'app fictive « Carnet » sur AWS Emulator avec la CLI AWS,
# joue un scénario applicatif, et écrit un rapport (rapport.md) : ce qui passe,
# ce qui renvoie 501, ce qui diverge.
#
# Prérequis : aws-emulator démarré (aws-emulator -t off), CLI AWS, et si possible psql.
# Usage     : ./scripts/test-emulateur.sh
#
# L'état de l'émulateur est en mémoire : redémarre-le pour repartir de zéro.

set -u
cd "$(dirname "$0")/.."
ROOT="$PWD"
# shellcheck source=env.sh
source scripts/env.sh

REPORT="$ROOT/rapport.md"
APP="carnet"
DB_USER="carnet"
DB_PASS="Carnet-Demo-2026"
USER_EMAIL="alice@example.com"
USER_PASS="Demo-Pass-123!"

# On passe toujours --endpoint-url : la CLI v1 ignore AWS_ENDPOINT_URL pour RDS
# en us-east-1 et enverrait l'appel au vrai AWS.
a() { aws --endpoint-url "$AWS_ENDPOINT_URL" "$@"; }

OK=0; KO=0; NI=0; OUT=""
row() { printf '| %s | %s | %s | %s |\n' "$1" "$2" "$3" "$4" >> "$REPORT"; }
clean() { tr '\n|' ' /' | sed 's/  */ /g' | cut -c1-160; }

# step <service> <libellé> <commande...> : exécute, classe le résultat, garde la sortie dans $OUT
step() {
  local svc="$1" label="$2"; shift 2
  OUT="$("$@" 2>&1)"; local rc=$?
  if [ $rc -eq 0 ]; then
    OK=$((OK+1)); row "$svc" "$label" "OK" ""; printf '  \033[32mOK \033[0m %-16s %s\n' "$svc" "$label"
  elif printf '%s' "$OUT" | grep -qiE 'NotImplemented|\(501\)'; then
    NI=$((NI+1)); row "$svc" "$label" "501 non implémenté" "$(printf '%s' "$OUT" | clean)"
    printf '  \033[33m501\033[0m %-16s %s\n' "$svc" "$label"
  else
    KO=$((KO+1)); row "$svc" "$label" "ÉCHEC" "$(printf '%s' "$OUT" | clean)"
    printf '  \033[31mKO \033[0m %-16s %s\n' "$svc" "$label"
  fi
  return $rc
}
# refuse <service> <libellé> <commande...> : la commande DOIT échouer (comportement attendu d'AWS)
refuse() {
  local svc="$1" label="$2"; shift 2
  OUT="$("$@" 2>&1)"
  if [ $? -ne 0 ]; then OK=$((OK+1)); row "$svc" "$label" "OK (refusé comme attendu)" ""; printf '  \033[32mOK \033[0m %-16s %s\n' "$svc" "$label"
  else KO=$((KO+1)); row "$svc" "$label" "ÉCART (aurait dû être refusé)" ""; printf '  \033[31mKO \033[0m %-16s %s\n' "$svc" "$label"; fi
}
note() { row "$1" "$2" "$3" "$4"; printf '  \033[36m.. \033[0m %-16s %s : %s\n' "$1" "$2" "$3"; }
section() { printf '\n## %s\n\n| Service | Étape | Résultat | Détail |\n| --- | --- | --- | --- |\n' "$1" >> "$REPORT"; printf '\n\033[1m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- préambule
if ! curl -fsS --noproxy '*' --cacert "$AWS_CA_BUNDLE" "$AWS_ENDPOINT_URL/__admin/health" >/dev/null 2>&1; then
  echo "L'émulateur ne répond pas sur $AWS_ENDPOINT_URL. Lance : aws-emulator -t off" >&2; exit 1
fi
{
  echo "# Rapport de test AWS Emulator, app fictive « Carnet »"
  echo
  echo "- Date : $(date '+%Y-%m-%d %H:%M')"
  echo "- Émulateur : $(aws-emulator -v 2>/dev/null | tr '\n' ' ')"
  echo "- CLI : $(aws --version 2>&1)"
} > "$REPORT"

# ---------------------------------------------------------------- 1. socle
section "1. Socle applicatif"
step "STS" "Identité de l'appelant" a sts get-caller-identity --query Account --output text

step "S3" "Créer le bucket" a s3api create-bucket --bucket "$APP-fichiers"
step "S3" "Bloquer l'accès public" a s3api put-public-access-block --bucket "$APP-fichiers" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
step "S3" "Activer le versionnement" a s3api put-bucket-versioning --bucket "$APP-fichiers" --versioning-configuration Status=Enabled
step "S3" "Chiffrement par défaut" a s3api put-bucket-encryption --bucket "$APP-fichiers" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

step "SQS" "Créer la file morte" a sqs create-queue --queue-name "$APP-jobs-dlq" --query QueueUrl --output text
DLQ_URL="$OUT"
step "SQS" "ARN de la file morte" a sqs get-queue-attributes --queue-url "$DLQ_URL" --attribute-names QueueArn --query Attributes.QueueArn --output text
DLQ_ARN="$OUT"
step "SQS" "Créer la file avec redrive" a sqs create-queue --queue-name "$APP-jobs" --query QueueUrl --output text \
  --attributes "{\"VisibilityTimeout\":\"30\",\"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"$DLQ_ARN\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}\"}"
QUEUE_URL="$OUT"

step "Secrets Manager" "Créer le secret de la base" a secretsmanager create-secret --name "$APP/db" \
  --secret-string "{\"username\":\"$DB_USER\",\"password\":\"$DB_PASS\"}" --query Name --output text
step "Secrets Manager" "Relire le secret" a secretsmanager get-secret-value --secret-id "$APP/db" --query SecretString --output text

step "CloudWatch Logs" "Créer le groupe de logs" a logs create-log-group --log-group-name "/$APP/backend"
step "CloudWatch Logs" "Rétention 14 jours" a logs put-retention-policy --log-group-name "/$APP/backend" --retention-in-days 14
step "CloudWatch" "Alarme sur les erreurs" a cloudwatch put-metric-alarm --alarm-name "$APP-erreurs" --namespace "Carnet" \
  --metric-name Erreurs --statistic Sum --period 60 --evaluation-periods 1 --threshold 1 --comparison-operator GreaterThanOrEqualToThreshold
step "CloudWatch" "Relire l'alarme" a cloudwatch describe-alarms --alarm-names "$APP-erreurs" --query 'MetricAlarms[0].StateValue' --output text

# ---------------------------------------------------------------- 2. authentification
section "2. Authentification (Cognito)"
step "Cognito" "Créer le user pool" a cognito-idp create-user-pool --pool-name "$APP-users" \
  --auto-verified-attributes email --username-attributes email --query UserPool.Id --output text
POOL_ID="$OUT"
step "Cognito" "Créer le client web" a cognito-idp create-user-pool-client --user-pool-id "$POOL_ID" --client-name web \
  --explicit-auth-flows ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH --query UserPoolClient.ClientId --output text
CLIENT_ID="$OUT"
step "Cognito" "Créer l'utilisatrice" a cognito-idp admin-create-user --user-pool-id "$POOL_ID" --username "$USER_EMAIL" \
  --user-attributes Name=email,Value="$USER_EMAIL" Name=email_verified,Value=true --message-action SUPPRESS --query User.UserStatus --output text
step "Cognito" "Fixer son mot de passe" a cognito-idp admin-set-user-password --user-pool-id "$POOL_ID" --username "$USER_EMAIL" --password "$USER_PASS" --permanent
step "Cognito" "Connexion (InitiateAuth)" a cognito-idp initiate-auth --client-id "$CLIENT_ID" --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters "USERNAME=$USER_EMAIL,PASSWORD=$USER_PASS" --query AuthenticationResult.AccessToken --output text
ACCESS_TOKEN="$OUT"
refuse "Cognito" "Mauvais mot de passe refusé" a cognito-idp initiate-auth --client-id "$CLIENT_ID" --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters "USERNAME=$USER_EMAIL,PASSWORD=faux"
step "Cognito" "GetUser avec le jeton" a cognito-idp get-user --access-token "$ACCESS_TOKEN" --query Username --output text
step "Cognito" "Clés publiques (JWKS)" curl -fsS --noproxy '*' --cacert "$AWS_CA_BUNDLE" "$AWS_ENDPOINT_URL/$POOL_ID/.well-known/jwks.json"

# ---------------------------------------------------------------- 3. données
section "3. Données (RDS PostgreSQL, ElastiCache)"
step "RDS" "Créer l'instance PostgreSQL" a rds create-db-instance --db-instance-identifier "$APP-db" --engine postgres \
  --db-instance-class db.t4g.micro --allocated-storage 20 --db-name "$APP" --master-username "$DB_USER" --master-user-password "$DB_PASS" \
  --query DBInstance.DBInstanceStatus --output text
DB_HOST=""; DB_PORT=""
for _ in $(seq 1 20); do
  s="$(a rds describe-db-instances --db-instance-identifier "$APP-db" --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null)"
  [ "$s" = "available" ] && break; sleep 1
done
step "RDS" "Instance disponible, lire l'endpoint" a rds describe-db-instances --db-instance-identifier "$APP-db" \
  --query 'DBInstances[0].[Endpoint.Address,Endpoint.Port]' --output text
read -r DB_HOST DB_PORT <<< "$OUT"
note "RDS" "Endpoint annoncé" "${DB_HOST:-aucun}:${DB_PORT:-}" ""

if command -v psql >/dev/null && [ -n "$DB_PORT" ]; then
  export PGPASSWORD="$DB_PASS" PGCONNECT_TIMEOUT=5
  q() { psql "host=$DB_HOST port=$DB_PORT user=$DB_USER dbname=$APP" -v ON_ERROR_STOP=1 -At -c "$1"; }
  step "RDS (SQL)" "Connexion et SELECT 1" q "select 1"
  PGPASSWORD=faux refuse "RDS (SQL)" "Mauvais mot de passe refusé" q "select 1"
  step "RDS (SQL)" "CREATE TABLE simple" q "create table sonde(id integer primary key, titre text not null, cree_le timestamp default current_timestamp)"
  step "RDS (SQL)" "INSERT ... RETURNING" q "insert into sonde(id,titre) values (1,'a') returning id"
  step "RDS (SQL)" "Transaction et ROLLBACK" q "begin; insert into sonde(id,titre) values (2,'b'); rollback"
  step "RDS (SQL)" "Fonction now()" q "select now()"
  step "RDS (SQL)" "Colonne serial auto-incrémentée" q "create table sonde_serial(id serial primary key, t text); insert into sonde_serial(t) values ('a'); select 1/count(id) from sonde_serial"
  step "RDS (SQL)" "Colonne identity" q "create table sonde_identity(id integer generated always as identity primary key, t text)"
  step "RDS (SQL)" "gen_random_uuid()" q "select gen_random_uuid()"
  step "RDS (SQL)" "Type jsonb" q "create table sonde_json(id integer primary key, d jsonb); insert into sonde_json values (1,'{\"a\":1}'); select d->>'a' from sonde_json"
  unset PGPASSWORD
else
  note "RDS (SQL)" "Sondes SQL" "ignorées" "psql absent ou pas d'endpoint (sudo apt-get install -y postgresql-client)"
fi

step "ElastiCache" "Créer le cache Redis" a elasticache create-cache-cluster --cache-cluster-id "$APP-cache" --engine redis \
  --cache-node-type cache.t4g.micro --num-cache-nodes 1 --query CacheCluster.CacheClusterStatus --output text
sleep 2
step "ElastiCache" "Lire l'endpoint du cache" a elasticache describe-cache-clusters --cache-cluster-id "$APP-cache" --show-cache-node-info \
  --query 'CacheClusters[0].CacheNodes[0].[Endpoint.Address,Endpoint.Port]' --output text
read -r CACHE_HOST CACHE_PORT <<< "$OUT"
# redis_cmd <commande en ligne> : envoie une commande Redis brute et affiche la première ligne de réponse
redis_cmd() {
  local rep
  exec 3<>"/dev/tcp/$CACHE_HOST/$CACHE_PORT" || return 1
  printf '%s\r\n' "$1" >&3
  IFS= read -r -t 3 rep <&3; exec 3<&- 3>&-
  rep="${rep%$'\r'}"; echo "$rep"
  [ -n "$rep" ] && [ "${rep#-}" = "$rep" ]      # une réponse qui commence par « - » est une erreur Redis
}
if [ -n "${CACHE_HOST:-}" ] && timeout 3 bash -c "exec 3<>/dev/tcp/$CACHE_HOST/${CACHE_PORT:-6379}" 2>/dev/null; then
  note "ElastiCache" "Endpoint joignable" "OUI" "$CACHE_HOST:$CACHE_PORT"
  step "ElastiCache (Redis)" "PING" redis_cmd "PING"
  step "ElastiCache (Redis)" "SET avec expiration" redis_cmd "SET sonde valeur EX 30"
  step "ElastiCache (Redis)" "GET" redis_cmd "GET sonde"
  step "ElastiCache (Redis)" "INCR" redis_cmd "INCR compteur"
  step "ElastiCache (Redis)" "HSET (table de hachage)" redis_cmd "HSET fiche champ 1"
  step "ElastiCache (Redis)" "LPUSH (liste)" redis_cmd "LPUSH file a"
else
  note "ElastiCache" "Endpoint joignable" "NON" "${CACHE_HOST:-aucun} : API seulement, pas de Redis derrière. L'app utilise le Redis local (docker compose)."
fi

# ---------------------------------------------------------------- 4. réseau et entrée HTTPS
section "4. Réseau et entrée HTTPS"
step "EC2" "Créer le VPC" a ec2 create-vpc --cidr-block 10.42.0.0/16 --query Vpc.VpcId --output text; VPC_ID="$OUT"
step "EC2" "Sous-réseau A" a ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.42.1.0/24 --availability-zone us-east-1a --query Subnet.SubnetId --output text; SUBNET_A="$OUT"
step "EC2" "Sous-réseau B" a ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.42.2.0/24 --availability-zone us-east-1b --query Subnet.SubnetId --output text; SUBNET_B="$OUT"
step "EC2" "Passerelle Internet" a ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text; IGW_ID="$OUT"
step "EC2" "Attacher la passerelle au VPC" a ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
step "EC2" "Groupe de sécurité de l'ALB" a ec2 create-security-group --group-name "$APP-alb" --description "ALB public" --vpc-id "$VPC_ID" --query GroupId --output text; SG_ALB="$OUT"
step "EC2" "Groupe de sécurité de l'app" a ec2 create-security-group --group-name "$APP-app" --description "Backend" --vpc-id "$VPC_ID" --query GroupId --output text; SG_APP="$OUT"
step "EC2" "Règle : HTTPS depuis Internet vers l'ALB" a ec2 authorize-security-group-ingress --group-id "$SG_ALB" --protocol tcp --port 443 --cidr 0.0.0.0/0
step "EC2" "Règle : ALB vers l'app sur 8000" a ec2 authorize-security-group-ingress --group-id "$SG_APP" --protocol tcp --port 8000 --source-group "$SG_ALB"
refuse "EC2" "Règle en double refusée" a ec2 authorize-security-group-ingress --group-id "$SG_ALB" --protocol tcp --port 443 --cidr 0.0.0.0/0
step "EC2" "Relire les règles" a ec2 describe-security-group-rules --filters "Name=group-id,Values=$SG_ALB" --query 'length(SecurityGroupRules)' --output text

step "ACM" "Demander un certificat" a acm request-certificate --domain-name carnet.example.com --validation-method DNS --query CertificateArn --output text; CERT_ARN="$OUT"
step "ACM" "Relire le certificat" a acm describe-certificate --certificate-arn "$CERT_ARN" --query Certificate.Status --output text
# L'émulateur fait évoluer certains états tout seul, comme AWS : on attend l'état stable
# pour que le rapport ne dépende pas de la vitesse de la machine.
attendre() { # attendre <valeur transitoire> <commande...> : relit jusqu'à ce que l'état change (10 s max)
  local transitoire="$1"; shift
  for _ in $(seq 1 20); do OUT="$("$@" 2>/dev/null)"; [ "$OUT" != "$transitoire" ] && return 0; sleep 0.5; done
}
attendre PENDING_VALIDATION a acm describe-certificate --certificate-arn "$CERT_ARN" --query Certificate.Status --output text
note "ACM" "Statut du certificat" "$OUT" "PENDING_VALIDATION à la création, puis FAILED après 3 s environ : aucune validation DNS n'est possible"

step "ALB" "Créer l'ALB" a elbv2 create-load-balancer --name "$APP-alb" --type application --subnets "$SUBNET_A" "$SUBNET_B" \
  --security-groups "$SG_ALB" --query 'LoadBalancers[0].LoadBalancerArn' --output text; ALB_ARN="$OUT"
step "ALB" "Créer le groupe cible" a elbv2 create-target-group --name "$APP-app" --protocol HTTP --port 8000 --vpc-id "$VPC_ID" \
  --target-type ip --health-check-path /api/health --query 'TargetGroups[0].TargetGroupArn' --output text; TG_ARN="$OUT"
step "ALB" "Listener HTTPS avec le certificat" a elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTPS --port 443 \
  --certificates "CertificateArn=$CERT_ARN" --default-actions "Type=forward,TargetGroupArn=$TG_ARN" --query 'Listeners[0].ListenerArn' --output text
step "ALB" "Enregistrer une cible" a elbv2 register-targets --target-group-arn "$TG_ARN" --targets Id=10.42.1.10,Port=8000
step "ALB" "Santé des cibles" a elbv2 describe-target-health --target-group-arn "$TG_ARN" --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text
attendre initial a elbv2 describe-target-health --target-group-arn "$TG_ARN" --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text
note "ALB" "État de la cible" "$OUT" "initial à l'enregistrement, puis unhealthy après 3 s environ : aucun trafic réel ne passe par l'ALB émulé"

# ---------------------------------------------------------------- 5. scénario applicatif
section "5. Scénario applicatif en CLI"
TMP="$(mktemp -d)"; echo "bonjour depuis l'émulateur" > "$TMP/note.txt"
step "S3" "Déposer un fichier" a s3 cp "$TMP/note.txt" "s3://$APP-fichiers/notes/note.txt"
step "S3" "Le relire à l'identique" bash -c "aws --endpoint-url '$AWS_ENDPOINT_URL' s3 cp 's3://$APP-fichiers/notes/note.txt' - | diff - '$TMP/note.txt'"
step "S3" "URL présignée utilisable" bash -c "curl -fsS --noproxy '*' --cacert '$AWS_CA_BUNDLE' \"\$(aws --endpoint-url '$AWS_ENDPOINT_URL' s3 presign 's3://$APP-fichiers/notes/note.txt' --expires-in 60)\" | diff - '$TMP/note.txt'"
step "SQS" "Envoyer un message" a sqs send-message --queue-url "$QUEUE_URL" --message-body '{"type":"note.creee","id":"1"}' --query MessageId --output text
step "SQS" "Recevoir le message" a sqs receive-message --queue-url "$QUEUE_URL" --wait-time-seconds 1 --query 'Messages[0].ReceiptHandle' --output text
[ -n "$OUT" ] && [ "$OUT" != "None" ] && step "SQS" "Supprimer le message" a sqs delete-message --queue-url "$QUEUE_URL" --receipt-handle "$OUT"
step "CloudWatch Logs" "Créer un flux" a logs create-log-stream --log-group-name "/$APP/backend" --log-stream-name cli
step "CloudWatch Logs" "Écrire un événement" a logs put-log-events --log-group-name "/$APP/backend" --log-stream-name cli \
  --log-events "timestamp=$(date +%s000),message=note.creee"
step "CloudWatch Logs" "Relire l'événement" bash -c "aws --endpoint-url '$AWS_ENDPOINT_URL' logs get-log-events --log-group-name '/$APP/backend' --log-stream-name cli --query 'events[0].message' --output text | grep -q note.creee"
step "CloudWatch" "Publier une métrique" a cloudwatch put-metric-data --namespace Carnet --metric-name Erreurs --value 0
step "SES v2" "Déclarer l'expéditeur" a sesv2 create-email-identity --email-identity no-reply@example.com
# L'identité n'est vérifiée qu'une demi-seconde après sa création ; avant, l'envoi est refusé.
attendre False a sesv2 get-email-identity --email-identity no-reply@example.com --query VerifiedForSendingStatus --output text
attendre false a sesv2 get-email-identity --email-identity no-reply@example.com --query VerifiedForSendingStatus --output text
step "SES v2" "Envoyer un e-mail" a sesv2 send-email --from-email-address no-reply@example.com --destination "ToAddresses=$USER_EMAIL" \
  --content 'Simple={Subject={Data=Bienvenue},Body={Text={Data=Bonjour}}}' --query MessageId --output text
note "SES v2" "Remise de l'e-mail" "aucune" "L'émulateur accepte l'envoi mais ne remet rien"
rm -rf "$TMP"

# ---------------------------------------------------------------- configuration de l'app
cat > "$ROOT/backend/.env" <<EOF
COGNITO_POOL_ID=$POOL_ID
COGNITO_CLIENT_ID=$CLIENT_ID
DB_INSTANCE_ID=$APP-db
DB_NAME=$APP
DB_SECRET_ID=$APP/db
CACHE_CLUSTER_ID=$APP-cache
REDIS_FALLBACK_URL=redis://127.0.0.1:6379/0
BUCKET=$APP-fichiers
QUEUE_URL=$QUEUE_URL
LOG_GROUP=/$APP/backend
EOF

{
  echo
  echo "## Bilan"
  echo
  echo "- Réussis : $OK"
  echo "- En échec ou divergents : $KO"
  echo "- Non implémentés (501) : $NI"
} >> "$REPORT"

printf '\n\033[1mBilan\033[0m : %s OK, %s en échec, %s non implémentés (501)\n' "$OK" "$KO" "$NI"
echo "Rapport : $REPORT"
echo "Config de l'app écrite dans backend/.env  (compte de test : $USER_EMAIL / $USER_PASS)"
