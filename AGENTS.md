# AGENTS.md

Agent instructions for `eureka-platform-bootstrap` — a Compose-centered local
FOLIO Eureka environment tool. `CLAUDE.md` is a symlink to this file; keep all
agent rules here so every tool behaves identically.

## Read first

- `README.md` — operator surface and configuration model.
- `docs/architecture.md` — runtime layers, descriptor flow, guards, invariants.
- The operator surface is exactly `./start.sh` and `./stop.sh`. Everything in
  `misc/` and `docker/lib/` is internal machinery those two invoke.

## Prime directive: subtract

Stability and simplicity outrank cleverness. The best change is the one that
deletes the most code while preserving behavior.

- Take the smallest change that solves the stated problem. No speculative
  generality, no abstraction "for future reuse".
- Reuse before create: `grep` for an existing var, script, or function before
  introducing a new name. A new name needs a reason nothing existing fits.
- One source of truth: never add a variable/default/path that restates another.
- Deleting code, docs, or tests is the preferred form of maintenance. Git
  history is the archive — keep superseded plans, backlogs, and design
  cookbooks out of the tree; `docs/` holds only `architecture.md`.
- Internal decomposition is allowed when it makes the result materially smaller
  or easier to understand — a new internal function or file must earn itself
  by net reduction, never by anticipated need. Keep files small; do not treat
  "no new files" as a reason to grow huge ones.
- Never introduce CLI frameworks, task runners, new dependencies, config or
  plugin frameworks, secret-management machinery, or generalized retry or
  rendering frameworks. This is a local development environment; the simple
  local credentials stay as they are.

## Changing things

- Do not add top-level scripts, flags, or wrappers — extend `./start.sh`,
  `./stop.sh`, or their libraries. If a change seems to genuinely need a new
  entry point, env var, or dependency, say why in one sentence and ask first.
- Cross-platform is mandatory: Linux, macOS (stock Bash 3.2), Windows/git-bash.
  No GNU-only flags, no associative arrays where a flat form works, no
  host-specific paths.
- Preserve correctness guards even where they cost lines: warm-rerun
  idempotency, descriptor/image skew halt, gateway route-loss halt, warm
  actualize upgrade semantics, per-module discovery fallback, project-scoped
  health waiting, bounded failure diagnostics. Do not remove a correctness fix
  merely because it added code.
- Config precedence is a contract: shell env > `docker/.env.local.credentials`
  > `docker/.env.local` > `docker/.env`. Never commit secrets; make provenance
  (source, override point, consumer) clear when touching config flow.
- Descriptor, `discovery.json`, Compose services, and the version-sync scripts
  stay aligned. Adding a module is a descriptor + Compose change, not a
  runtime option.

## Terminal output

- All operator-facing output flows through `misc/lib/ui.sh`; no ad-hoc styled
  `printf` in the engine or libraries.
- Hard rules: presentation writes to stderr only (stdout is reserved for
  captured values); zero ANSI escapes when piped, `NO_COLOR`, or `TERM=dumb`;
  never print a duration, count, or status that was not measured.
- Exact glyphs, ANSI byte sequences, and width arithmetic are not contracts —
  visual similarity to the current console is enough. Keep the primitive
  surface small (roughly: title, phase, step, ok, warn, error, prompt, run,
  one spinner, one panel) and do not grow a layout or rendering framework.

## Proving changes

- The offline net is `bash misc/tests/run.sh` (syntax + hermetic behavior
  tests). Run it after any change; extend it instead of building new harnesses.
- Smallest real check for a touched file: `bash -n`, `python3 -m py_compile`,
  or `jq .` as applicable.
- The end-to-end proof is a real `./start.sh` run finishing with its smoke
  check. Do not claim done without running the relevant check.
- Tests protect observable behavior (config precedence, warm reruns, actualize,
  gateway selection and route guard, ARM/native decisions, failure and
  recovery propagation). Tests that pin exact ANSI bytes, glyphs, or internal
  helper shapes are not contracts — do not add them.

## Conventions

- Naming: `mod-*` modules, `sc-*` sidecars, `mgr-*` managers, `docker/`
  runtime, `misc/` tooling, `descriptors/app-platform-minimal/` metadata.
- Shell: `#!/usr/bin/env bash`; `set -euo pipefail`; resolve paths via
  `SCRIPT_DIR`/`PROJECT_ROOT`; quote expansions; capture HTTP status
  separately from the response body.
- Python: stdlib-only unless clearly justified; 4-space indent; snake_case;
  `if __name__ == "__main__":` in runnable scripts.
- YAML/JSON: 2-space indent; env stays inline in Compose; preserve descriptor
  module ordering.
- Capture a change's rationale in its commit message, not in a tracked design
  doc; keep transient debugging notes out of rule files.
- Fail fast on missing commands or config; retry only known transient
  startup/network cases. Keep this file concise.
