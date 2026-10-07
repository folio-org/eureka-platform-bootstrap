#!/usr/bin/env bash
# Exercise registration, discovery and entitlement with synthetic HTTP responses.
# A descriptor alone must not imply that tenant module routes already exist.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT
stdout_file="${test_dir}/stdout"
stderr_file="${test_dir}/stderr"
request_log="${test_dir}/requests"
DEBUG=false
NO_COLOR=1
TERM=dumb
source "${PROJECT_ROOT}/misc/bootstrap-engine.sh"

APP_NAME=app-platform-minimal
APP_ID=app-platform-minimal-0.0.17
APP_DESCRIPTOR_PATH="${test_dir}/descriptor.json"
APP_DISCOVERY_PATH="${test_dir}/discovery.json"
printf '{"id":"%s","name":"%s"}' "${APP_ID}" "${APP_NAME}" >"${APP_DESCRIPTOR_PATH}"
printf '{"discovery":[{"id":"mod-alpha-2.0.0","location":"http://sc-alpha:8081"}]}' >"${APP_DISCOVERY_PATH}"
current='{"id":"app-platform-minimal-0.0.17","modules":[{"id":"mod-alpha-2.0.0"}]}'
older='{"id":"app-platform-minimal-0.0.1","modules":[{"name":"mod-alpha","version":"1.0.0"}]}'
ENABLED_BODY='[]'
ENABLED_STATUS=200
DESCRIPTOR_STATUS=409
DISCOVERY_STATUS=201
MODULE_STATUS=201
SERVICES=''
ADMIN_STATUS=200
OLD_DESCRIPTOR="${older}"
OLD_DESCRIPTOR_STATUS=200

obtain_system_access_token() { printf 'system-token'; }
obtain_tenant_access_token() { printf 'tenant-token'; }
sleep() { :; }
api_request() {
  local method="$1" url="$2"
  printf '%s %s\n' "${method}" "${url}" >>"${request_log}"
  API_RESPONSE_CODE=200
  API_RESPONSE_BODY='{}'
  case "${url}" in
    */apisix/admin/services|*/services)
      API_RESPONSE_CODE="${ADMIN_STATUS}"
      if [[ "${APIGW_TYPE}" == apisix ]]; then
        API_RESPONSE_BODY="$(printf '%s\n' "${SERVICES}" | jq -Rsc '{list: [split("\n")[] | select(length > 0) | {value:{name:.}}]}')"
      else
        API_RESPONSE_BODY="$(printf '%s\n' "${SERVICES}" | jq -Rsc '{data: [split("\n")[] | select(length > 0) | {name:.}]}')"
      fi ;;
    */applications)
      API_RESPONSE_CODE="${DESCRIPTOR_STATUS}"
      API_RESPONSE_BODY='{"message":"descriptor already registered"}' ;;
    */modules/discovery) API_RESPONSE_CODE="${DISCOVERY_STATUS}" ;;
    */modules/*/discovery) API_RESPONSE_CODE="${MODULE_STATUS}" ;;
    */tenants?*) API_RESPONSE_BODY='{"tenants":[{"id":"tenant-1"}]}' ;;
    */tenants) API_RESPONSE_CODE=201 ;;
    */entitlements/diku/applications?*)
      API_RESPONSE_CODE="${ENABLED_STATUS}"
      API_RESPONSE_BODY="${ENABLED_BODY}" ;;
    */entitlements?*) API_RESPONSE_BODY='{"flowId":"flow-1"}' ;;
    */entitlement-flows/*) API_RESPONSE_BODY='{"status":"finished"}' ;;
    */capabilities?*) API_RESPONSE_BODY='{"totalRecords":1}' ;;
    */applications/*)
      [[ "$*" == *'x-okapi-token: system-token'* ]] || fail 'metadata fallback lacks authentication'
      API_RESPONSE_CODE="${OLD_DESCRIPTOR_STATUS}"
      API_RESPONSE_BODY="${OLD_DESCRIPTOR}" ;;
    *) fail "unexpected request ${method} ${url}" ;;
  esac
}

run_bootstrap_registration() {
  : >"${request_log}"
  set +e
  (
    set -euo pipefail
    APIGW_TYPE="$1"
    register_application_descriptor system-token
    register_discovery_information system-token
    create_tenant_and_enable_application system-token
  ) >"${stdout_file}" 2>"${stderr_file}"
  RUN_STATUS=$?
  set -e
  [[ ! -s "${stdout_file}" ]] || fail 'registration presentation wrote to stdout'
}
expect_success() {
  [[ ${RUN_STATUS} -eq 0 ]] || { cat "${stderr_file}" >&2; fail "$*"; }
}
expect_halt() {
  [[ ${RUN_STATUS} -ne 0 ]] || fail "$*"
  if grep -Eq '/capabilities|^(POST|PUT) .*/entitlements\?' "${request_log}"; then
    cat "${request_log}" >&2
    fail 'halt must precede entitlement mutation and capabilities polling'
  fi
}

