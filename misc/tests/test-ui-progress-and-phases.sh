#!/usr/bin/env bash
#
# Two UI invariants, exercised with color forced on (the only mode where the
# progress line exists):
#
#   1. A committed line (ok/fail/step/title/panel) first erases any live
#      progress line, so a polling loop that goes straight from ui_progress to
#      its final status cannot glue spinner fragments in front of it.
#   2. ui_phase_finish is idempotent: closing a phase twice never prints a
#      duplicate close line, and opening the next phase does not re-close an
#      already-closed one.
#
# Piped output (color off) must stay byte-clean: no escapes at all.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/misc/lib/ui.sh"

err="$(mktemp)"
trap 'rm -f "${err}"' EXIT

# Progress -> committed line: a frame ends with \033[K and the commit must
# immediately carry \r\033[K, so the glued pair proves the final line started
# from a cleared position (color bytes around the mark are irrelevant).
(
  UI_COLOR=true
  ui_progress 'Verifying container health' '3/12' 6
  ui_ok 'Container health ready (6s)'
) 2>"${err}"
grep -aqF $'\033[K\r\033[K' "${err}" || fail 'ui_ok did not clear the live progress line before committing'
grep -aqF 'Container health ready (6s)' "${err}" || fail 'ui_ok line content missing'

(
  UI_COLOR=true
  ui_progress 'Verifying tenants route' 'HTTP 000' 4
  ui_fail 'tenants route did not become ready (4s)'
) 2>"${err}"
grep -aqF $'\033[K\r\033[K' "${err}" || fail 'ui_fail did not clear the live progress line before committing'
grep -aqF 'tenants route did not become ready (4s)' "${err}" || fail 'ui_fail line content missing'

# Titles and panels clear before their leading newline: the frame's \033[K is
# followed by the title's \r\033[K and only then the newline.
(
  UI_COLOR=true
  ui_progress 'Building images' '0/18' 3
  ui_title 'eureka platform bootstrap'
) 2>"${err}"
grep -aqF $'\033[K\r\033[K\n' "${err}" \
  || fail 'ui_title did not clear the progress line before its newline'

# ui_run: spinner stopped and the ok line is committed from a cleared position.
(
  UI_COLOR=true
  ui_run 'quick step' true
) 2>"${err}"
grep -aqF $'\033[K\r\033[K' "${err}" || fail 'ui_run did not clear its spinner before the ok line'
grep -aqF 'quick step (' "${err}" || fail 'ui_run ok line content missing'

# Phase idempotency.
(
  ui_phase_finish done                      # nothing open yet: no output
  ui_phase 'Prepare config'
  ui_phase_finish done
  ui_phase_finish done                      # second close: no-op
  ui_phase 'Start core services'            # previous already closed: no re-close
  ui_phase_finish failed
  ui_phase_finish done                      # after failed close: no-op
) 2>"${err}"

closes="$(grep -c 'done in\|failed after' "${err}")"
[[ ${closes} -eq 2 ]] || fail "expected exactly 2 phase close lines (one per phase), got ${closes}"
grep -q 'failed after' "${err}" || fail 'failed close lost its failure marker'
grep -q '01 Prepare config' "${err}" || fail 'phase numbering broken'
grep -q '02 Start core services' "${err}" || fail 'second phase not numbered'

# Color-off (piped) output stays free of escape bytes.
(
  UI_COLOR=false
  ui_progress 'm' 'd' 1
  ui_ok 'plain'
  ui_fail 'plain fail'
) 2>"${err}"
if grep -q $'\x1b' "${err}"; then
  fail 'piped output contains ANSI escapes'
fi
grep -qF "  ${UI_MARK_OK} plain" "${err}" || fail 'color-off ok line missing'

printf 'ok  ui: committed lines clear the progress line; phase close is idempotent; piped output byte-clean\n'
