# Rapport Terraform, app fictive « Carnet » sur AWS Emulator

- Date : 2026-11-16 20:15
- Émulateur : Version: 1.0.471 Release date: 2026.11.16 Commit: 91eb64ca5a78a7d78f4748085e65681abc417e15 
- Terraform : Terraform v1.17.2, provider AWS v5.100.0

## 1. Apply complet

| Ressource | Résultat | Détail |
| --- | --- | --- |
| aws_secretsmanager_secret.db | OK | 4s |
| aws_sesv2_email_identity.expediteur | OK | 4s |
| aws_cloudwatch_metric_alarm.erreurs | OK | 4s |
| aws_acm_certificate.site | OK | 4s |
| aws_cognito_user_pool.users | OK | 4s |
| aws_cloudwatch_log_group.backend | OK | 4s |
| aws_cognito_user_pool_client.web | OK | 0s |
| aws_secretsmanager_secret_version.db | OK | 0s |
| aws_vpc.main | OK | 4s |
| aws_subnet.a | OK | 1s |
| aws_subnet.b | OK | 1s |
| aws_internet_gateway.main | OK | 1s |
| aws_s3_bucket.fichiers | OK | 5s |
| aws_lb_target_group.app | OK | 2s |
| aws_s3_bucket_server_side_encryption_configuration.fichiers | OK | 1s |
| aws_s3_bucket_public_access_block.fichiers | OK | 1s |
| aws_db_subnet_group.db | OK | 1s |
| aws_elasticache_subnet_group.cache | OK | 1s |
| aws_s3_bucket_versioning.fichiers | OK | 2s |
| aws_sqs_queue.dlq | OK | 28s |
| aws_sqs_queue.jobs | OK | 25s |
| aws_security_group.alb[0] | ÉCHEC | revoking default IPv4 egress rule for Security Group (sg-0000000000000009c): api error InvalidPermission.NotFound: The specified rule does not exist in this security group. |
| aws_security_group.app[0] | ÉCHEC | revoking default IPv4 egress rule for Security Group (sg-00000000000000095): api error InvalidPermission.NotFound: The specified rule does not exist in this security group. |
| aws_security_group.donnees[0] | ÉCHEC | revoking default IPv4 egress rule for Security Group (sg-0000000000000009a): api error InvalidPermission.NotFound: The specified rule does not exist in this security group. |

## 2. Apply du reste, sans les groupes de sécurité

| Ressource | Résultat | Détail |
| --- | --- | --- |
| aws_elasticache_cluster.cache | OK | 30s |
| aws_lb.alb | OK | 1m0s |
| aws_lb_listener.https | OK | 0s |
| aws_db_instance.db | OK | 1m20s |

## 3. Plan de contrôle

Plan vide : Terraform relit toutes les ressources créées sans voir de dérive.

## 4. Destroy

Destroy complete! Resources: 25 destroyed.
