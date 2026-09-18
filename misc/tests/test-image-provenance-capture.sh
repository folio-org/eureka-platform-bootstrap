#!/usr/bin/env bash
#
# Image provenance labels must reflect where a value actually came from.
# capture_initial_image_env_names must run BEFORE load_folio_config (the
# engine's ordering): the capture is supposed to remember image variables that
# were present in the shell BEFORE repository config was loaded. Capturing
# after the load mislabels every committed docker/.env image default as
# "shell override" in the Image plan.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/misc/lib/folio-common.sh"
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/misc/bootstrap-engine.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# Crafted config tree: committed default, local override, and a real pre-run
# shell value. Credentials stay absent (their layer is covered by the loader's
# own precedence test).
cat >"${tmp}/.env" <<'EOF'
export FOLIO_KONG_IMAGE=folioci/folio-kong:latest
export FOLIO_APISIX_IMAGE=folioci/folio-apisix:latest
export MGR_TENANTS_IMAGE=folioci/mgr-tenants:latest
EOF
cat >"${tmp}/.env.local" <<'EOF'
export MGR_TENANTS_IMAGE=folioci/mgr-tenants:local-build
EOF

unset FOLIO_KONG_IMAGE FOLIO_APISIX_IMAGE MGR_TENANTS_IMAGE || true
export FOLIO_APISIX_IMAGE=folioci/folio-apisix:shell-pin

FOLIO_DOCKER_DIR="${tmp}"
DOCKER_DIR="${tmp}"

# The engine's ordering (run_bootstrap_flow): capture the pre-config shell set
# first, only then load repository config.
capture_initial_image_env_names
load_folio_config

source_is() {
  local name="$1" expected="$2" actual
  actual="$(image_source_for_var "${name}" default)"
  [[ "${actual}" == "${expected}" ]] \
    || fail "image_source_for_var ${name} = '${actual}', expected '${expected}'"
}

source_is FOLIO_APISIX_IMAGE 'shell override'
source_is FOLIO_KONG_IMAGE 'default'
source_is MGR_TENANTS_IMAGE 'local override'

# The capture must not be repeat-after-load: a capture taken after the config
# load would mislabel committed defaults (the original bug). Guard the exact
# ordering inside run_bootstrap_flow so a future reorder cannot resurrect it.
flow_body="$(awk '/^run_bootstrap_flow\(\) \{/,/^\}/' "${PROJECT_ROOT}/misc/bootstrap-engine.sh")"
capture_line="$(printf '%s\n' "${flow_body}" | grep -n 'capture_initial_image_env_names' | cut -d: -f1)"
load_line="$(printf '%s\n' "${flow_body}" | grep -n 'load_folio_config' | head -n 1 | cut -d: -f1)"
[[ -n "${capture_line}" && -n "${load_line}" ]] || fail 'run_bootstrap_flow no longer calls the capture/load pair'
[[ ${capture_line} -lt ${load_line} ]] \
  || fail 'run_bootstrap_flow captures image env names after load_folio_config (provenance regression)'

printf 'ok  image provenance: shell override vs committed default vs local override labeled correctly\n'
