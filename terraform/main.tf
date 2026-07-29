data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"

  # Excludes Local Zones and Wavelength Zones, which cannot host normal subnets.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}
