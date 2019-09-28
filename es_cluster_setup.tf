provider "aws" {
  version = "~> 2.0"
  region = var.region
}

module "vpc" {
  source     = "git::https://github.com/cloudposse/terraform-aws-vpc.git?ref=tags/0.8.0"
  namespace  = var.namespace
  name       = var.name
  stage      = var.stage
  cidr_block = var.cidr_block
  tags = {
    ManagedBy = "Terraform"
  }
}

resource "aws_route53_zone" "main" {
  name = var.parent_zone_name
}

resource "aws_route53_zone" "dev" {
  name = "$${var.environment}.$${var.parent_zone_name}"

  tags = {
    ManagedBy = "Terraform"
    Environment = var.environment
  }
}

resource "aws_route53_record" "dev-ns" {
  zone_id = "${aws_route53_zone.main.zone_id}"
  name    = "$${var.environment}.$${var.parent_zone_name}"
  type    = "NS"
  ttl     = "30"

  records = [
    "${aws_route53_zone.dev.name_servers.0}",
    "${aws_route53_zone.dev.name_servers.1}",
    "${aws_route53_zone.dev.name_servers.2}",
    "${aws_route53_zone.dev.name_servers.3}",
  ]
}

locals {
  public_cidr_block  = cidrsubnet(module.vpc.vpc_cidr_block, 1, 0)
  private_cidr_block = cidrsubnet(module.vpc.vpc_cidr_block, 1, 1)
}

module "subnets" {
  source             = "git::https://github.com/cloudposse/terraform-aws-dynamic-subnets.git?ref=tags/0.16.0"
  availability_zones   = var.availability_zones
  namespace            = var.namespace
  stage                = var.stage
  name                 = var.name
  vpc_id               = module.vpc.vpc_id
  igw_id               = module.vpc.igw_id
  cidr_block           = module.vpc.vpc_cidr_block
  nat_gateway_enabled  = true
  nat_instance_enabled = false
  tags = {
    ManagedBy = "Terraform"
    Environment = var.environment
  }
}

locals {
  private_az_subnet_ids  =  module.subnets.private_subnet_cidrs
  public_az_subnet_ids =  module.subnets.public_subnet_cidrs
}

module "kms_key" {
  source     = "git::https://github.com/cloudposse/terraform-aws-kms-key.git?ref=tags/0.2.0"
  namespace = var.namespace
  stage     = var.stage
  name      = var.name
  description             = "KMS key for $${var.name}"
  deletion_window_in_days = 10
  enable_key_rotation     = "true"
  alias                   = "alias/parameter_store_key"
  tags = {
    ManagedBy = "Terraform"
    Environment = var.environment
  }
}

module "bucket" {
  source  = "git::https://github.com/cloudposse/terraform-aws-s3-bucket.git?ref=tags/0.5.0"
  enabled = "true"

  namespace = var.namespace
  stage     = var.stage
  name      = var.name

  tags = {
    ManagedBy = "Terraform"
    Environment = var.environment
  }

  versioning_enabled = "false"
  user_enabled       = "false"

  sse_algorithm      = "aws:kms"
  kms_master_key_arn = "${module.kms_key.key_arn}"
}

data "aws_iam_policy_document" "resource_full_access" {
  statement {
    sid       = "FullAccess"
    effect    = "Allow"
    resources = ["${module.bucket.bucket_arn}/*"]

    actions = [
      "s3:PutObject",
      "s3:PutObjectAcl",
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:GetBucketLocation",
      "s3:AbortMultipartUpload",
    ]
  }
}

data "aws_iam_policy_document" "base" {
  statement {
    sid = "BaseAccess"

    actions = [
      "s3:ListBucket",
      "s3:ListBucketVersions",
    ]

    resources = ["${module.bucket.bucket_arn}"]
    effect    = "Allow"
  }
}

module "role" {
  source = "git::https://github.com/provenvelocity/terraform-aws-iam-role.git?ref=master"

  enabled   = "true"
  namespace = var.namespace
  stage     = var.stage
  name      = var.name

  policy_description = "Allow S3 FullAccess"
  role_description   = "IAM role with permissions to perform actions on S3 resources"

  principals = {
    AWS = "arn:aws:iam::123456789012:role/workers"
  }

  policy_documents = [data.aws_iam_policy_document.resource_full_access.json,
    data.aws_iam_policy_document.base.json]

  tags = {
    ManagedBy = "Terraform"
    Environment = var.environment
  }
}

# module "elasticsearch" {
#   source                  = "git::https://github.com/cloudposse/terraform-aws-elasticsearch.git?ref=tags/0.5.0"
#   namespace               = var.namespace
#   stage                   = var.stage
#   name                    = var.name
#   dns_zone_id             = module.domain.zone_id
#   security_groups         = [module.vpc.vpc_default_security_group_id]
#   vpc_id                  = module.vpc.vpc_id
#   subnet_ids              = private_az_subnet_ids
#   zone_awareness_enabled  = "true"
#   elasticsearch_version   = "6.5"
#   instance_type           = "t2.small.elasticsearch"
#   instance_count          = 4
#   iam_role_arns           = ["arn:aws:iam::XXXXXXXXX:role/ops", "arn:aws:iam::XXXXXXXXX:role/dev"]
#   iam_actions             = ["es:ESHttpGet", "es:ESHttpPut", "es:ESHttpPost"]
#   encrypt_at_rest_enabled = true
#   kibana_subdomain_name   = "kibana"
#   advanced_options {
#     "rest.action.multi.allow_explicit_index" = "true"
#   }
# }

