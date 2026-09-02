#!/usr/bin/env bash
#
# Contract for helpers whose stdout is consumed as machine data. These helpers
# must keep returning bare values on stdout and must not leak narration into the
# captured stream.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

stub_bin="$(mktemp -d)"
stdout_file="$(mktemp)"
stderr_file="$(mktemp)"
trap 'rm -rf "${stub_bin}" "${stdout_file}" "${stderr_file}"' EXIT

if grep -n '/usr/bin/'"python3" "${BASH_SOURCE[0]}" >/dev/null; then
  fail 'test must resolve python3 from PATH instead of hardcoding an absolute interpreter path'
fi

REAL_PYTHON3="$(command -v python3)"
export REAL_PYTHON3

cat > "${stub_bin}/curl" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "${args}" in
  *'/realms/master/protocol/openid-connect/token'*)
    printf '{"access_token":"system-token-123"}'
    ;;
  *'http://localhost:8200/v1/secret/data/folio/diku'*)
    printf '{"data":{"data":{"m2m-client":"tenant-secret-abc"}}}\n200'
    ;;
  *'/realms/diku/protocol/openid-connect/token'*)
    printf '{"access_token":"tenant-token-456"}'
    ;;
  *)
    printf 'unexpected curl call: %s\n' "${args}" >&2
    exit 2
    ;;
esac
EOF
chmod +x "${stub_bin}/curl"

cat > "${stub_bin}/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2 $3" == "image inspect --format" ]]; then
  fmt="$4"
  case "${fmt}" in
    *Architecture*) printf 'arm64\n' ;;
    *Entrypoint*) printf '["./application"]\n' ;;
    *Created*) printf '2026-06-20T00:00:00.000000000Z\n' ;;
  esac
  exit 0
fi
exit 0
EOF
chmod +x "${stub_bin}/docker"

cat > "${stub_bin}/python3" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'docker-module-updater/run.py'*'--services'*)
    printf 'mod-users sc-users\n'
    ;;
  -\ *)
    "${REAL_PYTHON3:?}" "$@"
    ;;
  *)
    "${REAL_PYTHON3:?}" "$@"
    ;;
esac
EOF
chmod +x "${stub_bin}/python3"

PATH="${stub_bin}:${PATH}"
DEBUG=false
NO_COLOR=1
TERM=dumb

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/misc/bootstrap-engine.sh"

APP_DESCRIPTOR_PATH="${PROJECT_ROOT}/descriptors/app-platform-minimal/descriptor.json"
SECRET_STORE_VAULT_TOKEN='vault-root-token'

assert_stdout_value() {
  local description="$1"
  local expected="$2"
  shift 2
  : >"${stdout_file}"
  : >"${stderr_file}"
  "$@" >"${stdout_file}" 2>"${stderr_file}"
  local actual
  actual="$(cat "${stdout_file}")"
  [[ "${actual}" == "${expected}" ]] || {
    sed 's/^/stdout: /' "${stdout_file}" >&2
    sed 's/^/stderr: /' "${stderr_file}" >&2
    fail "${description}: expected stdout '${expected}', got '${actual}'"
  }
}

assert_stdout_value 'resolve_absolute_path' "${PROJECT_ROOT}/start.sh" \
  resolve_absolute_path "${PROJECT_ROOT}/start.sh"
assert_stdout_value 'host_api_gateway_url' 'http://localhost:8000' host_api_gateway_url
assert_stdout_value 'host_kong_url' 'http://localhost:8000' host_kong_url
assert_stdout_value 'host_keycloak_url' 'http://localhost:8080' host_keycloak_url
assert_stdout_value 'image_source_for_var fallback' 'descriptor' image_source_for_var MOD_USERS_IMAGE descriptor
assert_stdout_value 'image_plan_action' 'native arm64 present' image_plan_action mod-users folioci/mod-users:latest
assert_stdout_value 'obtain_system_access_token' 'system-token-123' obtain_system_access_token
assert_stdout_value 'obtain_tenant_access_token' 'tenant-token-456' obtain_tenant_access_token diku

: >"${stdout_file}"
: >"${stderr_file}"
resolve_app_services >"${stdout_file}" 2>"${stderr_file}"
[[ ! -s "${stdout_file}" ]] || fail 'resolve_app_services leaked data to stdout'
[[ "${APP_SERVICES[*]}" == 'mod-users sc-users' ]] || fail "resolve_app_services set unexpected services: ${APP_SERVICES[*]}"

