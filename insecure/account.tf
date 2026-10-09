# ⚠️ INTENTIONALLY INSECURE - account-level settings. Scan only, never deploy.
#
# The workload in main.tf sits inside an AWS account. These are the account
# settings you get when nobody locks the account down after creating it.

# ---------------------------------------------------------------------------
# People and passwords
# ---------------------------------------------------------------------------

# ❌ Weak password rules: 6 characters, no complexity, reuse allowed, never expires.
resource "aws_iam_account_password_policy" "this" {
  minimum_password_length        = 6
  require_lowercase_characters   = false
  require_uppercase_characters   = false
  require_numbers                = false
  require_symbols                = false
  allow_users_to_change_password = true
}

# ❌ A shared IAM user with full admin rights, no MFA and a long-lived access key.
#    One leaked key (a laptop, a public repo, a CI log) means the whole account.
resource "aws_iam_user" "admin" {
  name = "admin"
}

resource "aws_iam_user_policy_attachment" "admin" {
  user       = aws_iam_user.admin.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_access_key" "admin" {
  user = aws_iam_user.admin.name
}

# ❌ A developer user with an inline wildcard policy attached straight to the user.
resource "aws_iam_user" "developer" {
  name = "developer"
}

resource "aws_iam_user_policy" "developer" {
  name = "everything"
  user = aws_iam_user.developer.name
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "*", Resource = "*" }]
  })
}

# ---------------------------------------------------------------------------
# Account-wide defaults
# ---------------------------------------------------------------------------

# ❌ The account-level S3 public access block is off, so any bucket can be made public.
resource "aws_s3_account_public_access_block" "this" {
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# ❌ New EBS volumes are not encrypted unless someone remembers to ask for it.
resource "aws_ebs_encryption_by_default" "this" {
  enabled = false
}

# ---------------------------------------------------------------------------
# Logging and detection
# ---------------------------------------------------------------------------

# ❌ CloudTrail in one region only, no log file validation, no encryption and no
#    alerting. An attacker working in another region is invisible, and logs can
#    be edited without anyone noticing.
resource "aws_cloudtrail" "this" {
  name                          = "${var.project}-trail"
  s3_bucket_name                = aws_s3_bucket.data.id
  is_multi_region_trail         = false
  include_global_service_events = false
  enable_log_file_validation    = false
}

# ❌ GuardDuty exists but is switched off.
resource "aws_guardduty_detector" "this" {
  enable = false
}
