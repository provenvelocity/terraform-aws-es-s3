variable "namespace" {
  type        = string
  description = "Namespace (e.g. `eg` or `cp`)"
  default     = "hw"
}

variable "stage" {
  type        = string
  description = "Stage (e.g. `prod`, `dev`, `staging`)"
  default     = "dev"
}

variable "name" {
  type        = string
  description = "Name  (e.g. `app` or `cluster`)"
  default     = "es-cluster"
}

variable "delimiter" {
  type        = string
  default     = "-"
  description = "Delimiter to be used between `namespace`, `stage`, `name` and `attributes`"
}

variable "environment" {
  type        = string
  description = "Environment Name  (e.g. `app-dev` or `cluster-test`)"
  default     = "es-cluster-dev"
}

variable "subdomain" {
  type        = string
  description = "Subdomain Name  (e.g. `dev` or `insternal`)"
  default     = "dev"
}

variable "attributes" {
  type        = list(string)
  default     = []
  description = "Additional attributes (e.g. `1`)"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Additional tags (e.g. `{ BusinessUnit = \"XYZ\" }`"
}


variable "region" {
  type        = string
  default     = "us-west-2"
  description = "If specified, the AWS region this bucket should reside in. Otherwise, the region used by the callee"
}

variable "availability_zones" {
  type        = "list"
  default     = ["us-west-2b", "us-west-2c"]
  description = "List of Availability Zones (e.g. `['us-east-1a', 'us-east-1b', 'us-east-1c']`)"
}


variable "cidr_block" {
  type        = "string"
  default     = "10.0.0.0/16"
  description = "Base CIDR block which is divided into subnet CIDR blocks (e.g. `10.0.0.0/16`)"
}

variable "parent_zone_name" {
  type        = string
  description = "Parent zone name"
  default     = "provenvelocity.com"
}

