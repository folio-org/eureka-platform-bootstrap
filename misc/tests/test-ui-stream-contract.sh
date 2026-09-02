#!/usr/bin/env bash
#
# Contract for the shared bootstrap presentation layer:
#   - human-facing output goes to stderr
#   - stdout remains empty for presentation calls
#   - no ANSI ESC bytes are emitted, including when NO_COLOR/TERM=dumb/piped

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

assert_value() {
  local description="$1"
  local expected="$2"
  local actual="$3"
  [[ "${actual}" == "${expected}" ]] || fail "${description}: expected '${expected}', got '${actual}'"
}

stdout_file="$(mktemp)"
stderr_file="$(mktemp)"
stub_bin="$(mktemp -d)"
trap 'rm -f "${stdout_file}" "${stderr_file}"; rm -rf "${stub_bin}"' EXIT

(
  cd "${PROJECT_ROOT}"
  DEBUG=true
  VERBOSE=true
  QUIET=false
  NO_COLOR=1
  TERM=dumb
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/misc/lib/folio-common.sh"

  ui_title 'Contract title'
  ui_phase 'Contract phase'
  ui_step 'Contract step'
  ui_ok 'Contract ok'
  ui_warn 'Contract warn'
  ui_debug 'Contract debug'
) >"${stdout_file}" 2>"${stderr_file}"

[[ ! -s "${stdout_file}" ]] || {
  sed 's/^/stdout: /' "${stdout_file}" >&2
  fail 'presentation calls wrote to stdout'
}

if LC_ALL=C grep "$(printf '\033')" "${stderr_file}" >/dev/null; then
  sed 's/^/stderr: /' "${stderr_file}" >&2
  fail 'presentation output contains ANSI ESC bytes'
fi

grep -q 'Contract title' "${stderr_file}" || fail 'title did not render to stderr'
grep -q 'Contract debug' "${stderr_file}" || fail 'debug did not render to stderr when DEBUG=true'

(
  cd "${PROJECT_ROOT}"
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/misc/lib/ui.sh"

  assert_value 'ui_fmt_duration 0ms' '0ms' "$(ui_fmt_duration 0)"
  assert_value 'ui_fmt_duration 41ms' '41ms' "$(ui_fmt_duration 41)"
  assert_value 'ui_fmt_duration 999ms' '999ms' "$(ui_fmt_duration 999)"
  assert_value 'ui_fmt_duration 1.2s' '1.2s' "$(ui_fmt_duration 1200)"
  assert_value 'ui_fmt_duration 22s' '22s' "$(ui_fmt_duration 22000)"
  assert_value 'ui_fmt_duration 1m00s' '1m00s' "$(ui_fmt_duration 60000)"
  assert_value 'ui_fmt_duration 1m02s' '1m02s' "$(ui_fmt_duration 62000)"
  assert_value 'ui_fmt_duration 3m04s' '3m04s' "$(ui_fmt_duration 184000)"

  UI_UNICODE=true
  assert_value 'ui_glyph box_h unicode' "$(printf '\342\224\200')" "$(ui_glyph box_h)"
  assert_value 'ui_glyph mark_ok unicode' "$(printf '\342\234\223')" "$(ui_glyph mark_ok)"
  assert_value 'ui_glyph dot_pending unicode' "$(printf '\342\227\213')" "$(ui_glyph dot_pending)"

  UI_UNICODE=false
  assert_value 'ui_glyph box_h ascii' '-' "$(ui_glyph box_h)"
  assert_value 'ui_glyph mark_ok ascii' '+' "$(ui_glyph mark_ok)"
  assert_value 'ui_glyph dot_pending ascii' '-' "$(ui_glyph dot_pending)"

  missing_timer_output=''
  if missing_timer_output="$(ui_timer_read missing_timer 2>/dev/null)"; then
    fail 'ui_timer_read succeeded for a timer that was never started'
  fi
  [[ -z "${missing_timer_output}" ]] || fail "ui_timer_read fabricated missing timer output: ${missing_timer_output}"
)

