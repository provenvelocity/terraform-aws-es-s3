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

module "domain" {
  source               = "git::https://github.com/cloudposse/terraform-aws-route53-cluster-zone.git?ref=tags/0.4.0"
  namespace            = var.namespace
  stage                = var.stage
  name                 = var.name
  parent_zone_name     = var.parent_zone_name
  zone_name            = "$${name}.$${parent_zone_name}"
  tags = {
    ManagedBy = "Terraform"
  }
}

locals {
  public_cidr_block  = cidrsubnet(module.vpc.vpc_cidr_block, 1, 0)
  private_cidr_block = cidrsubnet(module.vpc.vpc_cidr_block, 1, 1)
}

module "public_subnets" {
  source              = "git::https://github.com/cloudposse/terraform-aws-multi-az-subnets.git?ref=tags/0.3.0"
  namespace           = var.namespace
  stage               = var.stage
  name                = var.name
  availability_zones  = var.availability_zones
  vpc_id              = module.vpc.vpc_id
  igw_id              = module.vpc.igw_id
  cidr_block          = local.public_cidr_block
  type                = "public"
  nat_gateway_enabled = "true"
  tags = {
    ManagedBy = "Terraform"
  }
}

module "private_subnets" {
  source             = "git::https://github.com/cloudposse/terraform-aws-multi-az-subnets.git?ref=tags/0.3.0"
  namespace          = var.namespace
  stage              = var.stage
  name               = var.name
  availability_zones = var.availability_zones
  vpc_id             = module.vpc.vpc_id
  cidr_block         = local.private_cidr_block
  type               = "private"
  az_ngw_ids         = module.public_subnets.az_ngw_ids
  az_ngw_count       = 3
  tags = {
    ManagedBy = "Terraform"
  }
}

locals {
  private_az_subnet_ids  = module.private_subnets.az_subnet_ids
  public_az_subnet_ids = module.public_subnets.az_subnet_ids
}

module "kms_key" {
  source    = "git::https://github.com/cloudposse/terraform-aws-kms-key.git?ref=tags/0.2.0"
  namespace = var.namespace
  stage     = var.stage
  name      = var.name
  description             = "KMS key for $${var.name}"
  deletion_window_in_days = 10
  enable_key_rotation     = "true"
  alias                   = "alias/$${var.name}"
  tags = {
    ManagedBy = "Terraform"
  }
}

module "s3-bucket" {
  source  = "git::https://github.com/cloudposse/terraform-aws-s3-bucket.git?ref=tags/0.5.0"
  enabled = "true"

  namespace = var.namespace
  stage     = var.stage
  name      = var.name

  tags = {
    ManagedBy = "Terraform"
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

module "s3-role" {
  source = "git::https://github.com/provenvelocity/terraform-aws-iam-role.git?ref=master"

  enabled   = "true"
  namespace = var.namespace
  stage     = var.stage
  name      = var.name

  principals = {}

  policy_documents = [
    "${data.aws_iam_policy_document.resource_full_access.json}",
    "${data.aws_iam_policy_document.base.json}",
  ]
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

