output "account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "available_azs" {
  value = data.aws_availability_zones.available.names
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnet_ids" {
  value = module.vpc.private_subnets
}

output "public_subnet_ids" {
  value = module.vpc.public_subnets
}

output "domain_name" {
  value = "aws.ololol.lol"
}

output "zone_id" {
  value = data.terraform_remote_state.dns.outputs.zone_id
}

output "certificate_arn" {
  value = data.terraform_remote_state.dns.outputs.certificate_arn
}

output "alb_controller_role_arn" {
  value = module.alb_controller_irsa.arn
}

output "external_dns_role_arn" {
  value = module.external_dns_irsa.arn
}