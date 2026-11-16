# Rapport de test AWS Emulator, app fictive « Carnet »

- Date : 2026-11-16 19:36
- Émulateur : Version: 1.0.471 Release date: 2026.11.16 Commit: 91eb64ca5a78a7d78f4748085e65681abc417e15 
- CLI : aws-cli/2.40.2 Python/3.14.8 Linux/6.18.44-fc-v470 exe/x86_64.ubuntu.24

## 1. Socle applicatif

| Service | Étape | Résultat | Détail |
| --- | --- | --- | --- |
| STS | Identité de l'appelant | OK |  |
| S3 | Créer le bucket | OK |  |
| S3 | Bloquer l'accès public | OK |  |
| S3 | Activer le versionnement | OK |  |
| S3 | Chiffrement par défaut | OK |  |
| SQS | Créer la file morte | OK |  |
| SQS | ARN de la file morte | OK |  |
| SQS | Créer la file avec redrive | OK |  |
| Secrets Manager | Créer le secret de la base | OK |  |
| Secrets Manager | Relire le secret | OK |  |
| CloudWatch Logs | Créer le groupe de logs | OK |  |
| CloudWatch Logs | Rétention 14 jours | OK |  |
| CloudWatch | Alarme sur les erreurs | OK |  |
| CloudWatch | Relire l'alarme | OK |  |

## 2. Authentification (Cognito)

| Service | Étape | Résultat | Détail |
| --- | --- | --- | --- |
| Cognito | Créer le user pool | OK |  |
| Cognito | Créer le client web | OK |  |
| Cognito | Créer l'utilisatrice | OK |  |
| Cognito | Fixer son mot de passe | OK |  |
| Cognito | Connexion (InitiateAuth) | OK |  |
| Cognito | Mauvais mot de passe refusé | OK (refusé comme attendu) |  |
| Cognito | GetUser avec le jeton | OK |  |
| Cognito | Clés publiques (JWKS) | OK |  |

## 3. Données (RDS PostgreSQL, ElastiCache)

| Service | Étape | Résultat | Détail |
| --- | --- | --- | --- |
| RDS | Créer l'instance PostgreSQL | OK |  |
| RDS | Instance disponible, lire l'endpoint | OK |  |
| RDS | Endpoint annoncé | 127.0.0.1:42901 |  |
| RDS (SQL) | Connexion et SELECT 1 | OK |  |
| RDS (SQL) | Mauvais mot de passe refusé | OK (refusé comme attendu) |  |
| RDS (SQL) | CREATE TABLE simple | OK |  |
| RDS (SQL) | INSERT ... RETURNING | OK |  |
| RDS (SQL) | Transaction et ROLLBACK | OK |  |
| RDS (SQL) | Fonction now() | ÉCHEC | ERROR: syntax error at or near "now" |
| RDS (SQL) | Colonne serial auto-incrémentée | ÉCHEC | CREATE TABLE INSERT 0 1 ERROR: division by zero |
| RDS (SQL) | Colonne identity | ÉCHEC | ERROR: syntax error at or near "identity" |
| RDS (SQL) | gen_random_uuid() | ÉCHEC | ERROR: syntax error at or near "gen_random_uuid" |
| RDS (SQL) | Type jsonb | OK |  |
| ElastiCache | Créer le cache Redis | OK |  |
| ElastiCache | Lire l'endpoint du cache | OK |  |
| ElastiCache | Endpoint joignable | OUI | 127.0.0.1:36747 |
| ElastiCache (Redis) | PING | OK |  |
| ElastiCache (Redis) | SET avec expiration | OK |  |
| ElastiCache (Redis) | GET | OK |  |
| ElastiCache (Redis) | INCR | OK |  |
| ElastiCache (Redis) | HSET (table de hachage) | ÉCHEC | -ERR unknown command 'hset', with args beginning with:  |
| ElastiCache (Redis) | LPUSH (liste) | ÉCHEC | -ERR unknown command 'lpush', with args beginning with:  |

## 4. Réseau et entrée HTTPS

| Service | Étape | Résultat | Détail |
| --- | --- | --- | --- |
| EC2 | Créer le VPC | OK |  |
| EC2 | Sous-réseau A | OK |  |
| EC2 | Sous-réseau B | OK |  |
| EC2 | Passerelle Internet | OK |  |
| EC2 | Attacher la passerelle au VPC | OK |  |
| EC2 | Groupe de sécurité de l'ALB | OK |  |
| EC2 | Groupe de sécurité de l'app | OK |  |
| EC2 | Règle : HTTPS depuis Internet vers l'ALB | OK |  |
| EC2 | Règle : ALB vers l'app sur 8000 | OK |  |
| EC2 | Règle en double refusée | OK (refusé comme attendu) |  |
| EC2 | Relire les règles | OK |  |
| ACM | Demander un certificat | OK |  |
| ACM | Relire le certificat | OK |  |
| ACM | Statut du certificat | FAILED | PENDING_VALIDATION à la création, puis FAILED après 3 s environ : aucune validation DNS n'est possible |
| ALB | Créer l'ALB | OK |  |
| ALB | Créer le groupe cible | OK |  |
| ALB | Listener HTTPS avec le certificat | OK |  |
| ALB | Enregistrer une cible | OK |  |
| ALB | Santé des cibles | OK |  |
| ALB | État de la cible | unhealthy | initial à l'enregistrement, puis unhealthy après 3 s environ : aucun trafic réel ne passe par l'ALB émulé |

## 5. Scénario applicatif en CLI

| Service | Étape | Résultat | Détail |
| --- | --- | --- | --- |
| S3 | Déposer un fichier | OK |  |
| S3 | Le relire à l'identique | OK |  |
| S3 | URL présignée utilisable | OK |  |
| SQS | Envoyer un message | OK |  |
| SQS | Recevoir le message | OK |  |
| SQS | Supprimer le message | OK |  |
| CloudWatch Logs | Créer un flux | OK |  |
| CloudWatch Logs | Écrire un événement | OK |  |
| CloudWatch Logs | Relire l'événement | OK |  |
| CloudWatch | Publier une métrique | OK |  |
| SES v2 | Déclarer l'expéditeur | OK |  |
| SES v2 | Envoyer un e-mail | OK |  |
| SES v2 | Remise de l'e-mail | aucune | L'émulateur accepte l'envoi mais ne remet rien |

## Bilan

- Réussis : 66
- En échec ou divergents : 6
- Non implémentés (501) : 0
