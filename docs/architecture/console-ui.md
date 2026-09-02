# Console UI/UX — design cookbook

The operator console produced by `./start.sh` is rendered entirely through one
module: `misc/lib/ui.sh`. This document is the contract and the cookbook for that
layer. Any change to bootstrap output — a new step, a new panel, a reworded
message, a refactor — must follow what is written here so the console stays
consistent, honest, and safe on every platform and in every pipe.

It is a companion to `principles.md`: same discipline (smallest change, reuse
before create, cross-platform, stability over cleverness), applied to the visible
terminal surface.

## 1. Goals (in priority order)

1. **Truthful.** Never print a number, duration, count, or status that was not
   measured. No fake percentages, no invented per-line times.
2. **Safe in a pipe.** When output is not an interactive terminal (CI, `| tee`,
   `NO_COLOR`, `TERM=dumb`), it degrades to plain ASCII on stderr with **zero**
   escape bytes — and stdout stays empty for presentation calls.
3. **Cross-platform.** Linux, macOS (Bash 3.2), and Windows/git-bash must all
   render correctly. No GNU-only flags, no tools not already required.
4. **One source of truth.** All presentation flows through `ui.sh`. Callers never
   `printf` colored or boxed output themselves.
5. **Quietly beautiful when it can be.** On a real UTF-8 color terminal we add
   numbered phases, in-place header timing, boxes, and live spinners — but every
   one of those is a progressive enhancement layered on top of the plain output,
   never a replacement for it.

## 2. The capability ladder

Three booleans are detected once in `ui_init` and gate everything. Detect; never
assume. They form a ladder — each higher rung implies the one below it in
practice.

| Flag             | True when                                                        | Gates                                            |
|------------------|------------------------------------------------------------------|--------------------------------------------------|
| `UI_INTERACTIVE` | stderr is a tty (`[[ -t 2 ]]`)                                   | spinners, `ui_run` single-line upgrade, cursor moves |
| `UI_COLOR`       | `UI_INTERACTIVE` && `NO_COLOR` unset && `TERM != dumb`          | every ANSI escape (color **and** cursor control) |
| `UI_UNICODE`     | `UI_INTERACTIVE` && a UTF-8 locale (`LC_ALL/LC_CTYPE/LANG`)     | box-drawing + non-ASCII glyphs (`_ui_boxed`)     |

The three observable frames that result:

- **Interactive + color + UTF-8** — the full console: boxes, numbered phase
  headers with a dim `└─ <elapsed>` closing line, live spinners, single-line
  `ui_run`.
- **Interactive, no color** (rare: `NO_COLOR` on a UTF-8 tty) — boxes still draw
  in Unicode, but with no escapes; `ui_run` does not collapse (the upgrade needs
  color/cursor escapes).
- **Piped / CI** — flat `[NN] Name` phase lines, no boxes, no spinner, ASCII
  glyphs only, no escapes. This is the contract the regression test pins.

When in doubt about which rung you are on, do the safe (lower) thing.

## 3. Color — named ANSI only, always gated

Use **only** SGR `31`–`36` plus bold (`1`), dim (`2`), reset (`0`). Never `30`,
`37`, `90`–`97`, and never a background — they vanish or clash across light/dark
themes. Primary text is the terminal default foreground (no SGR at all).

Two primitives, both no-ops when `UI_COLOR=false`:

```sh
ui_sgr 1 31            # -> "\033[1;31m" with color, "" without
ui_c <role> <text>     # -> text wrapped in the role accent + reset, or raw text
```

Semantic roles (compose rich lines from `ui_c` segments — never paint a whole
composed line a single color):

| Role               | SGR | Meaning                                   |
|--------------------|-----|-------------------------------------------|
| `done`             | 32  | success / completed                       |
| `fail`             | 31  | failure                                   |
| `warn`             | 33  | warning / attention                       |
| `run` / `accent`   | 36  | in progress / accents / box labels        |
| `link`             | 34  | URLs                                      |
| `dim`              | 2   | secondary text, borders, gutters, times   |
| `strong`/`phasenum`| 1   | titles, phase names, phase numbers        |
| `decision`         | 1;35| interactive prompt label + caret (bold magenta — stands apart from cyan phases) |

