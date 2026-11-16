# La même infrastructure que scripts/test-emulateur.sh, décrite en Terraform.
# Aucun réglage propre à l'émulateur ici : c'est l'environnement (scripts/env.sh)
# qui fait pointer le provider sur AWS Emulator via AWS_ENDPOINT_URL.

terraform {
  required_version = ">= 1.6"
  required_providers {
    # Provider 5.x : la série 6.x lit les tags des buckets par l'API S3 Control, dont les
    # requêtes n'atteignent pas l'émulateur (l'identifiant de compte est ajouté au nom d'hôte).
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region                  = "us-east-1"
  s3_use_path_style       = true
  skip_metadata_api_check = true
}

variable "groupes_de_securite" {
  description = "Créer les groupes de sécurité. À passer à false pour voir jusqu'où va le reste quand ils échouent."
  type        = bool
  default     = true
}

locals {
  app = "carnet-tf"
  sg  = var.groupes_de_securite ? 1 : 0
}

# ---------------------------------------------------------------- socle
resource "aws_s3_bucket" "fichiers" {
  bucket        = "${local.app}-fichiers"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "fichiers" {
  bucket                  = aws_s3_bucket.fichiers.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "fichiers" {
  bucket = aws_s3_bucket.fichiers.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "fichiers" {
  bucket = aws_s3_bucket.fichiers.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_sqs_queue" "dlq" {
  name = "${local.app}-jobs-dlq"
}

resource "aws_sqs_queue" "jobs" {
  name                       = "${local.app}-jobs"
  visibility_timeout_seconds = 30
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "${local.app}/db"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id     = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({ username = "carnet", password = "Carnet-Demo-2026" })
}

resource "aws_cloudwatch_log_group" "backend" {
  name              = "/${local.app}/backend"
  retention_in_days = 14
}

resource "aws_cloudwatch_metric_alarm" "erreurs" {
  alarm_name          = "${local.app}-erreurs"
  namespace           = "Carnet"
  metric_name         = "Erreurs"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
}

resource "aws_sesv2_email_identity" "expediteur" {
  email_identity = "no-reply-tf@example.com"
}

# ---------------------------------------------------------------- authentification
resource "aws_cognito_user_pool" "users" {
  name                     = "${local.app}-users"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
}

resource "aws_cognito_user_pool_client" "web" {
  name                = "web"
  user_pool_id        = aws_cognito_user_pool.users.id
  explicit_auth_flows = ["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
}

# ---------------------------------------------------------------- réseau
resource "aws_vpc" "main" {
  cidr_block = "10.43.0.0/16"
  tags       = { Name = local.app }
}

resource "aws_subnet" "a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.43.1.0/24"
  availability_zone = "us-east-1a"
}

resource "aws_subnet" "b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.43.2.0/24"
  availability_zone = "us-east-1b"
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_security_group" "alb" {
  count       = local.sg
  name        = "${local.app}-alb"
  description = "ALB public"
  vpc_id      = aws_vpc.main.id
}

resource "aws_security_group" "app" {
  count       = local.sg
  name        = "${local.app}-app"
  description = "Backend"
  vpc_id      = aws_vpc.main.id
}

resource "aws_security_group" "donnees" {
  count       = local.sg
  name        = "${local.app}-donnees"
  description = "Base et cache"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  count             = local.sg
  security_group_id = aws_security_group.alb[0].id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "app_depuis_alb" {
  count                        = local.sg
  security_group_id            = aws_security_group.app[0].id
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
  referenced_security_group_id = aws_security_group.alb[0].id
}

resource "aws_vpc_security_group_ingress_rule" "postgres_depuis_app" {
  count                        = local.sg
  security_group_id            = aws_security_group.donnees[0].id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.app[0].id
}

# ---------------------------------------------------------------- entrée HTTPS
resource "aws_acm_certificate" "site" {
  domain_name       = "carnet-tf.example.com"
  validation_method = "DNS"
}

resource "aws_lb" "alb" {
  name               = "${local.app}-alb"
  load_balancer_type = "application"
  depends_on         = [aws_internet_gateway.main] # un ALB public exige une passerelle Internet
  subnets            = [aws_subnet.a.id, aws_subnet.b.id]
  security_groups    = local.sg == 1 ? aws_security_group.alb[*].id : null
}

resource "aws_lb_target_group" "app" {
  name        = "${local.app}-app"
  port        = 8000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id
  health_check { path = "/api/health" }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = aws_acm_certificate.site.arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ---------------------------------------------------------------- données
resource "aws_db_subnet_group" "db" {
  name       = "${local.app}-db"
  subnet_ids = [aws_subnet.a.id, aws_subnet.b.id]
}

resource "aws_db_instance" "db" {
  identifier             = "${local.app}-db"
  engine                 = "postgres"
  engine_version         = "16.4" # obligatoire ici : sans version, l'émulateur refuse la création
  instance_class         = "db.t4g.micro"
  allocated_storage      = 20
  db_name                = "carnet"
  username               = "carnet"
  password               = "Carnet-Demo-2026"
  db_subnet_group_name   = aws_db_subnet_group.db.name
  vpc_security_group_ids = local.sg == 1 ? aws_security_group.donnees[*].id : null
  skip_final_snapshot    = true
}

resource "aws_elasticache_subnet_group" "cache" {
  name       = "${local.app}-cache"
  subnet_ids = [aws_subnet.a.id, aws_subnet.b.id]
}

resource "aws_elasticache_cluster" "cache" {
  cluster_id         = "${local.app}-cache"
  engine             = "redis"
  node_type          = "cache.t4g.micro"
  num_cache_nodes    = 1
  subnet_group_name  = aws_elasticache_subnet_group.cache.name
  security_group_ids = local.sg == 1 ? aws_security_group.donnees[*].id : null
}

output "endpoint_base" { value = aws_db_instance.db.endpoint }
output "endpoint_cache" { value = aws_elasticache_cluster.cache.cache_nodes[0].address }
output "user_pool_id" { value = aws_cognito_user_pool.users.id }
