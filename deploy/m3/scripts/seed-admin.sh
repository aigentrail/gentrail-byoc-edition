#!/usr/bin/env bash
# Seed an admin user into a K8s-deployed Gentrail dashboard.
# Reads RDS endpoint + secret from the substrate CFN stack outputs.
#
# Usage:
#   ./seed-admin.sh <substrate-stack-name> [<email>] [<password>]
set -euo pipefail

STACK_NAME="${1:?usage: $0 <substrate-stack-name> [<email>] [<password>]}"
EMAIL="${2:-admin@local.test}"
PASSWORD="${3:-admin123}"
ORG_ID="${ORG_ID:-org_local}"
ORG_NAME="${ORG_NAME:-Local Dev}"
USER_ID="${USER_ID:-user_$(echo -n "$EMAIL" | shasum -a 256 | cut -c1-12)}"

REGION=$(aws configure get region)
RDS_ENDPOINT=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='RdsEndpoint'].OutputValue" --output text)
RDS_SECRET_ARN=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='RdsSecretArn'].OutputValue" --output text)

# Fetch the RDS master password from Secrets Manager.
RDS_PASSWORD=$(aws secretsmanager get-secret-value --secret-id "$RDS_SECRET_ARN" \
    --query 'SecretString' --output text | jq -r .password)
RDS_HOST="${RDS_ENDPOINT%:*}"

# PBKDF2-HMAC-SHA256, 600k iterations, matching services/dashboard/internal/db/auth.go
read -r SALT_HEX HASH_HEX <<<"$(python3 - <<PY
import hashlib, secrets
salt = secrets.token_bytes(16)
dk = hashlib.pbkdf2_hmac("sha256", "${PASSWORD}".encode(), salt, 600_000, 32)
print(salt.hex(), dk.hex())
PY
)"

echo "==> seeding admin (${EMAIL}) via a K8s Job"

cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: seed-admin-creds
  namespace: gentrail
type: Opaque
stringData:
  PGHOST: "${RDS_HOST}"
  PGUSER: "gentrail"
  PGPASSWORD: "${RDS_PASSWORD}"
  PGDATABASE: "gentrail"
  PGSSLMODE: "require"
  EMAIL: "${EMAIL}"
  USER_ID: "${USER_ID}"
  ORG_ID: "${ORG_ID}"
  ORG_NAME: "${ORG_NAME}"
  SALT_HEX: "${SALT_HEX}"
  HASH_HEX: "${HASH_HEX}"
---
apiVersion: batch/v1
kind: Job
metadata:
  name: seed-admin-$(date +%s)
  namespace: gentrail
  labels:
    app.kubernetes.io/component: seed-admin
spec:
  ttlSecondsAfterFinished: 60
  template:
    metadata:
      labels:
        app.kubernetes.io/component: seed-admin
    spec:
      restartPolicy: Never
      containers:
        - name: psql
          image: postgres:16-alpine
          envFrom:
            - secretRef: { name: seed-admin-creds }
          command: ["psql", "-v", "ON_ERROR_STOP=1", "-c"]
          args:
            - |
              INSERT INTO organizations (id, name, created_at)
              VALUES ('\${ORG_ID}', '\${ORG_NAME}', extract(epoch from now()))
              ON CONFLICT (id) DO NOTHING;
              INSERT INTO users (id, email, password_hash, password_salt, org_id, created_at, role)
              VALUES ('\${USER_ID}', '\${EMAIL}', '\${HASH_HEX}', '\${SALT_HEX}', '\${ORG_ID}',
                      extract(epoch from now()), 'admin')
              ON CONFLICT (email) DO UPDATE
                SET password_hash = EXCLUDED.password_hash,
                    password_salt = EXCLUDED.password_salt,
                    org_id = EXCLUDED.org_id,
                    role = EXCLUDED.role;
YAML

sleep 3
kubectl -n gentrail wait --for=condition=complete --timeout=60s \
    job -l app.kubernetes.io/component=seed-admin || true

HOSTNAME=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='Hostname'].OutputValue" --output text)
echo
echo "==> admin seeded - log in at https://${HOSTNAME}/login"
echo "    ${EMAIL} / ${PASSWORD}"