**Hard rule:** if `UI_COLOR=false`, the output must contain no `\033` byte. This
includes cursor control — spinners and `ui_run`'s single-line upgrade emit
escapes, so they are gated on `UI_INTERACTIVE`/`UI_COLOR` and never run in a pipe.

## 4. Glyphs — always through `ui_glyph`

Never hardcode a box-drawing character, check mark, dot, arrow, bullet,
ellipsis, or `⚠` inline. Call `ui_glyph <name>`; it returns the UTF-8 glyph when
`UI_UNICODE=true` and a readable ASCII fallback otherwise (`│→|`, `✓→+`, `✗→x`,
`●→*`, `○→-`, `→→->`, `·→-`, `…→...`, `⚠→!`, `›→>`). Hardcoding a multibyte character
leaks raw UTF-8 bytes into CI logs even on the ASCII path. Separators in
assembled strings (banner, panel labels) use `$(ui_glyph bullet)` for the same
reason.

Available names: `box_tl box_tr box_bl box_br box_h box_v box_vr box_vl mark_ok
mark_fail dot_done dot_pending arrow bullet ellipsis warn caret`. The animated
running-spinner frame is not a `ui_glyph` — it is a cycling sequence served by
`_ui_spin_frame` (see §9).

## 5. Output channel — and why rendering is position-independent

- All presentation goes to **stderr**. stdout is reserved for capturable data
  (`value="$(some_helper)"`). The contract test fails if a presentation call
  writes to stdout.
- Every newline-terminated line is emitted through `_ui_emit`. Prefer routing any
  line through an existing helper (`ui_info`, `ui_ok`, `ui_box_row`, …) for style
  consistency.
- **No rendering depends on counting lines.** An earlier design rewrote the phase
  header in place by counting body lines (`_UI_PHASE_LINES`) and moving the cursor
  up. That desynced whenever a phase emitted output the module could not count —
  `docker compose` progress on stderr, child workers with their own ui.sh state,
  or a `read -p` prompt — and
  reprinted a duplicate header mid-output. The model is now **append-only**: phase
  close (§7) and spinners never move the cursor based on counted lines, so external
  output can never corrupt the frame. The only cursor moves left are bounded and
  self-contained (the spinner's own `\r` line; `ui_run`'s single-line upgrade,
  which controls its own gap).
- Spinners write with a bare `\r` (no newline); their final committed line is a
  normal `_ui_emit`/`ok`.

## 6. Status lines and the gutter

Step-level lines render as `<gutter> <colored glyph> <text>`. The gutter is
**phase-aware and process-aware**, computed by `_ui_gutter`:

- Inside an open phase, on the boxed (interactive UTF-8) path, it is the dim `  │ `
  column that attaches a line to its phase header.
- With no phase open (the banner/preflight block) or in flat/piped output, it is a
  plain two-space indent — so neither an orphan column under the banner nor an ASCII
  `|` noise bar in CI logs is drawn.

`_UI_PHASE_OPEN` is **exported** and seeded from the environment, so child processes
that re-source `ui.sh` inherit the
open-phase state and keep the column continuous through child-driven output. A
continuous gutter is therefore an emergent property of shared state, never a cursor
trick — the same discipline as §5. The shims the engine calls:

| Helper      | Renders                          | Use for                          |
|-------------|----------------------------------|----------------------------------|
| `ui_step`   | cyan `○` + text                  | a step that is starting / ongoing|
| `ui_ok`     | green `✓` + text                 | a step that succeeded            |
| `ui_fail`   | red `✗` + text                   | a step that failed (non-fatal UX)|
| `ui_warn`   | yellow `!` + text                | a warning                        |
| `ui_error`  | bold-red `Error:` + text         | a hard error (usually pre-exit)  |

`ui_run <desc> <cmd...>` wraps a helper invocation: folded output uses a live
activity spinner on interactive color terminals, then commits one final timed
status line (`✓ <desc> 123ms`) whose elapsed is pushed to the right edge at
`ui_content_width` — the same column the phase rule and boxes end on. DEBUG streams
helper output and keeps the normal step/result lines, with no spinner or cursor rewrite. Piped/NO_COLOR output keeps
the plain two-line frame and stays escape-free. Prefer it for "do a thing, show
one result line" work.

