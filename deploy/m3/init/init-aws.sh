#!/usr/bin/env sh
# Creates the DDB tables expected by the Gentrail services in DynamoDB Local.
# Runs inside the `aws-cli` container against the local endpoint.
#
# Idempotent — every table checks existence first.
#
# The table schemas are NOT hand-authored here: each tables/<name>.json is an
# `aws dynamodb create-table --cli-input-json` document generated from iac/ddb.cue
# (the same model the CFN template and the OpenTofu tables come from). Edit the
# model and regenerate with deploy/m3/scripts/gen-all.sh; TestInitAwsTablesMatchModel
# guards the committed files. Adding a table is then automatic here.
set -eu

DDB_ENDPOINT="${DDB_ENDPOINT:-http://dynamodb-local:8000}"
AWS_REGION="${AWS_REGION:-us-west-2}"
TABLES_DIR="${TABLES_DIR:-$(dirname "$0")/tables}"

ddb () {
    aws --endpoint-url "$DDB_ENDPOINT" --region "$AWS_REGION" dynamodb "$@"
}

echo "==> waiting for DynamoDB Local"
for i in $(seq 1 60); do
    if ddb list-tables >/dev/null 2>&1; then
        echo "  ready"
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "  DDB never became ready" >&2
        exit 1
    fi
    sleep 1
done

for spec in "$TABLES_DIR"/*.json; do
    name=$(basename "$spec" .json)
    echo "==> ddb table: $name"
    if ddb describe-table --table-name "$name" >/dev/null 2>&1; then
        echo "  (exists)"
    else
        ddb create-table --cli-input-json "file://$spec" >/dev/null
        echo "  created"
    fi
done

echo "==> init complete"
