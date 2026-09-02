#!/usr/bin/env bash
#
# Contract for ui_run's optional bounded failure output (UI_RUN_TAIL_LINES):
#   - default (unset): the whole captured log is dumped on failure (unchanged);
#   - set to N: only the last N lines are shown, plus the full-log path, so a
#     long chatty command (the native sidecar build) does not flood the terminal;
#   - success never dumps the captured log.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

leaked_logs=()
cleanup() { local f; for f in "${leaked_logs[@]}"; do [[ -n "$f" ]] && rm -f "$f"; done; }
trap cleanup EXIT

# Deterministic non-interactive presentation: no spinner, no escapes.
export NO_COLOR=1 TERM=dumb
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/misc/lib/ui.sh"

emit_and_fail() { seq 1 100; return 3; }
emit_and_ok()   { seq 1 100; return 0; }

run_capture() {  # <tail_lines|''> <cmd...> ; sets OUT and RUN_STATUS
  local tail="$1"; shift
  set +e
  if [[ -n "${tail}" ]]; then
    OUT="$(UI_RUN_TAIL_LINES="${tail}" ui_run 'native build' "$@" 2>&1)"
  else
    OUT="$(ui_run 'native build' "$@" 2>&1)"
  fi
  RUN_STATUS=$?
  set -e
}

# --- Default: full log dumped on failure, status propagated -------------------
run_capture '' emit_and_fail
[[ ${RUN_STATUS} -eq 3 ]] || fail "default: expected status 3, got ${RUN_STATUS}"
grep -q '^1$'   <<<"${OUT}" || fail 'default: first captured line missing (not a full dump)'
grep -q '^100$' <<<"${OUT}" || fail 'default: last captured line missing'
grep -q 'Full log:' <<<"${OUT}" && fail 'default: should not print a full-log path'

# --- Tail=5: only the last 5 lines + a full-log path -------------------------
run_capture 5 emit_and_fail
[[ ${RUN_STATUS} -eq 3 ]] || fail "tail: expected status 3, got ${RUN_STATUS}"
grep -q '^100$' <<<"${OUT}" || fail 'tail: last line missing'
grep -q '^96$'  <<<"${OUT}" || fail 'tail: 5th-from-last line missing'
grep -q '^1$'   <<<"${OUT}" && fail 'tail: first line present (output not bounded)'
grep -q 'Full log:' <<<"${OUT}" || fail 'tail: full-log path not printed'
# Keep the referenced log for the caller; record it for cleanup.
leaked_logs+=("$(sed -n 's/.*Full log: //p' <<<"${OUT}" | tail -n 1)")

# --- Success never dumps the captured log ------------------------------------
run_capture 5 emit_and_ok
[[ ${RUN_STATUS} -eq 0 ]] || fail "success: expected status 0, got ${RUN_STATUS}"
grep -q '^50$' <<<"${OUT}" && fail 'success: captured log leaked on success path'

printf 'ok  ui_run: default full dump, UI_RUN_TAIL_LINES bounds failure output, success stays quiet\n'
