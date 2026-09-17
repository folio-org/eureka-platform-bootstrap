#!/usr/bin/env bash
# Presentation layer for the bootstrap scripts.
#
# Contract:
#   - human-facing output goes to stderr only; stdout is reserved for captured
#     values;
#   - zero ANSI escapes unless stderr is an interactive color terminal, and
#     plain ASCII glyphs unless that terminal is UTF-8 (piped and CI output
#     stays byte-clean);
#   - every printed duration/count is measured, at second resolution.

[[ -n "${_FOLIO_UI_SOURCED:-}" ]] && return 0
readonly _FOLIO_UI_SOURCED=1

UI_COLOR=false
UI_UNICODE=false
UI_MARK_OK='+'
UI_MARK_FAIL='x'
UI_MARK_RUN='-'
UI_BULLET='-'
UI_RULE='-'

# Failure context for the diagnostics snapshot: the last phase/step rendered,
# and (once a step fails) the phase/step that failed.
UI_CURRENT_PHASE=''
UI_CURRENT_STEP=''
UI_FAILED_PHASE=''
UI_FAILED_STEP=''

# Fixed content width for panel rows; terminals wider show slack, narrower
# ones wrap. No terminal-geometry probing by design.
UI_PANEL_WIDTH=76

ui_init() {
  [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]] || return 0
  UI_COLOR=true
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*)
      UI_UNICODE=true
      UI_MARK_OK='✓'
      UI_MARK_FAIL='✗'
      UI_MARK_RUN='○'
      UI_BULLET='·'
      UI_RULE='─'
      ;;
  esac
}

_ui_emit() {
  printf '%s\n' "$1" >&2
  return 0
}

# ui_c <role> <text> -> text wrapped in the role's color, or plain when off.
ui_c() {
  local role="$1"
  shift
  local text="$*"
  [[ "${UI_COLOR}" == true ]] || { printf '%s' "${text}"; return 0; }
  case "${role}" in
    done)   printf '\033[32m%s\033[0m' "${text}" ;;
    fail)   printf '\033[31m%s\033[0m' "${text}" ;;
    warn)   printf '\033[33m%s\033[0m' "${text}" ;;
    run)    printf '\033[36m%s\033[0m' "${text}" ;;
    link)   printf '\033[34m%s\033[0m' "${text}" ;;
    dim)    printf '\033[2m%s\033[0m' "${text}" ;;
    strong) printf '\033[1m%s\033[0m' "${text}" ;;
    *)      printf '%s' "${text}" ;;
  esac
}

# Measured seconds -> "12s" / "4m03s".
ui_fmt_seconds() {
  local seconds="$1"
  if (( seconds < 60 )); then
    printf '%ds' "${seconds}"
  else
    printf '%dm%02ds' $(( seconds / 60 )) $(( seconds % 60 ))
  fi
}

ui_title() {
  printf '\n' >&2
  _ui_emit "$(ui_c run "${UI_BULLET}") $(ui_c strong "$*")"
}

ui_step() {
  UI_CURRENT_STEP="$*"
  _ui_emit "  $(ui_c run "${UI_MARK_RUN}") $*"
}

ui_ok()   { _ui_emit "  $(ui_c done "${UI_MARK_OK}") $*"; }
ui_fail() { _ui_emit "  $(ui_c fail "${UI_MARK_FAIL}") $*"; }
ui_warn() { _ui_emit "  $(ui_c warn '!') $*"; }
ui_error() { _ui_emit "  $(ui_c fail 'Error:') $*"; }
ui_info() { _ui_emit "  $*"; }

ui_debug() {
  [[ "${DEBUG:-false}" == true ]] || return 0
  _ui_emit "  $*"
}

ui_kv() {
  _ui_emit "  ${1}: ${2}"
}