: >"${stdout_file}"
: >"${stderr_file}"
(
  cd "${PROJECT_ROOT}"
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/misc/lib/folio-api.sh"
  print_api_payload 'plain diagnostic body'
) >"${stdout_file}" 2>"${stderr_file}"
[[ ! -s "${stdout_file}" ]] || fail 'print_api_payload default wrote to stdout'
grep -q 'plain diagnostic body' "${stderr_file}" || fail 'print_api_payload default did not write to stderr'

cat >"${stub_bin}/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  'ps -a --filter label=com.docker.compose.project=contract-project --format table {{.Names}}\t{{.Status}}')
    printf 'NAMES\tSTATUS\nbroken-service\tExited'
    ;;
  'ps -aq --filter label=com.docker.compose.project=contract-project')
    printf 'cid1\n'
    ;;
  inspect\ --format\ \{\{.Id\}\}*)
    printf 'cid1 exited unhealthy\n'
    ;;
  'inspect --format {{.Name}} cid1')
    printf '/broken-service\n'
    ;;
  'logs --tail 6 cid1')
    printf 'log line\n'
    ;;
  *)
    printf 'unexpected docker call: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "${stub_bin}/docker"

: >"${stdout_file}"
: >"${stderr_file}"
(
  cd "${PROJECT_ROOT}"
  PATH="${stub_bin}:${PATH}"
  COMPOSE_PROJECT_NAME=contract-project
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/misc/lib/folio-common.sh"
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/misc/lib/docker-health.sh"
  dump_failure_diagnostics
) >"${stdout_file}" 2>"${stderr_file}"
[[ ! -s "${stdout_file}" ]] || fail 'failure diagnostics wrote to stdout'
grep -q 'Exited' "${stderr_file}" || fail 'failure diagnostics did not write status to stderr'
grep -q 'log line' "${stderr_file}" || fail 'failure diagnostics did not write logs to stderr'
if LC_ALL=C grep -q '[^ -~]' "${stderr_file}"; then
  sed 's/^/stderr: /' "${stderr_file}" >&2
  fail 'failure diagnostics emitted non-ASCII in flat output'
fi

cat >"${stub_bin}/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  'ps -a --filter label=com.docker.compose.project=empty-project --format table {{.Names}}\t{{.Status}}')
    printf 'NAMES\tSTATUS\n'
    ;;
  'ps -aq --filter label=com.docker.compose.project=empty-project')
    ;;
  *)
    printf 'unexpected docker call: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "${stub_bin}/docker"

: >"${stdout_file}"
: >"${stderr_file}"
(
  cd "${PROJECT_ROOT}"
  PATH="${stub_bin}:${PATH}"
  COMPOSE_PROJECT_NAME=empty-project
  UI_FAILED_PHASE='Prepare config'
  UI_FAILED_STEP='preparing support images'
  export UI_FAILED_PHASE UI_FAILED_STEP
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/misc/lib/folio-common.sh"
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/misc/lib/docker-health.sh"
  dump_failure_diagnostics
) >"${stdout_file}" 2>"${stderr_file}"
[[ ! -s "${stdout_file}" ]] || fail 'empty failure diagnostics wrote to stdout'
grep -q 'No compose containers were created before the failure.' "${stderr_file}" \
  || { sed 's/^/stderr: /' "${stderr_file}" >&2; fail 'empty diagnostics did not explain missing containers'; }
grep -q 'Failed phase: Prepare config' "${stderr_file}" \
  || fail 'empty diagnostics did not include failed phase'
grep -q 'Failed step: preparing support images' "${stderr_file}" \
  || fail 'empty diagnostics did not include failed step'
if LC_ALL=C grep -q '[^ -~]' "${stderr_file}"; then
  sed 's/^/stderr: /' "${stderr_file}" >&2
  fail 'empty diagnostics emitted non-ASCII in flat output'
fi

