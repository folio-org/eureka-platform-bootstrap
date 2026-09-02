#!/usr/bin/env bash
#
# Hermetic proof that ui_run does not force-enable `set -e` (errexit) for a
# caller that started without it. The set +e/set -e pair inside ui_run must
# restore the caller's prior errexit state, not unconditionally re-enable it.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

UI_COLOR=false
UI_INTERACTIVE=false
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/misc/lib/ui.sh"

# Confirm the precondition: errexit is OFF in this script (only -uo pipefail).
[[ $- == *e* ]] && fail 'test harness itself must start without errexit'

# A command that fails inside ui_run must propagate its exit code, but must NOT
# leave errexit enabled afterward. This script intentionally runs WITHOUT errexit
# (set -uo pipefail above, precondition-checked), so set +e is purely defensive;
# no set -e follows — re-enabling it here would defeat the assertion below.
set +e
ui_run 'failing-command' bash -c 'exit 7' 2>/dev/null
rc=$?

[[ ${rc} -eq 7 ]] || fail "ui_run should propagate exit code 7 (got ${rc})"
[[ $- != *e* ]] || fail 'ui_run force-enabled set -e for a caller that did not have it'

printf 'ok  ui_run restores caller errexit state\n'
