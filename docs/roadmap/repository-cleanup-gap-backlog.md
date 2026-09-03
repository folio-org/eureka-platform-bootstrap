# Repository Cleanup Gap Backlog

This roadmap captures the important cleanup gaps found during the 2026-06-24
repository audit. It is intentionally filtered: minor style-only cleanup, generic
doc polish, and "nice to have" refactors were removed.

Use this file as an agent-ready backlog. Each item should still start with local
research and a small plan before code changes.

## Review Filter

Kept:

- Gaps that can hide bootstrap failures or make recovery unreliable.
- Gaps that make supported helpers inconsistent with the documented config model.
- Gaps that keep risky generated diagnostics or external defaults in the repo.
- Gaps where a local custom implementation may be replaceable by upstream/stock
  behavior after research.

Dropped from the first draft:

- Python indentation/style as a standalone task.
- `stop-containers.sh` polish as a standalone task (since folded into the root `stop.sh` teardown entrypoint).
- Generic secondary documentation cleanup not tied to a real behavior decision.
- Non-gap confirmations and historical notes.

## Audit Inputs

Reviewed:

- `AGENTS.md` (and its `CLAUDE.md` symlink).
- `README.md`, `docker/README.md`, `docs/architecture/*.md`,
  `docs/roadmap/README.md`, `misc/*README*.md`.
- Recent commits through `6993534 stabilize bootstrap: ARM-native images, module
  health graph, native Kong entrypoint, set -e fix`.
- `start.sh`, `misc/bootstrap-engine.sh`, `misc/lib/*.sh`,
  `misc/docker-module-updater/run.py`, `misc/module-version-actualizer.py`,
  `docker/docker-compose*.yml`, `docker/.env`, supported and diagnostic scripts.

Verification run during the audit:

```bash
python3 misc/docker-module-updater/run.py --app descriptors/app-platform-minimal/descriptor.json --services
jq -r '.modules[].name' descriptors/app-platform-minimal/descriptor.json
jq -r '.discovery[].name' descriptors/app-platform-minimal/discovery.json
git diff --check
git ls-files '*.sh' | xargs -n 1 bash -n
bash misc/tests/run.sh
python3 -m py_compile misc/module-version-actualizer.py misc/docker-module-updater/run.py
```

Observed state:

- Existing unrelated local change before this file: `descriptors/app-platform-minimal/descriptor.json`
  timestamp-only app id/version bump.
- Descriptor and discovery module lists matched during audit.
- Compose expansion and the small offline test runner passed.
- The gaps below are therefore targeted cleanup risks, not a claim that the repo
  is currently unusable.

## Priority Model

- `P0`: can silently continue after a failed critical step or break a normal
  supported bootstrap/rerun.
- `P1`: makes supported flows fragile, misleading, unsafe by default, or hard to
  evolve.

## Backlog

### GAP-001: Bootstrap can continue after broken local support-image or token setup

Priority: `P0`

Problem:

Several bootstrap primitives are too forgiving or invoked incorrectly. On Apple
Silicon, the ARM image builder can record failed module builds but still return
success. Vault token population is bash-only but called through `sh`. Vault token
retrieval scrapes container logs and does not clearly fail on empty output.

Why it matters:

These are early bootstrap foundations. If they silently fail, later errors look
like random service/module failures instead of the real local setup problem.

Evidence:

- `misc/images-builder/build.sh:107-132` records clone/Maven/Docker failures but
  exits `0` inside failing subshells.
- `misc/images-builder/build.sh:171-179` prints failed modules but does not exit
  non-zero.
- `start.sh:99-109` forces ARM image builds on `arm64`/`aarch64`.
- Vault-token persistence was a separate script chain, while retrieval scraped
  `docker logs vault | grep | sed | tail`.

Direction:

- Make `misc/images-builder/build.sh` fail non-zero when any required image fails
  to build.
- Use temp workspaces and trap cleanup for cloned repos/temp files.
- Keep Vault-token read/persist logic internal to bootstrap and fail clearly on an
  empty value before manager services start.
- Keep log scraping only if no stable Vault state/API source exists; document the
  decision if retained.

Acceptance criteria:

- Simulated image build failure exits non-zero and lists failed modules.
- Bootstrap no longer shells out through a Vault-token CLI wrapper.
- Empty/missing Vault token is never written to `docker/.env.local.credentials`.
- Offline tests cover these failure paths with stubs; no Docker runtime required.

Verification:

```bash
bash -n misc/images-builder/build.sh misc/bootstrap-engine.sh docker/lib/local-credentials.sh
bash misc/tests/run.sh
```

### GAP-002: Config precedence and generated env state are correct but too opaque

