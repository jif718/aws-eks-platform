# bootstrap/teardown.sh
#!/usr/bin/env bash
# ALBs are created by the controller, not Terraform. They hold ENIs in the
# subnets, so VPC deletion fails unless Ingresses are removed first.
set -euo pipefail

export KUBECONFIG="${HOME}/.kube/aws.yaml"

kubectl delete ingress --all -A --ignore-not-found
echo "waiting for ALB deletion..."
sleep 90

cd "$(dirname "$0")/../terraform"
terraform destroy
