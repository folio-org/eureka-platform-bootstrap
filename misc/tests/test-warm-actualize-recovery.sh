#!/usr/bin/env bash
#
# Hermetic proof of the warm --actualize recovery path.
#
# A warm --actualize bumps the descriptor to a new application id (new module
# versions, new app id) while the database keeps the previous run's state. Two
# bootstrap steps used to break there (observed live: entitlement cancelled with
# only the flow initializer finished):
#   1. discovery: the bulk endpoint rejects the whole batch when any module id
#      is already registered, so the new module ids never got discovery;
#   2. entitlement: mgr-tenant-entitlements rejects a second entitle for an
#      application name whose last flow finished - the new version must go
#      through the upgrade operation (PUT /entitlements) instead.
#
# curl is stubbed with canned per-URL responses; jq stays real.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

stub_bin="$(mktemp -d)"
test_dir="$(mktemp -d)"
output_file="$(mktemp)"
entitlement_log="$(mktemp)"
transient_marker="$(mktemp)"
rm -f "${transient_marker}"
trap 'rm -rf "${stub_bin}" "${test_dir}"; rm -f "${output_file}" "${entitlement_log}" "${transient_marker}"' EXIT

# curl stub: mirrors api_request's response contract (body + status line) for
# -w calls, and a pure body for the plain token pipes (jq reads those whole).
# The per-module discovery POST for mod-alpha answers 503 exactly once when
# DISCOVERY_503_MARKER is armed (drives the one-shot transient retry).
cat > "${stub_bin}/curl" <<'EOF'
#!/usr/bin/env bash
body=''
status='200'
case "$*" in
  *"/v1/secret/data/folio/diku"*)
    body='{"data":{"data":{"m2m-client":"secret"}}}' ;;
  *"realms/master/protocol/openid-connect/token"*|*"realms/diku/protocol/openid-connect/token"*)
    body='{"access_token":"stub-token"}' ;;
  *"/modules/"*"/discovery"*)
    case "$*" in
      *mod-alpha*)
        if [[ -n "${DISCOVERY_503_MARKER:-}" && ! -f "${DISCOVERY_503_MARKER}" ]]; then
          touch "${DISCOVERY_503_MARKER}"
          body='{"errors":[{"message":"no upstream"}]}'; status='503'
        else
          body='{"id":"mod-alpha-1.0.0"}'; status='201'
        fi ;;
      *) body='{"errors":[{"message":"Module Discovery already exists"}]}'; status='409' ;;
    esac ;;
  *"/modules/discovery"*)
    # Bulk create on a warm stack: rejected because ids are already present.
    body='{"errors":[{"message":"Module Discovery already exists for ids: [mod-beta-2.0.0]"}]}'
    status='409' ;;
  *"/entitlements/diku/applications"*)
    body="$(cat "${ENABLED_APPLICATIONS_FILE:?}")" ;;
  *"/entitlements?"*)
    case "$*" in
      *" -X PUT "*) printf 'PUT' >> "${ENTITLEMENT_CALL_LOG:?}" ;;
      *" -X POST "*) printf 'POST' >> "${ENTITLEMENT_CALL_LOG:?}" ;;
    esac
    body='{"entitlements":[],"flowId":"flow-1","totalRecords":0}' ;;
  *"/entitlement-flows/"*)
    body='{"id":"flow-1","status":"finished","stages":[]}' ;;
  *"/tenants?query"*)
    body='{"tenants":[{"id":"tenant-1","name":"diku"}],"totalRecords":1}' ;;
  *"/tenants"*)
    body='{"id":"tenant-1","name":"diku"}'; status='201' ;;
  *"/capabilities"*)
    body='{"capabilities":[],"totalRecords":5}' ;;
  *)
    body='unhandled stub url'; status='404' ;;
esac

if [[ "$*" == *" -w "* ]]; then
  printf '%s\n%s\n' "${body}" "${status}"
else
  printf '%s\n' "${body}"
fi
EOF
chmod +x "${stub_bin}/curl"

cat >"${stub_bin}/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${stub_bin}/sleep"

