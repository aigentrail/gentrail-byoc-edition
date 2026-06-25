#!/usr/bin/env bash
# Evaluation tier: deploy the single-node k3s appliance (cfn/appliance.yaml) into
# your own AWS account. The box self-installs Gentrail on first boot, so your
# laptop only needs the aws CLI; reach the dashboard afterward with ./connect.sh.
# Single-AZ, node-local storage, no managed backups: a trial box, NOT a system
# of record. install.sh routes here when you pick Evaluation / pass --tier=eval.
#
# Config (env vars, all optional):
#   REGION         AWS region                 (default us-west-2)
#   STACK          CloudFormation stack name  (default gentrail)
#   INSTANCE_TYPE  appliance EC2 size         (default t3.large)
#   LICENSE_JWT    pre-seed a license         (default: paste it in the dashboard)
#   REPO_BRANCH    public repo branch the box clones for the chart (default main)
set -euo pipefail

REGION="${REGION:-us-west-2}"
export AWS_DEFAULT_REGION="$REGION" AWS_REGION="$REGION"
STACK="${STACK:-gentrail}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.large}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -d "$HERE/helm/gentrail" ]; then
    M3="$HERE"
elif [ -d "$HERE/deploy/m3/helm/gentrail" ]; then
    M3="$HERE/deploy/m3"
else
    echo "cannot locate the deploy tree relative to $HERE" >&2; exit 1
fi
TEMPLATE="$M3/cfn/appliance.yaml"

command -v aws >/dev/null || { echo "missing required tool: aws" >&2; exit 1; }
command -v session-manager-plugin >/dev/null || echo \
  "note: install the AWS Session Manager plugin so ./connect.sh can reach the box (https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)" >&2

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
echo "==> deploying the Gentrail evaluation appliance to account $ACCOUNT ($REGION); the box self-installs in ~5-8 min"

params=( InstanceType="$INSTANCE_TYPE" )
[ -n "${LICENSE_JWT:-}" ] && params+=( LicenseJwt="$LICENSE_JWT" )
[ -n "${REPO_BRANCH:-}" ] && params+=( RepoBranch="$REPO_BRANCH" )

# The template is small, so `deploy` inlines it; no S3 staging like the prod path.
aws cloudformation deploy --stack-name "$STACK" --region "$REGION" \
  --template-file "$TEMPLATE" \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides "${params[@]}"

cat <<DONE

==> Appliance up. There is no login; reach the dashboard and paste your license:

    ./connect.sh            # SSM-tunnels the dashboard to http://localhost:8001

The whole stack runs in-cluster, so your trace data never leaves your account.
This is an evaluation box (single-AZ, no managed backups), NOT a system of record.
DONE
