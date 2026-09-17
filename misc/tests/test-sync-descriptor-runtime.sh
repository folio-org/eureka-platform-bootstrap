#!/usr/bin/env bash
#
# Hermetic proof that sync_descriptor_runtime preserves operator-sourced
# MOD_*_IMAGE / MOD_*_VERSION overrides (shell env or .env.local) while still
# force-refreshing descriptor-derived values after an actualize.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

stub_bin="$(mktemp -d)"
tmp="$(mktemp -d)"
stdout_file="$(mktemp)"
stderr_file="$(mktemp)"
trap 'rm -rf "${stub_bin}" "${tmp}" "${stdout_file}" "${stderr_file}"' EXIT

# Stub python3: run.py --module-env emits the descriptor-derived image/version;
# the sync (--app) call is a no-op; everything else defers to real python3.
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
  *'docker-module-updater/run.py'*)
    exit 0
    ;;
  *)
    "\${REAL_PYTHON3:?}" "\$@"
    ;;
esac
EOF
chmod +x "${stub_bin}/python3"

# Stub docker: image inspect reports arm64 so the image plan rows render.
cat > "${stub_bin}/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2 $3" == "image inspect --format" ]]; then
  case "$4" in *Architecture*) printf 'arm64\n' ;; esac
  exit 0
fi
exit 0
EOF
chmod +x "${stub_bin}/docker"

mkdir -p "${tmp}/docker"
cat > "${tmp}/docker/.env.local" <<'EOF'
MOD_USERS_IMAGE=custom/mod-users:test
MOD_USERS_VERSION=19.0.0
EOF

PATH="${stub_bin}:${PATH}"
DEBUG=false
NO_COLOR=1
TERM=dumb

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/misc/bootstrap-engine.sh"

DOCKER_DIR="${tmp}/docker"
FOLIO_DOCKER_DIR="${DOCKER_DIR}"
APP_DESCRIPTOR_PATH="${PROJECT_ROOT}/descriptors/app-platform-minimal/descriptor.json"
SECRET_STORE_VAULT_TOKEN='vault-root-token'
MGR_APPLICATIONS_IMAGE='folioci/mgr-applications:latest'
MGR_TENANTS_IMAGE='folioci/mgr-tenants:latest'
MGR_TENANT_ENTITLEMENTS_IMAGE='folioci/mgr-tenant-entitlements:latest'
FOLIO_KEYCLOAK_IMAGE='folioci/folio-keycloak:latest'
FOLIO_KONG_IMAGE='folioci/folio-kong:latest'
FOLIO_MODULE_SIDECAR_IMAGE='folioorg/folio-module-sidecar:latest'
SIDECAR_MODE='jvm'
BUILD_ARM_IMAGES='false'
ASSUME_YES='true'
ACTUALIZE_MODULES='false'
UI_UNICODE=false
UI_COLOR=false

# --- Test A: operator override survives the sync and shows up as skew ---------
# Exported, so the pre-run shell-env provenance arm (initial_env_has_name) is
# the one under test; the tmp .env.local carries the same values as backup.
export MOD_USERS_IMAGE='custom/mod-users:test'
export MOD_USERS_VERSION='19.0.0'
capture_initial_image_env_names

sync_descriptor_runtime >"${stdout_file}" 2>"${stderr_file}"

[[ "${MOD_USERS_IMAGE}" == 'custom/mod-users:test' ]] \
  || fail "operator MOD_USERS_IMAGE was clobbered by the sync (got '${MOD_USERS_IMAGE}')"
[[ "${MOD_USERS_VERSION}" == '19.0.0' ]] \
  || fail "operator MOD_USERS_VERSION was clobbered by the sync (got '${MOD_USERS_VERSION}')"

grep -q 'custom/mod-users:test' "${stderr_file}" \
  || { cat "${stderr_file}" >&2; fail 'image plan did not show the operator override'; }
SKEW_MODULES=(); SKEW_DESCRIPTOR_VERSIONS=(); SKEW_IMAGE_TAGS=()
: >"${stdout_file}"; : >"${stderr_file}"
print_image_plan >"${stdout_file}" 2>"${stderr_file}"
[[ "${#SKEW_MODULES[@]}" -gt 0 && "${SKEW_MODULES[0]}" == 'mod-users' ]] \
  || fail 'image plan did not report skew for the surviving override'

# --- Test B: non-operator values are still force-refreshed by the sync --------
rm -rf "${tmp}/docker2"
mkdir -p "${tmp}/docker2"
DOCKER_DIR="${tmp}/docker2"
FOLIO_DOCKER_DIR="${DOCKER_DIR}"
unset MOD_USERS_IMAGE MOD_USERS_VERSION
capture_initial_image_env_names
# Simulate a value exported by a PREVIOUS bootstrap sync (not operator-sourced,
# hence invisible to the initial-env capture): the sync must replace it.
export MOD_USERS_IMAGE='folioorg/mod-users:19.5.0'

sync_descriptor_runtime >"${stdout_file}" 2>"${stderr_file}"

[[ "${MOD_USERS_IMAGE}" == 'folioorg/mod-users:19.6.0' ]] \
  || fail "descriptor-derived MOD_USERS_IMAGE was not refreshed (got '${MOD_USERS_IMAGE}')"
[[ "${MOD_USERS_VERSION}" == '19.6.0' ]] \
  || fail "descriptor-derived MOD_USERS_VERSION was not re-exported (got '${MOD_USERS_VERSION:-}')"

printf 'ok  sync_descriptor_runtime preserves operator overrides and refreshes descriptor values\n'
