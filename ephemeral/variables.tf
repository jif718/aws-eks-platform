variable "region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-west-2"
}

variable "project" {
  description = "Name prefix applied to all resources"
  type        = string
  default     = "aws-eks-platform"
}
