# Carnet : une app fictive pour tester AWS Emulator (version française)

> English version: [README.md](README.md)

Une petite application de notes, entièrement fictive, qui utilise les briques AWS
qu'une équipe de développement manipule tous les jours. Elle sert à mesurer ce que
[AWS Emulator](https://github.com/aws/aws-emulator) sait faire en local, sans compte AWS.

> Les résultats sont commentés dans l'article (en anglais) : [AWS Emulator, hands-on: 66 of 72 checks pass, and Terraform still hits a wall](https://dev.to/patricet/aws-emulator-hands-on-66-of-72-checks-pass-and-terraform-still-hits-a-wall-4l58).

| Partie | Technologie | Briques AWS |
| --- | --- | --- |
| Front | React (Vite) | aucune, il n'appelle que `/api` |
| Back | Python (FastAPI, boto3) | Cognito, Secrets Manager, RDS PostgreSQL, ElastiCache, S3, SQS, CloudWatch Logs |
| Infra | Script shell, CLI AWS | les mêmes, plus VPC, groupes de sécurité, ALB, ACM, CloudWatch, SES |

## Dérouler le test avec Docker (recommandé)

Seul prérequis : Docker dans WSL. Rien n'est installé sur le poste.

```bash
docker compose up --build
```

Cette commande enchaîne tout : l'émulateur démarre, le service `test` crée l'infrastructure
avec la CLI AWS et écrit `rapport.md`, puis le Redis local, le backend et le front se lancent.

- Front : http://localhost:5173
- API : http://127.0.0.1:8000/docs
- Compte de test : `alice@example.com` / `Demo-Pass-123!`
- Rapport seul : `docker compose logs test`
- Repartir de zéro : `docker compose down -v && docker compose up`

Tous les conteneurs partagent le réseau du conteneur `emulateur` (`network_mode: service:emulateur`).
Ils se parlent donc en 127.0.0.1, comme sur un poste de dev. C'est nécessaire : l'émulateur annonce
l'endpoint RDS sur `127.0.0.1:<port aléatoire>` et son certificat vaut pour 127.0.0.1.

`rapport.md` et `backend/.env` sont écrits par un conteneur, donc au nom de root.

## Dérouler le test sans Docker

Prérequis (WSL Ubuntu ou Linux) :

- AWS Emulator :
  ```bash
  curl -fsSLo aws-emulator.deb https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS/latest/aws-emulator_amd64.deb
  sudo apt-get install -y ./aws-emulator.deb
  ```
- CLI AWS **v2** (la v1 ignore `AWS_ENDPOINT_URL` pour RDS en us-east-1 ; le script passe `--endpoint-url` partout par sécurité)
- `psql` pour les sondes SQL : `sudo apt-get install -y postgresql-client`
- Python 3.10+, Node 18+, et un Redis local (`docker run -d -p 127.0.0.1:6379:6379 redis:7-alpine`)

```bash
aws-emulator -t off                # terminal 1 : l'émulateur, sans télémétrie
./scripts/test-emulateur.sh        # terminal 2 : écrit rapport.md et backend/.env
./scripts/lancer-backend.sh        # terminal 2 : API sur http://127.0.0.1:8000
cd frontend && npm install && npm run dev    # terminal 3 : http://localhost:5173
```

L'état de l'émulateur vit en mémoire : après un redémarrage, relancer
`test-emulateur.sh` (le port de la base change à chaque création).

## Ce que le script vérifie

1. **Socle** : S3, SQS avec file morte, Secrets Manager, CloudWatch Logs, alarme CloudWatch
2. **Authentification** : user pool Cognito, client, utilisatrice, connexion, refus d'un mauvais mot de passe, JWKS
3. **Données** : instance RDS PostgreSQL et sondes SQL, cache ElastiCache et joignabilité de son endpoint
4. **Réseau** : VPC, sous-réseaux, groupes de sécurité, certificat ACM, ALB avec listener HTTPS
5. **Scénario applicatif** : fichier S3 et URL présignée, message SQS, événement de log, métrique, e-mail SES

Chaque étape est classée : OK, échec ou divergence, 501 non implémenté.
`rapport-exemple.md` est le rapport d'une exécution du 16 novembre 2026 (émulateur 1.0.471).

## Constats (émulateur 1.0.471, 16 novembre 2026)

Sur 72 vérifications : 66 réussies, 6 en échec, aucune erreur 501.

- Le plan de contrôle des treize services répond sans 501 sur ce périmètre.
- **Cognito** délivre de vrais jetons RS256, vérifiables par JWKS. L'émetteur est l'adresse de l'émulateur, pas `cognito-idp.<région>.amazonaws.com`.
- **RDS** expose un port local qui parle le protocole PostgreSQL, mais ce n'est pas un vrai PostgreSQL : `now()`, `serial`, `identity` et `gen_random_uuid()` échouent. Le backend s'en tient donc à du SQL portable.
- **ElastiCache** expose, depuis la version 1.0.471, un port local qui parle Redis (PING, SET, GET, INCR), mais pas `HSET` ni `LPUSH`, et seulement en RESP2 : avec redis-py 8 il faut `protocol=2`. Le Redis local du `docker compose` ne sert plus que de secours.
- **ALB** : un ALB public exige une passerelle Internet sur le VPC, comme sur AWS. Aucun trafic ne passe par l'ALB émulé.
- **ACM, SES** : les états évoluent seuls (certificat en `FAILED` après 3 s, identité SES vérifiée après 0,5 s). Aucun e-mail n'est remis.
- L'URL présignée S3 pointe sur l'émulateur, dont le certificat est auto-signé : le navigateur affiche un avertissement.

## Le même test avec Terraform

`terraform/main.tf` décrit la même infrastructure (préfixe `carnet-tf`, donc sans conflit avec le script CLI).
`scripts/test-terraform.sh` enchaîne apply, plan de contrôle et destroy, et écrit `rapport-terraform.md`.

```bash
docker compose --profile terraform run --rm terraform     # avec Docker, la stack étant démarrée
./scripts/test-terraform.sh                               # sans Docker
```

Compter 4 minutes. `rapport-terraform-exemple.md` est le rapport d'une exécution du 16 novembre 2026 (émulateur 1.0.471,
Terraform 1.17.2, provider AWS 5.100.0). Constats :

- **Provider AWS 6.x inutilisable avec S3** : il lit les tags des buckets par l'API S3 Control, dont les requêtes
  n'atteignent pas l'émulateur. La création d'un bucket reste bloquée. Le provider 5.x fonctionne.
- **Groupes de sécurité en échec** : Terraform retire la règle de sortie par défaut à la création, et l'émulateur
  répond que cette règle n'existe pas (`RevokeSecurityGroupEgress`), alors qu'il la liste bien.
- **RDS** : sans `engine_version`, la création est refusée (« Cannot find version for postgres »).
- **Le reste passe** : 25 ressources sur 31 créées (manquent les 3 groupes de sécurité et leurs 3 règles), plan de contrôle vide, destroy complet.
