#!/usr/bin/env sh
# Creates the DDB tables expected by the Gentrail services.
# Runs inside the `aws-cli` container with the local endpoints.
#
# Idempotent — every operation checks existence first.
#
# Schemas mirror the real `aigentrail-*-dev` tables in account 617072386017
# (us-west-2). See `aws --profile aigentrail dynamodb describe-table ...`
# for the source of truth. Drift here will cause query paths that hit GSIs
# (agent-index, eval-index, etc.) to return empty results locally.
set -eu

DDB_ENDPOINT="${DDB_ENDPOINT:-http://dynamodb-local:8000}"
AWS_REGION="${AWS_REGION:-us-west-2}"

ddb () {
    aws --endpoint-url "$DDB_ENDPOINT" --region "$AWS_REGION" dynamodb "$@"
}

create_table_if_absent () {
    name="$1"; shift
    echo "==> ddb table: $name"
    if ddb describe-table --table-name "$name" >/dev/null 2>&1; then
        echo "  (exists)"
    else
        ddb create-table --table-name "$name" "$@" --billing-mode PAY_PER_REQUEST >/dev/null
        echo "  created"
    fi
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

# ───────────────────────────────────────────────────────────────────────────
# traces — PK + SK; three GSIs (agent-index, eval-index, span-index) all
# sharing SK as their range. Mirrors aigentrail-traces-dev.
# ───────────────────────────────────────────────────────────────────────────
create_table_if_absent "gentrail-traces" \
    --attribute-definitions \
        AttributeName=PK,AttributeType=S \
        AttributeName=SK,AttributeType=S \
        AttributeName=GSI1PK,AttributeType=S \
        AttributeName=GSI2PK,AttributeType=S \
        AttributeName=GSI3PK,AttributeType=S \
    --key-schema \
        AttributeName=PK,KeyType=HASH \
        AttributeName=SK,KeyType=RANGE \
    --global-secondary-indexes '[
        {"IndexName":"agent-index","KeySchema":[{"AttributeName":"GSI1PK","KeyType":"HASH"},{"AttributeName":"SK","KeyType":"RANGE"}],"Projection":{"ProjectionType":"ALL"}},
        {"IndexName":"eval-index","KeySchema":[{"AttributeName":"GSI2PK","KeyType":"HASH"},{"AttributeName":"SK","KeyType":"RANGE"}],"Projection":{"ProjectionType":"ALL"}},
        {"IndexName":"span-index","KeySchema":[{"AttributeName":"GSI3PK","KeyType":"HASH"},{"AttributeName":"SK","KeyType":"RANGE"}],"Projection":{"ProjectionType":"ALL"}}
    ]'

# ───────────────────────────────────────────────────────────────────────────
# violations — PK + SK; three GSIs, each with its own SK
# (org-recent-index, rule-index, source-index).
# Mirrors aigentrail-violations-dev.
# ───────────────────────────────────────────────────────────────────────────
create_table_if_absent "gentrail-violations" \
    --attribute-definitions \
        AttributeName=PK,AttributeType=S \
        AttributeName=SK,AttributeType=S \
        AttributeName=GSI1PK,AttributeType=S \
        AttributeName=GSI1SK,AttributeType=S \
        AttributeName=GSI2PK,AttributeType=S \
        AttributeName=GSI2SK,AttributeType=S \
        AttributeName=GSI3PK,AttributeType=S \
        AttributeName=GSI3SK,AttributeType=S \
    --key-schema \
        AttributeName=PK,KeyType=HASH \
        AttributeName=SK,KeyType=RANGE \
    --global-secondary-indexes '[
        {"IndexName":"org-recent-index","KeySchema":[{"AttributeName":"GSI1PK","KeyType":"HASH"},{"AttributeName":"GSI1SK","KeyType":"RANGE"}],"Projection":{"ProjectionType":"ALL"}},
        {"IndexName":"rule-index","KeySchema":[{"AttributeName":"GSI2PK","KeyType":"HASH"},{"AttributeName":"GSI2SK","KeyType":"RANGE"}],"Projection":{"ProjectionType":"ALL"}},
        {"IndexName":"source-index","KeySchema":[{"AttributeName":"GSI3PK","KeyType":"HASH"},{"AttributeName":"GSI3SK","KeyType":"RANGE"}],"Projection":{"ProjectionType":"ALL"}}
    ]'

# ───────────────────────────────────────────────────────────────────────────
# agent-stats — PK only (no SK); single GSI on org_id.
# Mirrors aigentrail-agent-stats-dev.
# ───────────────────────────────────────────────────────────────────────────
create_table_if_absent "gentrail-agent-stats" \
    --attribute-definitions \
        AttributeName=PK,AttributeType=S \
        AttributeName=org_id,AttributeType=S \
    --key-schema \
        AttributeName=PK,KeyType=HASH \
    --global-secondary-indexes '[
        {"IndexName":"org-index","KeySchema":[{"AttributeName":"org_id","KeyType":"HASH"}],"Projection":{"ProjectionType":"ALL"}}
    ]'

# ───────────────────────────────────────────────────────────────────────────
# policy-rules — PK + SK, no GSIs.
# Mirrors aigentrail-policy-rules-dev.
# ───────────────────────────────────────────────────────────────────────────
create_table_if_absent "gentrail-policy-rules" \
    --attribute-definitions \
        AttributeName=PK,AttributeType=S \
        AttributeName=SK,AttributeType=S \
    --key-schema \
        AttributeName=PK,KeyType=HASH \
        AttributeName=SK,KeyType=RANGE

# ───────────────────────────────────────────────────────────────────────────
# api-keys — hash key is `token` (NOT `PK`).
# Mirrors aigentrail-api-keys-dev.
# ───────────────────────────────────────────────────────────────────────────
create_table_if_absent "gentrail-api-keys" \
    --attribute-definitions \
        AttributeName=token,AttributeType=S \
    --key-schema \
        AttributeName=token,KeyType=HASH

echo "==> init complete"
