# eureka-platform-bootstrap

Local FOLIO Eureka environment (`app-platform-minimal`): Compose files, Bash and Python scripts, and an application descriptor, operated only through `./start.sh` and `./stop.sh`. Validation runs per file and through an offline test runner.

## Commands

```bash
./start.sh                               # start or repair the environment; every step is idempotent, so rerun to recover
./start.sh --yes                         # non-interactive: defaults for every prompt
./start.sh --actualize [--pre-release]   # refresh module versions in descriptor.json first (SNAPSHOT with --pre-release)
./start.sh --apisix                      # APISIX instead of Kong (same as APIGW_TYPE=apisix)
./start.sh --native-sidecar              # native sidecar image, built if missing; --rebuild-native-sidecar forces a build
./start.sh --debug                       # stream helper output instead of folding it
./stop.sh --yes                          # remove containers, keep volumes

bash misc/tests/run.sh                   # offline, no Docker: bash -n on tracked *.sh, Bash 3.2 guard, Python compile and unit tests, shell tests
bash misc/tests/test-config-precedence.sh   # one shell test
bash -n path/to/file.sh; python3 -m py_compile path/to/file.py; jq . path/to/file.json >/dev/null
```

Deploy a locally built module image (example `mod-scheduler:myfix`) without editing Compose files:

```bash
cd docker
source .env.local.credentials                                        # real Vault token; docker/.env has a placeholder
eval "$(python3 ../misc/docker-module-updater/run.py --module-env)"  # MOD_*_IMAGE values from descriptor.json
docker tag mod-scheduler:myfix "$MOD_SCHEDULER_IMAGE"
docker compose up -d mod-scheduler
```

The end-to-end proof is a `./start.sh` run whose final summary shows `Smoke check` as `passed`. Exit status 0 does not mean ready: a failed smoke check or admin user creation still returns 0 with status `Partially ready`. Hard failures exit non-zero.

A new `test-*.sh` must be listed in `shell_tests` and a new Python script in `python_targets` in `misc/tests/run.sh`; `test_*.py` files are found automatically.

## Conventions

- `./start.sh` and `./stop.sh` are the only entry points. Extend them or their libraries under `misc/` instead of adding top-level scripts, flags, or wrappers.
- Make the smallest change that solves the problem. Before adding an env var, script, function, or config key, `grep` for an existing one. Ask before adding a new script, entry point, env var, dependency, or abstraction, and give the reason in one sentence.
- Derive values instead of restating them. Example: `FOLIO_MODULE_SIDECAR_IMAGE` carries the sidecar version and `misc/build-native-sidecar.sh` derives the git ref from its tag, so a `SIDECAR_BRANCH` variable would be a second source of truth.
- Linux, macOS (stock Bash 3.2), and Windows (git-bash) must keep working: no Bash 4+ features without a fallback, no GNU-only flags (for example `date` extensions), no host-specific paths, and no tools beyond those the scripts already use (`check_tools` in `start.sh` lists the hard requirements). `bash -n` under a newer Bash does not catch Bash 4 syntax, and the `run.sh` guard only catches `${var^}`/`${var,}` expansions.
- Python is stdlib-only, with 2-space indent (`.editorconfig`).
- Compose files keep 2-space indent, because `run.py` finds services with a line regex (`^\s{2}name:`), not a YAML parser. Service env stays inline in the Compose files.
- Each module in `descriptor.json` needs a `mod-*` service in `docker/docker-compose.minimal.module.yml` and a matching `sc-*` service in `docker/docker-compose.minimal.sidecar.yml`; `run.py` stops the start otherwise. Keep the descriptor's module order.
- Scripts in `misc/vault/scripts/` run inside the Vault container, not on the host: keep them POSIX `sh`.
- Console output goes through `misc/lib/ui.sh`; read `docs/architecture/console-ui.md` before adding or restyling output. For operator-facing UX changes, set visible success criteria first (less noise, clearer steps, fewer prompts) and judge a real `./start.sh` run; cleaner architecture alone is not a UX improvement.
- Fail fast on missing commands or config. Retry only known transient startup or network cases.
- Never commit secrets. When changing config flow, make the source, override point, and consumer of each value clear.
- Put the rationale of a change in the commit message, not in per-change design docs. `docs/` holds durable architecture and roadmap only; read `docs/architecture/README.md` and `docs/roadmap/README.md` before structural changes, and keep generated verification output out of `docs/`. Confirm each gap in `docs/roadmap/repository-cleanup-gap-backlog.md` against the code first, because some entries are stale.
- This file is the only instruction file for every tool (`CLAUDE.md` is a symlink to it). Keep it under 120 lines and free of one-off notes. `skills/` holds skills for use from other repositories.

