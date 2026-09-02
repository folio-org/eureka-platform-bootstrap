#!/usr/bin/env bash
# Shared plain-text presentation helpers for bootstrap scripts.

[[ -n "${_FOLIO_UI_SOURCED:-}" ]] && return 0
readonly _FOLIO_UI_SOURCED=1

UI_INTERACTIVE=false
UI_COLOR=false
UI_UNICODE=false

# Single cap for content width. Not readonly and read via ${...:-} so child
# processes that re-source ui.sh
# inherit an env override, matching the exported _UI_PHASE_OPEN discipline.
UI_MAX_WIDTH="${UI_MAX_WIDTH:-120}"

if (( BASH_VERSINFO[0] >= 4 )); then
  declare -A _UI_TIMER_STARTS=()
else
  _UI_TIMER_STARTS_FLAT=''
fi

ui_init() {
  local locale_value

  if [[ -t 2 ]]; then
    UI_INTERACTIVE=true
  else
    UI_INTERACTIVE=false
  fi

  locale_value="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  case "${locale_value}" in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*)
      [[ "${UI_INTERACTIVE}" == "true" ]] && UI_UNICODE=true || UI_UNICODE=false
      ;;
    *)
      UI_UNICODE=false
      ;;
  esac

  # Color is enabled only on an interactive terminal that has not opted out.
  # When off, every helper below stays escape-free (CI/pipe/NO_COLOR/TERM=dumb).
  if [[ -n "${NO_COLOR:-}" || "${TERM:-}" == "dumb" || "${UI_INTERACTIVE}" != "true" ]]; then
    UI_COLOR=false
  else
    UI_COLOR=true
  fi
}

_ui_now_ms() {
  local now

  if command -v python3 >/dev/null 2>&1; then
    now="$(python3 - <<'PY' 2>/dev/null || true
import time
print(int(time.monotonic() * 1000))
PY
)"
    if [[ "${now}" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "${now}"
      return 0
    fi
  fi

  printf '%s000\n' "$(date +%s)"
}

ui_fmt_duration() {
  local millis="$1"
  local millis_int tenths whole decimal seconds minutes remaining

  [[ "${millis}" =~ ^[0-9]+([.][0-9]+)?$ ]] || millis=0
  millis_int="${millis%%.*}"
  millis_int=$((10#${millis_int}))

  if (( millis_int < 1000 )); then
    printf '%dms' "${millis_int}"
    return 0
  fi

  if (( millis_int < 10000 )); then
    tenths=$((millis_int / 100))
    whole=$((tenths / 10))
    decimal=$((tenths % 10))
    printf '%d.%ds' "${whole}" "${decimal}"
    return 0
  fi

  if (( millis_int < 60000 )); then
    seconds=$((millis_int / 1000))
    printf '%ds' "${seconds}"
    return 0
  fi

  minutes=$((millis_int / 60000))
  remaining=$(((millis_int / 1000) % 60))
  printf '%dm%02ds' "${minutes}" "${remaining}"
}

_ui_timer_supports_assoc() {
  (( BASH_VERSINFO[0] >= 4 ))
}

_ui_timer_flat_set() {
  local name="$1"
  local start="$2"
  local line new_lines=''

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    [[ "${line%%=*}" == "${name}" ]] && continue
    new_lines="${new_lines}${line}"$'\n'
  done <<< "${_UI_TIMER_STARTS_FLAT:-}"

  _UI_TIMER_STARTS_FLAT="${new_lines}${name}=${start}"$'\n'
}

_ui_timer_flat_get() {
  local name="$1"
  local line

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    if [[ "${line%%=*}" == "${name}" ]]; then
      printf '%s' "${line#*=}"
      return 0
    fi
  done <<< "${_UI_TIMER_STARTS_FLAT:-}"

  return 1
}

ui_timer_start() {
  local name="$1"
  local start

  start="$(_ui_now_ms)"
  if _ui_timer_supports_assoc; then
    _UI_TIMER_STARTS["${name}"]="${start}"
  else
    _ui_timer_flat_set "${name}" "${start}"
  fi
}

ui_timer_read() {
  local name="$1"
  local start now elapsed

  if _ui_timer_supports_assoc; then
    start="${_UI_TIMER_STARTS[${name}]:-}"
  else
    start="$(_ui_timer_flat_get "${name}" || true)"
  fi
  [[ "${start}" =~ ^[0-9]+$ ]] || return 1

  now="$(_ui_now_ms)"
  elapsed=$((now - start))
  (( elapsed < 0 )) && elapsed=0
  printf '%s\n' "${elapsed}"
}

ui_glyph() {
  local name="$1"
  local unicode="${UI_UNICODE:-false}"

  case "${name}:${unicode}" in
    box_tl:true)      printf '%s' $'\342\224\214' ;;
    box_tr:true)      printf '%s' $'\342\224\220' ;;
    box_bl:true)      printf '%s' $'\342\224\224' ;;
    box_br:true)      printf '%s' $'\342\224\230' ;;
    box_h:true)       printf '%s' $'\342\224\200' ;;
    box_v:true)       printf '%s' $'\342\224\202' ;;
    box_vr:true)      printf '%s' $'\342\224\234' ;;
    box_vl:true)      printf '%s' $'\342\224\244' ;;
    mark_ok:true)     printf '%s' $'\342\234\223' ;;
    mark_fail:true)   printf '%s' $'\342\234\227' ;;
    dot_done:true)    printf '%s' $'\342\227\217' ;;
    dot_pending:true) printf '%s' $'\342\227\213' ;;
    arrow:true)       printf '%s' $'\342\206\222' ;;
    bullet:true)      printf '%s' $'\302\267' ;;
    ellipsis:true)    printf '%s' $'\342\200\246' ;;
    warn:true)        printf '%s' $'\342\232\240' ;;
    caret:true)       printf '%s' $'\342\200\272' ;;
    box_tl:false|box_tr:false|box_bl:false|box_br:false|box_vr:false|box_vl:false) printf '%s' '+' ;;
    box_h:false)       printf '%s' '-' ;;
    box_v:false)       printf '%s' '|' ;;
    mark_ok:false)     printf '%s' '+' ;;
    mark_fail:false)   printf '%s' 'x' ;;
    dot_done:false)    printf '%s' '*' ;;
    dot_pending:false) printf '%s' '-' ;;
    arrow:false)       printf '%s' '->' ;;
    bullet:false)      printf '%s' '-' ;;
    ellipsis:false)    printf '%s' '...' ;;
    warn:false)        printf '%s' '!' ;;
    caret:false)       printf '%s' '>' ;;
    *)                 return 1 ;;
  esac
}

