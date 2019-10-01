provider "aws" {
  version = "~> 2.0"
  region = var.region
}

module "label" {
  source     = "git::https://github.com/cloudposse/terraform-null-label.git?ref=tags/0.14.1"
  namespace  = var.namespace
  name       = var.name
  stage      = var.stage
  delimiter  = var.delimiter
  attributes = var.attributes
  tags       = var.tags
}

module "vpc" {
  source     = "git::https://github.com/cloudposse/terraform-aws-vpc.git?ref=tags/0.8.0"
  namespace  = var.namespace
  name       = "${module.label.id}-cluster-vpc"
  stage      = var.stage
  cidr_block = var.cidr_block
  tags = module.label.tags
}

module "subnets" {
  source             = "git::https://github.com/cloudposse/terraform-aws-dynamic-subnets.git?ref=tags/0.16.0"
  availability_zones   = var.availability_zones
  namespace            = var.namespace
  stage                = var.stage
  name                 = "${module.label.id}-cluster-sn"
  vpc_id               = module.vpc.vpc_id
  igw_id               = module.vpc.igw_id
  cidr_block           = module.vpc.vpc_cidr_block
  nat_gateway_enabled  = true
  nat_instance_enabled = false
  tags = module.label.tags
}

resource "aws_route53_zone" "main" {
  name = var.parent_zone_name
  vpc {
    vpc_id = module.vpc.vpc_id
  }
  tags = module.label.tags
}


data "aws_acm_certificate" "cert" {
  domain   = "vpn.${var.parent_zone_name}"
  statuses = ["ISSUED"]
}

resource "aws_cloudwatch_log_group" "es-lg" {
  name = "${module.label.id}-cw-lg"
  tags = module.label.tags
}


resource "aws_cloudwatch_log_stream" "es-ls" {
  name           = "${module.label.id}-cw-ls"
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

  tags = module.label.tags
}

resource "aws_ec2_client_vpn_network_association" "es" {
  count = length(module.subnets.private_subnet_ids)
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.es.id
  subnet_id              = module.subnets.private_subnet_ids[count.index]
}

module "kms_key" {
  source     = "git::https://github.com/cloudposse/terraform-aws-kms-key.git?ref=tags/0.2.0"
  namespace = var.namespace
  stage     = var.stage
  name      = "${module.label.id}-kms-key"
  description             = "KMS key for ${var.name}"
  deletion_window_in_days = 10
  enable_key_rotation     = "true"
  alias                   = "alias/parameter_store_key"
  tags = module.label.tags
}

module "bucket" {
  source  = "git::https://github.com/cloudposse/terraform-aws-s3-bucket.git?ref=tags/0.5.0"
  enabled = "true"

  namespace = var.namespace
  stage     = var.stage
  name      = "${module.label.id}-s3-bucket"

  tags = module.label.tags

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
  name      = "${module.label.id}-s3-role"

  policy_description = "Allow S3 Access"
  role_description   = "IAM role with permissions to perform actions on S3 resources"

  principals = {
    AWS = "arn:aws:iam::681100878889:role/OrganizationAccountAccessRole"
  }

  policy_documents = [data.aws_iam_policy_document.resource_full_access.json,
    data.aws_iam_policy_document.base.json]

  tags = module.label.tags
}

resource "aws_security_group" "es" {
  vpc_id      = module.vpc.vpc_id
  name        = "${module.label.id}search-cluster-sg"
  description = "Elastic Search Limiting Security Group"
  tags = module.label.tags
}

resource "aws_security_group_rule" "ingress_https_cidr_blocks" {
  description       = "Allow inbound traffic from CIDR blocks"
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = concat(module.subnets.public_subnet_cidrs, ["172.17.0.0/16"])
  security_group_id = join("", aws_security_group.es.*.id)
}
resource "aws_security_group_rule" "ingress_ssh_cidr_blocks" {
  description       = "Allow inbound traffic from CIDR blocks"
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = concat(module.subnets.public_subnet_cidrs, ["172.17.0.0/16"])
  security_group_id = join("", aws_security_group.es.*.id)
}