## Gotchas

- Config precedence is shell env > `docker/.env.local.credentials` > `docker/.env.local` > `docker/.env`. `load_folio_config` loads files highest first and keeps values already set, so the last file does not win.
- Every start rewrites `docker/.env.local.credentials` with a fixed set of passwords and the Vault token, so any other variable put there is lost. Put overrides in `docker/.env.local`.
- Every start regenerates the tracked `descriptors/app-platform-minimal/discovery.json` from `descriptor.json`, and `--actualize` rewrites `descriptor.json`. Do not edit `discovery.json` by hand; after a run, check `git diff` and commit or revert these files.
- A `MOD_*_IMAGE` line in `docker/.env.local` outside the generated block is a manual override and survives `--actualize`. If its tag differs from the descriptor version, `start.sh` stops with a skew error, and reruns keep failing until the line is removed or aligned. Digest refs (`@sha256:`) are exempt.
- Local images are reused however old they are: on arm64 the build checks only the architecture, and on amd64 Compose never pulls a tag that is present. A retagged local build keeps replacing the released tag until it is removed or pulled again. Only interactive runs offer a refresh prompt.
- On arm64 hosts `start.sh` always builds native arm64 images, because the `folioci/*` images are amd64-only and hang or start minutes slower under emulation.
- Prompts appear only on a terminal (`-t 0`). Without one, every prompt takes its default: `/etc/hosts` aliases are not added (the commands are only printed), a skew error halts at once, and `./stop.sh` never clears volumes. A full reset needs the user to answer yes to "Clear volumes" in an interactive `./stop.sh`.
- `start.sh` needs the `/etc/hosts` aliases `127.0.0.1 keycloak`, `kafka`, and `kong`, and adds them with `sudo` only when interactive.
- `./stop.sh --yes` keeps the `db`, `kafka-data`, and `vault-data` volumes, so tenant `diku`, the registered application, and the Vault root token survive. The Vault container prints the stored token again on start, which is where `start.sh` reads it.
- A manual `docker compose` call needs what `start.sh` exports. `docker/compose.yaml` includes no gateway file, so set `COMPOSE_FILE=compose.yaml:docker-compose.kong.yml` (or `docker-compose.apisix.yml`) for any call that touches `api-gateway`, the `mgr-*` services, or a sidecar (sidecars depend on `mgr-*`). For APISIX also export `OKAPI_URL=http://api-gateway:9080`, because `docker/.env` hard-codes the Kong port 8000. Every service has a profile, so a bare `docker compose down` does nothing; stop with `./stop.sh`.
- `APIGW_TYPE` is not saved between runs. After an APISIX run, stop with `APIGW_TYPE=apisix ./stop.sh`: plain `./stop.sh` loads the Kong file, and clearing volumes then keeps the `etcd-data` volume.
- The host port preflight checks only 8000 and 8080, and only warns. Other published ports (for example 5432, 8200, 9092, 29092, 9080, 8001 or 9180) fail at `docker compose up`.
- Editing anything under `misc/vault/` makes the next start rebuild `folio-vault:1.13.3` and rewrite the tracked `misc/vault/.build-context.sha256`; commit that file with the change.