################################################################################
# Color substrate
#
# Named ANSI only (SGR 31-36 + bold/dim/reset). No 30/37/90-97, no backgrounds:
# they vanish or clash across light/dark themes. Everything is gated on UI_COLOR,
# so output is byte-for-byte escape-free when color is off.
################################################################################

# ui_sgr <code...> -> emit a single SGR escape, or nothing when color is off.
ui_sgr() {
  [[ "${UI_COLOR}" == true ]] || return 0
  local IFS=';'
  printf '\033[%sm' "$*"
}

# ui_c <role> <text> -> text wrapped in the role's accent, or raw text when off.
ui_c() {
  local role="$1"
  shift
  local text="$*" code
  if [[ "${UI_COLOR}" != true ]]; then
    printf '%s' "${text}"
    return 0
  fi
  case "${role}" in
    done)            code=32 ;;
    fail)            code=31 ;;
    warn)            code=33 ;;
    run|accent)      code=36 ;;
    link)            code=34 ;;
    dim)             code=2 ;;
    strong|phasenum) code=1 ;;
    decision)        code='1;35' ;;
    *)               code='' ;;
  esac
  if [[ -z "${code}" ]]; then
    printf '%s' "${text}"
  else
    printf '\033[%sm%s\033[0m' "${code}" "${text}"
  fi
}

_ui_paint() {
  local role="$1"
  shift
  local text="$*"
  case "${role}" in
    title) ui_c strong "${text}" ;;
    *)     printf '%s' "${text}" ;;
  esac
}

################################################################################
# Phase model state
#
# A run is a sequence of numbered phases. Phase close is position-independent: it
# appends a closing line rather than moving the cursor, so output that bypasses
# this module (docker compose progress, child scripts, the refresh prompt) can
# never desync the rendering. COMPLETED_PHASES feeds the recap line.
################################################################################

_UI_PHASE_NUM=0
_UI_PHASE_NUM_PADDED='00'
# Exported and seeded from the environment so child processes that re-source this
# file inherit the open-phase state
# and gutter their lines in step with the parent's column.
_UI_PHASE_OPEN="${_UI_PHASE_OPEN:-false}"
export _UI_PHASE_OPEN
_UI_PHASE_NAME=''
UI_CURRENT_PHASE="${UI_CURRENT_PHASE:-}"
UI_CURRENT_STEP="${UI_CURRENT_STEP:-}"
UI_FAILED_PHASE="${UI_FAILED_PHASE:-}"
UI_FAILED_STEP="${UI_FAILED_STEP:-}"
export UI_CURRENT_PHASE UI_CURRENT_STEP UI_FAILED_PHASE UI_FAILED_STEP
COMPLETED_PHASES=()

