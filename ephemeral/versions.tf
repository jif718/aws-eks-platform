terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Backend config cannot use variables — values must be literals.
  backend "s3" {
    bucket       = "tfstate-765148471972-us-west-2"
    key          = "aws-eks-platform/terraform.tfstate"
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true
  }
}
