#!/usr/bin/env bash
# Post-terraform cluster bootstrap. Run once after `terraform apply`.
# Everything after the root app is reconciled by ArgoCD from aws-gitops.
set -euo pipefail
trap 'echo "FAILED at line $LINENO" >&2' ERR

REGION="${REGION:-us-west-2}"
CLUSTER="${CLUSTER:-aws-lab}"                   # must match var.project in ephemeral/
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-765148471972}"
ARGOCD_VERSION="10.2.1"
EXPECTED_NODES="${EXPECTED_NODES:-2}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-${HOME}/.kube/aws.yaml}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '%s  %s\n' "$(date +%T)" "$*"; }

# --- 0. Preflight ----------------------------------------------------------
for bin in aws kubectl helm; do
  command -v "$bin" >/dev/null || { log "missing binary: $bin"; exit 1; }
done

ACCT=$(aws sts get-caller-identity --query Account --output text)
[ "$ACCT" = "$AWS_ACCOUNT_ID" ] || { log "wrong AWS account: $ACCT"; exit 1; }

# --- 1. Kubeconfig ---------------------------------------------------------
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" \
  --kubeconfig "$KUBECONFIG_PATH" >/dev/null
export KUBECONFIG="$KUBECONFIG_PATH"

CTX=$(kubectl config current-context)
case "$CTX" in
  *"$CLUSTER"*) log "context: $CTX" ;;
  *) log "unexpected context: $CTX"; exit 1 ;;
esac

# --- 2. Wait for nodes -----------------------------------------------------
# `wait --all` returns success on zero nodes, so count first.
log "waiting for $EXPECTED_NODES nodes to register"
for _ in $(seq 60); do
  [ "$(kubectl get nodes --no-headers 2>/dev/null | wc -l)" -ge "$EXPECTED_NODES" ] && break
  sleep 5
done
kubectl wait --for=condition=Ready nodes --all --timeout=300s

# --- 3. Storage ------------------------------------------------------------
# EBS CSI driver comes from the EKS addon managed by terraform.
kubectl get csidriver ebs.csi.aws.com >/dev/null \
  || { log "ebs.csi.aws.com not found — check terraform addon"; exit 1; }

# Demote gp2 BEFORE promoting gp3 to avoid a two-default window.
# Tolerate its absence: EKS may stop shipping a default gp2 StorageClass.
kubectl patch storageclass gp2 -p \
  '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' || true
kubectl apply -f "$SCRIPT_DIR/storageclass-gp3.yaml"

# --- 4. ArgoCD -------------------------------------------------------------
helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
helm upgrade --install argocd argo/argo-cd \
  --version "$ARGOCD_VERSION" \
  --namespace argocd --create-namespace \
  -f "$SCRIPT_DIR/argocd-values.yaml" \
  --atomic --wait --timeout 10m

# --- 5. Root app: hand over to GitOps --------------------------------------
# The only manually-applied Application; vendored here so bootstrap is
# self-contained and pinned alongside the terraform that created the cluster.
kubectl apply -f "$SCRIPT_DIR/root-app.yaml"

# --- 6. Status -------------------------------------------------------------
# platform-manifests owns the argocd Ingress, so it is what actually gates the
# UI URL printed below.
PLATFORM_APPS="aws-load-balancer-controller external-dns platform-manifests"
for app in $PLATFORM_APPS; do
  kubectl -n argocd wait --for=create "application/$app" --timeout=300s
done
log "waiting for platform apps to become Healthy (ALB ~3 min)"
for app in $PLATFORM_APPS; do
  kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy \
    "application/$app" --timeout=600s
done

log "done. UI: https://argocd.aws.ololol.lol"
log "admin password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"