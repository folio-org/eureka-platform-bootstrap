#!/usr/bin/env bash
#
# Hermetic proof of the gateway route guard in register_application_descriptor.
#
# A gateway switch with kept volumes (or a wiped gateway route store) leaves the
# application descriptor and entitlements in the database while the new gateway
# has none of the module routes: every bootstrap step then skips and the run
# dies much later at capabilities / user creation with opaque 404s (observed
# live as the P6 gateway-switch failure). On a 409 "already registered" the
# bootstrap must therefore check the gateway's admin API: module services
# present -> normal skip; gateway reachable but no module services -> fail fast
# with the recovery paths; admin API unreachable -> fail open (old behavior).
#
# curl is stubbed with canned per-URL responses; jq stays real.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

stub_bin="$(mktemp -d)"
output_file="$(mktemp)"
trap 'rm -rf "${stub_bin}"; rm -f "${output_file}"' EXIT

# curl stub: mirrors api_request's response contract (body + status line).
# /services GETs answer from a file chosen per case; everything else is the
# descriptor registration POST (409 already registered).
cat > "${stub_bin}/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  */services*)
    if [[ ! -r "${CURL_SERVICES_BODY_FILE:-}" ]]; then
      exit 7
    fi
    cat "${CURL_SERVICES_BODY_FILE:?}"
    printf '\n200\n'
    ;;
  *)
    printf '{"errors":[{"message":"Application descriptor already created with id: app-platform-minimal-0.0.17"}]}\n'
    printf '409\n'
    ;;
esac
EOF
chmod +x "${stub_bin}/curl"

DEBUG=false
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/misc/bootstrap-engine.sh"

# A synthetic descriptor pair (not the repo's own, which --actualize rewrites):
# the guard must match discovery ids against gateway service names regardless of
# what the real descriptor currently pins.
test_dir="$(mktemp -d)"
APP_DESCRIPTOR_PATH="${test_dir}/descriptor.json"
APP_DISCOVERY_PATH="${test_dir}/discovery.json"
APP_NAME=app-platform-minimal
APP_ID=app-platform-minimal-0.0.17
jq -n '{discovery: [{id: "mod-alpha-1.0.0", location: "http://sc-alpha:8081"}, {id: "mod-beta-2.0.0", location: "http://sc-beta:8081"}]}' \
  > "${APP_DISCOVERY_PATH}"
jq -n '{id: "app-platform-minimal-0.0.17", name: "app-platform-minimal"}' > "${APP_DESCRIPTOR_PATH}"

run_registration() {
  # Subshell: the halt path calls exit 1, which must terminate only this run.
  set +e
  (
    PATH="${stub_bin}:${PATH}" \
    APIGW_TYPE="${1:-kong}" \
    CURL_SERVICES_BODY_FILE="${2:-}" \
      register_application_descriptor system-token \
      > "${output_file}" 2>&1
  )
  local status=$?
  set -e
  return "${status}"
}

kong_with_modules="$(mktemp)"
jq -n '{data: [{name: "mgr-applications-4.0.0"}, {name: "mod-alpha-1.0.0"}]}' > "${kong_with_modules}"
kong_mgr_only="$(mktemp)"
jq -n '{data: [{name: "mgr-applications-4.0.0"}, {name: "mgr-tenants-1.0.0"}]}' > "${kong_mgr_only}"
apisix_with_modules="$(mktemp)"
jq -n '{total: 2, list: [{value: {name: "mgr-tenants-1.0.0"}}, {value: {name: "mod-beta-2.0.0"}}]}' > "${apisix_with_modules}"
apisix_mgr_only="$(mktemp)"
jq -n '{total: 2, list: [{value: {name: "mgr-tenants-1.0.0"}}, {value: {name: "mgr-applications-4.0.0"}}]}' > "${apisix_mgr_only}"
trap 'rm -rf "${stub_bin}" "${test_dir}"; rm -f "${output_file}" "${kong_with_modules}" "${kong_mgr_only}" "${apisix_with_modules}" "${apisix_mgr_only}"' EXIT

# Warm re-run: module services present -> the 409 stays a benign skip.
run_registration kong "${kong_with_modules}" \
  || { cat "${output_file}" >&2; fail 'warm kong re-run must not halt'; }
grep -q 'already registered' "${output_file}" \
  || { cat "${output_file}" >&2; fail 'warm kong re-run must keep the already-registered notice'; }

# Gateway switched with kept volumes: reachable, mgr services present, but no
# module services -> fail fast with the recovery paths.
run_registration kong "${kong_mgr_only}" \
  && { cat "${output_file}" >&2; fail 'routeless kong gateway must halt the bootstrap'; }
grep -q 'none of its module routes' "${output_file}" \
  || { cat "${output_file}" >&2; fail 'missing the route-state halt explanation'; }
grep -q 'Recovery options' "${output_file}" \
  || { cat "${output_file}" >&2; fail 'missing the recovery guidance'; }

# Same discrimination on the APISIX admin shape.
run_registration apisix "${apisix_with_modules}" \
  || { cat "${output_file}" >&2; fail 'warm apisix re-run must not halt'; }
run_registration apisix "${apisix_mgr_only}" \
  && { cat "${output_file}" >&2; fail 'routeless apisix gateway must halt the bootstrap'; }

# Admin API unreachable: the guard fails open (old benign-skip behavior).
run_registration kong "" \
  || { cat "${output_file}" >&2; fail 'unreachable admin API must fail open'; }
grep -q 'already registered' "${output_file}" \
  || { cat "${output_file}" >&2; fail 'fail-open path must keep the already-registered notice'; }

printf 'ok  gateway route guard: skip when routable, halt when routeless, fail open when unreachable\n'
