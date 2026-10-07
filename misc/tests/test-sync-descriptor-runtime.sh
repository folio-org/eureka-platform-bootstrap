#!/usr/bin/env bash
# Sync preserves operator IMAGE/VERSION overrides at each config layer, while
# descriptor-derived values are refreshed after actualize.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin" "${tmp}/docker"
stdout_file="${tmp}/stdout"
stderr_file="${tmp}/stderr"
REAL_PYTHON3="$(command -v python3)"
export REAL_PYTHON3

# Only runtime metadata generation is stubbed; module exports follow the test
# descriptor so actualize can exercise the real unset/re-export path.
cat >"${tmp}/bin/python3" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'docker-module-updater/run.py'*'--services'*) printf 'mod-users sc-users\n' ;;
  *'docker-module-updater/run.py'*'--module-env'*)
    version="$(jq -r '.modules[0].version' "$3")"
    printf 'export MOD_USERS_IMAGE=folioorg/mod-users:%s\n' "${version}"
    printf 'export MOD_USERS_VERSION=%s\n' "${version}"
    ;;
  *'docker-module-updater/run.py'*) ;;
  *) "${REAL_PYTHON3:?}" "$@" ;;
esac
EOF
cat >"${tmp}/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  'image inspect --format {{.Architecture}} '*) printf 'arm64\n' ;;
esac
EOF
chmod +x "${tmp}/bin/python3" "${tmp}/bin/docker"
PATH="${tmp}/bin:${PATH}"
DEBUG=false
NO_COLOR=1
TERM=dumb

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/misc/bootstrap-engine.sh"

DOCKER_DIR="${tmp}/docker"
FOLIO_DOCKER_DIR="${DOCKER_DIR}"
APP_DESCRIPTOR_PATH="${tmp}/descriptor.json"
cat >"${APP_DESCRIPTOR_PATH}" <<'EOF'
{"id":"app-test-1.0.0","name":"app-test","modules":[{"name":"mod-users","version":"19.6.0"}]}
EOF
SIDECAR_MODE=jvm
BUILD_ARM_IMAGES=false
ASSUME_YES=true
ACTUALIZE_MODULES=false
UI_UNICODE=false
UI_COLOR=false

cat >"${DOCKER_DIR}/.env" <<'EOF'
MOD_USERS_IMAGE=folioorg/mod-users:19.4.0
MOD_USERS_VERSION=19.4.0
EOF
printf 'MOD_USERS_VERSION=19.1.0\n' >"${DOCKER_DIR}/.env.local"
printf 'MOD_USERS_VERSION=19.2.0\n' >"${DOCKER_DIR}/.env.local.credentials"

run_sync() { # <expected VERSION> [shell VERSION] [shell IMAGE]
  set +e
  (
    set -euo pipefail
    unset MOD_USERS_IMAGE MOD_USERS_VERSION
    if [[ $# -gt 1 ]]; then export MOD_USERS_VERSION="$2"; fi
    if [[ $# -gt 2 ]]; then export MOD_USERS_IMAGE="$3"; fi
    capture_initial_image_env_names
    load_folio_config
    sync_descriptor_runtime
    [[ "${MOD_USERS_VERSION}" == "$1" ]] || fail "sync replaced the chosen VERSION with '${MOD_USERS_VERSION}'"
    [[ "${MOD_USERS_IMAGE}" == "${3:-folioorg/mod-users:19.6.0}" ]] \
      || fail "sync replaced the chosen IMAGE with '${MOD_USERS_IMAGE}'"
    check_and_handle_descriptor_image_skew
  ) >"${stdout_file}" 2>"${stderr_file}"
  run_status=$?
  set -e
  [[ ! -s "${stdout_file}" ]] || fail 'sync or skew guard wrote to stdout'
}

assert_skew() { # <chosen VERSION> <winning source>
  [[ ${run_status} -ne 0 ]] || { cat "${stderr_file}" >&2; fail "VERSION from $2 passed the skew guard"; }
  grep -Fq "MOD_USERS_VERSION='$1' ($2)" "${stderr_file}" \
    || { cat "${stderr_file}" >&2; fail "diagnostic did not show the chosen VERSION from $2"; }
}

# Shell wins even when both override files contain a different VERSION.
run_sync '19.0.0' '19.0.0'
assert_skew '19.0.0' 'shell override'
run_sync '' ''
assert_skew '' 'shell override'
run_sync '19.6.0' '19.6.0'
[[ ${run_status} -eq 0 ]] || fail 'matching shell VERSION did not beat file overrides'

# IMAGE and VERSION operator overrides both survive the sync.
run_sync '19.0.0' '19.0.0' 'custom/mod-users:test'
assert_skew '19.0.0' 'shell override'
grep -Fq "MOD_USERS_IMAGE='custom/mod-users:test' (shell override)" "${stderr_file}" \
  || fail 'sync discarded the operator IMAGE override'

# Without shell overrides, credentials wins over local; local wins over defaults.
run_sync '19.2.0'
assert_skew '19.2.0' 'credentials'
rm -f "${DOCKER_DIR}/.env.local.credentials"
run_sync '19.1.0'
assert_skew '19.1.0' 'local override'
printf 'MOD_USERS_VERSION=19.6.0\n' >"${DOCKER_DIR}/.env.local"
run_sync '19.6.0'
[[ ${run_status} -eq 0 ]] || fail 'matching local VERSION was rejected'

# With no operator override, stale defaults and a previous sync must be replaced
# by the actualized descriptor IMAGE and VERSION, rather than causing skew.
rm -f "${DOCKER_DIR}/.env.local"
run_module_version_actualizer() {
  cat >"${APP_DESCRIPTOR_PATH}" <<'EOF'
{"id":"app-test-1.0.1","name":"app-test","modules":[{"name":"mod-users","version":"19.7.0"}]}
EOF
}
(
  set -euo pipefail
  unset MOD_USERS_IMAGE MOD_USERS_VERSION
  capture_initial_image_env_names
  load_folio_config
  export MOD_USERS_IMAGE='folioorg/mod-users:19.5.0'
  export MOD_USERS_VERSION='19.5.0'
  ACTUALIZE_MODULES=true
  sync_descriptor_runtime
  [[ "${MOD_USERS_IMAGE}" == 'folioorg/mod-users:19.7.0' ]] || fail 'descriptor IMAGE was not refreshed'
  [[ "${MOD_USERS_VERSION}" == '19.7.0' ]] || fail 'descriptor VERSION was not refreshed'
  check_and_handle_descriptor_image_skew
) >"${stdout_file}" 2>"${stderr_file}" \
  || { cat "${stderr_file}" >&2; fail 'actualize refresh did not produce aligned runtime values'; }
[[ ! -s "${stdout_file}" ]] || fail 'actualize sync wrote to stdout'

printf 'ok  runtime sync preserves shell/credentials/local overrides and refreshes descriptor defaults\n'
