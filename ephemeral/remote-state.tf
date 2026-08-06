# DNS zone and certificate live in a separate state (terraform/dns)
# because they must survive `terraform destroy` of the cluster stack.
data "terraform_remote_state" "dns" {
  backend = "s3"

  config = {
    bucket = "tfstate-765148471972-us-west-2"
    key    = "aws-lab/dns.tfstate"
    region = "us-west-2"
  }
}