Priority: `P1`

Problem:

The documented model is shell env > credentials > local > Compose defaults. The
implementation achieves this through `source` plus "restore previous variables"
logic, which is easy to misread. Generated `.env.local` module metadata can also
accumulate old generated sections instead of one clear managed block.

Why it matters:

Config provenance is a core design goal of this repo. If agents or maintainers
cannot quickly tell where a value wins, cleanup work will keep adding local
workarounds.

Evidence:

- `misc/lib/folio-common.sh:96-119` loads `.env.local.credentials` then
  `.env.local`.
- `misc/lib/folio-common.sh:124-159` preserves earlier values by sourcing a temp
  file after sourcing the current file.
- `misc/docker-module-updater/run.py:169-212` updates generated variables in
  place and appends missing ones, which can preserve stale generated sections.

Direction:

- Replace the source/restore loader with an explicit, small env parser or make
  the current mechanism clearer with strong tests and corrected docs.
- Standardize generated local env syntax.
- Regenerate module runtime metadata atomically inside one managed block, for
  example `# BEGIN generated module runtime metadata` / `# END ...`.
- Preserve hand-authored local settings outside the managed block.

Acceptance criteria:

- Tests prove shell env beats credentials, credentials beat local, and local beats
  Compose defaults.
- `misc/docker-module-updater/run.py --app ...` is idempotent and produces one
  generated module metadata block.
- Docs and implementation describe the same precedence order.

Verification:

```bash
bash misc/tests/run.sh
```

### GAP-003: Supported API helpers duplicate curl/token/error handling

Priority: `P1`

Problem:

Supported and diagnostic scripts repeatedly implement the same `curl -w
HTTP_CODE` parsing, token retrieval, and error extraction logic. `create-user.sh`
is particularly important because it is both documented and called by bootstrap,
but it bypasses the shared config loader and defines its own logging/helpers.

Why it matters:

Bootstrap reliability depends on these API flows. Duplicated parsing makes errors
inconsistent and increases the chance that one helper is fixed while another
keeps the old behavior.

Evidence:

- `misc/create-user.sh:24-35` directly sources only `.env.local.credentials` and
  sets its own URL defaults.
- `misc/create-user.sh:60-119` defines local error/log/response helpers.
- `misc/create-user.sh:137-167` manually splits Vault/token responses.
- Similar manual response parsing exists in `misc/test-tenant-installation.sh`,
  `misc/fix-all-tenants.sh`, `misc/get-tenant-client-secrets.sh`, and
  `misc/search-capability-by-name.sh`.
- `docs/architecture/supported-workflows.md` lists `bash misc/create-user.sh
  <user> <pass>` as a supported helper.

Direction:

- Extract or extend one small shell API helper layer for HTTP response splitting,
  compact error messages, Vault tenant secret lookup, and token retrieval.
- Migrate supported helpers first: `misc/create-user.sh` and any bootstrap-called
  helper.
- Only migrate diagnostic scripts that survive GAP-004; do not refactor code that
  should be deleted.

Acceptance criteria:

- `create-user.sh` uses `load_folio_config` and the same precedence as
  `start.sh`.
- Supported helpers do not hand-roll HTTP body/status splitting.
- Error messages include method/path/status and a compact body summary.
- Standalone invocation still works from any working directory.

Verification:

```bash
bash -n misc/lib/folio-common.sh misc/lib/folio-api.sh misc/create-user.sh
bash misc/tests/run.sh
```

Runtime proof after a successful bootstrap:

```bash
bash misc/create-user.sh folio folio
```

### GAP-004: Unsupported diagnostics are too prominent and have risky defaults

Priority: `P1`

Problem:

Large diagnostic scripts are classified as unsupported in architecture docs, but
they live next to supported helpers and present themselves as full tools. Several
contain generated-agent markers, external CI endpoints, and `SecretPassword`
defaults.

Why it matters:

This repository is a local environment bootstrap tool. Executable diagnostics
with external defaults blur the support boundary and can cause accidental calls
against non-local systems.

Evidence:

- Unsupported diagnostics include `misc/test-tenant-installation.sh`,
  `misc/keycloak-token-stress-test.sh`, `misc/find-failed-iteration.sh`,
  `misc/fix-all-tenants.sh`, `misc/get-tenant-client-secrets.sh`,
  `misc/search-capability-by-name.sh`, and `misc/check-system-caps.sh`.
- `misc/fix-all-tenants.sh:12` says `Author: Generated by Claude Code`.
- `misc/fix-all-tenants.sh:24-28` defaults to external FOLIO CI URLs and
  `SecretPassword`.
