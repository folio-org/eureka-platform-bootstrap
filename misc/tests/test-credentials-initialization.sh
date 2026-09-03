#!/usr/bin/env bash
#
# A first bootstrap must seed credentials from the effective local configuration,
# not replace docker/.env.local values with hard-coded fallback defaults.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

mkdir -p "${tmp}/docker"
cat > "${tmp}/docker/.env" <<'EOF'
POSTGRES_PASSWORD=default-password
KC_DB_PASSWORD=default-keycloak-password
OKAPI_DB_PASSWORD=default-okapi-password
KONG_DB_PASSWORD=default-kong-password
MGR_APPLICATIONS_DB_PASSWORD=default-applications-password
MGR_TENANTS_DB_PASSWORD=default-tenants-password
MGR_TENANT_ENTITLEMENTS_DB_PASSWORD=default-entitlements-password
KC_ADMIN_PASSWORD=default-admin-password
KC_ADMIN_CLIENT_SECRET=default-client-secret
EOF
cat > "${tmp}/docker/.env.local" <<'EOF'
POSTGRES_PASSWORD=local-password
EOF

(
  unset POSTGRES_PASSWORD KC_DB_PASSWORD OKAPI_DB_PASSWORD KONG_DB_PASSWORD
  unset MGR_APPLICATIONS_DB_PASSWORD MGR_TENANTS_DB_PASSWORD
  unset MGR_TENANT_ENTITLEMENTS_DB_PASSWORD KC_ADMIN_PASSWORD KC_ADMIN_CLIENT_SECRET
  PROJECT_ROOT="${PROJECT_ROOT}"
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/misc/bootstrap-engine.sh"
  DOCKER_DIR="${tmp}/docker"
  FOLIO_DOCKER_DIR="${DOCKER_DIR}"
  refresh_local_credentials
)

grep -qx 'export POSTGRES_PASSWORD=local-password' "${tmp}/docker/.env.local.credentials" \
  || { cat "${tmp}/docker/.env.local.credentials" >&2; fail 'local password was not preserved when seeding credentials'; }

echo 'ok  initial credentials preserve docker/.env.local overrides'
