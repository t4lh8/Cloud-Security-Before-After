# ✅ SECURE VERSION of ../insecure/account.tf - the account itself, locked down.
#
# Some things cannot be done in Terraform and are listed in the README checklist:
# MFA on the root user, deleting root access keys and setting alternate contacts.

# ---------------------------------------------------------------------------
# People and passwords
# ---------------------------------------------------------------------------

# ✅ Strong password rules for any IAM user that might still exist (CIS 1.8-1.9).
resource "aws_iam_account_password_policy" "this" {
  minimum_password_length        = 14
  require_lowercase_characters   = true
  require_uppercase_characters   = true
  require_numbers                = true
  require_symbols                = true
  allow_users_to_change_password = true
  password_reuse_prevention      = 24
  max_password_age               = 90
}

# ✅ No IAM users and no long-lived access keys. People sign in through IAM
#    Identity Center (with MFA) and then assume one of these roles. Both roles
#    refuse to be assumed without MFA, and sessions expire after one hour.
locals {
  require_mfa = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AccountPrincipalsWithMfaOnly"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = "sts:AssumeRole"
      Condition = {
        Bool            = { "aws:MultiFactorAuthPresent" = "true" }
        NumericLessThan = { "aws:MultiFactorAuthAge" = "3600" }
      }
    }]
  })
}

# ✅ Least privilege: the everyday role can look at everything and change nothing.
resource "aws_iam_role" "readonly" {
  name                 = "${var.project}-readonly"
  assume_role_policy   = local.require_mfa
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "readonly" {
  role       = aws_iam_role.readonly.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ✅ Admin rights only through a separate break-glass role, so using them is a
#    deliberate step that shows up on its own in CloudTrail.
resource "aws_iam_role" "admin" {
  name                 = "${var.project}-break-glass-admin"
  assume_role_policy   = local.require_mfa
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "admin" {
  #checkov:skip=CKV_AWS_274:Break-glass role. MFA is required to assume it, sessions last one hour and every use raises an alarm.
  role       = aws_iam_role.admin.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# ✅ IAM Access Analyzer reports any resource shared outside the account.
resource "aws_accessanalyzer_analyzer" "this" {
  analyzer_name = "${var.project}-account"
  type          = "ACCOUNT"
}

# ---------------------------------------------------------------------------
# Account-wide defaults
# ---------------------------------------------------------------------------

# ✅ Nothing public: blocks public buckets account-wide, even if a single
#    bucket is misconfigured later.
resource "aws_s3_account_public_access_block" "this" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ✅ Every new EBS volume and snapshot is encrypted with our key.
resource "aws_ebs_encryption_by_default" "this" {
  enabled = true
}

resource "aws_ebs_default_kms_key" "this" {
  key_arn = aws_kms_key.main.arn
}

# ---------------------------------------------------------------------------
# Logging and detection
# ---------------------------------------------------------------------------

# ✅ One trail for all regions, with signed digest files so edited or deleted
#    logs can be detected, encrypted with KMS and streamed to CloudWatch.
resource "aws_cloudtrail" "this" {
  name                          = "${var.project}-trail"
  s3_bucket_name                = aws_s3_bucket.logs.id
  s3_key_prefix                 = "cloudtrail"
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  kms_key_id                    = aws_kms_key.main.arn
  sns_topic_name                = aws_sns_topic.security_alerts.name
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn     = aws_iam_role.cloudtrail.arn

  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }

  depends_on = [aws_s3_bucket_policy.logs]
}

# ✅ CloudTrail may write into the log bucket, nobody may use plain HTTP.
resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "CloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.logs.arn
      },
      {
        Sid       = "CloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.logs.arn}/cloudtrail/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = { StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" } }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.logs.arn, "${aws_s3_bucket.logs.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "/aws/cloudtrail/${var.project}"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_iam_role" "cloudtrail" {
  name = "${var.project}-cloudtrail-to-cloudwatch"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "cloudtrail" {
  name = "write-to-log-group"
  role = aws_iam_role.cloudtrail.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
    }]
  })
}

# ✅ Alerts go to an encrypted SNS topic. Subscribe an email address to it after deploying.
resource "aws_sns_topic" "security_alerts" {
  name              = "${var.project}-security-alerts"
  kms_master_key_id = aws_kms_key.main.id
}

# ✅ Alarms on the events that should never happen quietly (CIS 4.x):
#    the root user being used, and console sign-ins without MFA.
locals {
  alarms = {
    root-usage = {
      pattern = "{ $.userIdentity.type = \"Root\" && $.userIdentity.invokedBy NOT EXISTS && $.eventType != \"AwsServiceEvent\" }"
      text    = "The root user was used."
    }
    console-login-without-mfa = {
      pattern = "{ ($.eventName = \"ConsoleLogin\") && ($.additionalEventData.MFAUsed != \"Yes\") && ($.responseElements.ConsoleLogin = \"Success\") }"
      text    = "Someone signed in to the console without MFA."
    }
    break-glass-admin-used = {
      pattern = "{ ($.eventName = \"AssumeRole\") && ($.requestParameters.roleArn = \"*break-glass-admin\") }"
      text    = "The break-glass admin role was assumed."
    }
  }
}

resource "aws_cloudwatch_log_metric_filter" "alarm" {
  for_each       = local.alarms
  name           = each.key
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = each.value.pattern

  metric_transformation {
    name      = each.key
    namespace = "${var.project}/Security"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "alarm" {
  for_each            = local.alarms
  alarm_name          = "${var.project}-${each.key}"
  alarm_description   = each.value.text
  namespace           = "${var.project}/Security"
  metric_name         = each.key
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.security_alerts.arn]
}

# ✅ GuardDuty watches CloudTrail, DNS and VPC flow data for known attack patterns.
resource "aws_guardduty_detector" "this" {
  #checkov:skip=CKV2_AWS_3:Single account, not part of an AWS Organization, so there is no org-wide GuardDuty config to set.
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
}