`ui_prompt <question> [default:y|n]` renders an interactive yes/no **decision** as
a branch off the flow, then reads the answer (returns 0 for yes, 1 for no). Inside
an open phase on the boxed path it sprouts from the gutter's `│` as a dim `├` —
`├─ decision · <question> ─── [y/N] › ` — so a fork reads as part of the phase;
outside a phase it is a plain dim rule (`─ decision · … `). The prompt is emitted
explicitly to stderr, and the answer is read from stdin, so both share the stream
cleanly. It renders and reads only — the caller owns the
interactive/`ASSUME_YES` policy and guards non-interactive runs (`[[ -t 0 ]]`); on
an empty answer or EOF the `default` decides. Prefer it over a raw `read -r -p` for
any operator decision.

Do not change the wording of existing messages when restyling — only the
marker/prefix/box around them.

## 7. The phase model

A run is a sequence of numbered phases. The engine calls `phase '<Name>'`
(`→ ui_phase`) once per phase; numbering is automatic and zero-padded
(`01`, `02`, …).

The run opens with phase **01 Configure**, opened by `start.sh`'s `main` (not the
engine): it owns the interactive decisions (`ui_prompt` branches), the tool check,
and the host preflight — output that used to float unattached above the banner now
nests under its gutter. `run_bootstrap_flow`'s first `phase 'Prepare config'` closes
it and continues at 02.

- On a new `phase`, the previous phase is closed first, then a header is printed:
  `● NN  Name ─────────────` (cyan dot, fill to `ui_content_width`; interactive
  UTF-8) or flat `[NN] Name` (pipe). Filling to the shared content width aligns the
  header's right edge with the boxes below it. The header carries **no** status token — completion is marked
  by the closing line, not by rewriting the header. A per-phase timer `phase_NN`
  starts.
- A phase **closes** via `phase_done [done|failed]` (`→ ui_phase_finish`), or
  automatically when the next `phase` opens. Close is **append-only — never moves
  the cursor** (see §5 for why):
  - **Boxed** (interactive UTF-8): append one closing line — `  └─ <elapsed>` (dim)
    for `done`, or `  └─ failed · <elapsed>` (red) for `failed`.
  - **Flat/pipe**: nothing extra — the next `[NN]` delimits.
  - Because the close appends rather than seeking a counted row, any external
    output the phase emitted (docker progress, child scripts, prompts) is harmless.
- Only phases closed as `done` are recorded in `COMPLETED_PHASES` (the recap;
  see §10). A failed phase is shown but excluded from the recap.

Recipe — add a numbered phase to the flow (in `bootstrap-engine.sh`):

```sh
phase 'Start core services'      # opens 0N, starts timer phase_0N
docker compose --profile core up -d
wait_for_all_healthy             # emits step/ok/spinner lines under the header
# closed automatically by the next phase, or by phase_done before the final box
```

Add the short recap label for any new phase name to `_ui_phase_label` in
`ui.sh` (a small explicit case map; unknown names fall back to lowercase).

## 8. Boxes (panels)

Use a box for a self-contained sub-report (image plan, smoke check, the final
summary, the failure snapshot). Boxes draw only when `_ui_boxed` (UTF-8); in a
pipe they degrade to flat indented lines so CI logs stay clean.

A box opened **while a phase is open** nests one level into the column: every line
is prefixed with the `  │ ` gutter and `_ui_box_width` subtracts that margin
(`_ui_box_indent` / `_ui_box_indent_width`), so the panel reads as part of its
phase. A box drawn with no phase open (the final completion box, printed after
`phase_done`) has no margin and spans full width.

| Helper                                  | Boxed render                          | Flat (pipe) render        |
|-----------------------------------------|---------------------------------------|---------------------------|
| `ui_box_top <label> [right] [role]`     | `┌─ label ──…──  right ─┐`             | `label: right`            |
| `ui_box_row <text>`                     | `│ text…            │` (clamped)       | `  text`                  |
| `ui_box_status_row <ok\|fail> <t> [r]`  | `│ ✓ t            r │`                 | `  + t  r`                |
| `ui_box_kv <key> <value>`               | `│ key      value  │` (URLs blue)      | `  key: value`            |
| `ui_box_sep`                            | `├──…──┤`                              | (nothing)                 |
| `ui_box_bottom`                         | `└──…──┘`                              | (nothing)                 |