- `misc/get-tenant-client-secrets.sh:8` says `Author: Generated by Claude Code`.
- `misc/get-tenant-client-secrets.sh:71-78` documents external URL and secret
  defaults; `misc/get-tenant-client-secrets.sh:148-152` implements them.
- `misc/search-capability-by-name.sh:8` says `Author: Generated by Claude Code`;
  `misc/search-capability-by-name.sh:40-47` documents external defaults.
- `misc/TEST_TENANT_README.md:41-60` says all configuration is optional with
  defaults, including `SecretPassword` and external CI endpoints.

Direction:

- Decide which diagnostics are still worth keeping.
- Preferred cleanup: delete or move obsolete diagnostics out of `misc/`; git
  history is enough for historical recovery.
- If a diagnostic remains executable, put it under a clearly named diagnostics
  area, remove external/secret defaults, use the shared config loader, and print
  an unsupported-diagnostic banner.

Acceptance criteria:

- A new contributor can distinguish supported helpers from diagnostics by path
  and docs.
- No executable diagnostic defaults to an external environment or placeholder
  secret.
- Generated-agent boilerplate is gone from maintained scripts.

Verification:

```bash
rg -n "Generated by|SecretPassword|folio-edev|\\.ci\\.folio\\.org" misc docs
bash misc/tests/run.sh
```

Expected remaining matches should be intentional historical records only.

### GAP-005: Compose profile and merge model has stale seams

Priority: `P1`

Problem:

The documented runtime model is `core`, `mgr-components` and
`app-platform-minimal`, but Compose files contain additional profiles
(`app-notification`, `app-core-storage`, `legacy`, `keycloak-cluster`, `full`).
The former Compose wrapper merged files through filesystem discovery.

Why it matters:

Compose is the visible runtime definition. Hidden/dead profiles and implicit file
merge order undermine that transparency and make service topology changes risky.

Evidence:

- `docs/architecture/README.md` lists only the current four-layer model.
- `docker/docker-compose.core.yml:3-8` includes `app-notification` and
  `app-core-storage`.
- `docker/docker-compose.core.yml:19-26` adds `legacy` and `keycloak-cluster` to
  `db`.
- `docker/docker-compose.keycloak.yml:59-65` and `88-97` include extra profiles.
- `docker/docker-compose.minimal.module.yml:48-70` includes `legacy` on only some
  modules.
- The former wrapper built `COMPOSE_FILE` from unsorted `find`.
- `docker/README.md:41-47` still describes `keycloak-cluster` as a separate
  startup step, while default Keycloak is included in `core`.

Direction:

- Inventory every profile and classify it as supported, internal/future, or dead.
- Delete dead profiles; document any future seams outside the supported quick
  path.
- Replace implicit Compose file discovery with an explicit ordered list, or sort
  and document the convention.
- Clarify that full bootstrap starts app-platform-minimal services by explicit
  service name, while manual `-p app-platform-minimal` starts the static profile.

Acceptance criteria:

- `docker/README.md`, architecture docs, and Compose profiles agree.
- No profile exists as unexplained residue.
- `docker/compose.yaml` has explicit Compose file order.
- Compose expansion still succeeds.

Verification:

```bash
bash -n misc/bootstrap-engine.sh stop.sh
./start.sh --yes
rg -n "app-notification|app-core-storage|legacy|keycloak-cluster|full" docker docs README.md
```

### GAP-006: UI build flow may be duplicating upstream stock behavior

Status: **SUPERSEDED — resolved by removal.** FOLIO UI support (the
`platform-complete` build, `configure-ui-redirect.sh`, the `folio-ui` Compose
service and the `./start.sh --ui` flag) has been removed; this environment is
backend-only. The file paths quoted below no longer exist and are kept only as a
record of why the subsystem was dropped rather than reworked.

Priority: `P1` (closed)

Problem:

The UI build subsystem clones `platform-complete`, mutates `stripes.config.js`
and `package.json`, and comments that some behavior matches or was
reverse-engineered from Eureka CLI internals. This may still be necessary, but it
is a custom local implementation around an upstream UI build path.

Why it matters:

The roadmap explicitly warns against growing wrappers when an existing script or
stock mechanism can provide the same operator outcome. UI build is also expensive
and network-heavy, so drift is costly to diagnose.

Evidence:

- `misc/folio-ui/prepare-stripes-config.sh:55-65` uses `sed` placeholder
  substitution.
- `misc/folio-ui/prepare-stripes-config.sh:70-75` patches
  `@folio/consortia-settings` with a comment referencing eureka-cli behavior.
- `misc/folio-ui/prepare-package-json.sh:33-51` injects modules and a build
  script with comments referencing `ui_svc_package.go`.
