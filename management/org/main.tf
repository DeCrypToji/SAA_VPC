# management/org/main.tf

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket       = "mngm-tf-state-119750096239"
    key          = "org/terraform.tfstate"
    region       = "eu-west-2"
    profile      = "mgmt"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region              = "eu-west-2"
  profile             = "mgmt"
  allowed_account_ids = ["119750096239"]

  default_tags {
    tags = {
      Project   = "foundation"
      ManagedBy = "terraform"
      Account   = "management"
    }
  }
}

# ───────────── PHASE 1: IMPORT EXISTING ─────────────

import {
  to = aws_organizations_organization.this
  id = "o-19hkst9d7c"
}

import {
  to = aws_organizations_policy.deny_leave_close
  id = "p-zpmb8tps"
}

import {
  to = aws_organizations_policy_attachment.deny_leave_close_root
  id = "r-az0i:p-zpmb8tps"
}

resource "aws_organizations_organization" "this" {
  feature_set                   = "ALL"
  enabled_policy_types          = ["SERVICE_CONTROL_POLICY"]
  aws_service_access_principals = ["cloudtrail.amazonaws.com"]

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_organizations_policy" "deny_leave_close" {
  name        = "DenyLeaveAndCloseAccount"
  description = "Prevents member accounts from leaving the organization and self closure"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        "Effect" : "Deny",
        "Action" : ["organizations:LeaveOrganization", "account:CloseAccount"],
        "Resource" : "*"
      }
    ]
  })
}

resource "aws_organizations_policy_attachment" "deny_leave_close_root" {
  policy_id = aws_organizations_policy.deny_leave_close.id
  target_id = aws_organizations_organization.this.roots[0].id
}

# ───────────── PHASE 2: CREATE NEW (add only after Phase 1 = zero diff) ─────────────

resource "aws_organizations_organizational_unit" "workloads" {
  name      = "Workloads"
  parent_id = aws_organizations_organization.this.roots[0].id
}

resource "aws_organizations_account" "workloads" {
  name              = "senpai-workloads"
  email             = "lowkeyjanz+aws-workloads@gmail.com"
  parent_id         = aws_organizations_organizational_unit.workloads.id
  role_name         = "OrganizationAccountAccessRole"
  close_on_deletion = true
  tags = {
    Account = "workloads"
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [role_name, iam_user_access_to_billing]
  }
}

output "workloads_account_id" {
  value = aws_organizations_account.workloads.id
}


# ───────────── PHASE 3: CREATE NEW OU(for Log-Archive) ─────────────

resource "aws_organizations_organizational_unit" "security" {
  name      = "Security"
  parent_id = aws_organizations_organization.this.roots[0].id
}

resource "aws_organizations_account" "log_archive" {
  name              = "senpai-log-archive"
  email             = "lowkeyjanz+aws-log-archive@gmail.com"
  parent_id         = aws_organizations_organizational_unit.security.id
  role_name         = "OrganizationAccountAccessRole"
  close_on_deletion = true
  tags = {
    Account = "log-archive"
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [role_name, iam_user_access_to_billing]
  }
}

output "log_archive_account_id" {
  value = aws_organizations_account.log_archive.id
}