output "account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "available_azs" {
  value = data.aws_availability_zones.available.names
}
