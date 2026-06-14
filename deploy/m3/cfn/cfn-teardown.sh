#!/usr/bin/env bash
# Tear down a BYOC validation stack created by cfn-deploy.sh. Best-effort: each
# step is guarded so a partially-created or already-deleted stack still cleans up.
#
# Order matters. (1) chart + namespace first so PVCs/EBS and pod ENIs release
# before the cluster delete. (2) drop RDS WITHOUT a final snapshot, so the stack
# delete does not stall on "instance not available" or leave a snapshot behind
# (the template keeps DeletionPolicy:Snapshot for real customers; we bypass it).
# (3) delete the stack. (4) sweep the DeletionPolicy:Retain orphans CloudFormation
# leaves on purpose (DDB tables, evidence + trace-archive buckets, KMS key) --
# see README.md.
set -uo pipefail

STACK="${STACK:-gentrail-byoc-validate}"
REGION="${REGION:-us-west-2}"
CLUSTER="${CLUSTER:-gtbx}"
PREFIX="${PREFIX:-$CLUSTER}"
NAMESPACE="${NAMESPACE:-gentrail}"
export KUBECONFIG="${KUBECONFIG:-/tmp/${STACK}-kubeconfig}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"

log() { printf '==> %s\n' "$*"; }

if [ -f "$KUBECONFIG" ]; then
  log "helm uninstall + delete namespace (releases PVCs/EBS + ENIs)"
  helm uninstall gentrail -n "$NAMESPACE" 2>/dev/null || true
  kubectl delete namespace "$NAMESPACE" --timeout=180s 2>/dev/null || true
fi

rds_id=$(aws cloudformation describe-stack-resources --stack-name "$STACK" --region "$REGION" \
  --query 'StackResources[?ResourceType==`AWS::RDS::DBInstance`].PhysicalResourceId' \
  --output text 2>/dev/null)
if [ -n "${rds_id:-}" ] && [ "$rds_id" != "None" ]; then
  log "delete RDS $rds_id (skip final snapshot)"
  aws rds delete-db-instance --db-instance-identifier "$rds_id" \
    --skip-final-snapshot --delete-automated-backups --region "$REGION" >/dev/null 2>&1 || true
fi

log "delete-stack $STACK"
aws cloudformation delete-stack --stack-name "$STACK" --region "$REGION" 2>/dev/null || true
aws cloudformation wait stack-delete-complete --stack-name "$STACK" --region "$REGION" 2>/dev/null || true

log "sweep retained DDB tables ($PREFIX-*)"
aws dynamodb list-tables --region "$REGION" --query 'TableNames' --output text 2>/dev/null \
  | tr '\t' '\n' | grep -E "^${PREFIX}-(traces|violations|agent-stats|policy-rules|graph|api-keys)$" \
  | while read -r t; do
      aws dynamodb delete-table --table-name "$t" --region "$REGION" >/dev/null 2>&1 && echo "  deleted $t"
    done

log "sweep evidence bucket"
bucket="${CLUSTER}-evidence-${ACCOUNT}-${REGION}"
if aws s3api head-bucket --bucket "$bucket" --region "$REGION" 2>/dev/null; then
  aws s3api delete-objects --bucket "$bucket" --region "$REGION" --bypass-governance-retention \
    --delete "$(aws s3api list-object-versions --bucket "$bucket" --region "$REGION" \
      --query '{Objects: (Versions||`[]`)[].{Key:Key,VersionId:VersionId}, DeleteMarkers: (DeleteMarkers||`[]`)[].{Key:Key,VersionId:VersionId}}' \
      --output json 2>/dev/null)" >/dev/null 2>&1 || true
  aws s3api delete-bucket --bucket "$bucket" --region "$REGION" 2>/dev/null && echo "  deleted $bucket"
fi

log "sweep trace-archive bucket"
bucket="${CLUSTER}-trace-archive-${ACCOUNT}-${REGION}"
if aws s3api head-bucket --bucket "$bucket" --region "$REGION" 2>/dev/null; then
  aws s3 rm "s3://$bucket" --recursive --region "$REGION" >/dev/null 2>&1 || true
  aws s3api delete-bucket --bucket "$bucket" --region "$REGION" 2>/dev/null && echo "  deleted $bucket"
fi

log "sweep RDS final snapshots ($STACK-*)"
aws rds describe-db-snapshots --region "$REGION" --snapshot-type manual \
  --query "DBSnapshots[?starts_with(DBSnapshotIdentifier,'${STACK}')].DBSnapshotIdentifier" \
  --output text 2>/dev/null | tr '\t' '\n' | grep . \
  | while read -r s; do
      aws rds delete-db-snapshot --db-snapshot-identifier "$s" --region "$REGION" >/dev/null 2>&1 && echo "  deleted $s"
    done

log "schedule deletion of the substrate KMS key ($CLUSTER)"
for k in $(aws kms list-keys --region "$REGION" --query 'Keys[].KeyId' --output text 2>/dev/null | tr '\t' '\n'); do
  desc=$(aws kms describe-key --key-id "$k" --region "$REGION" \
    --query 'KeyMetadata.[KeyState,Description]' --output text 2>/dev/null)
  case "$desc" in
    Enabled*"substrate KEK - ${CLUSTER}")
      aws kms schedule-key-deletion --key-id "$k" --pending-window-in-days 7 --region "$REGION" \
        >/dev/null 2>&1 && echo "  scheduled $k (7-day window)";;
  esac
done

log "sweep CloudWatch log groups ($CLUSTER)"
aws logs describe-log-groups --region "$REGION" \
  --query "logGroups[?contains(logGroupName,'${CLUSTER}')].logGroupName" --output text 2>/dev/null \
  | tr '\t' '\n' | grep . \
  | while read -r lg; do
      aws logs delete-log-group --log-group-name "$lg" --region "$REGION" 2>/dev/null && echo "  deleted $lg"
    done

log "teardown complete"