health_state_file="$(mktemp)"
cat >"${stub_bin}/docker" <<'EOF'
#!/usr/bin/env bash
state_file="${HEALTH_STATE_FILE:?}"
case "$*" in
  ps\ -aq\ --filter\ label=com.docker.compose.project=health-contract\ --filter\ status=exited\ --filter\ status=dead)
    ;;
  'ps -q')
    state="$(cat "${state_file}" 2>/dev/null || printf '0')"
    state=$((state + 1))
    printf '%s' "${state}" >"${state_file}"
    printf 'cid1\ncid2\n'
    ;;
  inspect\ --format\ \{\{if\ .Config.Healthcheck\}\}*)
    ;;
  inspect\ --format\ \{\{if\ .State.Health\}\}*)
    state="$(cat "${state_file}" 2>/dev/null || printf '1')"
    cid="${!#}"
    if [[ "${state}" -eq 1 ]]; then
      case "${cid}" in
        cid1) printf '/svc1 healthy\n' ;;
        cid2) printf '/svc2 starting\n' ;;
      esac
    else
      case "${cid}" in
        cid1) printf '/svc1 healthy\n' ;;
        cid2) printf '/svc2 healthy\n' ;;
      esac
    fi
    ;;
  *)
    printf 'unexpected docker call: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "${stub_bin}/docker"

cat >"${stub_bin}/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${stub_bin}/sleep"

: >"${stdout_file}"
: >"${stderr_file}"
if ! (
  cd "${PROJECT_ROOT}"
  PATH="${stub_bin}:${PATH}"
  COMPOSE_PROJECT_NAME=health-contract
  HEALTH_STATE_FILE="${health_state_file}"
  export HEALTH_STATE_FILE
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/misc/lib/folio-common.sh"
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/misc/lib/docker-health.sh"
  UI_INTERACTIVE=true
  # Spinner cursor control is gated on UI_COLOR, so the live ready/total frame
  # only renders with color on; exercise that path here.
  UI_COLOR=true
  wait_for_all_healthy
  [[ "${HEALTH_READY_COUNT:-}" == '2' ]] || fail "expected HEALTH_READY_COUNT=2, got '${HEALTH_READY_COUNT:-}'"
  [[ "${HEALTH_TOTAL_COUNT:-}" == '2' ]] || fail "expected HEALTH_TOTAL_COUNT=2, got '${HEALTH_TOTAL_COUNT:-}'"
) >"${stdout_file}" 2>"${stderr_file}"; then
  sed 's/^/stderr: /' "${stderr_file}" >&2
  fail 'health wait contract failed'
fi
[[ ! -s "${stdout_file}" ]] || fail 'health wait wrote to stdout'
# The spinner colors the dim [counter] and uses carriage returns, so normalize the
# capture before matching the visible frames.
health_clean="$(perl -pe 's/\e\[[0-9;]*[A-Za-z]//g; s/\r/\n/g' "${stderr_file}")"
grep -q 'Verifying container health \[1/2\]' <<<"${health_clean}" || {
  sed 's/^/stderr: /' "${stderr_file}" >&2
  fail 'health spinner did not include measured ready/total count'
}
if grep -Eq '^[[:space:]]*- Verifying container health$' <<<"${health_clean}"; then
  sed 's/^/stderr: /' "${stderr_file}" >&2
  fail 'health wait left a stale standalone pending line'
fi
grep -Eq 'Container health ready[[:space:]]+[0-9]+ms' <<<"${health_clean}" \
  || fail 'health wait did not report readiness with millisecond timing'

: >"${stdout_file}"
: >"${stderr_file}"
if ! (
  cd "${PROJECT_ROOT}"
  PATH="${stub_bin}:${PATH}"
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/misc/lib/folio-common.sh"
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/misc/lib/folio-api.sh"

  APP_NAME='contract-app'
  APP_ID='contract-app-1.0.0'
  SECRET_STORE_VAULT_TOKEN='contract-token'
  _api_request_count=0

  obtain_system_access_token() { printf 'system-token'; }
  obtain_tenant_access_token() { printf 'tenant-token'; }
  wait_for_capabilities_real="$(declare -f wait_for_capabilities)"
  wait_for_capabilities() { return 0; }
  api_request() {
    local method="$1"
    local url="$2"
    _api_request_count=$((_api_request_count + 1))
    API_RESPONSE_CODE=200
    case "${method} ${url}" in
      'POST http://localhost:8000/tenants')
        API_RESPONSE_BODY='{"id":"created"}'
        ;;
      'GET http://localhost:8000/tenants?query=name==diku')
        API_RESPONSE_BODY='{"tenants":[{"id":"tenant-id"}]}'
        ;;
      'GET http://localhost:8000/entitlements/diku/applications?limit=500')
        API_RESPONSE_BODY='[]'
        ;;
      'POST http://localhost:8000/entitlements?ignoreErrors=false&async=true&tenantParameters=loadSample=true,loadReference=true')
        API_RESPONSE_BODY='{"flowId":"flow-1"}'
        ;;
      'GET http://localhost:8000/entitlement-flows/flow-1?includeStages=true')
        API_RESPONSE_BODY='{"status":"finished"}'
        ;;
      *)
        printf 'unexpected api_request: %s %s\n' "${method}" "${url}" >&2
        return 2
        ;;
    esac
  }

  create_tenant_and_enable_application system-token
  eval "${wait_for_capabilities_real}"
  api_request() {
    API_RESPONSE_CODE=200
    API_RESPONSE_BODY='{"totalRecords":1}'
  }
  wait_for_capabilities
) >"${stdout_file}" 2>"${stderr_file}"; then
  sed 's/^/stderr: /' "${stderr_file}" >&2
  fail 'api wait duration contract failed'
