#!/usr/bin/env bash
# Tear down the EKS platform stack.
#
# Terraform's dependency graph only covers resources it created. Load balancers,
# their ENIs, and the k8s-* security groups are created at runtime by the AWS
# Load Balancer Controller and are invisible to Terraform, yet they block subnet
# and VPC deletion. This script removes them first, then runs terraform destroy.
#
# terraform/dns is a separate state and is intentionally NOT destroyed.
set -euo pipefail

REGION="${REGION:-us-west-2}"
CLUSTER="${CLUSTER:-aws-eks-platform}"
TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/aws.yaml}"

log() { printf '%s  %s\n' "$(date +%T)" "$*"; }

# Poll until the given command prints 0. Args: <cmd> <max_tries>
wait_zero() {
  local cmd="$1" tries="${2:-30}" n
  for _ in $(seq 1 "$tries"); do
    n=$(eval "$cmd" 2>/dev/null || echo 0)
    [ "$n" = "0" ] && return 0
    log "  $n remaining..."
    sleep 10
  done
  log "  timed out, continuing anyway"
}

cd "$TF_DIR"
VPC_ID=$(terraform output -raw vpc_id 2>/dev/null || true)
[ -z "$VPC_ID" ] && { log "no vpc in state, nothing to do"; exit 0; }
log "target vpc: $VPC_ID"

# --- 1. Let the controller delete its own load balancers -------------------
# Going through kubectl is cleaner: finalizers guarantee the AWS-side delete
# completes before the K8s object disappears.
if aws eks describe-cluster --region "$REGION" --name "$CLUSTER" >/dev/null 2>&1; then
  log "cluster alive: deleting ingresses and LoadBalancer services"
  aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null
  kubectl delete ingress --all -A --ignore-not-found --timeout=300s || true
  kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' \
    | while read -r ns name; do
        [ -n "${name:-}" ] && kubectl -n "$ns" delete svc "$name" --timeout=300s || true
      done
else
  log "cluster gone: deleting load balancers directly"
fi

# --- 2. Force-delete anything the controller left behind -------------------
aws elbv2 describe-load-balancers --region "$REGION" \
  --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text \
  | tr '\t' '\n' | while read -r arn; do
      [ -n "$arn" ] && log "deleting $arn" \
        && aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$arn"
    done

# Classic ELBs, created by the in-tree cloud provider for un-annotated Services.
aws elb describe-load-balancers --region "$REGION" \
  --query "LoadBalancerDescriptions[?VPCId=='$VPC_ID'].LoadBalancerName" --output text \
  | tr '\t' '\n' | while read -r name; do
      [ -n "$name" ] && aws elb delete-load-balancer --region "$REGION" --load-balancer-name "$name"
    done

log "waiting for load balancers to disappear"
wait_zero "aws elbv2 describe-load-balancers --region $REGION \
  --query \"length(LoadBalancers[?VpcId=='$VPC_ID'])\" --output text" 30

# --- 3. Wait for ENIs to be released ---------------------------------------
# The ENIs outlive the LB object by several minutes and keep public addresses
# mapped to the VPC, which blocks internet gateway detachment.
log "waiting for ENI release"
wait_zero "aws ec2 describe-network-interfaces --region $REGION \
  --filters Name=vpc-id,Values=$VPC_ID \
  --query 'length(NetworkInterfaces)' --output text" 60

# --- 4. Delete controller-created security groups --------------------------
# Two passes: k8s-traffic-* references k8s-* as a rule source, so the first
# pass can only delete the referenced group.
for pass in 1 2; do
  aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text \
    | tr '\t' '\n' | while read -r sg; do
        [ -n "$sg" ] && aws ec2 delete-security-group --region "$REGION" --group-id "$sg" 2>/dev/null \
          && log "deleted sg $sg (pass $pass)" || true
      done
done

# --- 5. Destroy ------------------------------------------------------------
# Retry once: AWS eventual consistency occasionally reports a dependency that
# has in fact already been removed.
log "running terraform destroy"
terraform destroy -auto-approve || {
  log "first destroy failed, retrying in 60s"
  sleep 60
  terraform destroy -auto-approve
}

# --- 6. Verify -------------------------------------------------------------
log "remaining tagged resources (ACM cert and pending-deletion KMS key are expected):"
aws resourcegroupstaggingapi get-resources --region "$REGION" \
  --tag-filters Key=Project,Values=aws-eks-platform \
  --query 'ResourceTagMappingList[].ResourceARN' --output table