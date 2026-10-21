terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  
  backend "s3" {
    bucket         = "mngm-tf-state-119750096239"
    key            = "bootstrap/terraform.tfstate"
    region         = "eu-west-2"
    profile        = "mgmt"
    encrypt        = true
    use_lockfile   = true 
  }
}

provider "aws" {
  region  = "eu-west-2"
  profile = "mgmt" 
  allowed_account_ids = ["119750096239"]
  default_tags {
    tags = {
      Project   = "foundation"
      ManagedBy = "terraform"
      Account = "management"
    }
  }
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "tf_state" {
  bucket = "mngm-tf-state-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "tf_state" {
  bucket     = aws_s3_bucket.tf_state.id
  depends_on = [aws_s3_bucket_public_access_block.tf_state]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Deny"
        Principal = "*"
        Action = "s3:*"
        Resource = [
          aws_s3_bucket.tf_state.arn,
          "${aws_s3_bucket.tf_state.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

output "state_bucket_name" {
  value = aws_s3_bucket.tf_state.bucket
}