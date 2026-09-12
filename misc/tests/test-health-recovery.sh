#!/usr/bin/env bash
#
# Hermetic proof for the gateway recovery wiring in misc/lib/docker-health.sh:
#   - a health-wait timeout on api-gateway triggers exactly ONE recovery attempt
#     and continues the wait with a fresh window (bounded: no retry loop)
#   - the run fails when recovery does not help, and succeeds when it does
#   - a timeout on an unrelated service never triggers gateway surgery
#   - dump_failure_diagnostics points at the in-container fix when a container
#     log reports "Kong is already running" (stale PID state)
#
# No real Docker: docker, curl, and sleep are stubbed on PATH.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

stub_bin="$(mktemp -d)"
stdout_file="$(mktemp)"
stderr_file="$(mktemp)"
marker_file="$(mktemp)"
trap 'rm -rf "${stub_bin}" "${stdout_file}" "${stderr_file}" "${marker_file}"' EXIT

cat >"${stub_bin}/docker" <<'EOF'
#!/usr/bin/env bash
marker="${RECOVERY_MARKER_FILE:?}"
case "$*" in
  'ps -aq --filter label=com.docker.compose.project=recovery-project --filter status=exited --filter status=dead')
    ;;
  'ps -q')
    printf 'cid1\ncid2\n'
    ;;
  inspect\ --format\ \{\{if\ .Config.Healthcheck\}\}*)
    ;;
  inspect\ --format\ \{\{if\ .State.Health\}\}*)
    cid="${!#}"
    case "${cid}" in
      cid1) printf '/svc1 healthy\n' ;;
      cid2)
        if [[ -s "${marker}" && "${RECOVERY_FIXES:-true}" == true ]]; then
          printf '%s healthy\n' "${STUCK_NAME:-api-gateway}"
        else
          printf '%s unhealthy\n' "${STUCK_NAME:-api-gateway}"
        fi
        ;;
    esac
    ;;
  'inspect --format {{.State.Status}} api-gateway')
    printf 'running\n'
    ;;
  exec\ api-gateway*)
    printf 'exec\n' >>"${marker}"
    ;;
  *)
    printf 'unexpected docker call: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "${stub_bin}/docker"

cat >"${stub_bin}/curl" <<'EOF'
#!/usr/bin/env bash
# Admin API probe never answers inside the hermetic run.
printf '000'
EOF
chmod +x "${stub_bin}/curl"

cat >"${stub_bin}/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${stub_bin}/sleep"

run_health_wait() {
  set +e
  (
    set -euo pipefail
    cd "${PROJECT_ROOT}"
    PATH="${stub_bin}:${PATH}"
    export RECOVERY_MARKER_FILE="${marker_file}" RECOVERY_FIXES STUCK_NAME
    export HEALTH_WAIT_TIMEOUT_SECONDS=8
    COMPOSE_PROJECT_NAME=recovery-project
    # shellcheck source=/dev/null
    source "${PROJECT_ROOT}/misc/lib/folio-common.sh"
    # shellcheck source=/dev/null
    source "${PROJECT_ROOT}/misc/lib/docker-health.sh"
    wait_for_all_healthy
  ) >"${stdout_file}" 2>"${stderr_file}"
  run_status=$?
  set -e
}

recovery_count() {
  [[ -f "${marker_file}" ]] && wc -l <"${marker_file}" | tr -d ' ' || printf '0'
}

# Case 1: gateway stuck, recovery does not help -> one recovery attempt, then
# the wait fails on the second timeout without retrying.
: >"${marker_file}"
RECOVERY_FIXES=false STUCK_NAME=api-gateway run_health_wait
[[ ${run_status} -ne 0 ]] || fail "health wait succeeded although recovery did not help"
[[ "$(recovery_count)" == '1' ]] \
  || { cat "${stderr_file}" >&2; fail "expected exactly one recovery attempt, got '$(recovery_count)'"; }
grep -q 'Timed out waiting for containers to become healthy' "${stderr_file}" \
  || fail 'health wait did not report the timeout'
grep -q 'attempting recovery' "${stderr_file}" \
  || { cat "${stderr_file}" >&2; fail 'gateway recovery was not attempted on the timeout path'; }

# Case 2: gateway stuck, recovery helps -> recovery runs once and the wait
# continues to a healthy finish.
: >"${marker_file}"
RECOVERY_FIXES=true STUCK_NAME=api-gateway run_health_wait
[[ ${run_status} -eq 0 ]] || { cat "${stderr_file}" >&2; fail "health wait failed although recovery helped"; }
[[ "$(recovery_count)" == '1' ]] \
  || { cat "${stderr_file}" >&2; fail "expected exactly one recovery attempt, got '$(recovery_count)'"; }
grep -q 'Container health ready' "${stderr_file}" \
  || fail 'health wait did not report readiness after recovery'

# Case 3: an unrelated service times out -> no gateway surgery at all.
: >"${marker_file}"
RECOVERY_FIXES=false STUCK_NAME=other-service run_health_wait
[[ ${run_status} -ne 0 ]] || fail "health wait succeeded although other-service stayed unhealthy"
[[ "$(recovery_count)" == '0' ]] \
  || fail "recovery was invoked for a non-gateway timeout"
[[ ! -s "${stdout_file}" ]] || { sed 's/^/stdout: /' "${stdout_file}" >&2; fail 'health wait wrote to stdout'; }

# Case 4: failure diagnostics detect the stale-Kong-PID log line and print the
# repo's own in-container fix.
cat >"${stub_bin}/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  'ps -a --filter label=com.docker.compose.project=kong-project --format table {{.Names}}\t{{.Status}}')
    printf 'NAMES\tSTATUS\napi-gateway\tUp 5 minutes (unhealthy)'
    ;;
  'ps -aq --filter label=com.docker.compose.project=kong-project')
    printf 'cid1\n'
    ;;
  inspect\ --format\ \{\{.Id\}\}*)
    printf 'cid1|running|unhealthy|1|\n'
    ;;
  'inspect --format {{.Name}} cid1')
    printf '/api-gateway\n'
    ;;
  'logs --tail 200 cid1')
    printf 'Error: Kong is already running in /usr/local/kong\n'
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
  COMPOSE_PROJECT_NAME=kong-project
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/misc/lib/folio-common.sh"
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/misc/lib/docker-health.sh"
  dump_failure_diagnostics
) >"${stdout_file}" 2>"${stderr_file}"
[[ ! -s "${stdout_file}" ]] || fail 'failure diagnostics wrote to stdout'
grep -q 'already running in /usr/local/kong' "${stderr_file}" \
  || fail 'diagnostics did not show the stale-Kong log line'
grep -q 'rm -f /usr/local/kong/pids/nginx.pid' "${stderr_file}" \
  || { cat "${stderr_file}" >&2; fail 'diagnostics did not print the in-container fix command'; }
grep -q 'rerun ./start.sh after ./stop.sh' "${stderr_file}" \
  || fail 'diagnostics did not print the stop/start alternative'

printf 'ok  health-wait timeout recovers the gateway once and diagnostics name the stale-PID fix\n'