# Ask a yes/no question. The prompt goes to stderr, the answer is read from
# stdin; returns 0 for yes, 1 for no, with <default> (y|n, default n) deciding
# an empty answer or EOF. Callers own the interactive/ASSUME_YES policy.
ui_prompt() {
  local question="$1" default="${2:-n}" hint reply
  [[ "${default}" == y ]] && hint='[Y/n]' || hint='[y/N]'
  printf '  %s %s %s > ' "$(ui_c strong 'decision')" "${question}" "$(ui_c dim "${hint}")" >&2
  reply=''
  read -r reply || true
  case "${reply}" in
    [Yy]*) return 0 ;;
    [Nn]*) return 1 ;;
    *) [[ "${default}" == y ]] && return 0 || return 1 ;;
  esac
}

################################################################################
# Phases
################################################################################

_UI_PHASE_NUM=0
_UI_PHASE_START=0

# Open the next numbered phase (closing any previous one).
ui_phase() {
  ui_phase_finish done
  _UI_PHASE_NUM=$(( _UI_PHASE_NUM + 1 ))
  _UI_PHASE_START=${SECONDS}
  UI_CURRENT_PHASE="$1"
  UI_CURRENT_STEP=''
  printf '\n' >&2
  _ui_emit "$(printf '%02d' "${_UI_PHASE_NUM}") $(ui_c strong "$1")"
}

# Close the open phase with its measured duration, or the failure marker.
ui_phase_finish() {
  [[ "${_UI_PHASE_NUM}" -gt 0 ]] || return 0
  local elapsed
  elapsed=$(( SECONDS - _UI_PHASE_START ))
  if [[ "${1:-done}" == "failed" ]]; then
    [[ -n "${UI_FAILED_PHASE}" ]] || UI_FAILED_PHASE="${UI_CURRENT_PHASE}"
    [[ -n "${UI_FAILED_STEP}" ]] || UI_FAILED_STEP="${UI_CURRENT_STEP}"
    _ui_emit "  $(ui_c fail "failed after $(ui_fmt_seconds "${elapsed}")")"
    return 0
  fi
  _ui_emit "  $(ui_c dim "done in $(ui_fmt_seconds "${elapsed}")")"
}

################################################################################
# Live progress
#
# One spinner line shared by every wait loop: polling callers call ui_progress
# with their own measured detail/elapsed each iteration and ui_progress_end
# before committing the final line. Color-only, like ui_run's background frame:
# the line moves the cursor, and piped output must stay escape-free.
################################################################################

_UI_SPIN_INDEX=0

ui_progress() {
  local message="$1" detail="${2:-}" elapsed="${3:-}"
  [[ "${UI_COLOR}" == true ]] || return 0
  local frames='-\|/' seg=''
  local frame="${frames:$(( _UI_SPIN_INDEX % 4 )):1}"
  _UI_SPIN_INDEX=$(( _UI_SPIN_INDEX + 1 ))
  [[ -n "${detail}" ]] && seg=" $(ui_c dim "[${detail}]")"
  [[ -n "${elapsed}" ]] && seg="${seg} ${elapsed}s"
  printf '\r  %s %s%s\033[K' "$(ui_c run "${frame}")" "${message}" "${seg}" >&2
}

ui_progress_end() {
  [[ "${UI_COLOR}" == true ]] || return 0
  printf '\r\033[K' >&2
}

################################################################################
# Panels (image plan, smoke check, diagnostics, final summary)
################################################################################