fi
grep -Eq 'Entitlement completed successfully[[:space:]]+([0-9]+ms|[0-9]+[.][0-9]s|[0-9]+s|[0-9]+m[0-9][0-9]s)' "${stderr_file}" || {
  sed 's/^/stderr: /' "${stderr_file}" >&2
  fail 'entitlement success did not include measured duration'
}
grep -Eq 'Capabilities registered \(found 1\)[[:space:]]+([0-9]+ms|[0-9]+[.][0-9]s|[0-9]+s|[0-9]+m[0-9][0-9]s)' "${stderr_file}" || {
  sed 's/^/stderr: /' "${stderr_file}" >&2
  fail 'capabilities success did not include measured duration'
}

: >"${stdout_file}"
: >"${stderr_file}"
set +e
(
  set -euo pipefail
  cd "${PROJECT_ROOT}"
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/misc/lib/folio-common.sh"
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/misc/lib/folio-api.sh"

  UI_INTERACTIVE=true
  UI_COLOR=true
  UI_UNICODE=false
  obtain_tenant_access_token() {
    ui_error 'tenant token lookup failed'
    exit 1
  }
  wait_for_capabilities
) >"${stdout_file}" 2>"${stderr_file}"
token_status=$?
set -e
[[ ${token_status} -ne 0 ]] || fail 'capabilities wait token failure returned success'
[[ ! -s "${stdout_file}" ]] || fail 'capabilities wait token failure wrote to stdout'
capability_token_clean="$(perl -pe 's/\e\[[0-9;]*[A-Za-z]//g; s/\r/\n/g' "${stderr_file}")"
grep -q 'Error: tenant token lookup failed' <<<"${capability_token_clean}" \
  || { sed 's/^/stderr: /' "${stderr_file}" >&2; fail 'capabilities wait token error missing'; }
if grep -Eq 'Waiting for capabilities.*Error:' <<<"${capability_token_clean}"; then
  sed 's/^/stderr: /' "${stderr_file}" >&2
  fail 'capabilities wait left spinner text attached to initial token error'
fi

: >"${stdout_file}"
: >"${stderr_file}"
token_count_file="$(mktemp)"
printf '0' >"${token_count_file}"
set +e
(
  set -euo pipefail
  cd "${PROJECT_ROOT}"
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/misc/lib/folio-common.sh"
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/misc/lib/folio-api.sh"

  UI_INTERACTIVE=true
  UI_COLOR=true
  UI_UNICODE=false
  TOKEN_COUNT_FILE="${token_count_file}"
  obtain_tenant_access_token() {
    local token_count
    token_count="$(cat "${TOKEN_COUNT_FILE}")"
    token_count=$((token_count + 1))
    printf '%s' "${token_count}" >"${TOKEN_COUNT_FILE}"
    if [[ ${token_count} -eq 1 ]]; then
      printf 'tenant-token'
    else
      ui_error 'tenant token refresh failed'
      exit 1
    fi
  }
  api_request() {
    API_RESPONSE_CODE=401
    API_RESPONSE_BODY='{}'
  }
  sleep() { :; }
  wait_for_capabilities
) >"${stdout_file}" 2>"${stderr_file}"
token_refresh_status=$?
set -e
rm -f "${token_count_file}"
[[ ${token_refresh_status} -ne 0 ]] || fail 'capabilities wait refresh token failure returned success'
[[ ! -s "${stdout_file}" ]] || fail 'capabilities wait refresh token failure wrote to stdout'
capability_refresh_clean="$(perl -pe 's/\e\[[0-9;]*[A-Za-z]//g; s/\r/\n/g' "${stderr_file}")"
grep -q 'Error: tenant token refresh failed' <<<"${capability_refresh_clean}" \
  || { sed 's/^/stderr: /' "${stderr_file}" >&2; fail 'capabilities wait refresh token error missing'; }
