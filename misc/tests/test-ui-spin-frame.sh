#!/usr/bin/env bash
#
# Contract for the single spinner-frame source (_ui_spin_frame):
#   - ASCII `-\|/` when UI_UNICODE is off (the piped/CI path — must stay ASCII);
#   - a non-ASCII (braille) frame when UI_UNICODE is on;
#   - UI_SPIN_FRAMES overrides the whole sequence;
#   - the index cycles.
# Every spinner in the repo draws from this one helper, so this pins the style.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_value() {
  local description="$1" expected="$2" actual="$3"
  [[ "${actual}" == "${expected}" ]] || fail "${description}: expected '${expected}', got '${actual}'"
}

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/misc/lib/ui.sh"

# --- ASCII path (UI_UNICODE off): exact frames + cycling -----------------------
UI_UNICODE=false
unset UI_SPIN_FRAMES
assert_value 'ascii frame 0' '-'  "$(_ui_spin_frame 0)"
assert_value 'ascii frame 1' '\'  "$(_ui_spin_frame 1)"
assert_value 'ascii frame 2' '|'  "$(_ui_spin_frame 2)"
assert_value 'ascii frame 3' '/'  "$(_ui_spin_frame 3)"
assert_value 'ascii frame wraps at 4' '-' "$(_ui_spin_frame 4)"
assert_value 'ascii frame default index' '-' "$(_ui_spin_frame)"

# --- Unicode path (UI_UNICODE on): braille branch is selected -----------------
# Assert the frame is non-empty and NOT an ASCII spin char, i.e. the braille
# branch was taken. Exact multibyte extraction depends on a UTF-8 locale, so we
# avoid asserting the precise glyph to keep the test locale-independent.
UI_UNICODE=true
unset UI_SPIN_FRAMES
frame="$(_ui_spin_frame 0)"
[[ -n "${frame}" ]] || fail 'unicode frame 0 is empty'
case "${frame}" in
  '-'|'\'|'|'|'/') fail "unicode path returned an ASCII spin char '${frame}'" ;;
esac

# --- Override: UI_SPIN_FRAMES wins in either mode ------------------------------
UI_SPIN_FRAMES='.oO'
assert_value 'override frame 0' '.' "$(_ui_spin_frame 0)"
assert_value 'override frame 1' 'o' "$(_ui_spin_frame 1)"
assert_value 'override frame 2' 'O' "$(_ui_spin_frame 2)"
assert_value 'override wraps at 3' '.' "$(_ui_spin_frame 3)"
UI_UNICODE=false
assert_value 'override wins with unicode off too' 'o' "$(_ui_spin_frame 1)"
unset UI_SPIN_FRAMES

printf 'ok  _ui_spin_frame: one source, ASCII/braille by UI_UNICODE, override, cycling\n'
