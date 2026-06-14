#!/usr/bin/env bash
# Uninstall a Gentrail M3 deployment. Five phases, each requires y/n confirmation.
#
# 1) helm uninstall (drops Pods + K8s resources)
# 2) drain RDS deletion protection
# 3) delete the substrate CFN stack (retains S3 buckets + KMS key + RDS snapshot)
# 4) optionally empty + delete the retained S3 buckets
# 5) optionally schedule the substrate KMS key for deletion (crypto-shred)
#
# The cross-account scanner role is part of the substrate stack since
# the trust-role + substrate were collapsed into a single template,
# so it's deleted automatically in phase 3.
#
# Usage:
#   ./uninstall.sh <substrate-stack-name>
set -euo pipefail

SUBSTRATE_STACK="${1:?usage: $0 <substrate-stack-name>}"

confirm () {
    read -p "$1 [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "skipped."; return 1; }
}

# Phase 0: capture stack outputs BEFORE they're lost when we delete the stack
get_output () {
    aws cloudformation describe-stacks --stack-name "$1" \
        --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text 2>/dev/null || true
}
EVIDENCE_BUCKET=$(get_output "$SUBSTRATE_STACK" EvidenceBucketName)
TRACE_ARCHIVE_BUCKET=$(get_output "$SUBSTRATE_STACK" TraceArchiveBucketName)
ALB_LOGS_BUCKET=$(get_output "$SUBSTRATE_STACK" AlbLogsBucketName)
VPC_FLOW_LOGS_BUCKET=$(get_output "$SUBSTRATE_STACK" VpcFlowLogsBucketName)
KMS_KEY_ARN=$(get_output "$SUBSTRATE_STACK" KmsKeyArn)

echo "==> Phase 1: helm uninstall"
if confirm "Run 'helm uninstall gentrail -n gentrail'?"; then
    helm uninstall gentrail -n gentrail || true
    kubectl delete namespace gentrail --ignore-not-found || true
fi

echo
echo "==> Phase 2: disable RDS deletion protection"
if confirm "Disable RDS deletion protection on gentrail-rds?"; then
    aws rds modify-db-instance --db-instance-identifier gentrail-rds \
        --no-deletion-protection --apply-immediately || true
fi

echo
echo "==> Phase 3: delete substrate CFN stack"
if confirm "Delete CFN stack ${SUBSTRATE_STACK}?"; then
    aws cloudformation delete-stack --stack-name "$SUBSTRATE_STACK"
    aws cloudformation wait stack-delete-complete --stack-name "$SUBSTRATE_STACK"
fi

echo
echo "==> Phase 4: empty + delete retained S3 buckets"
for BUCKET in "$EVIDENCE_BUCKET" "$TRACE_ARCHIVE_BUCKET" "$ALB_LOGS_BUCKET" "$VPC_FLOW_LOGS_BUCKET"; do
    [ -z "$BUCKET" ] && continue
    if aws s3 ls "s3://${BUCKET}" >/dev/null 2>&1; then
        if confirm "Empty + delete s3://${BUCKET}?"; then
            aws s3 rm "s3://${BUCKET}" --recursive
            aws s3api delete-bucket --bucket "${BUCKET}"
        fi
    fi
done

echo
echo "==> Phase 5: CRYPTO-SHRED - schedule substrate KMS key for deletion"
echo "    This is the irreversible step. Once the key is deleted (7-30 day"
echo "    waiting period), all SSE-KMS-encrypted backups become permanently"
echo "    unreadable. Read deploy/m3/helm/gentrail/runbook.md before proceeding."
if confirm "Schedule KMS key for deletion (30-day waiting period)?"; then
    if [ -n "$KMS_KEY_ARN" ]; then
        aws kms schedule-key-deletion --key-id "$KMS_KEY_ARN" --pending-window-in-days 30 || true
    else
        echo "  warning: could not read KmsKeyArn from stack — skipping KMS key deletion" >&2
        echo "  (if you BYOK'd, the key wasn't ours to delete; if not, look up the key manually)" >&2
    fi
fi


echo
echo "==> uninstall complete"
