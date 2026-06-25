#!/usr/bin/env bash
# Connect to a running Gentrail BYOC install from your machine and tunnel the
# dashboard (and OTLP ingest) to localhost. Auto-detects the tier from the stack:
# Production tunnels through the EKS API; Evaluation (the appliance) tunnels the
# single node's k3s API over SSM. Either way nothing is publicly exposed.
#
# Needs: aws + kubectl (+ the SSM session-manager-plugin for the appliance tier).
# Run:   ./connect.sh           # leave it running; Ctrl-C to disconnect
#
# Config (env vars, optional):
#   REGION      AWS region                  (default us-west-2)
#   STACK       CloudFormation stack name   (default gentrail)
#   NAMESPACE   k8s namespace               (default gentrail)
#   DASH_PORT   local dashboard port        (default 8001)
#   OTEL_PORT   local OTLP ingest port      (default 4318)
#   TIER        eval|prod                   (default: auto-detect from the stack)
set -euo pipefail

REGION="${REGION:-us-west-2}"
export AWS_DEFAULT_REGION="$REGION" AWS_REGION="$REGION"
STACK="${STACK:-gentrail}"
NAMESPACE="${NAMESPACE:-gentrail}"
DASH_PORT="${DASH_PORT:-8001}"
OTEL_PORT="${OTEL_PORT:-4318}"

for t in aws kubectl; do command -v "$t" >/dev/null || { echo "missing required tool: $t" >&2; exit 1; }; done

# The appliance stack tags itself Tier=eval; the EKS stack has no such output.
TIER="${TIER:-}"
if [ -z "$TIER" ]; then
  TIER="$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`Tier`].OutputValue' --output text 2>/dev/null || true)"
  [ "$TIER" = eval ] || TIER=prod
fi

cleanup() { trap - EXIT INT TERM; kill 0; }
trap cleanup EXIT INT TERM

if [ "$TIER" = eval ]; then
  command -v session-manager-plugin >/dev/null || { echo "missing required tool: session-manager-plugin (https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)" >&2; exit 1; }
  INSTANCE="$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' --output text)"
  [ -n "$INSTANCE" ] && [ "$INSTANCE" != "None" ] || { echo "no appliance InstanceId in stack $STACK" >&2; exit 1; }
  CLUSTER="appliance ($INSTANCE)"

  # First free local port; tiny TOCTOU window before the tunnel binds it is fine.
  PORT=""
  for p in $(seq 16443 16600); do ss -ltnH "( sport = :$p )" 2>/dev/null | grep -q . || { PORT=$p; break; }; done
  [ -n "$PORT" ] || { echo "no free local port in 16443-16600" >&2; exit 1; }

  echo "==> SSM tunnel to the appliance k3s API ($INSTANCE)"
  KUBECONFIG_OUT="${KUBECONFIG_OUT:-$HOME/.kube/gentrail-appliance}"
  mkdir -p "$(dirname "$KUBECONFIG_OUT")"
  cid=$(aws ssm send-command --region "$REGION" --instance-ids "$INSTANCE" \
    --document-name AWS-RunShellScript --parameters 'commands=["cat /etc/rancher/k3s/k3s.yaml"]' \
    --query Command.CommandId --output text)
  for _ in $(seq 1 30); do
    sleep 2
    [ "$(aws ssm get-command-invocation --region "$REGION" --command-id "$cid" --instance-id "$INSTANCE" --query Status --output text 2>/dev/null)" = Success ] && break
  done
  aws ssm get-command-invocation --region "$REGION" --command-id "$cid" --instance-id "$INSTANCE" \
    --query StandardOutputContent --output text \
    | sed "s#https://127.0.0.1:6443#https://localhost:${PORT}#" > "$KUBECONFIG_OUT"
  export KUBECONFIG="$KUBECONFIG_OUT"

  # In-group background job (not setsid) so the cleanup trap's `kill 0` reaps it
  # on Ctrl-C; the loop restarts a timed-out/dropped SSM session.
  ( while true; do
      aws ssm start-session --region "$REGION" --target "$INSTANCE" \
        --document-name AWS-StartPortForwardingSession \
        --parameters "{\"portNumber\":[\"6443\"],\"localPortNumber\":[\"${PORT}\"]}" >/dev/null 2>&1
      sleep 2
    done ) &
  for _ in $(seq 1 30); do kubectl get --raw /healthz >/dev/null 2>&1 && break; sleep 1; done
else
  # The cluster name is a stack output (defaults to the stack name on older installs).
  CLUSTER="$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`ClusterName`].OutputValue' --output text 2>/dev/null || true)"
  [ -n "$CLUSTER" ] && [ "$CLUSTER" != "None" ] || CLUSTER="$STACK"
  echo "==> kubeconfig for cluster '$CLUSTER' ($REGION)"
  aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null
fi

# A port-forward targets a single pod, so it drops when that pod is replaced (a
# rolling upgrade, a restart, a transient blip). Reconnect so the local link
# survives pod rolls instead of dying and needing a manual restart.
forward() {
  while true; do
    kubectl -n "$NAMESPACE" port-forward "$1" "$2" >/dev/null 2>&1 || true
    sleep 1
  done
}

kubectl -n "$NAMESPACE" rollout status deploy/dashboard --timeout=120s >/dev/null 2>&1 || true
forward deploy/dashboard "$DASH_PORT:8001" &
forward deploy/authproxy "$OTEL_PORT:4318" &
sleep 3

cat <<EOF

Connected to '$CLUSTER'. Leave this running; Ctrl-C to disconnect.

  Dashboard     http://localhost:$DASH_PORT   (no login - paste your license here)
  OTLP ingest   http://localhost:$OTEL_PORT   (export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:$OTEL_PORT)

EOF
wait