DEBUG=false
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/misc/bootstrap-engine.sh"

# Synthetic descriptor pair, so the test does not depend on the repo descriptor
# (which --actualize rewrites in place).
APP_DESCRIPTOR_PATH="${test_dir}/descriptor.json"
APP_DISCOVERY_PATH="${test_dir}/discovery.json"
APP_NAME=app-platform-minimal
APP_ID=app-platform-minimal-0.0.17
jq -n '{id: "app-platform-minimal-0.0.17", name: "app-platform-minimal"}' > "${APP_DESCRIPTOR_PATH}"
jq -n '{discovery: [{id: "mod-alpha-1.0.0", location: "http://sc-alpha:8081"}, {id: "mod-beta-2.0.0", location: "http://sc-beta:8081"}]}' \
  > "${APP_DISCOVERY_PATH}"

run_discovery() {
  set +e
  (
    PATH="${stub_bin}:${PATH}" \
      register_discovery_information system-token
  ) > "${output_file}" 2>&1
  local status=$?
  set -e
  return "${status}"
}

# Warm bulk conflict -> per-module fallback registers the new module and skips
# the present one.
run_discovery || { cat "${output_file}" >&2; fail 'discovery fallback failed'; }
grep -q '1 module(s) registered, 1 already present' "${output_file}" \
  || { cat "${output_file}" >&2; fail 'discovery fallback summary is wrong'; }

# A 503 on a per-module discovery POST gets exactly one bounded retry, which
# here succeeds — the fallback summary must be unchanged.
rm -f "${transient_marker}"
set +e
(
  PATH="${stub_bin}:${PATH}" \
  DISCOVERY_503_MARKER="${transient_marker}" \
    register_discovery_information system-token \
  > "${output_file}" 2>&1
)
transient_status=$?
set -e
[[ ${transient_status} -eq 0 ]] || { cat "${output_file}" >&2; fail 'per-module transient 503 was not retried to success'; }
grep -q 'retrying once' "${output_file}" \
  || { cat "${output_file}" >&2; fail 'missing the transient-retry notice'; }
grep -q '1 module(s) registered, 1 already present' "${output_file}" \
  || { cat "${output_file}" >&2; fail 'transient retry changed the fallback summary'; }

run_enable() {
  : > "${entitlement_log}"
  set +e
  (
    PATH="${stub_bin}:${PATH}" \
    ENABLED_APPLICATIONS_FILE="${1:?}" \
    ENTITLEMENT_CALL_LOG="${entitlement_log}" \
      create_tenant_and_enable_application system-token
  ) > "${output_file}" 2>&1
  local status=$?
  set -e
  return "${status}"
}

# New version of an already-enabled application name -> upgrade (PUT).
enabled_same_name="${test_dir}/enabled-same-name.json"
printf '[{"applicationId":"app-platform-minimal-0.0.1","tenantId":"tenant-1"}]' > "${enabled_same_name}"
run_enable "${enabled_same_name}" \
  || { cat "${output_file}" >&2; fail 'same-name entitlement run failed'; }
grep -qx 'PUT' "${entitlement_log}" \
  || { cat "${output_file}" >&2; fail 'same-name entitlement must use the upgrade operation (PUT)'; }
grep -q 'Upgrading entitlement' "${output_file}" \
  || { cat "${output_file}" >&2; fail 'missing the upgrading-entitlement step line'; }

# Fresh application (no same-name entitlement) -> classic entitle (POST).
enabled_empty="${test_dir}/enabled-empty.json"
printf '[]' > "${enabled_empty}"
run_enable "${enabled_empty}" \
  || { cat "${output_file}" >&2; fail 'fresh entitlement run failed'; }
grep -qx 'POST' "${entitlement_log}" \
  || { cat "${output_file}" >&2; fail 'fresh entitlement must use the entitle operation (POST)'; }
grep -q 'Enabling (entitling)' "${output_file}" \
  || { cat "${output_file}" >&2; fail 'missing the enabling-entitlement step line'; }

printf 'ok  warm actualize recovery: per-module discovery fallback and PUT-based entitlement upgrade\n'
