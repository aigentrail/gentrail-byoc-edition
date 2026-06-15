#!/usr/bin/env bash
# Connect to a running Gentrail BYOC install from your machine. The ALBs are
# internal, so this tunnels the dashboard (and the OTLP ingest endpoint) to
# localhost through the EKS API server - no public exposure needed.
#
# Needs: aws (authenticated to the install's account) and kubectl on your PATH.
# Run:   ./connect.sh           # leave it running; Ctrl-C to disconnect
#
# Config (env vars, optional):
#   REGION      AWS region                  (default us-west-2)
#   STACK       CloudFormation stack name   (default gentrail)
#   NAMESPACE   k8s namespace               (default gentrail)
#   DASH_PORT   local dashboard port        (default 8001)
#   OTEL_PORT   local OTLP ingest port      (default 4318)
set -euo pipefail

REGION="${REGION:-us-west-2}"
export AWS_DEFAULT_REGION="$REGION" AWS_REGION="$REGION"
STACK="${STACK:-gentrail}"
NAMESPACE="${NAMESPACE:-gentrail}"
DASH_PORT="${DASH_PORT:-8001}"
OTEL_PORT="${OTEL_PORT:-4318}"

for t in aws kubectl; do command -v "$t" >/dev/null || { echo "missing required tool: $t" >&2; exit 1; }; done

# The cluster name is a stack output (defaults to the stack name on older installs).
CLUSTER="$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`ClusterName`].OutputValue' --output text 2>/dev/null)"
[ -n "$CLUSTER" ] && [ "$CLUSTER" != "None" ] || CLUSTER="$STACK"

echo "==> kubeconfig for cluster '$CLUSTER' ($REGION)"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null

cleanup() { kill $(jobs -p) 2>/dev/null || true; }
trap cleanup EXIT INT TERM

kubectl -n "$NAMESPACE" rollout status deploy/dashboard --timeout=120s >/dev/null 2>&1 || true
kubectl -n "$NAMESPACE" port-forward deploy/dashboard "$DASH_PORT:8001" >/dev/null 2>&1 &
kubectl -n "$NAMESPACE" port-forward deploy/authproxy "$OTEL_PORT:4318" >/dev/null 2>&1 &
sleep 3

cat <<EOF

Connected to '$CLUSTER'. Leave this running; Ctrl-C to disconnect.

  Dashboard     http://localhost:$DASH_PORT   (no login - paste your license here)
  OTLP ingest   http://localhost:$OTEL_PORT   (export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:$OTEL_PORT)

EOF
wait
