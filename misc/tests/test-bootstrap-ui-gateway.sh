#!/usr/bin/env bash
#
# Offline regression check for the bootstrap -> UI helper boundary.
#
# The bootstrap parent shell may contain Compose-internal OKAPI_URL from docker/.env.
# UI helpers must receive explicit host/browser URLs instead of relying on that
# inherited value.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

stub_bin="$(mktemp -d)"
docker_dir="$(mktemp -d)"
env_log="$(mktemp)"
trap 'rm -rf "${stub_bin}" "${docker_dir}" "${env_log}"' EXIT

cat > "${stub_bin}/bash" <<'EOF'
#!/bin/bash
set -euo pipefail

printf 'cmd=%s\n' "$*" >> "${UI_HELPER_ENV_LOG:?}"
printf 'OKAPI_URL=%s\n' "${OKAPI_URL:-}" >> "${UI_HELPER_ENV_LOG:?}"
printf 'KONG_URL=%s\n' "${KONG_URL:-}" >> "${UI_HELPER_ENV_LOG:?}"
printf 'KEYCLOAK_URL=%s\n' "${KEYCLOAK_URL:-}" >> "${UI_HELPER_ENV_LOG:?}"
exit 0
EOF
chmod +x "${stub_bin}/bash"

cat > "${stub_bin}/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  'compose --profile ui up -d') exit 0 ;;
  *) printf 'unexpected docker call: %s\n' "$*" >&2; exit 2 ;;
esac
EOF
chmod +x "${stub_bin}/docker"
touch "${docker_dir}/.env.local"

DEBUG=false
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/misc/bootstrap-engine.sh"
wait_for_all_healthy() { return 0; }
DOCKER_DIR="${docker_dir}"

run_build_and_deploy_ui() {
  : > "${env_log}"
  (
    cd "${docker_dir}"
    PATH="${stub_bin}:${PATH}" \
      UI_HELPER_ENV_LOG="${env_log}" \
      OKAPI_URL='http://api-gateway:8000' \
      "$@"
  )
}

run_build_and_deploy_ui build_and_deploy_ui
grep -q '^OKAPI_URL=http://api-gateway:8000$' "${env_log}" \
  || { cat "${env_log}" >&2; fail "test did not simulate inherited Compose OKAPI_URL"; }
grep -q '^KONG_URL=http://localhost:8000$' "${env_log}" \
  || { cat "${env_log}" >&2; fail "bootstrap did not pass host KONG_URL to UI helpers"; }
grep -q '^KEYCLOAK_URL=http://localhost:8080$' "${env_log}" \
  || { cat "${env_log}" >&2; fail "bootstrap did not pass host KEYCLOAK_URL to UI helpers"; }

KONG_URL='http://gateway.example.test:18000' \
  KEYCLOAK_URL='http://keycloak.example.test:18080' \
  run_build_and_deploy_ui build_and_deploy_ui
grep -q '^KONG_URL=http://gateway.example.test:18000$' "${env_log}" \
  || { cat "${env_log}" >&2; fail "bootstrap overwrote operator KONG_URL"; }
grep -q '^KEYCLOAK_URL=http://keycloak.example.test:18080$' "${env_log}" \
  || { cat "${env_log}" >&2; fail "bootstrap overwrote operator KEYCLOAK_URL"; }

printf 'ok  bootstrap passes host/browser URLs to UI helpers\n'
