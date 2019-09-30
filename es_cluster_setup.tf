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
    Environment = var.environment
  }
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
  nat_instance_enabled = true
  tags = {
    ManagedBy = "Terraform"
    Environment = var.environment
  }
}

locals {
  private_az_subnet_ids  =  module.subnets.private_subnet_ids
  public_az_subnet_ids =  module.subnets.public_subnet_ids
  subdomain = "${var.subdomain}.${var.parent_zone_name}"
}

resource "aws_route53_zone" "dev" {
  name = local.subdomain
  vpc {
    vpc_id = module.vpc.vpc_id
  }
  tags = {
    ManagedBy = "Terraform"
    Environment = var.environment
  }
}

data "aws_acm_certificate" "cert" {
  domain   = "vpn.provenvelocity.com"
  statuses = ["ISSUED"]
}

resource "aws_cloudwatch_log_group" "es-lg" {
  name = var.name

  tags = {
    ManagedBy = "Terraform"
    Environment = var.environment
  }
}


resource "aws_cloudwatch_log_stream" "es-ls" {
  name           = "${var.name}-logstream"
  log_group_name = aws_cloudwatch_log_group.es-lg.name
}

resource "aws_ec2_client_vpn_endpoint" "es" {
  description            = "es-clientvpn"
  server_certificate_arn = data.aws_acm_certificate.cert.arn
  client_cidr_block      = "172.17.0.0/16"

  authentication_options {
    type                       = "certificate-authentication"
    root_certificate_chain_arn = data.aws_acm_certificate.cert.arn
  }

  connection_log_options {
    enabled               = true
    cloudwatch_log_group  = aws_cloudwatch_log_group.es-lg.name
    cloudwatch_log_stream = aws_cloudwatch_log_stream.es-ls.name
  }

  tags = {
    ManagedBy = "Terraform"
    Environment = var.environment
  }
}

resource "aws_ec2_client_vpn_network_association" "es" {
  count = length(local.private_az_subnet_ids)
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.es.id
  subnet_id              = local.private_az_subnet_ids[count.index]
}

module "kms_key" {
  source     = "git::https://github.com/cloudposse/terraform-aws-kms-key.git?ref=tags/0.2.0"
  namespace = var.namespace
  stage     = var.stage
  name      = var.name
  description             = "KMS key for ${var.name}"
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
    AWS = "arn:aws:iam::681100878889:role/OrganizationAccountAccessRole"
  }

  policy_documents = [data.aws_iam_policy_document.resource_full_access.json,
    data.aws_iam_policy_document.base.json]

  tags = {
    ManagedBy = "Terraform"
    Environment = var.environment
  }
}

resource "aws_security_group" "es" {
  name        = "${var.name}-${var.stage}"
  description = "Managed by Terraform"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port = 443
    to_port   = 443
    protocol  = "tcp"

    cidr_blocks = [
      local.private_cidr_block
    ]
  }
}

module "elasticsearch" {
  source                  = "git::https://github.com/provenvelocity/terraform-aws-elasticsearch.git?ref=master"
  namespace               = var.namespace
  stage                   = var.stage
  name                    = "elastic"
  dns_zone_id             = aws_route53_zone.dev.zone_id
  security_groups         = [aws_security_group.es.id]
  vpc_id                  = module.vpc.vpc_id
  subnet_ids              = local.private_az_subnet_ids
  zone_awareness_enabled  = true
  elasticsearch_version   = "6.5"
  instance_type           = "t2.small.elasticsearch"
  instance_count          = 4
  iam_role_arns           = ["arn:aws:iam::681100878889:role/OrganizationAccountAccessRole"]
  iam_actions             = ["es:ESHttpGet", "es:ESHttpPut", "es:ESHttpPost"]
  encrypt_at_rest_enabled = false
  ebs_volume_size = 10
  create_iam_service_linked_role = true
  dedicated_master_enabled = false
  kibana_subdomain_name   = "kibana"
  advanced_options = {
    "rest.action.multi.allow_explicit_index" = true
  }
}