# Emit one newline-terminated line to stderr. Spinners use raw \r and only commit
# their final line through here.
_ui_emit() {
  printf '%s\n' "$1" >&2
  return 0
}

_ui_line() {
  local role="$1"
  shift
  _ui_emit "$(_ui_paint "${role}" "$*")"
}

# Indent for body lines. Inside an open phase, on the boxed (interactive UTF-8)
# path, it is the dim "│ " gutter that attaches a line to its phase header. With
# no phase open (the banner/preflight block) or in flat/piped output it is a plain
# two-space indent, so neither an orphan column nor an ASCII "|" noise bar is drawn.
_ui_gutter() {
  if [[ "${_UI_PHASE_OPEN}" == true ]] && _ui_boxed; then
    printf '  %s ' "$(ui_c dim "$(ui_glyph box_v)")"
  else
    printf '  '
  fi
}

ui_title() {
  printf '\n%s %s\n' "$(ui_c run "$(ui_glyph dot_done)")" "$(ui_c strong "$*")" >&2
}

ui_ok()   { _ui_emit "$(_ui_gutter)$(ui_c done "$(ui_glyph mark_ok)") $*"; }
ui_fail() { _ui_emit "$(_ui_gutter)$(ui_c fail "$(ui_glyph mark_fail)") $*"; }
ui_step() {
  UI_CURRENT_STEP="$*"
  export UI_CURRENT_STEP
  _ui_emit "$(_ui_gutter)$(ui_c run "$(ui_glyph dot_pending)") $*"
}
ui_warn() { _ui_emit "$(_ui_gutter)$(ui_c warn '!') $*"; }
ui_error() { _ui_emit "$(_ui_gutter)$(ui_sgr 1 31)Error:$(ui_sgr 0) $*"; }

# Render a yes/no decision as a "branch" off the flow and read the answer. On the
# boxed path inside an open phase it sprouts from the phase gutter's │ as a dim ├,
# so the question reads as an explicit fork; otherwise it is a plain dim rule. The
# `decision` label and caret use the bold-magenta `decision` role so the prompt
# stands apart from the cyan phase furniture rather than blending into it. The
# prompt goes explicitly to stderr and the answer is read from stdin. Returns 0
# for yes, 1 for no; <default> (y|n, default n) decides on an
# empty answer or EOF. Callers own the interactive/ASSUME_YES policy — this only
# renders and reads, so it stays testable by piping stdin.
ui_prompt() {
  local question="$1" default="${2:-n}"
  local h lead hint caret prompt reply

  h="$(ui_glyph box_h)"
  if [[ "${_UI_PHASE_OPEN}" == true ]] && _ui_boxed; then
    lead="  $(ui_c dim "$(ui_glyph box_vr)${h}") "
  else
    lead="  $(ui_c dim "${h}") "
  fi
  [[ "${default}" == y ]] && hint='[Y/n]' || hint='[y/N]'
  caret="$(ui_glyph caret)"

  prompt="${lead}$(ui_c decision 'decision') $(ui_c dim "$(ui_glyph bullet)") ${question} $(ui_c dim "${h}${h}${h}") $(ui_c dim "${hint}") $(ui_c decision "${caret}") "
  # Emit the prompt explicitly (not via read -p, which bash suppresses when stdin
  # is not a terminal) so it always reaches stderr — like every other UI line.
  reply=''
  printf '%s' "${prompt}" >&2
  read -r reply || true

  case "${reply}" in
    [Yy]*) return 0 ;;
    [Nn]*) return 1 ;;
    *) [[ "${default}" == y ]] && return 0 || return 1 ;;
  esac
}

