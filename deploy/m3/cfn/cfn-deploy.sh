#!/usr/bin/env bash
# Stand up the BYOC substrate (CloudFormation -> EKS) and deploy the gentrail
# chart onto it, for end-to-end validation. Idempotent: reruns reuse an existing
# stack and helm-upgrade in place. Pair with cfn-teardown.sh.
#
# This is a VALIDATION harness, not a customer install: it pulls images from our
# private GHCR via `gh` and sources the license JWT from our Secrets Manager. A
# real customer mirrors the images and supplies their own license. See README.md.
set -euo pipefail

STACK="${STACK:-gentrail-byoc-validate}"
REGION="${REGION:-us-west-2}"
# Export so bare `aws` calls in sub-scripts (cfn-to-values.sh) inherit the region.
export AWS_DEFAULT_REGION="$REGION" AWS_REGION="$REGION"
TEMPLATE_BUCKET="${TEMPLATE_BUCKET:-aigentrail-tfstate-617072386017}"
CLUSTER="${CLUSTER:-gtbx}"
PREFIX="${PREFIX:-$CLUSTER}"
SUBSTRATE_HOSTNAME="${SUBSTRATE_HOSTNAME:-byoc-test.aigentrail.com}"
EXTERNAL_ID="${EXTERNAL_ID:-byoc-validate-ext-id}"
IMAGE_TAG="${IMAGE_TAG:-v0.2.0-rc.1}"
NAMESPACE="${NAMESPACE:-gentrail}"
LICENSE_SM_SECRET="${LICENSE_SM_SECRET:-aigentrail/license/dev-jwt}"
LICENSE_JWT_KEY="${LICENSE_JWT_KEY:-}"   # set to a JSON key when the secret is a JSON document

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="$HERE/../helm/gentrail"
TEMPLATE="$HERE/m3-byoc-substrate.yaml"
VALUES="/tmp/${STACK}-values.yaml"
export KUBECONFIG="${KUBECONFIG:-/tmp/${STACK}-kubeconfig}"

log() { printf '==> %s\n' "$*"; }

status=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo ABSENT)
if [ "$status" = ABSENT ]; then
  log "staging template to s3://$TEMPLATE_BUCKET/cfn/ (over the 51 KB inline limit)"
  aws s3 cp "$TEMPLATE" "s3://$TEMPLATE_BUCKET/cfn/m3-byoc-substrate.yaml" --region "$REGION" >/dev/null
  log "building + staging the trace-archiver lambda zip"
  ARCHIVER_DIR="$HERE/../../../services/ingestion/lambda-archiver"
  (cd "$ARCHIVER_DIR" && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o bootstrap . \
    && rm -f archiver.zip && zip -q archiver.zip bootstrap)
  aws s3 cp "$ARCHIVER_DIR/archiver.zip" "s3://$TEMPLATE_BUCKET/cfn/archiver.zip" --region "$REGION" >/dev/null
  log "create-stack $STACK (cost-minimized, teardown-safe params)"
  aws cloudformation create-stack --stack-name "$STACK" --region "$REGION" \
    --template-url "https://s3.$REGION.amazonaws.com/$TEMPLATE_BUCKET/cfn/m3-byoc-substrate.yaml" \
    --capabilities CAPABILITY_NAMED_IAM --on-failure DELETE \
    --parameters \
      ParameterKey=ClusterName,ParameterValue="$CLUSTER" \
      ParameterKey=DdbTableNamePrefix,ParameterValue="$PREFIX" \
      ParameterKey=KmsKeyAlias,ParameterValue="alias/$CLUSTER-substrate" \
      ParameterKey=Hostname,ParameterValue="$SUBSTRATE_HOSTNAME" \
      ParameterKey=ExternalId,ParameterValue="$EXTERNAL_ID" \
      ParameterKey=AzCount,ParameterValue=2 \
      ParameterKey=NodeInstanceType,ParameterValue=t3.medium \
      ParameterKey=NodeCountMin,ParameterValue=1 \
      ParameterKey=NodeCountDesired,ParameterValue=2 \
      ParameterKey=NodeCountMax,ParameterValue=3 \
      ParameterKey=EnableVpcEndpoints,ParameterValue=false \
      ParameterKey=EnableVpcFlowLogs,ParameterValue=false \
      ParameterKey=EnableAlbAccessLogs,ParameterValue=false \
      ParameterKey=RdsInstanceClass,ParameterValue=db.t3.micro \
      ParameterKey=RdsMultiAz,ParameterValue=false \
      ParameterKey=RdsDeletionProtection,ParameterValue=false \
      ParameterKey=EnableRdsPerformanceInsights,ParameterValue=false \
      ParameterKey=RdsAllocatedStorageGb,ParameterValue=20 \
      ParameterKey=RdsBackupRetentionDays,ParameterValue=0 \
      ParameterKey=S3ObjectLockRetentionDays,ParameterValue=1 \
      ParameterKey=DdbEnablePointInTimeRecovery,ParameterValue=false \
      ParameterKey=ArchiverCodeS3Bucket,ParameterValue="$TEMPLATE_BUCKET" \
      ParameterKey=ArchiverCodeS3Key,ParameterValue=cfn/archiver.zip \
    >/dev/null
