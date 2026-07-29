terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Separate state: these resources outlive the ephemeral cluster stack.
  backend "s3" {
    bucket       = "tfstate-765148471972-us-west-2"
    key          = "aws-eks-platform/dns.tfstate"
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-west-2"

  default_tags {
    tags = {
      Project   = "aws-eks-platform"
      ManagedBy = "terraform"
    }
  }
}
