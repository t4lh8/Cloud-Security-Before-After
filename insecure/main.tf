# ⚠️ INTENTIONALLY INSECURE - FOR EDUCATIONAL PURPOSES ONLY. NEVER DEPLOY THIS.
#
# A small web app stack (S3 bucket, EC2 web server, RDS database, IAM role) written
# the way many real breaches start. Every problem is marked with ❌ and fixed in ../secure.

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
}

# Safety switch: `terraform plan` / `apply` always stop here, so this stack can be scanned but never deployed.
locals {
  deployment_allowed = false
}

resource "terraform_data" "do_not_deploy" {
  lifecycle {
    precondition {
      condition     = local.deployment_allowed
      error_message = "This configuration is intentionally insecure and must NOT be deployed. Use ../secure instead."
    }
  }
}

# ---------------------------------------------------------------------------
# S3 bucket for customer uploads
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "data" {
  bucket = "${var.project}-customer-data"
  # ❌ No versioning: a deleted or ransomware-encrypted file is gone forever.
  # ❌ No access logging: nobody can tell who downloaded what.
  # ❌ No customer-managed encryption key.
}

# ❌ Public access protections are all switched off.
resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# ❌ Anyone on the internet can list and download every file.
resource "aws_s3_bucket_policy" "data" {
  bucket = aws_s3_bucket.data.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicRead"
      Effect    = "Allow"
      Principal = "*"
      Action    = ["s3:GetObject", "s3:ListBucket"]
      Resource  = [aws_s3_bucket.data.arn, "${aws_s3_bucket.data.arn}/*"]
    }]
  })
}

# ---------------------------------------------------------------------------
# Network access
# ---------------------------------------------------------------------------

resource "aws_security_group" "web" {
  name   = "${var.project}-web"
  vpc_id = var.vpc_id

  # ❌ SSH open to the whole internet - bots start brute-forcing within minutes.
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # ❌ RDP open to the whole internet - a favorite entry point for ransomware.
  ingress {
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # ❌ Database port reachable from anywhere.
  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # ❌ Unrestricted outbound traffic makes data exfiltration easy.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
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

# ❌ Full admin rights: if the web server is hacked, the whole AWS account is hacked.
resource "aws_iam_role_policy" "web" {
  name = "${var.project}-web-admin"
  role = aws_iam_role.web.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "*"
      Resource = "*"
    }]
  })
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
  subnet_id                   = var.public_subnet_id
  vpc_security_group_ids      = [aws_security_group.web.id]
  iam_instance_profile        = aws_iam_instance_profile.web.name
  associate_public_ip_address = true # ❌ Directly exposed to the internet.

  # ❌ IMDSv1 allowed: an SSRF bug can steal the instance's AWS credentials
  #    (this is how the 2019 Capital One breach happened).
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "optional"
  }

  # ❌ Disk is not encrypted.
  root_block_device {
    volume_size = 20
    encrypted   = false
  }

  # ❌ Secrets hardcoded in user data are readable by anyone who can describe the instance.
  user_data = <<-EOF
    #!/bin/bash
    echo "DB_PASSWORD=SuperSecret123!" >> /etc/environment
    echo "API_KEY=Zm9yLWRlbW8tb25seS1ub3QtYS1yZWFsLWtleQ==" >> /etc/environment
  EOF
}

# ---------------------------------------------------------------------------
# RDS database
# ---------------------------------------------------------------------------

resource "aws_db_instance" "main" {
  identifier              = "${var.project}-db"
  engine                  = "mysql"
  engine_version          = "8.0"
  instance_class          = "db.t3.micro"
  allocated_storage       = 20
  username                = "admin"
  password                = "SuperSecret123!" # ❌ Hardcoded password, now in Git history forever.
  publicly_accessible     = true              # ❌ Database has a public IP address.
  storage_encrypted       = false             # ❌ Data at rest is not encrypted.
  backup_retention_period = 0                 # ❌ No backups.
  deletion_protection     = false             # ❌ One wrong command deletes production.
  skip_final_snapshot     = true
  vpc_security_group_ids  = [aws_security_group.web.id]
}
