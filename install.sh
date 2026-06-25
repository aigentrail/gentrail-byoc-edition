#!/usr/bin/env bash
# One-command BYOC install. Stands up the substrate (CloudFormation -> EKS) and
# installs the Gentrail chart in your AWS account. Internal by default: private
# ALBs, no public domain. When it finishes, open the dashboard and paste your
# free license (no secret to create - the chart provisions an empty one).
#
# Prereqs on your PATH: aws (authenticated to your account), kubectl, helm, jq.
# Run from the root of this repo:  deploy/m3/install.sh
#
# Config (env vars, all optional):
#   REGION       AWS region                         (default us-west-2)
#   STACK        CloudFormation stack / cluster name (default gentrail)
#   IMAGE_TAG    container image tag                 (default: the chart's pin)
#   GHCR_USER + GHCR_TOKEN  a read:packages token, only if the images are private
#   PUBLIC_HOST  set to a public FQDN to do an internet-facing install instead
#                (also set PUBLIC_OTEL_HOST; ACM_CERT_ARN for an HTTPS listener)
set -euo pipefail

REGION="${REGION:-us-west-2}"
export AWS_DEFAULT_REGION="$REGION" AWS_REGION="$REGION"   # bare aws calls inherit it
STACK="${STACK:-gentrail}"
NAMESPACE="${NAMESPACE:-gentrail}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Locate the deploy/m3 tree whether this script sits at the repo root (the public
# deploy repo, where it's ./install.sh) or inside deploy/m3 (the monorepo).
if [ -d "$HERE/helm/gentrail" ]; then
    M3="$HERE"
elif [ -d "$HERE/deploy/m3/helm/gentrail" ]; then
    M3="$HERE/deploy/m3"
else
    echo "cannot locate the deploy/m3 chart relative to $HERE" >&2; exit 1
fi
CHART="$M3/helm/gentrail"
TEMPLATE="$M3/cfn/m3-byoc-substrate.yaml"
ARCHIVER="$M3/archiver.zip"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/gentrail-$STACK}"
log() { printf '\n==> %s\n' "$*"; }

# Tier: Evaluation (single-node appliance) vs Production (this EKS path). Resolve
# from --tier=, then $TIER, then an interactive menu; non-interactive with neither
# set falls through to Production, so existing scripted callers are unchanged.
TIER="${TIER:-}"
for arg in "$@"; do case "$arg" in --tier=*) TIER="${arg#--tier=}";; esac; done
if [ -z "$TIER" ] && [ -t 0 ]; then
  cat <<'MENU'

Gentrail installs into your own AWS account; your data never leaves it. Pick a tier:

  [1] Evaluation   single EC2 + k3s, all in-cluster    ~5 min   ~$70/mo while running
                   single-AZ, node-local storage, NO managed backups: a trial box,
                   NOT a system of record.
  [2] Production   EKS + Multi-AZ RDS + KMS CMK + S3    ~30 min  ~$400/mo
                   Object-Lock evidence, managed backups, HA: the system of record.

MENU
  printf 'Tier [1/2]: '
  read -r choice
  case "$choice" in 1 | eval | e | E) TIER="eval" ;; *) TIER="prod" ;; esac
fi
[ "$TIER" = eval ] && exec "$M3/install-appliance.sh" "$@"

for t in aws kubectl helm jq; do command -v "$t" >/dev/null || { echo "missing required tool: $t" >&2; exit 1; }; done
[ -f "$ARCHIVER" ] || { echo "missing $ARCHIVER (the trace-archiver zip ships with this repo)" >&2; exit 1; }

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${BUCKET:-gentrail-cfn-${ACCOUNT}-${REGION}}"
IMAGE_TAG="${IMAGE_TAG:-$(awk '/^image:/{i=1} i&&/^  tag:/{print $2; exit}' "$CHART/values.yaml")}"
log "account $ACCOUNT, region $REGION, image tag $IMAGE_TAG"

log "stage archiver lambda to s3://$BUCKET"
aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION" 2>/dev/null || true
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3 cp "$ARCHIVER" "s3://$BUCKET/cfn/archiver.zip" --region "$REGION" >/dev/null

params=(
  ClusterName="$STACK" DdbTableNamePrefix="$STACK" KmsKeyAlias="alias/$STACK-substrate"
  ArchiverCodeS3Bucket="$BUCKET" ArchiverCodeS3Key=cfn/archiver.zip
)
[ -n "${PUBLIC_HOST:-}" ] && params+=( Hostname="$PUBLIC_HOST" )
[ -n "${PUBLIC_OTEL_HOST:-}" ] && params+=( OtelHostname="$PUBLIC_OTEL_HOST" )
[ -n "${ACM_CERT_ARN:-}" ] && params+=( ExistingAcmCertArn="$ACM_CERT_ARN" )

log "deploy substrate $STACK (EKS + RDS, ~25 min)"
# `deploy` only takes --template-file; --s3-bucket lets it upload the >51 KB
# template itself (the inline limit) instead of us pre-staging it.
aws cloudformation deploy --stack-name "$STACK" --region "$REGION" \
  --template-file "$TEMPLATE" \
  --s3-bucket "$BUCKET" --s3-prefix cfn \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides "${params[@]}"

CLUSTER_NAME=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`ClusterName`].OutputValue' --output text)
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" --kubeconfig "$KUBECONFIG" >/dev/null

log "AWS Load Balancer Controller + default StorageClass"
"$M3/scripts/install-alb-controller.sh" "$STACK"
kubectl annotate sc gp2 storageclass.kubernetes.io/is-default-class- 2>/dev/null || true
kubectl apply -f - <<'SC'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: { name: gp3-csi, annotations: { storageclass.kubernetes.io/is-default-class: "true" } }
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
parameters: { type: gp3 }
SC

log "generate values"
values="$(mktemp)"; "$M3/scripts/cfn-to-values.sh" "$STACK" > "$values"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

helm_extra=(--set storage.class=gp3-csi)
if [ -n "${GHCR_TOKEN:-}" ]; then
  kubectl -n "$NAMESPACE" create secret docker-registry ghcr \
    --docker-server=ghcr.io --docker-username="${GHCR_USER:-x}" --docker-password="$GHCR_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
  helm_extra+=(--set image.pullSecret=ghcr)
fi
# Each endpoint's ALB scheme is independent: expose OTLP ingest publicly (so
# agents send telemetry without a tunnel) without exposing the dashboard.
[ -n "${PUBLIC_OTEL_HOST:-}" ] && helm_extra+=(--set ingress.otelInternal=false)
[ -n "${PUBLIC_HOST:-}" ] && helm_extra+=(--set ingress.dashboardInternal=false)

log "install the chart (tag $IMAGE_TAG)"
helm upgrade --install gentrail "$CHART" -n "$NAMESPACE" -f "$values" \
  --set image.tag="$IMAGE_TAG" --set createNamespace=false \
  "${helm_extra[@]}" --timeout 12m --wait

cat <<DONE

==> Installed. There is no login - open the dashboard and paste your license:

    kubectl -n $NAMESPACE port-forward deploy/dashboard 8001:8001   # then http://localhost:8001
    # or reach the internal ALB directly:  kubectl -n $NAMESPACE get ingress

The dashboard runs unlicensed until you paste a license, which it writes to the
provisioned secret; every service then activates within ~2 minutes.
DONE