ui_status_timed() {
  local state="$1" message="$2" elapsed="$3"
  local glyph role elapsed_text
  if [[ "${state}" == fail ]]; then
    glyph="$(ui_glyph mark_fail)"
    role=fail
  else
    glyph="$(ui_glyph mark_ok)"
    role=done
  fi
  elapsed_text="$(ui_fmt_duration "${elapsed}")"

  if [[ "${UI_INTERACTIVE}" == true && "${UI_COLOR}" == true ]]; then
    local cols gutter_width left_plain right_plain space_count spaces
    cols="$(ui_content_width)"
    gutter_width=2
    [[ "${_UI_PHASE_OPEN}" == true ]] && _ui_boxed && gutter_width=4
    printf -v left_plain '%*s%s %s' "${gutter_width}" '' "${glyph}" "${message}"
    right_plain="${elapsed_text}"
    space_count=$((cols - ${#left_plain} - ${#right_plain}))
    (( space_count < 2 )) && space_count=2
    printf -v spaces '%*s' "${space_count}" ''
    _ui_emit "$(_ui_gutter)$(ui_c "${role}" "${glyph}") ${message}${spaces}$(ui_c dim "${elapsed_text}")"
  else
    _ui_emit "$(_ui_gutter)$(ui_c "${role}" "${glyph}") ${message} ${elapsed_text}"
  fi
}

ui_activity_start() {
  local message="$*"
  UI_CURRENT_STEP="${message}"
  export UI_CURRENT_STEP
  if [[ "${UI_COLOR}" == true ]]; then
    ui_spinner '-' "${message}" '' '0ms'
  else
    ui_step "${message}"
  fi
}

ui_activity_tick() {
  local spin_char="$1" message="$2" detail="${3:-}" elapsed="${4:-}"
  local elapsed_text=''
  [[ -n "${elapsed}" ]] && elapsed_text="$(ui_fmt_duration "${elapsed}")"
  ui_spinner "${spin_char}" "${message}" "${detail}" "${elapsed_text}"
}

ui_activity_finish() {
  local state="$1" message="$2" elapsed="$3"
  ui_spinner_clear
  ui_status_timed "${state}" "${message}" "${elapsed}"
}

# Single source for the running-spinner frame sequence. Returns the frame for a
# tick index, cycling. A braille pulse under UI_UNICODE (interactive UTF-8, where
# substring indexing is character-based), ASCII `-\|/` otherwise so piped/CI
# output stays ASCII per the console-ui contract. Override the whole sequence via
# UI_SPIN_FRAMES. Every spinner (ui_run, wait loops, the image builder) draws
# from here so the style has one point of change.
_ui_spin_frame() {
  local index="${1:-0}" frames
  if [[ -n "${UI_SPIN_FRAMES:-}" ]]; then
    frames="${UI_SPIN_FRAMES}"
  elif [[ "${UI_UNICODE}" == true ]]; then
    frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  else
    frames='-\|/'
  fi
  printf '%s' "${frames:$(( index % ${#frames} )):1}"
}

_ui_spinner_loop() {
  local message="$1" timer_name="$2"
  local i=0 spin_char elapsed
  while true; do
    spin_char="$(_ui_spin_frame "${i}")"
    elapsed="$(ui_timer_read "${timer_name}" 2>/dev/null || printf 0)"
    ui_activity_tick "${spin_char}" "${message}" '' "${elapsed}"
    i=$((i + 1))
    sleep 0.2
  done
}

_ui_stop_spinner_loop() {
  local spinner_pid="${1:-}"
  [[ -n "${spinner_pid}" ]] || return 0
  kill "${spinner_pid}" 2>/dev/null || true
  wait "${spinner_pid}" 2>/dev/null || true
  ui_spinner_clear
}
# Free-form narration. Gutters in step with the phase column when one is open;
# an empty message stays a bare blank line (never a lone gutter bar), so callers
# that use ui_info "" as a spacer do not grow a dangling "│".
ui_info() {
  if [[ -z "$*" ]]; then
    _ui_emit ''
  else
    _ui_emit "$(_ui_gutter)$*"
  fi
}
ui_note()  { _ui_line note "$*"; }

ui_debug() {
  [[ "${DEBUG:-false}" == true ]] || return 0
  _ui_line debug "$*"
}

ui_kv() {
  local key="$1"
  local value="$2"
  # Inside an open phase, nest under the gutter so it aligns with sibling steps;
  # standalone (no phase) it stays a plain "key: value" line.
  if [[ "${_UI_PHASE_OPEN}" == true ]]; then
    _ui_emit "$(_ui_gutter)${key}: ${value}"
  else
    _ui_line kv "${key}: ${value}"
  fi
}

# Short recap label for a phase name (a small explicit map; unknown names fall
# back to a lowercased copy).
_ui_phase_label() {
  case "$1" in
    'Configure')                 printf 'setup' ;;
    'Prepare config')            printf 'config' ;;
    'Start core services')       printf 'core' ;;
    'Start manager services')    printf 'managers' ;;
    'Register application')      printf 'registration' ;;
    'Start application services') printf 'app services' ;;
    'Finalize tenant setup')     printf 'tenant' ;;
    'Create default admin user') printf 'user' ;;
    *) printf '%s' "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" ;;
  esac
}

