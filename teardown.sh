#!/usr/bin/env bash
# Tear down a Gentrail BYOC install. Auto-detects the tier: Evaluation (the
# appliance) is a single CloudFormation stack delete; Production removes the chart,
# the substrate stack (EKS + RDS + VPC), the retained S3 buckets, and schedules
# the KMS key for deletion. Destructive; the prod KMS step is irreversible.
#
# Needs: aws (+ kubectl, helm for the Production tier).
# Run:   ./teardown.sh                 # tears down STACK=gentrail
#
# Config (env vars, all optional):
#   REGION      AWS region                  (default us-west-2)
#   STACK       CloudFormation stack name   (default gentrail)
#   NAMESPACE   k8s namespace               (default gentrail)
#   TIER        eval|prod                   (default: auto-detect from the stack)
#   YES=1       skip the confirmation prompt
set -euo pipefail

REGION="${REGION:-us-west-2}"
export AWS_DEFAULT_REGION="$REGION" AWS_REGION="$REGION"
STACK="${STACK:-gentrail}"
NAMESPACE="${NAMESPACE:-gentrail}"

command -v aws >/dev/null || { echo "missing required tool: aws" >&2; exit 1; }

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"

# The appliance stack outputs Tier=eval, the EKS substrate Tier=prod; older stacks
# output neither, so anything but eval is treated as prod.
TIER="${TIER:-}"
if [ -z "$TIER" ]; then
  TIER="$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`Tier`].OutputValue' --output text 2>/dev/null || true)"
  [ "$TIER" = eval ] || TIER=prod
fi

if [ "$TIER" = eval ]; then
  echo "About to tear down the Gentrail evaluation appliance in account $ACCOUNT:"
  echo "  stack: $STACK (one EC2 + its VPC; all data on the node is destroyed)"
  if [ "${YES:-}" != "1" ]; then
    read -r -p "Type the stack name (${STACK}) to confirm: " ans
    [ "$ans" = "$STACK" ] || { echo "aborted."; exit 1; }
  fi
  echo "==> delete appliance stack $STACK (~3-5 min)"
  aws cloudformation delete-stack --stack-name "$STACK" --region "$REGION"
  aws cloudformation wait stack-delete-complete --stack-name "$STACK" --region "$REGION"
  echo "==> teardown complete"
  exit 0
fi

for t in kubectl helm; do command -v "$t" >/dev/null || { echo "missing required tool: $t" >&2; exit 1; }; done

out() {
    aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text 2>/dev/null
}

# Resolve cluster, RDS, and VPC from the stack rather than assuming names (an
# install with a custom STACK names them after the cluster, not "gentrail").
CLUSTER="$(out ClusterName)"
[ -n "$CLUSTER" ] && [ "$CLUSTER" != "None" ] || CLUSTER="$STACK"
RDS="$(aws cloudformation describe-stack-resources --stack-name "$STACK" --region "$REGION" \
    --query "StackResources[?ResourceType=='AWS::RDS::DBInstance'].PhysicalResourceId | [0]" --output text 2>/dev/null)"
VPC="$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
    --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || true)"

echo "About to tear down the Gentrail install in account $ACCOUNT:"
echo "  stack:   $STACK"
echo "  cluster: $CLUSTER"
echo "  rds:     ${RDS:-<none>}"
echo "This deletes the EKS cluster, RDS, VPC, and S3 buckets, and schedules the KMS key for deletion."
if [ "${YES:-}" != "1" ]; then
    read -r -p "Type the stack name (${STACK}) to confirm: " ans
    [ "$ans" = "$STACK" ] || { echo "aborted."; exit 1; }
fi

# Capture retained-bucket + KMS names before the stack (and its outputs) are gone.
BUCKETS="$(for k in EvidenceBucketName TraceArchiveBucketName AlbLogsBucketName VpcFlowLogsBucketName; do out "$k"; done | grep . || true)"
KMS="$(out KmsKeyArn)"

echo "==> helm uninstall (drops pods; the load balancer controller then removes its ALBs)"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1 || true
helm uninstall gentrail -n "$NAMESPACE" 2>/dev/null || true
kubectl delete namespace "$NAMESPACE" --ignore-not-found 2>/dev/null || true

# Wait for the controller to drain its ALBs: an ALB ENI left in a subnet blocks
# the CFN VPC/subnet delete, so the stack delete fails without this.
if [ -n "${VPC:-}" ] && [ "$VPC" != "None" ]; then
    echo "==> waiting for load balancers in $VPC to deprovision"
    for _ in $(seq 1 60); do
        albs="$(aws elbv2 describe-load-balancers --region "$REGION" \
            --query "LoadBalancers[?VpcId=='$VPC'].LoadBalancerArn" --output text 2>/dev/null || true)"
        [ -z "$albs" ] && break
        sleep 5
    done
fi

if [ -n "${RDS:-}" ] && [ "$RDS" != "None" ]; then
    echo "==> disable RDS deletion protection on $RDS"
    aws rds modify-db-instance --db-instance-identifier "$RDS" --no-deletion-protection --apply-immediately >/dev/null 2>&1 || true
fi

echo "==> delete substrate stack $STACK (EKS + RDS + VPC, ~10-15 min)"
aws cloudformation delete-stack --stack-name "$STACK" --region "$REGION"
aws cloudformation wait stack-delete-complete --stack-name "$STACK" --region "$REGION"

echo "==> delete retained S3 buckets"
while IFS= read -r b; do
    [ -z "$b" ] && continue
    aws s3 rm "s3://$b" --recursive >/dev/null 2>&1 || true
    aws s3api delete-bucket --bucket "$b" --region "$REGION" 2>/dev/null && echo "    deleted $b" || true
done <<< "$BUCKETS"

if [ -n "${KMS:-}" ] && [ "$KMS" != "None" ]; then
    echo "==> schedule KMS key for deletion (7-day window, irreversible once it completes)"
    aws kms schedule-key-deletion --key-id "$KMS" --pending-window-in-days 7 >/dev/null 2>&1 || true
fi

echo "==> teardown complete"