if grep -Eq 'Waiting for capabilities.*Error:' <<<"${capability_refresh_clean}"; then
  sed 's/^/stderr: /' "${stderr_file}" >&2
  fail 'capabilities wait left spinner text attached to refresh token error'
fi

: >"${stdout_file}"
: >"${stderr_file}"
set +e
(
  cd "${PROJECT_ROOT}"
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/misc/lib/folio-common.sh"
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/misc/lib/folio-api.sh"

  curl() {
    case "$*" in
      *'-w %{http_code}'*) printf '404' ;;
      *) printf '{"totalRecords":0}' ;;
    esac
  }
  obtain_system_access_token() { return 1; }
  obtain_tenant_access_token() { return 1; }
  smoke_check
) >"${stdout_file}" 2>"${stderr_file}"
smoke_status=$?
set -e
[[ ${smoke_status} -ne 0 ]] || fail 'failing smoke check returned success'
[[ ! -s "${stdout_file}" ]] || fail 'failing smoke check wrote to stdout'
grep -q 'System access token obtained  token failed' "${stderr_file}" \
  || { sed 's/^/stderr: /' "${stderr_file}" >&2; fail 'system token smoke failure reason missing'; }
grep -q 'Tenant access token obtained  token failed' "${stderr_file}" \
  || { sed 's/^/stderr: /' "${stderr_file}" >&2; fail 'tenant token smoke failure reason missing'; }

