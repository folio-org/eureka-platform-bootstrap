# Repository Roadmap

How `eureka-platform-bootstrap` should keep evolving into a clearer, simpler,
more user-friendly environment-definition tool — without losing its core idea.

## Mission

Preserve the repository's foundation while keeping it:

- easy to understand
- easy to operate
- easy to extend
- transparent in how configuration works
- simple enough for both humans and agents to inspect quickly

## Foundation to preserve

- Compose remains central to the runtime model.
- The repository remains the source-controlled definition of the local environment.
- Application metadata for `app-platform-minimal` stays explicit.
- The layered runtime model (core → managers → bundled application services) stays understandable.
- Operator UX stays thin over a transparent runtime definition.

## North star

- each Compose service is easy to inspect in one clear place
- each service exposes its configurable inputs, defaults, and dependencies
- configuration provenance is traceable end to end
- the bundled application starts only its declared services
- the operator experience is thin and simple, not over-engineered

## Principles

- simplicity first; clarity before compression
- explicit definitions before convenience wrappers
- thin UX over transparent runtime definitions
- one entrypoint; encapsulate logic in small, focused libraries
- delete superseded artifacts deliberately (git history preserves them)

## Current state (2026-06)

The repository was consolidated to a single, modular bootstrap:

- **One entrypoint:** `./start.sh` (thin: args, prompts, tool checks, run flow).
- **Focused libraries:** `misc/bootstrap-engine.sh` (orchestration),
  `misc/lib/folio-common.sh` (logging/config/output), `misc/lib/folio-api.sh`
  (tokens/registration/entitlement/smoke), `misc/lib/docker-health.sh` (readiness waits).
- **Bundled descriptor startup:** only modules in the app-platform-minimal
  descriptor are started, registered, and entitled.
- **Inline env in Compose:** no `env/*.env` split; values live in the Compose files.
- **Single-node Keycloak by default**, scalable by uncommenting a couple of lines
  (see `docs/architecture/runtime-containers.md`); health waiting is dynamic.
- **Verification reduced to a smoke check** at the end of the bootstrap flow, plus a
  small offline test runner (`misc/tests/run.sh`).

A prior "bootstrap cockpit" attempt was abandoned in favor of keeping operator UX
thin over a transparent runtime definition; that lesson informs the guardrails in
`AGENTS.md`. Git history preserves the abandoned attempt.

## Next directions (not yet committed)

- Operator-UX polish: compact progress, folded low-value logs, trustworthy final
  status — defined against explicit UX acceptance criteria before implementation.
- Whether some metadata should remain handwritten or become partially generated.

Decide these only after dedicated, criteria-first design — not by accreting layers.