# Fixed-width truncation helpers for table rows.
ui_trunc() {
  local text="$1" width="${2:-${UI_PANEL_WIDTH}}"
  if (( ${#text} <= width )); then
    printf '%s' "${text}"
  elif (( width <= 3 )); then
    printf '%.*s' "${width}" "${text}"
  else
    printf '%.*s...' "$(( width - 3 ))" "${text}"
  fi
}

# Keep the tail (image refs: the name:tag at the end is what matters).
ui_trunc_tail() {
  local text="$1" width="${2:-${UI_PANEL_WIDTH}}"
  if (( ${#text} <= width )); then
    printf '%s' "${text}"
  elif (( width <= 3 )); then
    printf '%.*s' "${width}" "${text}"
  else
    printf '...%s' "${text:$(( ${#text} - width + 3 ))}"
  fi
}

ui_panel() {
  local title="$1" right="${2:-}"
  printf '\n' >&2
  if [[ -n "${right}" ]]; then
    _ui_emit "  $(ui_c strong "${title}")  $(ui_c dim "${right}")"
  else
    _ui_emit "  $(ui_c strong "${title}")"
  fi
}

ui_panel_row() {
  _ui_emit "    $(ui_trunc "$*" "${UI_PANEL_WIDTH}")"
}

ui_panel_kv() {
  local key="$1" value
  value="$(ui_trunc "$2" "$(( UI_PANEL_WIDTH - ${#key} - 2 ))")"
  case "${value}" in
    http://*|https://*) value="$(ui_c link "${value}")" ;;
  esac
  _ui_emit "    $(ui_c dim "${key}:") ${value}"
}

# A check row: colored ok/fail mark, text, optional right-aligned value.
ui_panel_check() {
  local mark role
  if [[ "$1" == fail ]]; then mark="${UI_MARK_FAIL}"; role=fail; else mark="${UI_MARK_OK}"; role=done; fi
  _ui_emit "    $(ui_c "${role}" "${mark}") $(ui_trunc "$2" 66)${3:+  ${3}}"
}

ui_panel_end() {
  local rule='' i=0
  while (( i < UI_PANEL_WIDTH )); do rule="${rule}${UI_RULE}"; i=$(( i + 1 )); done
  _ui_emit "  $(ui_c dim "${rule}")"
}

################################################################################
# ui_run — run one command with its output folded
################################################################################

# On success only the ok line with the measured duration is shown. On failure
# the captured output is dumped (bounded to the last UI_RUN_TAIL_LINES lines
# when set, keeping the full log on disk) and the command's exit status is
# returned. The caller's errexit state is restored either way.
ui_run() {
  local description="$1"
  shift
  local start="${SECONDS}" status output_file='' spinner_pid=''
  local errexit_was_on=false
  [[ $- == *e* ]] && errexit_was_on=true

  ui_step "${description}"
  if [[ "${UI_COLOR}" == true && "${DEBUG:-false}" != true ]]; then
    (
      while :; do
        ui_progress "${description}"
        sleep 0.2
      done
    ) &
    spinner_pid=$!
  fi

  if [[ "${DEBUG:-false}" == true ]]; then
    set +e
    "$@" >&2
    status=$?
    ${errexit_was_on} && set -e
  else
    output_file="$(mktemp)"
    set +e
    "$@" >"${output_file}" 2>&1
    status=$?
    ${errexit_was_on} && set -e
  fi

  if [[ -n "${spinner_pid}" ]]; then
    kill "${spinner_pid}" 2>/dev/null || true
    wait "${spinner_pid}" 2>/dev/null || true
  fi
  ui_progress_end

  local elapsed
  elapsed="$(ui_fmt_seconds $(( SECONDS - start )))"

  if [[ ${status} -eq 0 ]]; then
    [[ -n "${output_file}" ]] && rm -f "${output_file}"
    ui_ok "${description} (${elapsed})"
    return 0
  fi

  UI_FAILED_PHASE="${UI_CURRENT_PHASE}"
  UI_FAILED_STEP="${description}"
  ui_fail "${description} failed (${elapsed})"
  if [[ -n "${output_file}" ]]; then
    if [[ -n "${UI_RUN_TAIL_LINES:-}" ]]; then
      tail -n "${UI_RUN_TAIL_LINES}" "${output_file}" >&2
      ui_info "Full log: ${output_file}"
    else
      cat "${output_file}" >&2
      rm -f "${output_file}"
    fi
  fi
  return "${status}"
}

ui_init
