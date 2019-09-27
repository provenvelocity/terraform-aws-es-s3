
#all
  namespace               = "eg"
  stage                   = "dev"
  name                    = "es-$${stage}"
#aws
  region = "us-west-1"
  availability_zones = ["us-west-1b", "us-west-1c"]
  cidr_block = "10.0.0.0/16"
#domain
  parent_zone_name  = "provenvelocity.com"
#elastic search Vars
