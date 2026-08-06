# aws-infra

Terraform-managed AWS infrastructure for the EKS platform.

Scope: VPC, EKS control plane, node groups, IAM/IRSA, ECR, ALB, Route53.
Cluster workloads are managed by ArgoCD in the `gitops-lab` repository.

Region: us-west-2
