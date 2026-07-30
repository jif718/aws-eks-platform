#!/usr/bin/env bash
# Post-terraform cluster bootstrap. Run once after `terraform apply`.
# Everything after the root app is reconciled by ArgoCD from gitops-lab-aws.
set -euo pipefail

REGION="${REGION:-us-west-2}"
CLUSTER="${CLUSTER:-aws-eks-platform}"
ARGOCD_VERSION="10.2.1"
GITOPS_ROOT_APP="https://raw.githubusercontent.com/jif718/gitops-lab-aws/main/root-app.yaml"
KUBECONFIG_PATH="${HOME}/.kube/aws.yaml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '%s  %s\n' "$(date +%T)" "$*"; }

# --- 1. Kubeconfig ---------------------------------------------------------
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" \
  --kubeconfig "$KUBECONFIG_PATH" >/dev/null
export KUBECONFIG="$KUBECONFIG_PATH"

# Guard against operating on the wrong cluster (learned the hard way).
CTX=$(kubectl config current-context)
case "$CTX" in
  *"$CLUSTER"*) log "context: $CTX" ;;
  *) log "unexpected context: $CTX"; exit 1 ;;
esac

# --- 2. Wait for nodes -----------------------------------------------------
log "waiting for nodes to be Ready"
kubectl wait --for=condition=Ready nodes --all --timeout=300s

# --- 3. Storage ------------------------------------------------------------
kubectl apply -f "$SCRIPT_DIR/storageclass-gp3.yaml"
kubectl patch storageclass gp2 -p \
  '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' \
  2>/dev/null || true   # gp2 may already be non-default on re-runs

# --- 4. ArgoCD -------------------------------------------------------------
helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
helm upgrade --install argocd argo/argo-cd \
  --version "$ARGOCD_VERSION" \
  --namespace argocd --create-namespace \
  -f "$SCRIPT_DIR/argocd-values.yaml" \
  --wait --timeout 10m

# --- 5. Root app: hand over to GitOps --------------------------------------
# The only manually-applied Application; everything else comes from Git.
kubectl apply -f "$GITOPS_ROOT_APP"

# --- 6. Status -------------------------------------------------------------
log "initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo

log "waiting for platform apps to sync (ALB may take ~3 min)"
kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy \
  app/aws-load-balancer-controller app/external-dns --timeout=600s || true

log "done. UI will be at https://argocd.aws.ololol.lol once the ALB is provisioned."