for gateway in kong apisix; do
  # Resume after descriptor-only registration, including mixed discovery state.
  ENABLED_BODY='[]'
  SERVICES=''
  for DISCOVERY_STATUS in 201 409; do
    run_bootstrap_registration "${gateway}"
    expect_success 'descriptor conflict before entitlement must be recoverable'
    grep -q '^POST .*/entitlements?' "${request_log}" || fail 'fresh entitlement was not reached'
    grep -q 'already registered' "${stderr_file}" || fail 'descriptor conflict notice lost'
    [[ "$(sed -n '1p' "${request_log}")" == 'POST http://localhost:8000/applications' ]] || fail 'descriptor must precede discovery'
    [[ "$(sed -n '2p' "${request_log}")" == 'POST http://localhost:8000/modules/discovery' ]] || fail 'discovery must precede entitlement'
  done
  MODULE_STATUS=409
  run_bootstrap_registration "${gateway}"
  expect_success 'existing discovery without entitlement must be recoverable'
  MODULE_STATUS=201
  DISCOVERY_STATUS=201

  # Routes are required for an enabled application, including the older version
  # before an upgrade. New target module versions need no services yet.
  for DESCRIPTOR_STATUS in 201 409; do
    for enabled in "${current}" "${older}"; do
      ENABLED_BODY="{\"applicationDescriptors\":[${enabled}]}"
      for SERVICES in '' mgr-applications-4.0.0 mod-foreign-1.0.0; do
        run_bootstrap_registration "${gateway}"
        expect_halt 'enabled application without its services must halt'
        grep -q 'none of its module routes' "${stderr_file}" || fail 'route-loss explanation missing'
      done
    done
    ENABLED_BODY="{\"applicationDescriptors\":[${older}]}"
    SERVICES=mod-alpha-1.0.0
    run_bootstrap_registration "${gateway}"
    expect_success 'healthy older module version must permit upgrade'
    grep -q '^PUT .*/entitlements?' "${request_log}" || fail 'older entitlement must select PUT'
    [[ "$(grep -c '/services$' "${request_log}")" == 1 ]] || fail 'gateway should be probed once'
    grep -q '/applications/app-platform-minimal-0.0.1$' "${request_log}" && fail 'full enabled descriptor must not need metadata GET'

    ENABLED_BODY="{\"applicationDescriptors\":[${older},${current}]}"
    SERVICES=mod-alpha-2.0.0
    run_bootstrap_registration "${gateway}"
    expect_success 'exact current entitlement must win over earlier same-name entry'
    grep -q 'skipping entitlement' "${stderr_file}" || fail 'current entitlement was not skipped'
    grep -q '^PUT .*/entitlements?' "${request_log}" && fail 'current entitlement must not upgrade'
  done
  DESCRIPTOR_STATUS=409

  # Compatible ID-only arrays: current id uses local discovery; old id requires
  # metadata only for a reachable, nonempty gateway store.
  ENABLED_BODY="[{\"applicationId\":\"${APP_ID}\"}]"
  SERVICES=mod-alpha-2.0.0
  run_bootstrap_registration "${gateway}"
  expect_success 'current ID-only entitlement must use local discovery'
  ENABLED_BODY='{"applications":[{"applicationId":"app-platform-minimal-0.0.1"}]}'
  SERVICES=mod-alpha-1.0.0
  run_bootstrap_registration "${gateway}"
  expect_success 'older ID-only entitlement must resolve the enabled descriptor'
  grep -q '^GET .*/applications/app-platform-minimal-0.0.1$' "${request_log}" || fail 'fallback requested the wrong application'
  for OLD_DESCRIPTOR in '{"id":"wrong","modules":[{"id":"mod-alpha-1.0.0"}]}' '{"id":"app-platform-minimal-0.0.1","modules":[]}' 'not-json'; do
    run_bootstrap_registration "${gateway}"
    expect_halt 'unverifiable older module metadata must halt'
    grep -q 'Cannot verify' "${stderr_file}" || fail 'metadata verification error missing'
    grep -q 'none of its module routes' "${stderr_file}" && fail 'metadata failure must not claim route loss'
  done
  OLD_DESCRIPTOR="${older}"
  OLD_DESCRIPTOR_STATUS=503
  run_bootstrap_registration "${gateway}"
  expect_halt 'failed metadata GET must halt'
  ADMIN_STATUS=503
  run_bootstrap_registration "${gateway}"
  expect_success 'unreachable gateway admin must preserve fail-open'
  grep -q '/applications/app-platform-minimal-0.0.1$' "${request_log}" && fail 'unavailable admin must not trigger fallback'
  ADMIN_STATUS=200
  SERVICES=''
  run_bootstrap_registration "${gateway}"
  expect_halt 'empty gateway store must halt without resolving old metadata'
  grep -q '/applications/app-platform-minimal-0.0.1$' "${request_log}" && fail 'empty store must not need fallback'
  OLD_DESCRIPTOR_STATUS=200

  for ENABLED_BODY in '{}' '{"applications":{}}' 'not-json'; do
    run_bootstrap_registration "${gateway}"
    expect_halt 'invalid entitlement response must not be interpreted as fresh'
    grep -q 'Cannot determine enabled applications' "${stderr_file}" || fail 'entitlement verification explanation missing'
  done
  ENABLED_BODY='[]'
  ENABLED_STATUS=503
  run_bootstrap_registration "${gateway}"
  expect_halt 'failed entitlement GET must not be interpreted as fresh'
  ENABLED_STATUS=200
  ENABLED_BODY='{"applicationDescriptors":[]}'
  run_bootstrap_registration "${gateway}"
  expect_success 'valid empty entitlement collection must permit POST'
done
printf 'ok  gateway guard protects enabled versions and permits incomplete registration recovery\n'
