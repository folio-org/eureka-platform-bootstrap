#!/usr/bin/env bash
#
# Hermetic proof that descriptor/image version skew is detected, and that the
# non-interactive path hard-halts with an actionable message. Also covers the
# tagless and digest-pinned edge cases (no false positives).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

stub_bin="$(mktemp -d)"
stdout_file="$(mktemp)"
stderr_file="$(mktemp)"
trap 'rm -rf "${stub_bin}" "${stdout_file}" "${stderr_file}"' EXIT

# Stub python3: --services returns one module pair; --module-env returns a
# pinned image that is NEWER than the descriptor version (the skew case).
REAL_PYTHON3="$(command -v python3)"
cat > "${stub_bin}/python3" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *'docker-module-updater/run.py'*'--services'*)
    printf 'mod-users sc-users\n'
    ;;
  *'docker-module-updater/run.py'*'--module-env'*)
    printf 'export MOD_USERS_IMAGE=folioorg/mod-users:19.6.0\n'
    printf 'export MOD_USERS_VERSION=19.6.0\n'
    ;;
  *)
    "\${REAL_PYTHON3:?}" "\$@"
    ;;
esac
EOF
chmod +x "${stub_bin}/python3"

# Stub docker: image inspect returns arm64 so print_image_plan_row is happy.
cat > "${stub_bin}/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2 $3" == "image inspect --format" ]]; then
  case "$4" in *Architecture*) printf 'arm64\n' ;; esac
  exit 0
fi
exit 0
EOF
chmod +x "${stub_bin}/docker"

PATH="${stub_bin}:${PATH}"
DEBUG=false
NO_COLOR=1
TERM=dumb

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/misc/bootstrap-engine.sh"

APP_DESCRIPTOR_PATH="${PROJECT_ROOT}/descriptors/app-platform-minimal/descriptor.json"
SECRET_STORE_VAULT_TOKEN='vault-root-token'

# Read the mod-users version the same way print_image_plan does (bootstrap-engine.sh:
# `jq '.modules[] | [.name, .version]'`) so the test tracks the descriptor instead of
# a hardcoded tag that re-breaks on every --actualize.
MOD_USERS_DESC_VER="$(jq -r '.modules[] | select(.name=="mod-users") | .version' "${APP_DESCRIPTOR_PATH}")"
[[ -n "${MOD_USERS_DESC_VER}" && "${MOD_USERS_DESC_VER}" != null ]] \
  || fail "could not read mod-users version from ${APP_DESCRIPTOR_PATH}"

# Populate the infra image vars so print_image_plan renders without errors.
MGR_APPLICATIONS_IMAGE='folioci/mgr-applications:latest'
MGR_TENANTS_IMAGE='folioci/mgr-tenants:latest'
MGR_TENANT_ENTITLEMENTS_IMAGE='folioci/mgr-tenant-entitlements:latest'
FOLIO_KEYCLOAK_IMAGE='folioci/folio-keycloak:latest'
FOLIO_KONG_IMAGE='folioci/folio-kong:latest'
FOLIO_MODULE_SIDECAR_IMAGE='folioorg/folio-module-sidecar:latest'
SIDECAR_MODE='jvm'
BUILD_ARM_IMAGES='false'
ASSUME_YES='true'
IMAGE_BUILD_PENDING=false
IMAGE_REFRESH_AVAILABLE=false
UI_UNICODE=false
UI_COLOR=false
ui_cols() { printf '140\n'; }

# --- Test A: skew IS detected when MOD_USERS_IMAGE tag != descriptor version ---
# Force a tag guaranteed to differ from whatever the descriptor pins.
MOD_USERS_IMAGE="folioci/mod-users:${MOD_USERS_DESC_VER}-skew"

: >"${stdout_file}"; : >"${stderr_file}"
print_image_plan >"${stdout_file}" 2>"${stderr_file}"