Rules:

- Width comes from `ui_content_width()` (= `min(ui_cols, UI_MAX_WIDTH)`, default
  cap 120) — the single source of truth shared by the phase header rule, the box
  right edge, and the right-aligned timed line, so all three align on the same
  column. Every cell is clamped with `ui_trunc` (or `ui_trunc_left` to keep the
  tail of a long image ref) so nothing wraps.
- **Measure on plain text, color whole cells/glyphs only.** Visible-length math
  must never have to account for embedded escapes — apply color to a complete
  glyph or a complete cell, after you have computed widths from the plain string.
- `label_role` colors the box label (`accent` default; `done` for the success
  box; `warn` for the diagnostic box). Pass the `⚠` etc. as part of the label
  via `ui_glyph`.

Recipe — a results panel whose right label depends on the outcome (collect
first, render once):

```sh
local states=() texts=() rights=() idx
# ... run checks, push ok|fail / text / right value per check ...
ui_box_top 'smoke check' "$([[ $failures -eq 0 ]] && echo passed || echo "${failures} failed")"
for idx in "${!states[@]}"; do
  ui_box_status_row "${states[$idx]}" "${texts[$idx]}" "${rights[$idx]}"
done
ui_box_bottom
```

## 9. Live spinners

`ui_activity_start <message>`, `ui_activity_tick <spin> <message> [detail]
[elapsed_ms]`, and `ui_activity_finish <ok|fail> <message> <elapsed_ms>` are the
public wait-loop primitives. On interactive color terminals they render one live
spinner line and then one committed status line. In pipes/NO_COLOR, `start`
prints the normal pending step, `tick` is silent, and `finish` prints the final
status line.

`ui_spinner <char> <message> [counter] [elapsed]` is the low-level renderer used
by the activity helpers. It emits cursor escapes, so it is gated on `UI_COLOR`
(returns immediately otherwise), matching the no-`\033`-when-`UI_COLOR=false`
rule. It renders the shared phase gutter (`_ui_gutter`) + a cyan spin glyph +
message + dim `[counter]` + dim elapsed, on one line via `\r`, terminated with
`\033[K`.

The running-frame character comes from one source, `_ui_spin_frame <index>`: a
braille pulse (`⠋⠙⠹…`) under `UI_UNICODE`, ASCII `-\|/` otherwise so piped/CI
output stays ASCII. Never hardcode a frame string in a wait loop — pass a cycling
index to `_ui_spin_frame` so every spinner (this, `ui_run`, the image builder)
shares the style. Override the whole sequence with `UI_SPIN_FRAMES`.

Tick it once per poll iteration in a wait loop, feeding **measured** values:

```sh
ui_timer_start health_wait
ui_activity_start 'Verifying container health'
while …; do
  spin_char="$(_ui_spin_frame "$((i++))")"
  ui_activity_tick "$spin_char" 'Verifying container health' \
    "${HEALTH_READY_COUNT}/${HEALTH_TOTAL_COUNT}" "$(ui_timer_read health_wait)"
  sleep 2
done
ui_activity_finish ok 'Container health ready' "$(ui_timer_read health_wait)"
```

No percentages. No counter unless it is a real ready/total. No elapsed unless a
real timer backs it.

## 10. Banner and recap

