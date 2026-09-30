# ✅ SECURE VERSION of ../insecure - the same web app stack, hardened.
# Every fix is marked with ✅ and matches an ❌ in the insecure version.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Encryption key shared by S3, EBS and RDS
# ---------------------------------------------------------------------------

# ✅ Customer-managed KMS key with automatic yearly rotation.
resource "aws_kms_key" "main" {
  description             = "${var.project} data encryption key"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AccountAdministration"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = "kms:*"
      Resource  = "*"
    }]
  })
}

resource "aws_kms_alias" "main" {
  name          = "alias/${var.project}-data"
  target_key_id = aws_kms_key.main.key_id
}

# ---------------------------------------------------------------------------
# S3 bucket for customer uploads + a bucket for its access logs
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "data" {
  #checkov:skip=CKV_AWS_144:Cross-region replication is a disaster-recovery choice, out of scope for this demo.
  #checkov:skip=CKV2_AWS_62:No downstream consumer needs event notifications.
  bucket = "${var.project}-customer-data"
}

resource "aws_s3_bucket" "logs" {
  #checkov:skip=CKV_AWS_18:This is the access-log bucket itself; logging it to itself would loop.
  #checkov:skip=CKV_AWS_144:Cross-region replication is a disaster-recovery choice, out of scope for this demo.
  #checkov:skip=CKV2_AWS_62:No downstream consumer needs event notifications.
  bucket = "${var.project}-access-logs"
}

# ✅ Every public access path is blocked on both buckets.
resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ✅ Versioning keeps old copies, so deleted or overwritten files can be restored.
resource "aws_s3_bucket_versioning" "data" {
  bucket = aws_s3_bucket.data.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_versioning" "logs" {
  bucket = aws_s3_bucket.logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

# ✅ Encrypted with our own KMS key.
resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
    bucket_key_enabled = true
  }
}

# ✅ Access logging: every request to the data bucket is recorded.
resource "aws_s3_bucket_logging" "data" {
  bucket        = aws_s3_bucket.data.id
  target_bucket = aws_s3_bucket.logs.id
  target_prefix = "s3-access/"
}

# ✅ Lifecycle rules clean up old versions and unfinished uploads.
resource "aws_s3_bucket_lifecycle_configuration" "data" {
  bucket = aws_s3_bucket.data.id
  rule {
    id     = "expire-old-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    id     = "expire-logs"
    status = "Enabled"
    filter {}
    expiration {
      days = 365
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ✅ Refuse any request that is not over HTTPS.
resource "aws_s3_bucket_policy" "data" {
  bucket = aws_s3_bucket.data.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.data.arn, "${aws_s3_bucket.data.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

# ---------------------------------------------------------------------------
# Network access
# ---------------------------------------------------------------------------

# ✅ No SSH or RDP at all: admins connect through AWS Systems Manager Session Manager,
#    which needs no open inbound port and logs every session.
resource "aws_security_group" "web" {
  name        = "${var.project}-web"
  description = "Web server: HTTPS in from the load balancer only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "HTTPS from the load balancer"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [var.load_balancer_sg_id]
  }

  egress {
    description = "HTTPS out for OS updates and AWS APIs"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "MySQL to the database only"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
}

# ✅ The database only accepts connections from the web servers.
resource "aws_security_group" "db" {
  name        = "${var.project}-db"
  description = "Database: MySQL from the web servers only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "MySQL from the web servers"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]
  }
}

# ---------------------------------------------------------------------------
# IAM role for the web server
# ---------------------------------------------------------------------------

resource "aws_iam_role" "web" {
  name = "${var.project}-web-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# ✅ Least privilege: read/write only its own bucket, nothing else.
resource "aws_iam_role_policy" "web" {
  name = "${var.project}-web-s3-access"
  role = aws_iam_role.web.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadWriteOwnBucket"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${aws_s3_bucket.data.arn}/*"
      },
      {
        Sid      = "UseDataKey"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.main.arn
      },
    ]
  })
}

# ✅ AWS-managed policy that lets Session Manager replace SSH.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.web.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "web" {
  name = "${var.project}-web-profile"
  role = aws_iam_role.web.name
}

# ---------------------------------------------------------------------------
# EC2 web server
# ---------------------------------------------------------------------------

resource "aws_instance" "web" {
  ami                         = var.ami_id
  instance_type               = "t3.micro"
  subnet_id                   = var.private_subnet_id
  vpc_security_group_ids      = [aws_security_group.web.id]
  iam_instance_profile        = aws_iam_instance_profile.web.name
  associate_public_ip_address = false # ✅ Private subnet, reachable only through the load balancer.
  monitoring                  = true  # ✅ Detailed CloudWatch monitoring.
  ebs_optimized               = true

  # ✅ IMDSv2 only: every metadata request needs a session token, which blocks SSRF credential theft.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # ✅ Disk encrypted with our KMS key.
  root_block_device {
    volume_size = 20
    encrypted   = true
    kms_key_id  = aws_kms_key.main.arn
  }

  # ✅ No secrets here. The app reads the database password from Secrets Manager at runtime.
  user_data = <<-EOF
    #!/bin/bash
    dnf update -y
  EOF
}

# ---------------------------------------------------------------------------
# RDS database
# ---------------------------------------------------------------------------

resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-db"
  subnet_ids = var.db_subnet_ids
}

# Role that lets RDS publish enhanced monitoring metrics.
resource "aws_iam_role" "rds_monitoring" {
  name = "${var.project}-rds-monitoring"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_db_instance" "main" {
  identifier     = "${var.project}-db"
  engine         = "mysql"
  engine_version = "8.0"
  instance_class = "db.t3.micro"

  allocated_storage = 20
  storage_encrypted = true # ✅ Encrypted at rest with our KMS key.
  kms_key_id        = aws_kms_key.main.arn

  username                            = "app_admin"
  manage_master_user_password         = true # ✅ AWS generates the password and keeps it in Secrets Manager.
  master_user_secret_kms_key_id       = aws_kms_key.main.arn
  iam_database_authentication_enabled = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false # ✅ Private IP only.
  multi_az               = true  # ✅ Survives the loss of an availability zone.

  backup_retention_period   = 7    # ✅ Daily backups kept for a week.
  deletion_protection       = true # ✅ Cannot be deleted by accident.
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.project}-db-final"
  copy_tags_to_snapshot     = true

  auto_minor_version_upgrade      = true # ✅ Security patches are applied automatically.
  enabled_cloudwatch_logs_exports = ["audit", "error", "general", "slowquery"]
  monitoring_interval             = 60
  monitoring_role_arn             = aws_iam_role.rds_monitoring.arn
  performance_insights_enabled    = true
  performance_insights_kms_key_id = aws_kms_key.main.arn
}