(
  cd "${PROJECT_ROOT}"
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/misc/lib/ui.sh"

  # ui_c: exact escape on, raw text off.
  UI_COLOR=true
  assert_value 'ui_c done color on' "$(printf '\033[32mok\033[0m')" "$(ui_c done ok)"
  assert_value 'ui_sgr color on' "$(printf '\033[1;31m')" "$(ui_sgr 1 31)"
  UI_COLOR=false
  assert_value 'ui_c done color off' 'ok' "$(ui_c done ok)"
  assert_value 'ui_sgr color off' '' "$(ui_sgr 1 31)"

  # Color off => zero ESC bytes, even on the boxed (UTF-8) code path. Covers the
  # reworked phase close, the gutter'd ui_kv, and ui_run's success path.
  UI_COLOR=false; UI_UNICODE=true; UI_INTERACTIVE=true
  out="$( {
    ui_ok 'ok line'; ui_step 'step line'
    ui_run 'run desc' true
    ui_phase 'Phase'
    ui_kv 'Tenant ID' 'abc-123'
    ui_box_top 'panel' 'right'; ui_box_row 'cell'
    ui_box_status_row ok 'check' 'HTTP 200'; ui_box_kv 'API' 'http://localhost:8000'
    ui_box_sep; ui_box_bottom
    ui_phase_finish done
    ui_phase 'Phase 2'; ui_phase_finish failed
  } 2>&1 )"
  if LC_ALL=C grep -q "$(printf '\033')" <<<"${out}"; then
    printf '%s\n' "${out}" | sed 's/^/out: /' >&2
    fail 'ui helpers emitted ESC bytes with UI_COLOR=false'
  fi
  # The deterministic phase close appends a closing line in boxed mode.
  [[ "${out}" == *"$(ui_glyph box_bl)"* ]] || fail 'phase close did not append a closing line in boxed mode'
  # ui_kv inside an open phase nests under the gutter.
  [[ "${out}" == *"$(ui_glyph box_v) Tenant ID: abc-123"* ]] || fail 'ui_kv did not nest under the phase gutter'

  # ui_info gutters in a phase, but an empty message is a bare blank line (no bar).
  note_line="$( ( export _UI_PHASE_OPEN=true; ui_info 'note text' ) 2>&1 )"
  [[ "${note_line}" == *"$(ui_glyph box_v) note text"* ]] || fail 'ui_info did not nest under the phase gutter'
  empty_line="$( ( export _UI_PHASE_OPEN=true; ui_info '' ) 2>&1 )"
  [[ -z "${empty_line//[$' \t']/}" ]] || fail 'empty ui_info emitted a non-blank (gutter) line'

  # Outside any phase, status lines drop the bar (plain two-space indent).
  no_phase="$( ( _UI_PHASE_OPEN=false; ui_ok 'standalone' ) 2>&1 )"
  [[ "${no_phase}" == *"$(ui_glyph box_v)"* ]] && fail 'ui_ok drew a gutter bar with no open phase'

  # ui_error nests under the phase gutter, and drops the bar with no phase open.
  err_in_phase="$( ( export _UI_PHASE_OPEN=true; ui_error 'boom' ) 2>&1 )"
  [[ "${err_in_phase}" == *"$(ui_glyph box_v) Error: boom"* ]] || fail 'ui_error did not nest under the phase gutter'
  err_no_phase="$( ( _UI_PHASE_OPEN=false; ui_error 'boom' ) 2>&1 )"
  [[ "${err_no_phase}" == *"$(ui_glyph box_v)"* ]] && fail 'ui_error drew a gutter bar with no open phase'

  # A box opened inside a phase nests under the gutter: the dim "│ " precedes the
  # box's own top-left corner.
  boxed_in_phase="$( {
    ui_phase 'BoxPhase'; ui_box_top 'plan' 'x'; ui_phase_finish done
  } 2>&1 )"
  top_line="$(printf '%s\n' "${boxed_in_phase}" | grep "$(ui_glyph box_tl)")"
  [[ "${top_line}" == "  $(ui_glyph box_v) $(ui_glyph box_tl)"* ]] || fail 'in-phase box did not nest under the gutter'

  # Cursor-moving helpers are gated on UI_COLOR (not just UI_INTERACTIVE), so with
  # color off they emit nothing — no \033 byte can escape even on a tty.
  spin_out="$( ( UI_INTERACTIVE=true; ui_spinner '/' 'working' '1/2' '3s'; ui_spinner_clear ) 2>&1 )"
  [[ -z "${spin_out}" ]] || fail 'ui_spinner/ui_spinner_clear emitted output with UI_COLOR=false'

  UI_INTERACTIVE=true; UI_COLOR=true; UI_UNICODE=false
  run_clean="$( ( ui_run 'fast command' true ) 2>&1 | perl -pe 's/\e\[[0-9;]*[A-Za-z]//g; s/\r/\n/g' )"
  if grep -Eq '^[[:space:]]*- fast command$' <<<"${run_clean}"; then
    printf '%s\n' "${run_clean}" | sed 's/^/run: /' >&2
    fail 'ui_run left a stale standalone pending line'
  fi
  grep -Eq 'fast command[[:space:]]+[0-9]+ms' <<<"${run_clean}" || {
    printf '%s\n' "${run_clean}" | sed 's/^/run: /' >&2
    fail 'ui_run did not render millisecond timing'
  }

  # Single source of truth for content width: every full-width element (phase
  # header rule, box right edge, right-aligned timing) derives from
  # ui_content_width = min(ui_cols, UI_MAX_WIDTH). Pin at the function level —
  # measuring rendered widths over multibyte box glyphs would be locale/byte-count
  # flaky. Mocking ui_cols also makes the truncation check below deterministic
  # regardless of the runner's real terminal size.
  ui_cols() { printf '%s\n' "${MOCK_COLS:-80}"; }
  UI_MAX_WIDTH=120
  MOCK_COLS=200
  [[ "$(ui_content_width)" == 120 ]] || fail 'ui_content_width did not cap at UI_MAX_WIDTH'
  [[ "$(_ui_box_width 0)" == "$(ui_content_width)" ]] \
    || fail '_ui_box_width(0) diverged from ui_content_width above the cap'
  MOCK_COLS=90
  [[ "$(ui_content_width)" == 90 ]] || fail 'ui_content_width did not track ui_cols below the cap'
  [[ "$(_ui_box_width 0)" == 90 ]] || fail '_ui_box_width(0) diverged from ui_content_width below the cap'
  MOCK_COLS=80

  # Boxed rows clamp width and truncate over-long cells.
  UI_UNICODE=true; UI_COLOR=false
  long='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  row="$(ui_box_row "${long}" 2>&1)"
  [[ "${row}" == *"${long}"* ]] && fail 'ui_box_row did not truncate an over-long cell'
  [[ "${row}" == *"$(ui_glyph box_v)"* ]] || fail 'ui_box_row dropped its border'

  # UI_UNICODE=false => flat panels: content kept, no box-drawing bytes, no ESC.
  UI_UNICODE=false; UI_COLOR=false
  flat="$( { ui_box_top 'panel' 'right'; ui_box_row 'hello'; ui_box_sep; ui_box_bottom; } 2>&1 )"
  [[ "${flat}" == *'panel'* && "${flat}" == *'hello'* ]] || fail 'flat panels dropped content'
  if LC_ALL=C grep -q "$(printf '\342')" <<<"${flat}"; then fail 'flat panels emitted Unicode box bytes'; fi
  if LC_ALL=C grep -q "$(printf '\033')" <<<"${flat}"; then fail 'flat panels emitted ESC bytes'; fi

  flat_in_phase="$( ( export _UI_PHASE_OPEN=true; ui_box_top 'panel' 'right'; ui_box_row 'hello' ) 2>&1 )"
  first_flat_line="$(printf '%s\n' "${flat_in_phase}" | sed -n '1p')"
  [[ "${first_flat_line}" == '  panel: right' ]] || fail "flat in-phase box top was not nested: ${first_flat_line}"

  UI_UNICODE=true; UI_COLOR=false
  wrapped_value='Run ./misc/create-user.sh folio folio after the platform stabilizes.'
  wrapped="$(ui_box_kv_wrapped 'Next step' "${wrapped_value}" 2>&1)"
  [[ "${wrapped}" == *'Run ./misc/create-user.sh folio folio after the platform'* && "${wrapped}" == *'stabilizes.'* ]] \
    || fail 'wrapped key/value row lost actionable command text'
)

