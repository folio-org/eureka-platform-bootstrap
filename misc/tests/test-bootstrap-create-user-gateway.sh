#!/usr/bin/env bash
#
# Offline regression check for the bootstrap -> create-user.sh boundary.
#
# The bootstrap loads docker/.env into its environment, including the
# Compose-internal OKAPI_URL=http://api-gateway:8000. create-user.sh must not
# inherit that value as its host gateway when called by the bootstrap.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DOCKER_DIR="${PROJECT_ROOT}/docker"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

stub_bin="$(mktemp -d)"
env_log="$(mktemp)"
trap 'rm -rf "${stub_bin}" "${env_log}"' EXIT

cat > "${stub_bin}/bash" <<'EOF'
#!/bin/bash
set -euo pipefail

printf 'cmd=%s\n' "$*" >> "${CREATE_USER_ENV_LOG:?}"
printf 'OKAPI_URL=%s\n' "${OKAPI_URL:-}" >> "${CREATE_USER_ENV_LOG:?}"
printf 'API_GATEWAY_URL=%s\n' "${API_GATEWAY_URL:-}" >> "${CREATE_USER_ENV_LOG:?}"
exit 0
EOF
chmod +x "${stub_bin}/bash"

DEBUG=false
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/misc/bootstrap-engine.sh"

run_create_default_admin_user() {
  : > "${env_log}"
  PATH="${stub_bin}:${PATH}" \
    CREATE_USER_ENV_LOG="${env_log}" \
    OKAPI_URL='http://api-gateway:8000' \
    "$@"
}

run_create_default_admin_user create_default_admin_user
grep -q 'cmd=.*/misc/create-user.sh folio folio' "${env_log}" \
  || { cat "${env_log}" >&2; fail "bootstrap did not invoke create-user.sh"; }
grep -q '^OKAPI_URL=http://api-gateway:8000$' "${env_log}" \
  || { cat "${env_log}" >&2; fail "test did not simulate inherited Compose OKAPI_URL"; }
grep -q '^API_GATEWAY_URL=http://localhost:8000$' "${env_log}" \
  || { cat "${env_log}" >&2; fail "bootstrap did not pass host API_GATEWAY_URL to create-user.sh"; }

API_GATEWAY_URL='http://gateway.example.test:18000' run_create_default_admin_user create_default_admin_user
grep -q '^API_GATEWAY_URL=http://gateway.example.test:18000$' "${env_log}" \
  || { cat "${env_log}" >&2; fail "bootstrap overwrote operator API_GATEWAY_URL"; }

FOLIO_KONG_URL='http://folio-kong.example.test:18000' run_create_default_admin_user create_default_admin_user
grep -q '^API_GATEWAY_URL=http://folio-kong.example.test:18000$' "${env_log}" \
  || { cat "${env_log}" >&2; fail "bootstrap ignored FOLIO_KONG_URL host gateway"; }

KONG_URL='http://kong.example.test:18000' \
  FOLIO_KONG_URL='http://folio-kong.example.test:18000' \
  run_create_default_admin_user create_default_admin_user
grep -q '^API_GATEWAY_URL=http://kong.example.test:18000$' "${env_log}" \
  || { cat "${env_log}" >&2; fail "bootstrap did not prefer KONG_URL over FOLIO_KONG_URL"; }

printf 'ok  bootstrap passes a host gateway URL to create-user.sh\n'