# Build a phase header line: <dot> NN  Name <fill...>. Length math is done on the
# plain glyphs (each one visible character) so the colored render lines up. The
# header carries no right-hand status token — completion is marked by the closing
# line appended in ui_phase_finish, which keeps rendering position-independent.
_ui_phase_header() {
  local num="$1" name="$2"
  local cols dot fill_char left_plain fill_len fill='' i
  cols="$(ui_content_width)"
  dot="$(ui_glyph dot_done)"
  fill_char="$(ui_glyph box_h)"
  left_plain="${dot} ${num}  ${name} "
  fill_len=$(( cols - ${#left_plain} ))
  (( fill_len < 1 )) && fill_len=1
  for (( i = 0; i < fill_len; i++ )); do fill="${fill}${fill_char}"; done
  printf '%s %s  %s %s' \
    "$(ui_c run "${dot}")" \
    "$(ui_c phasenum "${num}")" \
    "$(ui_c strong "${name}")" \
    "$(ui_c dim "${fill}")"
}

# Open a numbered phase: close the previous one, then print its header.
ui_phase() {
  local name="$1"
  ui_phase_finish done

  _UI_PHASE_NUM=$(( _UI_PHASE_NUM + 1 ))
  printf -v _UI_PHASE_NUM_PADDED '%02d' "${_UI_PHASE_NUM}"
  _UI_PHASE_NAME="${name}"
  UI_CURRENT_PHASE="${name}"
  UI_CURRENT_STEP=''
  export UI_CURRENT_PHASE UI_CURRENT_STEP
  _UI_PHASE_OPEN=true
  ui_timer_start "phase_${_UI_PHASE_NUM_PADDED}"

  printf '\n' >&2
  if _ui_boxed; then
    printf '%s\n' "$(_ui_phase_header "${_UI_PHASE_NUM_PADDED}" "${name}")" >&2
  else
    _ui_emit "[${_UI_PHASE_NUM_PADDED}] ${name}"
  fi
}

# Close the open phase. Position-independent: never moves the cursor. In a boxed
# run it appends one closing line carrying the measured elapsed (dim) or a red
# "failed" marker; in a flat/piped run the next "[NN]" header delimits, so nothing
# is appended. Safe regardless of any external output the phase emitted.
ui_phase_finish() {
  local status="${1:-done}"
  [[ "${_UI_PHASE_OPEN}" == true ]] || return 0
  _UI_PHASE_OPEN=false

  local num="${_UI_PHASE_NUM_PADDED}" name="${_UI_PHASE_NAME}" elapsed
  elapsed="$(ui_fmt_duration "$(ui_timer_read "phase_${num}" 2>/dev/null || printf 0)")"

  if [[ "${status}" == failed ]]; then
    [[ -n "${UI_FAILED_PHASE}" ]] || UI_FAILED_PHASE="${_UI_PHASE_NAME}"
    [[ -n "${UI_FAILED_STEP}" ]] || UI_FAILED_STEP="${UI_CURRENT_STEP}"
    export UI_FAILED_PHASE UI_FAILED_STEP
    _ui_boxed && _ui_emit "  $(ui_c fail "$(ui_glyph box_bl)$(ui_glyph box_h) failed $(ui_glyph bullet) ${elapsed}")"
    return 0
  fi

  # Only phases that actually completed feed the recap.
  COMPLETED_PHASES+=("$(_ui_phase_label "${name}")")
  _ui_boxed && _ui_emit "  $(ui_c dim "$(ui_glyph box_bl)$(ui_glyph box_h) ${elapsed}")"
  return 0
}

# Dim recap of completed phases, printed before the final (or diagnostic) box.
ui_recap() {
  local total="${1:-}"
  [[ "${#COMPLETED_PHASES[@]}" -gt 0 ]] || return 0

  local sep joined='' p line
  sep=" $(ui_c dim "$(ui_glyph bullet)") "
  for p in "${COMPLETED_PHASES[@]}"; do
    if [[ -z "${joined}" ]]; then joined="${p}"; else joined="${joined}${sep}${p}"; fi
  done
  line="$(ui_c done "$(ui_glyph mark_ok)") ${joined}"
  [[ -n "${total}" ]] && line="${line}   $(ui_c dim "${total}")"
  printf '\n' >&2
  _ui_emit "${line}"
}

ui_cols() {
  # `stty size </dev/tty` reads the controlling terminal's winsize directly, so it
  # survives command substitution. `$(tput cols)` does not: ncurses resolves width
  # via TIOCGWINSZ on tput's stdout fd, which is the substitution pipe here (not a
  # tty), so it silently falls back to the static terminfo cols (usually 80). tput
  # stays as the fallback for hosts without a usable /dev/tty.
  local cols='' size=''
  # The group redirect covers the </dev/tty open too: on a host with no controlling
  # terminal the shell's own "cannot open" message would otherwise escape `2>` set on
  # stty alone, leaking onto the console and the captured stream in tests.
  if size="$( { stty size </dev/tty; } 2>/dev/null )"; then
    cols="${size##* }"
  fi
  [[ "${cols}" =~ ^[0-9]+$ && "${cols}" -gt 0 ]] || cols="$(tput cols 2>/dev/null || true)"
  [[ "${cols}" =~ ^[0-9]+$ && "${cols}" -gt 0 ]] || cols=80
  printf '%s\n' "${cols}"
}

# Canonical content width: the terminal width, clamped to UI_MAX_WIDTH. The single
# source of truth for every full-width element — the phase header rule, the box
# right edge, and the right-aligned timing all derive from this, so their right
# edges land on the same column. Never re-cap ui_cols elsewhere.
ui_content_width() {
  local c
  c="$(ui_cols)"
  (( c > UI_MAX_WIDTH )) && c="${UI_MAX_WIDTH}"
  printf '%s\n' "${c}"
}

ui_trunc() {
  local text="$1"
  local width="$2"

  [[ "${width}" =~ ^[0-9]+$ ]] || width=80
  if (( width <= 0 )); then
    printf ''
  elif (( ${#text} <= width )); then
    printf '%s' "${text}"
  elif (( width <= 3 )); then
    printf '%.*s' "${width}" "${text}"
  else
    printf '%.*s...' "$((width - 3))" "${text}"
  fi
}

# Truncate keeping the tail, prefixing an ellipsis (for long image refs where the
# name:tag at the end is what matters). `${text:offset}` form works on Bash 3.2.
ui_trunc_left() {
  local text="$1" width="$2" ell keep
  [[ "${width}" =~ ^[0-9]+$ ]] || width=80
  (( width <= 0 )) && { printf ''; return 0; }
  (( ${#text} <= width )) && { printf '%s' "${text}"; return 0; }
  ell="$(ui_glyph ellipsis)"
  (( width <= ${#ell} )) && { printf '%.*s' "${width}" "${text}"; return 0; }
  keep=$(( width - ${#ell} ))
  printf '%s%s' "${ell}" "${text:$(( ${#text} - keep ))}"
}

################################################################################
# Box panels
#
# A panel renders as a Unicode box when _ui_boxed (interactive UTF-8). Otherwise
# it degrades to flat indented lines so piped/CI logs stay clean and escape-free.
# Cells are width-clamped via ui_trunc; coloring is applied to whole glyphs or
# whole cells only, so visible-length math is computed on the plain text.
################################################################################

_ui_boxed() { [[ "${UI_UNICODE}" == true ]]; }

# Left margin for a box. Inside an open phase a box nests one level into the
# column (the dim "│ " gutter, visible width 4); standalone (the completion box,
# printed after the last phase closed) it has no margin. Pairs with _ui_box_width,
# which subtracts the margin so margin + box stays within the terminal.
_ui_box_indent() {
  [[ "${_UI_PHASE_OPEN}" == true ]] || return 0
  printf '  %s ' "$(ui_c dim "$(ui_glyph box_v)")"
}
_ui_box_indent_width() { [[ "${_UI_PHASE_OPEN}" == true ]] && printf 4 || printf 0; }

_ui_box_width() {
  local indent_w="${1:-0}"
  printf '%s' "$(( $(ui_content_width) - indent_w ))"
}

ui_box_inner_width() {
  local width
  width="$(_ui_box_width "$(_ui_box_indent_width)")"
  printf '%s' "$(( width - 4 ))"
}

ui_box_top() {
  local label="$1" right="${2:-}" label_role="${3:-accent}"
  if ! _ui_boxed; then
    local indent=''
    [[ "${_UI_PHASE_OPEN}" == true ]] && indent="$(_ui_gutter)"
    if [[ -n "${right}" ]]; then _ui_emit "${indent}${label}: ${right}"; else _ui_emit "${indent}${label}"; fi
    return 0
  fi

  local width tl h tr left_plain right_plain fill_len fill='' i out indent
  indent="$(_ui_box_indent)"
  width="$(_ui_box_width "$(_ui_box_indent_width)")"
  tl="$(ui_glyph box_tl)"; h="$(ui_glyph box_h)"; tr="$(ui_glyph box_tr)"
  left_plain="${tl}${h} ${label} "
  if [[ -n "${right}" ]]; then right_plain=" ${right} ${h}${tr}"; else right_plain="${h}${tr}"; fi
  fill_len=$(( width - ${#left_plain} - ${#right_plain} ))
  (( fill_len < 0 )) && fill_len=0
  for (( i = 0; i < fill_len; i++ )); do fill="${fill}${h}"; done

  out="$(ui_c dim "${tl}${h}") $(ui_c "${label_role}" "${label}") $(ui_c dim "${fill}")"
  if [[ -n "${right}" ]]; then
    out="${out} $(ui_c dim "${right}") $(ui_c dim "${h}${tr}")"
  else
    out="${out}$(ui_c dim "${h}${tr}")"
  fi
  _ui_emit "${indent}${out}"
}

ui_box_row() {
  local text="$*" width inner pad spaces indent
  if ! _ui_boxed; then _ui_emit "  ${text}"; return 0; fi
  indent="$(_ui_box_indent)"
  width="$(_ui_box_width "$(_ui_box_indent_width)")"; inner=$(( width - 4 ))
  text="$(ui_trunc "${text}" "${inner}")"
  pad=$(( inner - ${#text} )); (( pad < 0 )) && pad=0
  printf -v spaces '%*s' "${pad}" ''
  _ui_emit "${indent}$(ui_c dim "$(ui_glyph box_v)") ${text}${spaces} $(ui_c dim "$(ui_glyph box_v)")"
}

# A check row: a colored ok/fail glyph, a message, and an optional right value
# pushed to the inner right edge.
ui_box_status_row() {
  local state="$1" text="$2" right="${3:-}"
  local glyph role
  if [[ "${state}" == fail ]]; then glyph="$(ui_glyph mark_fail)"; role=fail
  else glyph="$(ui_glyph mark_ok)"; role=done; fi

  if ! _ui_boxed; then
    _ui_emit "  ${glyph} ${text}${right:+  ${right}}"
    return 0
  fi

  local width inner rlen textw tpad tspaces rightseg='' indent
  indent="$(_ui_box_indent)"
  width="$(_ui_box_width "$(_ui_box_indent_width)")"; inner=$(( width - 4 ))
  rlen=0; [[ -n "${right}" ]] && rlen=$(( ${#right} + 1 ))
  textw=$(( inner - 2 - rlen )); (( textw < 1 )) && textw=1
  text="$(ui_trunc "${text}" "${textw}")"
  tpad=$(( textw - ${#text} )); (( tpad < 0 )) && tpad=0
  printf -v tspaces '%*s' "${tpad}" ''
  [[ -n "${right}" ]] && rightseg=" $(ui_c dim "${right}")"
  _ui_emit "${indent}$(ui_c dim "$(ui_glyph box_v)") $(ui_c "${role}" "${glyph}") ${text}${tspaces}${rightseg} $(ui_c dim "$(ui_glyph box_v)")"
}

# A key/value row; URLs render blue.
ui_box_kv() {
  local key="$1" value="$2"
  if ! _ui_boxed; then _ui_emit "  ${key}: ${value}"; return 0; fi

  local width inner keyw valw vpad vspaces keycol rendered_value indent
  indent="$(_ui_box_indent)"
  width="$(_ui_box_width "$(_ui_box_indent_width)")"; inner=$(( width - 4 ))
  keyw=12
  (( ${#key} > keyw )) && key="${key:0:keyw}"
  valw=$(( inner - keyw - 2 )); (( valw < 1 )) && valw=1
  value="$(ui_trunc "${value}" "${valw}")"
  vpad=$(( valw - ${#value} )); (( vpad < 0 )) && vpad=0
  printf -v vspaces '%*s' "${vpad}" ''
  printf -v keycol '%-*s' "${keyw}" "${key}"
  case "${value}" in
    http://*|https://*) rendered_value="$(ui_c link "${value}")" ;;
    *)                  rendered_value="${value}" ;;
  esac
  _ui_emit "${indent}$(ui_c dim "$(ui_glyph box_v)") $(ui_c dim "${keycol}")  ${rendered_value}${vspaces} $(ui_c dim "$(ui_glyph box_v)")"
}

ui_box_kv_wrapped() {
  local key="$1" value="$2"
  if ! _ui_boxed; then
    _ui_emit "  ${key}: ${value}"
    return 0
  fi

  local width inner keyw valw indent line_key segment rest break_at i keycol rendered_value vpad vspaces
  indent="$(_ui_box_indent)"
  width="$(_ui_box_width "$(_ui_box_indent_width)")"; inner=$(( width - 4 ))
  keyw=12
  (( ${#key} > keyw )) && key="${key:0:keyw}"
  valw=$(( inner - keyw - 2 )); (( valw < 1 )) && valw=1
  rest="${value}"
  line_key="${key}"

  while [[ -n "${rest}" ]]; do
    if (( ${#rest} <= valw )); then
      segment="${rest}"
      rest=''
    else
      segment="${rest:0:${valw}}"
      break_at=0
      for (( i = ${#segment}; i > 0; i-- )); do
        [[ "${segment:$((i - 1)):1}" == ' ' ]] && { break_at=$i; break; }
      done
      if (( break_at > 0 )); then
        segment="${segment:0:$((break_at - 1))}"
        rest="${rest:${break_at}}"
      else
        rest="${rest:${valw}}"
      fi
    fi

    printf -v keycol '%-*s' "${keyw}" "${line_key}"
    case "${segment}" in
      http://*|https://*) rendered_value="$(ui_c link "${segment}")" ;;
      *)                  rendered_value="${segment}" ;;
    esac
    vpad=$(( valw - ${#segment} )); (( vpad < 0 )) && vpad=0
    printf -v vspaces '%*s' "${vpad}" ''
    _ui_emit "${indent}$(ui_c dim "$(ui_glyph box_v)") $(ui_c dim "${keycol}")  ${rendered_value}${vspaces} $(ui_c dim "$(ui_glyph box_v)")"
    line_key=''
  done
}

ui_box_sep() {
  _ui_boxed || return 0
  local width h i bar='' indent
  indent="$(_ui_box_indent)"
  width="$(_ui_box_width "$(_ui_box_indent_width)")"; h="$(ui_glyph box_h)"
  for (( i = 0; i < width - 2; i++ )); do bar="${bar}${h}"; done
  _ui_emit "${indent}$(ui_c dim "$(ui_glyph box_vr)${bar}$(ui_glyph box_vl)")"
}

ui_box_bottom() {
  _ui_boxed || return 0
  local width h i bar='' indent
  indent="$(_ui_box_indent)"
  width="$(_ui_box_width "$(_ui_box_indent_width)")"; h="$(ui_glyph box_h)"
  for (( i = 0; i < width - 2; i++ )); do bar="${bar}${h}"; done
  _ui_emit "${indent}$(ui_c dim "$(ui_glyph box_bl)${bar}$(ui_glyph box_br)")"
}

ui_run() {
  local description="$1"
  shift
  local output_file status elapsed timer_name spinner_pid=''
  local errexit_was_on=false
  [[ $- == *e* ]] && errexit_was_on=true

  timer_name="run_$$_${RANDOM:-0}"
  ui_timer_start "${timer_name}"

  if [[ "${DEBUG:-false}" == true ]]; then
    ui_step "${description}"
  else
    ui_activity_start "${description}"
    if [[ "${UI_COLOR}" == true ]]; then
      _ui_spinner_loop "${description}" "${timer_name}" &
      spinner_pid=$!
    fi
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

  elapsed="$(ui_timer_read "${timer_name}" 2>/dev/null || printf 0)"
  _ui_stop_spinner_loop "${spinner_pid}"

  if [[ ${status} -eq 0 ]]; then
    [[ -n "${output_file:-}" ]] && rm -f "${output_file}"
    if [[ "${DEBUG:-false}" == true ]]; then
      ui_status_timed ok "${description}" "${elapsed}"
    else
      ui_activity_finish ok "${description}" "${elapsed}"
    fi
    return 0
  fi

  UI_FAILED_PHASE="${UI_CURRENT_PHASE:-${_UI_PHASE_NAME:-}}"
  UI_FAILED_STEP="${description}"
  export UI_FAILED_PHASE UI_FAILED_STEP
  if [[ "${DEBUG:-false}" == true ]]; then
    ui_status_timed fail "${description} failed" "${elapsed}"
  else
    ui_activity_finish fail "${description} failed" "${elapsed}"
  fi
  if [[ -n "${output_file:-}" ]]; then
    # Default: dump the whole captured log (short commands). For a long, chatty
    # command (a native build), the caller sets UI_RUN_TAIL_LINES to bound the
    # failure output to the last N lines and keep the full log on disk for
    # inspection instead of flooding the terminal.
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

# Live, single-line progress. Emits cursor escapes, so — like ui_run's in-place
# upgrade and per the no-\033-when-UI_COLOR=false contract — it is gated on
# UI_COLOR, not just UI_INTERACTIVE. Shares the phase gutter via _ui_gutter (dim
# "│ " inside a boxed phase, plain indent otherwise), then a cyan spin glyph and
# message, with an optional dim [counter] and dim elapsed. The trailing \033[K
# clears any leftover from a longer previous frame; commit the final ok/fail line
# with ui_spinner_clear first.
ui_spinner() {
  local spin_char="$1" message="$2" counter="${3:-}" elapsed="${4:-}"
  [[ "${UI_COLOR}" == true ]] || return 0
  local seg=''
  [[ -n "${counter}" ]] && seg="${seg} $(ui_c dim "[${counter}]")"
  [[ -n "${elapsed}" ]] && seg="${seg} $(ui_c dim "${elapsed}")"
  printf '\r%s%s %s%s\033[K' \
    "$(_ui_gutter)" "$(ui_c run "${spin_char}")" "${message}" "${seg}" >&2
}

# Clear the current spinner line before committing a final ok/fail line. No-op
# unless color is on, matching ui_spinner: when no spinner was drawn there is
# nothing to clear, and the contract forbids emitting an escape with color off.
ui_spinner_clear() {
  [[ "${UI_COLOR}" == true ]] || return 0
  printf '\r\033[K' >&2
}

ui_init
