#!/usr/bin/env bash
#
# Hermetic proofs for the folio-api waits and the post-bootstrap smoke check:
#   - wait_for_capabilities succeeds when capabilities are registered, fails
#     hard when the tenant token cannot be obtained (initially or on a 401/403
#     refresh), and bounds its token refreshes instead of looping forever
#   - smoke_check reports per-check failure reasons and returns non-zero when
#     any check fails
#
# curl is stubbed with canned per-URL responses; jq stays real.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

stub_bin="$(mktemp -d)"
stdout_file="$(mktemp)"
stderr_file="$(mktemp)"
token_count_file="$(mktemp)"
trap 'rm -rf "${stub_bin}"; rm -f "${stdout_file}" "${stderr_file}" "${token_count_file}"' EXIT

cat >"${stub_bin}/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'/v1/secret/data/folio/diku'*)
    printf '{"data":{"data":{"m2m-client":"secret"}}}\n200\n'
    ;;
  *'realms/diku/protocol/openid-connect/token'*)
    printf '{"access_token":"tenant-token"}'
    ;;
  *'/capabilities'*)
    # api_request polling calls.
    printf '{"totalRecords":%s}\n%s' "${CAPABILITIES_COUNT:-1}" "${CAPABILITIES_STATUS:-200}"
    ;;
  *'-w'*)
    # Direct single-status probes (smoke proxy reachability).
    printf '404'
    ;;
  *)
    printf '{"totalRecords":0}\n404\n'
    ;;
esac
EOF
chmod +x "${stub_bin}/curl"

cat >"${stub_bin}/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${stub_bin}/sleep"

NO_COLOR=1
TERM=dumb
export NO_COLOR TERM TOKEN_COUNT_FILE="${token_count_file}"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/misc/lib/folio-common.sh"
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/misc/lib/folio-api.sh"

SECRET_STORE_VAULT_TOKEN='vault-root-token'

run_snippet() {  # <shell snippet>; captures output, sets RUN_STATUS
  set +e
  (
    # The bootstrap engine always runs these helpers under errexit; a failed
    # token lookup inside a command substitution must abort the run.
    set -euo pipefail
    cd "${PROJECT_ROOT}"
    PATH="${stub_bin}:${PATH}"
    eval "$1"
  ) >"${stdout_file}" 2>"${stderr_file}"
  RUN_STATUS=$?
  set -e
}

# Case 1: capabilities present -> success with the measured count.
run_snippet 'wait_for_capabilities'
[[ ${RUN_STATUS} -eq 0 ]] || { cat "${stderr_file}" >&2; fail 'capabilities wait failed although capabilities were registered'; }
grep -q 'Capabilities registered (found 1)' "${stderr_file}" \
  || { cat "${stderr_file}" >&2; fail 'capabilities wait did not report the found count'; }
[[ ! -s "${stdout_file}" ]] || fail 'capabilities wait wrote to stdout'

# Case 2: the initial tenant token lookup fails -> the wait exits non-zero.
run_snippet '
  obtain_tenant_access_token() { ui_error "tenant token lookup failed"; exit 1; }
  wait_for_capabilities
'
[[ ${RUN_STATUS} -ne 0 ]] || fail 'initial tenant token failure returned success'
grep -q 'Error: tenant token lookup failed' "${stderr_file}" \
  || { cat "${stderr_file}" >&2; fail 'initial tenant token error missing'; }

# Case 3: a 401 on the capabilities poll forces a token refresh; when the
# refresh itself keeps failing the wait must give up (bounded), not loop.
printf '0' >"${token_count_file}"
run_snippet '
  api_request() {
    API_RESPONSE_CODE=401
    API_RESPONSE_BODY="{}"
  }
  obtain_tenant_access_token() {
    local n
    n="$(cat "${TOKEN_COUNT_FILE}")"
    n=$((n + 1))
    printf "%s" "${n}" >"${TOKEN_COUNT_FILE}"
    if [[ ${n} -gt 1 ]]; then
      ui_error "tenant token refresh failed"
      exit 1
    fi
    printf "tenant-token"
  }
  wait_for_capabilities
'
[[ ${RUN_STATUS} -ne 0 ]] || fail 'refresh token failure returned success'
grep -q 'Error: tenant token refresh failed' "${stderr_file}" \
  || { cat "${stderr_file}" >&2; fail 'refresh token error missing'; }

# Case 4: smoke check with both token lookups failing -> non-zero with reasons.
run_snippet '
  obtain_system_access_token() { return 1; }
  obtain_tenant_access_token() { return 1; }
  smoke_check
'
[[ ${RUN_STATUS} -ne 0 ]] || fail 'failing smoke check returned success'
[[ ! -s "${stdout_file}" ]] || fail 'smoke check wrote to stdout'
grep -q 'System access token obtained' "${stderr_file}" \
  || { cat "${stderr_file}" >&2; fail 'system token smoke row missing'; }
grep -q 'token failed' "${stderr_file}" \
  || { cat "${stderr_file}" >&2; fail 'smoke failure reason missing'; }

printf 'ok  capabilities wait and smoke check propagate token failures with reasons\n'