MGR_APPLICATIONS_IMAGE='folioci/mgr-applications:very-long-tag-that-should-expand'
MGR_TENANTS_IMAGE='folioci/mgr-tenants:very-long-tag-that-should-expand'
MGR_TENANT_ENTITLEMENTS_IMAGE='folioci/mgr-tenant-entitlements:very-long-tag-that-should-expand'
FOLIO_KEYCLOAK_IMAGE='folioci/folio-keycloak:very-long-tag-that-should-expand'
FOLIO_KONG_IMAGE='folioci/folio-kong:very-long-tag-that-should-expand'
FOLIO_MODULE_SIDECAR_IMAGE='folioorg/folio-module-sidecar:very-long-tag-that-should-expand'
SIDECAR_MODE='jvm'
BUILD_ARM_IMAGES='true'
ASSUME_YES='true'
IMAGE_BUILD_PENDING=false
IMAGE_REFRESH_AVAILABLE=false

: >"${stdout_file}"
: >"${stderr_file}"
UI_UNICODE=true
UI_COLOR=false
ui_cols() { printf '140\n'; }
print_image_plan >"${stdout_file}" 2>"${stderr_file}"
[[ ! -s "${stdout_file}" ]] || fail 'print_image_plan leaked data to stdout'
grep -q 'SRC' "${stderr_file}" || { sed 's/^/stderr: /' "${stderr_file}" >&2; fail 'image plan did not render source column'; }
grep -q 'default' "${stderr_file}" || { sed 's/^/stderr: /' "${stderr_file}" >&2; fail 'image plan did not render default provenance'; }
grep -q 'mgr-tenant-entitlements' "${stderr_file}" \
  || { sed 's/^/stderr: /' "${stderr_file}" >&2; fail 'wide image plan still truncated module names'; }
grep -q 'folio-module-sidecar' "${stderr_file}" \
  || { sed 's/^/stderr: /' "${stderr_file}" >&2; fail 'wide image plan still truncated sidecar name'; }
awk 'length($0) > 90 { found = 1 } END { exit found ? 0 : 1 }' "${stderr_file}" \
  || { sed 's/^/stderr: /' "${stderr_file}" >&2; fail 'wide image plan did not expand beyond the legacy 78 columns'; }

: >"${stdout_file}"
: >"${stderr_file}"
UI_UNICODE=false
print_final_summary 'Partially ready' '12s' 'failed' \
  'Rerun ./start.sh after the platform stabilizes.' \
  >"${stdout_file}" 2>"${stderr_file}"
[[ ! -s "${stdout_file}" ]] || fail 'print_final_summary leaked data to stdout'
grep -q 'Bootstrap complete - Partially ready' "${stderr_file}" \
  || { sed 's/^/stderr: /' "${stderr_file}" >&2; fail 'final summary did not render ASCII-safe title'; }
grep -q 'Smoke check: failed' "${stderr_file}" \
  || fail 'final summary did not include smoke check result'
grep -q 'Rerun ./start.sh after the platform stabilizes.' "${stderr_file}" \
  || fail 'final summary truncated next-step command'
if LC_ALL=C grep -q '[^ -~]' "${stderr_file}"; then
  sed 's/^/stderr: /' "${stderr_file}" >&2
  fail 'final summary emitted non-ASCII in flat output'
fi

# The identity banner prints above the Configure phase, before the prompts settle,
# so it must not carry a chosen sidecar mode (that would be stale). print_run_mode
# surfaces the resolved sidecar/module choices instead.
: >"${stdout_file}"
: >"${stderr_file}"
SIDECAR_MODE='native'
print_run_banner >"${stdout_file}" 2>"${stderr_file}"
[[ ! -s "${stdout_file}" ]] || fail 'print_run_banner leaked data to stdout'
grep -q 'eureka platform bootstrap' "${stderr_file}" \
  || { sed 's/^/stderr: /' "${stderr_file}" >&2; fail 'banner dropped its title'; }
if grep -q 'native' "${stderr_file}"; then
  sed 's/^/stderr: /' "${stderr_file}" >&2
  fail 'banner still shows the sidecar mode token (should be surfaced by print_run_mode)'
fi

: >"${stdout_file}"
: >"${stderr_file}"
SIDECAR_MODE='native'
ACTUALIZE_MODULES='true'
print_run_mode >"${stdout_file}" 2>"${stderr_file}"
[[ ! -s "${stdout_file}" ]] || fail 'print_run_mode leaked data to stdout'
grep -q 'sidecar native' "${stderr_file}" \
  || { sed 's/^/stderr: /' "${stderr_file}" >&2; fail 'run mode did not surface the sidecar runtime'; }
grep -q 'modules actualized' "${stderr_file}" \
  || { sed 's/^/stderr: /' "${stderr_file}" >&2; fail 'run mode did not surface module actualization'; }
if LC_ALL=C grep -q "$(printf '\033')" "${stderr_file}"; then
  sed 's/^/stderr: /' "${stderr_file}" >&2
  fail 'print_run_mode emitted ESC bytes with color off'
fi

printf 'ok  capture-sensitive helpers keep bare stdout values\n'
