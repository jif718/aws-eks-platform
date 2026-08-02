#!/usr/bin/env bash
# Tear down the EKS platform stack in one shot.
#
# Terraform's dependency graph only covers resources it created. The AWS Load
# Balancer Controller creates load balancers, ENIs and k8s-traffic-* security
# groups at runtime; they are invisible to Terraform yet block subnet and VPC
# deletion. PodDisruptionBudgets block managed-node-group drain and push it
# into EKS's 15-minute eviction timeout. This script clears both classes of
# blocker, then destroys.
#
# terraform/dns is a separate state and is intentionally NOT destroyed.
set -euo pipefail

REGION="${REGION:-us-west-2}"
CLUSTER="${CLUSTER:-aws-eks-platform}"
TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../ephemeral" && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/aws.yaml}"

log() { printf '%s  %s\n' "$(date +%T)" "$*"; }

# Poll a command until it prints 0. Args: <shell-cmd> [max_tries]
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

# Delete every non-default SG in the VPC. Rules that reference another SG are
# revoked first: k8s-traffic-* is used as a rule source by the cluster/node SGs,
# and that mutual reference is what makes a naive delete fail.
sweep_security_groups() {
  local sgs sg rule
  sgs=$(aws ec2 describe-security-groups --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
        --output text | tr '\t' '\n' | grep -v '^$' || true)
  [ -z "$sgs" ] && return 0

  for sg in $sgs; do
    for rule in $(aws ec2 describe-security-group-rules --region "$REGION" \
                  --filters "Name=group-id,Values=$sg" \
                  --query 'SecurityGroupRules[?ReferencedGroupInfo!=null].SecurityGroupRuleId' \
                  --output text 2>/dev/null); do
      aws ec2 revoke-security-group-ingress --region "$REGION" \
        --group-id "$sg" --security-group-rule-ids "$rule" >/dev/null 2>&1 \
      || aws ec2 revoke-security-group-egress --region "$REGION" \
        --group-id "$sg" --security-group-rule-ids "$rule" >/dev/null 2>&1 || true
    done
  done

  for sg in $sgs; do
    aws ec2 delete-security-group --region "$REGION" --group-id "$sg" >/dev/null 2>&1 \
      && log "  deleted sg $sg" || true
  done
}

# Detached ENIs occasionally linger after their owner is gone.
sweep_detached_enis() {
  local eni
  for eni in $(aws ec2 describe-network-interfaces --region "$REGION" \
               --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" \
               --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null); do
    aws ec2 delete-network-interface --region "$REGION" --network-interface-id "$eni" >/dev/null 2>&1 \
      && log "  deleted eni $eni" || true
  done
}

cd "$TF_DIR"
VPC_ID=$(terraform output -raw vpc_id 2>/dev/null || true)
[ -z "$VPC_ID" ] && { log "no vpc in state, nothing to do"; exit 0; }
log "target vpc: $VPC_ID"

# --- 1. Drain the cluster's cloud-side footprint ---------------------------
if aws eks describe-cluster --region "$REGION" --name "$CLUSTER" >/dev/null 2>&1; then
  aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null

  # ArgoCD self-heal would recreate the Ingresses we are about to delete.
  log "stopping argocd reconciliation"
  kubectl -n argocd scale statefulset argocd-application-controller --replicas=0 >/dev/null 2>&1 || true
  kubectl -n argocd scale deploy argocd-applicationset-controller --replicas=0 >/dev/null 2>&1 || true

  # PDBs protect availability; during teardown they only stall node drain.
  log "removing pod disruption budgets"
  kubectl delete pdb --all -A --ignore-not-found >/dev/null 2>&1 || true

  # Finalizers guarantee the AWS-side delete (ALB + target groups + frontend SG)
  # completes before the K8s object disappears.
  log "deleting ingresses and LoadBalancer services"
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

# Only ELB-owned ENIs matter here; node/NAT/control-plane ENIs are removed by
# terraform destroy itself and must NOT be waited on.
log "waiting for ELB ENI release"
wait_zero "aws ec2 describe-network-interfaces --region $REGION \
  --filters Name=vpc-id,Values=$VPC_ID Name=description,Values='ELB *' \
  --query 'length(NetworkInterfaces)' --output text" 60

# --- 3. Drop the controller's frontend SGs ---------------------------------
# These survive the ALB because their lifecycle is bound to the Ingress object.
log "sweeping controller-created security groups"
sweep_security_groups

# --- 4. Destroy, sweeping orphans between attempts -------------------------
# A blind retry is useless: if a dependency is still there, waiting will not
# remove it. Each retry re-sweeps now that terraform has deleted the cluster
# and node security groups that were holding cross-references.
for attempt in 1 2 3; do
  log "terraform destroy (attempt $attempt)"
  if terraform destroy -auto-approve; then
    log "destroy complete"
    break
  fi
  [ "$attempt" = "3" ] && { log "destroy failed after 3 attempts"; exit 1; }
  log "destroy failed, sweeping orphans before retry"
  sweep_detached_enis
  sweep_security_groups
  sleep 15
done

# --- 5. Verify -------------------------------------------------------------
log "remaining tagged resources (ACM cert and pending-deletion KMS key are expected):"
aws resourcegroupstaggingapi get-resources --region "$REGION" \
  --tag-filters Key=Project,Values=aws-eks-platform \
  --query 'ResourceTagMappingList[].ResourceARN' --output table