- **Banner**: `print_run_banner` (bootstrap-engine, called from `start.sh` at the top,
  **above** the Configure phase) renders `● <bold name>` via `title`, then one dim
  identity line `app · arch` (version prepended only if `git describe --tags` yields
  one — never hardcode a version). Separators via `ui_glyph bullet`. The sidecar/module
  choices are not shown here — the banner prints before those prompts settle — so
  `print_run_mode` surfaces them inside the Configure phase as a
  `· sidecar <mode> · modules <pinned|actualized>` line (dim separators, values at
  normal weight — matching the banner's own identity line).
- **Recap**: `ui_recap [total]` prints a dim `✓ phase · phase · …  <total>` line
  built from `COMPLETED_PHASES`, before the final summary box (success) and
  before the diagnostic box (failure). It no-ops when no phase has completed.

## 11. Timing — the only source of numbers

Durations come exclusively from the timer helpers; format with
`ui_fmt_duration` (`123ms`, `1.2s`, `22s`, `1m02s`):

```sh
ui_timer_start <name>            # records monotonic-ish start in milliseconds
ui_timer_read  <name>            # prints elapsed milliseconds, or fails if never started
```

`ui_timer_read` **fails** (non-zero, no output) for a timer that was never
started — callers must guard (`… 2>/dev/null || printf 0`) rather than invent a
value. The Bash 3.2 fallback store is already handled inside `ui.sh`; use the
helpers, don't reach into `_UI_TIMER_*`.

Active timers today: `run_total`, `phase_NN`, `health_wait`, `entitlement_wait`,
`capabilities_wait`.

## 12. Cross-platform notes

- Target Bash 3.2 (macOS system bash). No associative arrays in new code paths
  without a flat fallback; use `${var:$((i))}` slicing rather than `${var: -n}`.
- `tput cols` may be empty — always default to 80.
- `${arr[@]}` on a possibly-empty array under `set -u` is a known footgun on old
  Bash; the existing panels always have ≥1 row, keep it that way or guard.

## 13. What NOT to do

- No truecolor / 256-color, no backgrounds, no `30/37/90–97`.
- No raw `printf` of colored or boxed output outside `ui.sh`.
- No fabricated numbers, durations, or percentages.
- No new top-level entry point/flag/env/dep to drive output — extend `ui.sh` and
  the existing call sites.
- No hardcoded multibyte glyphs or separators — always `ui_glyph`.
- No cursor movement (`\033[…A/B`) outside the `UI_INTERACTIVE && UI_COLOR` guard,
  and only when self-contained (own `\r` line, or a gap you fully control like
  `ui_run`). Never seek to a row whose position depends on counting emitted lines —
  external output makes that count wrong.
- Don't reword existing operator messages while restyling.

## 14. Validation (run before claiming done)

- `bash -n` on every changed `.sh`.
- `bash misc/tests/run.sh` — the offline net. The presentation contract lives in
  `misc/tests/test-ui-stream-contract.sh`; extend it, do not add a new harness.
  It pins: stdout stays empty; **no `\033` when `UI_COLOR=false`** (incl. the
  boxed path); `ui_c`/`ui_sgr` on/off behavior; box width-clamp + truncation;
  flat panels emit no Unicode/escape bytes; spinners and entitlement/capabilities
  waits print measured durations; failure diagnostics reach stderr.
- `NO_COLOR=1 ./start.sh --help | cat` and `./start.sh --help 2>&1 | cat` must be
  escape-free.
- The end-to-end proof is a real `./start.sh` run on an interactive terminal,
  plus a `./start.sh 2>&1 | tee run.log` to confirm the piped frame is plain
  ASCII with no escapes, no boxes, no spinner.

## 15. Function map (where to look in `ui.sh`)

```
ui_init                              capability detection (the three flags)
ui_sgr / ui_c / _ui_paint            color substrate
ui_glyph                             glyph + ASCII fallback table
_ui_emit / _ui_line / _ui_gutter     stderr line emit + gutter
ui_title ui_info ui_note ui_kv       plain lines / banner (ui_kv nests in a phase)
ui_ok ui_fail ui_step ui_warn ui_error  status lines (gutter + glyph)
ui_prompt                            interactive yes/no decision (branch off the flow)
ui_status_timed                      timed ok/fail status line
ui_activity_start/tick/finish        wait-loop activity primitive
ui_run                               run-a-helper-with-result (folded spinner)
ui_phase / ui_phase_finish           numbered phase open / append-only close
_ui_phase_header / _ui_phase_label   header rendering / recap labels
_ui_boxed _ui_box_width ui_box_inner_width  box gating + width
ui_box_top/row/status_row/kv/sep/bottom  panels
ui_recap                             completed-phase recap line
ui_spinner                           live single-line progress
ui_cols ui_content_width             raw terminal width / capped content width (UI_MAX_WIDTH)
ui_trunc ui_trunc_left               truncation
ui_timer_start ui_timer_read ui_fmt_duration  timing
```

Shims in `misc/lib/folio-common.sh` (`title phase phase_done step ok warn`) are
what the engine calls; new bootstrap code may call `ui_*` directly.