resource "aws_security_group_rule" "egress_cidr_blocks" {
  description       = "Allow outbound traffic from CIDR blocks"
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = join("", aws_security_group.es.*.id)
}

module "elasticsearch" {
  source                  = "git::https://github.com/provenvelocity/terraform-aws-elasticsearch.git?ref=master"
  namespace               = var.namespace
  stage                   = var.stage
  name                    = "elastic"
  dns_zone_id             = aws_route53_zone.main.zone_id
  security_groups         = [aws_security_group.es.id]
  vpc_id                  = module.vpc.vpc_id
  subnet_ids              = module.subnets.private_subnet_ids
  zone_awareness_enabled  = true
  elasticsearch_version   = "6.5"
  instance_type           = "t2.small.elasticsearch"
  instance_count          = 4
  iam_role_arns           = ["arn:aws:iam::681100878889:role/OrganizationAccountAccessRole", module.role.arn ]
  iam_actions             = ["es:ESHttpGet", "es:ESHttpPut", "es:ESHttpPost","es:ESHttpHead"]
  encrypt_at_rest_enabled = false
  ebs_volume_size = 10
  create_iam_service_linked_role = true
  dedicated_master_enabled = false
  kibana_subdomain_name   = "kibana"
  advanced_options = {
    "rest.action.multi.allow_explicit_index" = true
  }
}

####plublic web

resource "aws_security_group" "proxy" {
  vpc_id      = module.vpc.vpc_id
  name        = "${module.label.id}-insance-sg"
  description = "Proxy Search Public Security Group"
  tags = module.label.tags
}

resource "aws_security_group_rule" "ingress_https_public_cidr_blocks" {
  description       = "Allow inbound traffic from public CIDR blocks"
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = [var.cidr_block]
  security_group_id = join("", aws_security_group.proxy.*.id)
}

resource "aws_security_group_rule" "ingress_ssh_public_cidr_blocks" {
  description       = "Allow inbound traffic from public CIDR blocks"
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = ["172.17.0.0/16"]
  security_group_id = join("", aws_security_group.proxy.*.id)
}

resource "aws_security_group_rule" "egress_cidr_public_blocks" {
  description       = "Allow outbound traffic from public CIDR blocks"
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = join("", aws_security_group.proxy.*.id)
}

resource "aws_security_group" "elb" {
  name        = "${module.label.id}-elb-sg"
  description = "elb for proxy"
  vpc_id      = module.vpc.vpc_id

  # HTTP access from anywhere
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["172.17.0.0/16"]
  }

  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


resource "aws_key_pair" "auth" {
  key_name   = var.key_name
  public_key = file(var.public_key_path)
}

# To get the latest Centos7 AMI
data "aws_ami" "centos" {
  owners      = ["679593333241"]
  most_recent = true

  filter {
    name   = "name"
    values = ["CentOS Linux 7 x86_64 HVM EBS *"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

module "proxy-instance" {
  source                      = "git::https://github.com/cloudposse/terraform-aws-ec2-instance-group.git?ref=master"
  name                        = "${module.label.id}-insances"
  region                      = var.region
  ami                         = data.aws_ami.centos.id
  ami_owner                   = "679593333241"
  ssh_key_pair                = var.key_name
  vpc_id                      = module.vpc.vpc_id
  security_groups             = aws_security_group.proxy.*.id
  subnet                      = module.subnets.public_subnet_ids[0]
  instance_type               = "t2.micro"
  additional_ips_count        = 0
  ebs_volume_count            = 1
  allowed_ports               = [22, 443]
  instance_count              = 1
}

module "instance-dns" {
  source    = "git::https://github.com/cloudposse/terraform-aws-route53-cluster-hostname.git?ref=tags/0.3.0"
  name      = var.name
  zone_id   = aws_route53_zone.main.zone_id
  ttl       = 60
  records   = module.proxy_instance.public_dns
}












