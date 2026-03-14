# terragrunt.hcl in infra/

terraform {
  # Use this folder as the Terraform module source
  source = "./"
}

# Common settings / defaults
locals {
  region       = "ap-south-1"
  project_name = "jenkins-cicd"     # override if you want
  account_id   = "442042504916"                 # OPTIONAL: fill in or leave empty if variable has no default
}

inputs = {
  region       = local.region
  project_name = local.project_name
  account_id   = local.account_id
}