printf 'ok  ui stream contract keeps presentation on stderr without ANSI escapes\n'

# ui_prompt renders a decision branch to stderr and reads a y/n answer from stdin.
# The caller owns the tty guard, so we feed stdin by pipe here. Verify it stays
# escape-free with color off, keeps the label/question, and returns the right code
# (including default handling on an empty answer).
(
  cd "${PROJECT_ROOT}"
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/misc/lib/folio-common.sh"

  UI_COLOR=false; UI_UNICODE=false

  prompt_out="$(printf 'y\n' | { ui_prompt 'Decide the thing?' n; } 2>&1 1>/dev/null || true)"
  if LC_ALL=C grep -q "$(printf '\033')" <<<"${prompt_out}"; then
    printf '%s\n' "${prompt_out}" | sed 's/^/out: /' >&2
    fail 'ui_prompt emitted ESC bytes with UI_COLOR=false'
  fi
  [[ "${prompt_out}" == *'decision'* && "${prompt_out}" == *'Decide the thing?'* ]] \
    || { printf '%s\n' "${prompt_out}" | sed 's/^/out: /' >&2; fail 'ui_prompt dropped its label/question'; }

  rc=0; printf 'y\n' | ( ui_prompt 'x?' n ) >/dev/null 2>&1 || rc=$?
  [[ "${rc}" -eq 0 ]] || fail 'ui_prompt did not return yes for y'
  rc=0; printf 'n\n' | ( ui_prompt 'x?' y ) >/dev/null 2>&1 || rc=$?
  [[ "${rc}" -eq 1 ]] || fail 'ui_prompt did not return no for n'
  rc=0; printf '\n'  | ( ui_prompt 'x?' y ) >/dev/null 2>&1 || rc=$?
  [[ "${rc}" -eq 0 ]] || fail 'ui_prompt empty answer did not honor default y'
  rc=0; printf '\n'  | ( ui_prompt 'x?' n ) >/dev/null 2>&1 || rc=$?
  [[ "${rc}" -eq 1 ]] || fail 'ui_prompt empty answer did not honor default n'
)

printf 'ok  ui_prompt renders a decision branch and reads a y/n answer\n'
