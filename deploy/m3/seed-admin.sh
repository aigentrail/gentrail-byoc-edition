#!/usr/bin/env bash
# Seed an admin user into the local Gentrail dashboard's Postgres.
# Signup is disabled in the handler, so users must be inserted directly.
#
# Usage:
#   ./seed-admin.sh                                   # defaults: admin@local.test / admin123
#   ./seed-admin.sh me@example.com hunter2
#   EMAIL=you@local PASSWORD=letmein ./seed-admin.sh
#
# Requires the docker-compose stack to be running (postgres service in particular).
# Re-running with the same email updates the password.
set -euo pipefail

cd "$(dirname "$0")"

EMAIL="${1:-${EMAIL:-admin@local.test}}"
PASSWORD="${2:-${PASSWORD:-admin123}}"
ORG_ID="${ORG_ID:-org_local}"
ORG_NAME="${ORG_NAME:-Local Dev}"
USER_ID="${USER_ID:-user_$(echo -n "$EMAIL" | shasum -a 256 | cut -c1-12)}"

# Sanity-check the postgres container is up
if ! docker compose ps --status running --services 2>/dev/null | grep -qx postgres; then
    echo "postgres service is not running. Start the stack first:" >&2
    echo "  docker compose up -d postgres" >&2
    exit 1
fi

# Generate PBKDF2-HMAC-SHA256 hash matching services/dashboard/internal/db/auth.go
# (600,000 iterations, SHA-256, 32-byte key, salt as hex).
read -r SALT_HEX HASH_HEX <<<"$(python3 - <<PY
import hashlib, secrets
salt = secrets.token_bytes(16)
dk   = hashlib.pbkdf2_hmac("sha256", "${PASSWORD}".encode(), salt, 600_000, 32)
print(salt.hex(), dk.hex())
PY
)"

echo "==> seeding admin"
echo "    email   : ${EMAIL}"
echo "    org     : ${ORG_NAME} (${ORG_ID})"

docker compose exec -T -e PGPASSWORD=gentrail postgres \
    psql -U gentrail -d gentrail -v ON_ERROR_STOP=1 <<SQL >/dev/null
INSERT INTO organizations (id, name, created_at)
VALUES ('${ORG_ID}', '${ORG_NAME}', extract(epoch from now()))
ON CONFLICT (id) DO NOTHING;

INSERT INTO users (id, email, password_hash, password_salt, org_id, created_at, role)
VALUES ('${USER_ID}', '${EMAIL}', '${HASH_HEX}', '${SALT_HEX}', '${ORG_ID}',
        extract(epoch from now()), 'admin')
ON CONFLICT (email) DO UPDATE
  SET password_hash = EXCLUDED.password_hash,
      password_salt = EXCLUDED.password_salt,
      org_id        = EXCLUDED.org_id,
      role          = EXCLUDED.role;
SQL

echo "==> done"
echo
echo "Log in at http://localhost:8001/login with:"
echo "    ${EMAIL} / ${PASSWORD}"
