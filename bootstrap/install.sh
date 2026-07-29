# bootstrap/install.sh
#!/usr/bin/env bash
# Post-terraform cluster bootstrap. Run once after `terraform apply`.
set -euo pipefail

CLUSTER_NAME="aws-eks-platform"
REGION="us-west-2"
KUBECONFIG_PATH="${HOME}/.kube/aws.yaml"

aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME" \
  --kubeconfig "$KUBECONFIG_PATH"
export KUBECONFIG="$KUBECONFIG_PATH"

kubectl apply -f "$(dirname "$0")/storageclass-gp3.yaml"
kubectl patch storageclass gp2 -p \
  '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'

helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm upgrade --install argocd argo/argo-cd \
  --version 9.5.15 \
  --namespace argocd --create-namespace \
  -f "$(dirname "$0")/argocd-values.yaml" \
  --wait
