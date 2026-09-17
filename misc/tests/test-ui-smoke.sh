#!/usr/bin/env bash
#
# Small UI smoke contract:
#   - presentation goes to stderr only and stays escape-free and ASCII when
#     piped / NO_COLOR / TERM=dumb;
#   - ui_prompt renders the question to stderr and honors y/n/default answers;
#   - live progress (spinner) emits nothing without color, so piped output is
#     byte-clean.
#
# (ui_run exit propagation and bounded failure output are covered by
# test-ui-run-errexit-restore.sh and test-ui-run-tail.sh.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

stdout_file="$(mktemp)"
stderr_file="$(mktemp)"
trap 'rm -f "${stdout_file}" "${stderr_file}"' EXIT

export NO_COLOR=1 TERM=dumb

(
  cd "${PROJECT_ROOT}"
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/misc/lib/ui.sh"

  ui_title 'Contract title'
  ui_phase 'Contract phase'
  ui_step 'Contract step'
  ui_ok 'Contract ok'
  ui_warn 'Contract warn'
  ui_error 'Contract error'
  ui_debug 'Contract debug'
  ui_kv 'Contract key' 'value'
  ui_panel 'Contract panel' 'right'
  ui_panel_row 'Contract row'
  ui_panel_kv 'Contract kv' 'http://localhost:8000'
  ui_panel_check ok 'Contract check' 'HTTP 200'
  ui_panel_check fail 'Contract fail row' 'reason'
  ui_panel_end
  ui_phase_finish done
  ui_phase 'Contract phase 2'
  ui_phase_finish failed
) >"${stdout_file}" 2>"${stderr_file}"

[[ ! -s "${stdout_file}" ]] || {
  sed 's/^/stdout: /' "${stdout_file}" >&2
  fail 'presentation calls wrote to stdout'
}
if LC_ALL=C grep -q "$(printf '\033')" "${stderr_file}"; then
  sed 's/^/stderr: /' "${stderr_file}" >&2
  fail 'presentation output contains ANSI ESC bytes'
fi
if LC_ALL=C grep -q '[^ -~]' "${stderr_file}"; then
  sed 's/^/stderr: /' "${stderr_file}" >&2
  fail 'piped presentation output contains non-ASCII bytes'
fi
for expected in 'Contract title' '01 Contract phase' 'Contract step' 'Contract ok' \
                'Error: Contract error' 'Contract panel' 'Contract check' \
                'failed after' 'done in'; do
  grep -q "${expected}" "${stderr_file}" \
    || { sed 's/^/stderr: /' "${stderr_file}" >&2; fail "missing expected output: ${expected}"; }
done

# Debug lines only render when DEBUG is on.
DEBUG=false
(
  cd "${PROJECT_ROOT}"
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/misc/lib/ui.sh"
  ui_debug 'Contract debug'
) >"${stdout_file}" 2>"${stderr_file}"
grep -q 'Contract debug' "${stderr_file}" && fail 'ui_debug rendered with DEBUG off'

# Live progress is color-only: byte-silent when piped.
(
  cd "${PROJECT_ROOT}"
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/misc/lib/ui.sh"
  ui_progress 'Working' '1/2' 5
  ui_progress_end
) >"${stdout_file}" 2>"${stderr_file}"
[[ ! -s "${stdout_file}" ]] || fail 'ui_progress wrote to stdout'
[[ ! -s "${stderr_file}" ]] || fail 'ui_progress emitted output without color'

# ui_prompt renders to stderr and reads a y/n answer with default handling.
(
  cd "${PROJECT_ROOT}"
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/misc/lib/ui.sh"

  prompt_out="$(printf 'y\n' | { ui_prompt 'Decide the thing?' n; } 2>&1 1>/dev/null || true)"
  [[ "${prompt_out}" == *'Decide the thing?'* ]] || fail 'ui_prompt dropped its question'
  if LC_ALL=C grep -q "$(printf '\033')" <<<"${prompt_out}"; then
    fail 'ui_prompt emitted ESC bytes with color off'
  fi

  rc=0; printf 'y\n' | ( ui_prompt 'x?' n ) >/dev/null 2>&1 || rc=$?
  [[ "${rc}" -eq 0 ]] || fail 'ui_prompt did not return yes for y'
  rc=0; printf 'n\n' | ( ui_prompt 'x?' y ) >/dev/null 2>&1 || rc=$?
  [[ "${rc}" -eq 1 ]] || fail 'ui_prompt did not return no for n'
  rc=0; printf '\n' | ( ui_prompt 'x?' y ) >/dev/null 2>&1 || rc=$?
  [[ "${rc}" -eq 0 ]] || fail 'ui_prompt empty answer did not honor default y'
  rc=0; printf '\n' | ( ui_prompt 'x?' n ) >/dev/null 2>&1 || rc=$?
  [[ "${rc}" -eq 1 ]] || fail 'ui_prompt empty answer did not honor default n'
)

printf 'ok  ui smoke: stderr-only, escape-free piped output, prompt answers\n'