[[ ${#SKEW_MODULES[@]} -gt 0 ]] || { sed 's/^/stderr: /' "${stderr_file}" >&2; fail 'skew not detected when image tag differs from descriptor version'; }
[[ "${SKEW_MODULES[0]}" == 'mod-users' ]] || fail "expected mod-users in SKEW_MODULES, got '${SKEW_MODULES[0]}'"
[[ "${SKEW_DESCRIPTOR_VERSIONS[0]}" == "${MOD_USERS_DESC_VER}" ]] || fail "expected descriptor ${MOD_USERS_DESC_VER}, got '${SKEW_DESCRIPTOR_VERSIONS[0]}'"
[[ "${SKEW_IMAGE_TAGS[0]}" == "${MOD_USERS_DESC_VER}-skew" ]] || fail "expected tag ${MOD_USERS_DESC_VER}-skew, got '${SKEW_IMAGE_TAGS[0]}'"

# --- Test B: skew NOT detected when tag matches descriptor version ---
MOD_USERS_IMAGE="folioorg/mod-users:${MOD_USERS_DESC_VER}"
SKEW_MODULES=(); SKEW_DESCRIPTOR_VERSIONS=(); SKEW_IMAGE_TAGS=()
: >"${stdout_file}"; : >"${stderr_file}"
print_image_plan >"${stdout_file}" 2>"${stderr_file}"
[[ ${#SKEW_MODULES[@]} -eq 0 ]] || { sed 's/^/stderr: /' "${stderr_file}" >&2; fail 'false-positive skew when tag matches descriptor version'; }

# --- Test C: tagless image ref is skipped (no false positive) ---
MOD_USERS_IMAGE='folioorg/mod-users'
SKEW_MODULES=(); SKEW_DESCRIPTOR_VERSIONS=(); SKEW_IMAGE_TAGS=()
: >"${stdout_file}"; : >"${stderr_file}"
print_image_plan >"${stdout_file}" 2>"${stderr_file}"
[[ ${#SKEW_MODULES[@]} -eq 0 ]] || { sed 's/^/stderr: /' "${stderr_file}" >&2; fail 'false-positive skew on tagless image ref'; }

# --- Test D: digest-pinned image ref is skipped (no false positive) ---
MOD_USERS_IMAGE='folioorg/mod-users@sha256:abcdef'
SKEW_MODULES=(); SKEW_DESCRIPTOR_VERSIONS=(); SKEW_IMAGE_TAGS=()
: >"${stdout_file}"; : >"${stderr_file}"
print_image_plan >"${stdout_file}" 2>"${stderr_file}"
[[ ${#SKEW_MODULES[@]} -eq 0 ]] || { sed 's/^/stderr: /' "${stderr_file}" >&2; fail 'false-positive skew on digest-pinned image ref'; }

# --- Test E: non-interactive skew halt produces actionable message ---
# check_and_handle_descriptor_image_skew ends with `exit 1` (the established
# hard-halt pattern in this codebase). A sourced `exit` terminates the whole
# process, so it cannot be caught by set +e in the caller — it MUST run in a
# subshell, whose array-inheriting fork lets SKEW_* be read and whose exit code
# can be captured.
MOD_USERS_IMAGE="folioci/mod-users:${MOD_USERS_DESC_VER}-skew"
SKEW_MODULES=(); SKEW_DESCRIPTOR_VERSIONS=(); SKEW_IMAGE_TAGS=()
: >"${stdout_file}"; : >"${stderr_file}"
print_image_plan >/dev/null 2>"${stderr_file}"
set +e
( check_and_handle_descriptor_image_skew ) >"${stdout_file}" 2>"${stderr_file}"
rc=$?
set -e
[[ ${rc} -ne 0 ]] || fail 'check_and_handle_descriptor_image_skew should halt on skew in non-interactive mode'
grep -qi 'actualize' "${stderr_file}" || { sed 's/^/stderr: /' "${stderr_file}" >&2; fail 'halt message does not mention actualize'; }
grep -qi 'mod-users' "${stderr_file}" || { sed 's/^/stderr: /' "${stderr_file}" >&2; fail 'halt message does not name the skewing module'; }

printf 'ok  descriptor/image skew detected and halted with actionable message\n'