fi

log "waiting for $STACK CREATE_COMPLETE (15-20 min for EKS + RDS)"
aws cloudformation wait stack-create-complete --stack-name "$STACK" --region "$REGION"

CLUSTER_NAME=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`ClusterName`].OutputValue' --output text)
log "kubeconfig for $CLUSTER_NAME -> $KUBECONFIG"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" --kubeconfig "$KUBECONFIG" >/dev/null

log "default CSI StorageClass (EKS 1.32 dropped the in-tree EBS provisioner)"
kubectl annotate sc gp2 storageclass.kubernetes.io/is-default-class- 2>/dev/null || true
kubectl apply -f - <<'SC'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-csi
  annotations: { storageclass.kubernetes.io/is-default-class: "true" }
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
parameters: { type: gp3 }
SC

log "cfn-to-values -> $VALUES"
"$HERE/../scripts/cfn-to-values.sh" "$STACK" > "$VALUES"

log "namespace + image-pull secret"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NAMESPACE" create secret docker-registry ghcr \
  --docker-server=ghcr.io --docker-username="$(gh api user --jq .login)" \
  --docker-password="$(gh auth token)" --dry-run=client -o yaml | kubectl apply -f -
# The chart provisions an empty gentrail-license secret (pre-install hook); the
# license is pasted in the dashboard, not created here. Vendor validation may
# optionally pre-fill it after install (below).

log "helm upgrade --install gentrail"
helm upgrade --install gentrail "$CHART" -n "$NAMESPACE" \
  -f "$VALUES" \
  --set image.tag="$IMAGE_TAG" \
  --set image.pullSecret=ghcr \
  --set createNamespace=false \
  --set dashboard.auditLoop=false \
  --set storage.class=gp3-csi \
  --timeout 12m --wait

kubectl -n "$NAMESPACE" get pods

# Optional: pre-fill the license from Secrets Manager (vendor validation), the
# same patch the in-dashboard upload performs. Absent (e.g. customer accounts)
# the install stays unlicensed and you paste the license in the dashboard.
if license_jwt=$(aws secretsmanager get-secret-value --secret-id "$LICENSE_SM_SECRET" \
    --region "$REGION" --query SecretString --output text 2>/dev/null); then
  [ -n "$LICENSE_JWT_KEY" ] && license_jwt=$(printf '%s' "$license_jwt" | jq -r ".$LICENSE_JWT_KEY")
  kubectl -n "$NAMESPACE" patch secret gentrail-license --type merge \
    -p "{\"stringData\":{\"jwt\":\"${license_jwt}\"}}" >/dev/null
  log "license pre-filled from $LICENSE_SM_SECRET"
else
  log "no Secrets Manager license; install is unlicensed - paste it in the dashboard"
fi

log "done. export KUBECONFIG=$KUBECONFIG"
