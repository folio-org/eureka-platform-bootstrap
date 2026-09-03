# AGENTS.md

## Purpose

- This repository defines and bootstraps a local FOLIO Eureka environment.
- Treat it as a Compose-centered environment-definition tool, not a single app with one build system.
- Read `docs/architecture/README.md` and `docs/roadmap/README.md` before structural changes.
- For cleanup/stock-alignment work, use `docs/roadmap/repository-cleanup-gap-backlog.md` as the active gap backlog.

## Operating Principles — read before changing anything

Goal of this repo: a simple, surgically precise, cross-platform-stable local FOLIO environment. Stability and simplicity outrank cleverness. Default to the smallest change that solves the stated problem.

- Reuse before create. Before adding any env var, script, function, file, or config key, `grep` the repo for one that already exists and use it. A new name is justified only when nothing existing fits.
- One source of truth. Never add a variable/default/path that restates an existing one. If `FOLIO_MODULE_SIDECAR_IMAGE` already carries the version, derive from it — do not add a `SIDECAR_BRANCH` to mirror it.
- Subtract before add. Prefer deleting or simplifying over introducing. If a change only adds lines, ask whether removing something achieves the same outcome.
- No new entry points. `./start.sh` and `./stop.sh` are the operator surface. Do not add top-level scripts, flags, or wrappers — extend the existing ones or their libs in `misc/`.
- Stop and ask before expanding scope. If you believe the task genuinely needs a new script, entry point, env var, dependency, or abstraction, do not create it silently — state why in one sentence and ask first.
- Stay cross-platform. Linux, macOS, and Windows must all keep working. No GNU-only flags, host-specific paths, or tools not already required.
- Match what's there. Follow existing script/lib/descriptor patterns and naming; new code should read like its neighbors.
- Prove it, minimally. Validate with the smallest real command (`bash -n`, `jq .`, the relevant `misc/tests/run.sh` check). A full runtime proof is `./start.sh`, which exports descriptor-derived image variables before invoking Compose. Do not spin up a new test harness when the offline runner already covers the area — add to it. Do not claim done without running the check.

## Current Repo Reality

- No root `package.json`, `Makefile`, `Taskfile.yml`, `justfile`, or single lint runner. Validation is script-by-script.
- `docker/.env` = committed defaults. `docker/.env.local` = local overrides. `docker/.env.local.credentials` = local secrets (never committed).
- `./start.sh` is the single operator entrypoint; it is thin. Logic lives in `misc/bootstrap-engine.sh` and `misc/lib/{folio-common,folio-api,docker-health}.sh`.
- `./stop.sh` is the single teardown entrypoint.
- The offline regression net is `bash misc/tests/run.sh` (shell syntax + python unit tests).

## Build And Run

- Full bootstrap: `./start.sh` (flags: `--actualize [--pre-release]`, `--native-sidecar`, `--rebuild-native-sidecar`, `--yes`, `--debug`).
- Stop/reset: `./stop.sh` (prompts to remove containers / clear volumes; `--yes` accepts defaults).
- Version sync and image workers are internal implementation details invoked by `./start.sh`.

## Validate And Test

- Bash: `bash -n path/to/file.sh`. Python: `python3 -m py_compile path/to/file.py`. JSON: `jq . path/to/file.json >/dev/null`. Compose runtime: `./start.sh` (its smoke check is the end-to-end proof).
- Offline checks: `bash misc/tests/run.sh`.
- The end-to-end proof is a real `./start.sh` run, which finishes with a built-in smoke check.
- Validate only the files you changed; there is no project-wide lint command.

## Conventions

- Naming: `mod-*` backend modules, `sc-*` sidecars, `mgr-*` managers, `docker/` runtime/orchestration, `misc/` operator tooling, `descriptors/app-platform-minimal/` registration metadata.
- Keep `descriptor.json`, `discovery.json`, and the version-sync scripts aligned.
- Shell: `#!/usr/bin/env bash`; `set -euo pipefail` in new or heavily edited scripts; resolve paths via `SCRIPT_DIR`/`PROJECT_ROOT`; quote expansions; capture HTTP status separately from the response body.
- Python: stdlib-only unless a new dependency is clearly justified; 4-space indent; snake_case; `if __name__ == "__main__":` in runnable scripts.
- YAML/JSON: 2-space indent; env stays inline in Compose; preserve descriptor module ordering.
- Operator-facing UX changes: define explicit UX success criteria first (less terminal noise, clearer step boundaries, fewer prompts); architectural cleanup is not proof of UX improvement; run a real operator smoke flow and judge the visible output.
- Terminal output: all console UI flows through `misc/lib/ui.sh`. Before adding/restyling any output (step, phase, panel, spinner, color), follow `docs/architecture/console-ui.md` — the design cookbook (color/glyph/phase/box/spinner contract, cross-platform and pipe-safety rules).
- Verification: the smoke check at the end of `./start.sh` plus `misc/tests/run.sh` is the proof; keep generated verification output out of `docs/` (use a temp path).

## Memory And Safety

- Keep `AGENTS.md`/`CLAUDE.md` well under 120 lines. Keep all agent instructions in this one tracked file so every tool (Codex, Claude Code, OpenCode) behaves identically; do not add tool-specific rule layers.
- Capture the rationale of a change in a well-described commit message; do not persist per-change design or spec docs. Reserve `docs/` for durable architecture, roadmap, and explicitly-requested reports.
- Do not store transient debugging notes or learned one-off workflows in tracked rule files.
- Fail fast on missing required commands or config. Use retries only for known transient startup/network cases.
- Never hardcode or commit real secrets. When changing config flow, make provenance clear: source, override point, consumer.