- `misc/folio-ui/utils.sh:59-67` runs `git fetch`, `git checkout`, and
  `git reset --hard "origin/$branch"` in the UI repo.
- `misc/folio-ui/README.md` says the implementation is based on
  reverse-engineered Eureka CLI behavior.

Direction:

- Research current upstream FOLIO/Eureka UI build tooling before changing code.
- If a maintained upstream command exists, call it with documented inputs instead
  of duplicating its implementation.
- If local patching remains necessary, treat `REPO_DIR` as a disposable cache and
  make that explicit; do not silently discard user changes in a non-cache repo.
- Keep `./start.sh --ui` thin.

Acceptance criteria:

- The repo either uses a documented upstream UI build path or records why local
  patching is still required.
- UI build mutations are reproducible and isolated to an agent-owned/cache
  directory.
- `./start.sh --ui` behavior remains operator-simple.

Verification:

```bash
bash -n misc/build-folio-ui.sh misc/folio-ui/*.sh
SKIP_BUILD=true UPDATE_REPO=false bash misc/build-folio-ui.sh
```

Run full UI build only after accepting network/build time.

### GAP-007: Offline regression net is too narrow for future cleanup

Priority: `P1`

Problem:

The offline runner is intentionally small, but it does not syntax-check all
supported shell helpers and lacks hermetic tests for the fragile behaviors above.
Recent commits removed a heavy verification subsystem, which was good cleanup,
but the replacement regression net should still protect the supported surface.

Why it matters:

The next cleanup iterations will touch shell orchestration, config loading, and
API helpers. Without cheap tests, agents will either over-run full bootstrap or
make unverified edits.

Evidence:

- `misc/tests/run.sh:23-32` syntax-checks only a subset of shell files.
- Supported helpers include Docker helpers, image builders, Vault helpers, and
  `create-user.sh`.
- During audit, `git ls-files '*.sh' | xargs -n 1 bash -n` passed, but this is
  not part of `misc/tests/run.sh`.

Direction:

- Expand syntax checks to all tracked `.sh` files, or at least all supported
  helpers and libraries.
- Add small shell tests for:
  - ARM builder failure propagation.
  - Empty Vault token refusal.
  - Config precedence.
  - Generated env metadata idempotency.
- Keep tests offline and fast; do not rebuild the removed verification subsystem.

Acceptance criteria:

- `bash misc/tests/run.sh` catches syntax regressions in every supported script.
- New tests are hermetic and do not require Docker runtime or network.
- `misc/tests/README.md` accurately describes the expanded scope.

Verification:

```bash
bash misc/tests/run.sh
```

### GAP-008: Bootstrap scaffolds and rewrites `docker/.env.local`, hiding config provenance

Priority: `P1`

Problem:

`ensure_local_env_file` wrote seven runtime defaults into `docker/.env.local`
(`KC_*`, `MGR_*_IMAGE`, `FOLIO_MODULE_SIDECAR_IMAGE`) and force-managed the sidecar
line on every run — re-appending it if an operator deleted it. All seven already
have committed defaults in `docker/.env`, so the `.env.local` copies were dead
duplicates that always shadowed `.env`; the sidecar default was even contradictory
(`docker/.env`: `folioorg/...:4.0.0` vs `.env.local`: `folioci/...:latest`).

Why it matters:

This was the concrete instance of the GAP-002 provenance problem: editing the
obvious file (`docker/.env`) did nothing, and deleting a var from `.env.local`
made it reappear. The operator could not tell where a value came from or how to
change it durably.

Resolution (done):

- Removed `ensure_local_env_file`; the bootstrap no longer writes `.env.local`.
- `docker/.env` is the single source for these defaults (sidecar default fixed to
  `folioci/folio-module-sidecar:latest`).
- `--native-sidecar` selects the `:native` tag via the shell environment
  (`select_sidecar_image`), respecting any operator override and never touching
  `.env.local`.
- `.env.local` now holds only the `run.py`-managed `MOD_*` block plus genuine hand
  overrides. Test: `misc/tests/test-sidecar-image-selection.sh`.

## Suggested Execution Order

1. Fix GAP-001 first. It contains the most direct bootstrap correctness risks.
2. Expand the offline regression net from GAP-007 enough to protect the next
   changes.
3. Normalize config loading/generated env state via GAP-002.
4. Decide what to delete/quarantine from diagnostics via GAP-004 before refactoring
   shared API logic.
5. Refactor supported API helper behavior via GAP-003.
6. Clean Compose/profile merge semantics via GAP-005.
   (GAP-006 is closed: UI support was removed instead of reworked.)
