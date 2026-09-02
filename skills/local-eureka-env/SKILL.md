---
name: local-eureka-env
description: Use when working in any EBSCO FOLIO repository and the task involves the local FOLIO Eureka environment — running Karate or integration tests locally (karate.env=local, localhost:8000), deploying a locally built module image into the environment, attaching a debugger to a running module, or raising/reproducing an issue on the local environment before or after fixing it.
---

# Local Eureka Environment

A full local FOLIO Eureka platform (Kong, Keycloak, Vault, Kafka, PostgreSQL, managers, 12 `mod-*`
modules with `sc-*` sidecars) lives in `~/EBSCO-FOLIO/eureka-platform-bootstrap`. It is raised and
torn down only by that repo's `./start.sh` and `./stop.sh`. Everything else — tests, deploys,
debugging, reproduction — happens from the repository you are working in, against this environment.

If this skill is mentioned but no environment operation was requested, say so and stop.

## Step 1 — Discover the environment state

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8000/   # 200/404 = gateway up
docker ps --filter label=com.docker.compose.project=folio-platform-minimal --format '{{.Names}} {{.Status}}'
```

| Observation | Action |
|---|---|
| Gateway answers, containers healthy | proceed with the task |
| Nothing running | `cd ~/EBSCO-FOLIO/eureka-platform-bootstrap && ./start.sh --yes` (first run: interactive; ~10+ min) |
| Containers exist but a service is unhealthy | see Triage; recovery is a plain `./start.sh` re-run — every step is idempotent. A changed compose file is NOT applied by a re-run alone — see Restart and propagating changes |

## Environment facts

| Fact | Value | Verify in |
|---|---|---|
| API gateway / admin | `http://localhost:8000` / `:8001` | `docker/.env`, core compose |
| Keycloak | `http://localhost:8080` | `docker/docker-compose.keycloak.yml` |
| Vault / DB / Kafka / Kafka UI | `:8200` / `:5432` / `:9092` / `:9080` | `docker/docker-compose.core.yml` |
| Module direct ports (bypass sidecar) | 9001–9020 → module :8081 | `docker/docker-compose.minimal.module.yml` |
| Sidecar ports / JDWP debug | 19xxx → sidecar :8081; modules 100xx→5005, sidecars 11xxx→5005 | module + sidecar compose files |
| Tenant / admin user | `diku` / `folio`:`folio` | `misc/bootstrap-engine.sh` (final summary) |
| Admin client / m2m client | `folio-backend-admin-client` (secret `folio-backend-admin-client-secret`) / `m2m-client` | `docker/.env` |

Never rely on remembered values — re-read the file in the Verify-in column.

## Restart and propagating changes

Any `docker compose up` command needs the environment context first:

```bash
cd ~/EBSCO-FOLIO/eureka-platform-bootstrap/docker
source .env.local.credentials
eval "$(python3 ../misc/docker-module-updater/run.py --module-env)"
```

| Goal | Command |
|---|---|
| Restart a service in place (no config change) | `docker compose restart <svc>` |
| Make a compose-file change take effect (new env var, port, image) | `docker compose up -d --force-recreate <svc>` — a plain re-run leaves the old container; verified with a sidecar env var that did not propagate until forced |
| Recreate all sidecars after editing `docker-compose.minimal.sidecar.yml` | `docker compose up -d --force-recreate $(docker compose config --services \| grep '^sc-')` |
| Full re-raise (always recreates, volumes kept) | `cd .. && ./stop.sh --yes && ./start.sh --yes` |

After any recreate, verify: `docker ps --filter name=<svc>` shows healthy, and for env changes
`docker exec <svc> printenv <VAR>` returns the new value.

## Step 2 — Run Karate tests locally (folio-integration-tests)

```bash
cd ~/EBSCO-FOLIO/folio-integration-tests
mvn test -pl common,testrail-integration,mod-users-keycloak \
  -Dkarate.env=local \
  -DargLine="-Dadmin.name=folio -Dadmin.password=folio" \
  -Dtest=ModUsersKeycloakTests#authUsers \
  -DfailIfNoTests=false -Dsurefire.failIfNoSpecifiedTests=false
```

- The `surefire.failIfNoSpecifiedTests=false` flag is required with `-Dtest`: the pattern applies to
  every module in the reactor and would otherwise fail on `common`, which has no matching test.

- `karate.env=local` targets `localhost:8000/8080` with the bootstrap's client secret
  (`*/src/main/resources/karate-config.js`, `local` branch) — the environment must be up first.
- The `admin.*` overrides are REQUIRED: Karate's defaults (`diku_admin`/`admin`) do not exist in
  this environment; the bootstrap creates `folio`/`folio`. Overrides must travel via `-DargLine`,
  plain `-D` does not reach the forked JVM.
- Replace `mod-users-keycloak` with the module under test and `-Dtest=` with its runner.
- Tests provision their own random tenant (`@BeforeAll`); tenant `diku` is not touched.

## Step 3 — Deploy a locally built module image

You built an image in the module repo (e.g. `mod-scheduler:myfix`). The environment runs images by
descriptor-derived tags (`MOD_<NAME>_IMAGE`). Do not edit compose files. Retag and recreate:

```bash
cd ~/EBSCO-FOLIO/eureka-platform-bootstrap/docker
source .env.local.credentials                                  # real Vault token + DB creds
eval "$(python3 ../misc/docker-module-updater/run.py --module-env)"   # exports MOD_*_IMAGE/_VERSION
docker tag mod-scheduler:myfix "$MOD_SCHEDULER_IMAGE"
docker compose up -d mod-scheduler                             # recreates on the new image
```

Both exports are REQUIRED. A one-off `docker compose up` without them starts the module with the
placeholder Vault token from `docker/.env` and it crash-loops. This deploy covers changed behavior
on existing endpoints; a new interface version needs descriptor re-registration — say so and stop.

Verify: `docker ps --filter name=mod-scheduler` (healthy), then exercise the endpoint through the
gateway (`:8000`). Ports 9001–9020 hit a module directly, 19xxx through its sidecar, `:8000` the
full path — use the three to isolate a fault to module, sidecar, or routing.

## Step 4 — Attach a debugger

Modules already listen for JDWP (`suspend=n`, attach anytime): IntelliJ/VS Code → Remote JVM Debug →
`localhost`, port `100xx` for a module (e.g. `mod-scheduler` → `10020`; `mod-users-keycloak` →
`10009`); sidecars use `11xxx`. Port maps live in the module/sidecar compose files.

To debug YOUR code (not the released image the container runs), deploy your build first (Step 3) —
otherwise breakpoints resolve against mismatched sources.

## Step 5 — Reproduce an issue / verify a fix

1. Environment up (Step 1); if a specific older version is needed, pin it: set
   `MOD_<NAME>_IMAGE=folioorg/<module>@sha256:...` in `docker/.env.local` (digest refs are exempt
   from the version-skew halt; remove the line afterwards), then `./start.sh`.
2. Reproduce through the gateway (`http://localhost:8000`) with a tenant token.
3. Check a Liquibase migration landed: `docker exec -it db psql -U postgres -c '\l'`, then query
   the module's database (schema per module compose env).
4. Fix locally → deploy (Step 3) → confirm the repro is gone. No pushes involved.

## Version moves

- All modules to latest: `./start.sh --actualize` (add `--pre-release` for SNAPSHOT).
- A stale `MOD_*_IMAGE` tag override in `docker/.env.local` that differs from the descriptor makes
  `./start.sh` halt by design (skew guard); the halt message names the modules and recovery paths.

## Triage

| Symptom | Cause → action |
|---|---|
| Module crash-loops after a manual deploy | placeholder Vault token → re-do Step 3 with both exports, or plain `./start.sh` |
| `./start.sh` halts on descriptor/image skew | actualize or align the `.env.local` override (message lists modules) |
| 503/504 during registration | Kong DNS warm-up; bootstrap retries; re-run `./start.sh` |
| Non-Docker process on 8000/8080 | preflight warning names the ports; free them and re-run |
| Karate setup fails at entitlement ("No row with the given identifier", "System user token is required for the module") | environment-level version skew between running containers and the registered descriptor; check `docker logs mgr-tenant-entitlements`; re-raise with `./start.sh` — not a test or command problem |
| OOM / slow modules | Docker memory <12GB; raise it in Docker Desktop settings |

Never run a bare `docker compose down` in `docker/` — every service is profile-gated, it silently
no-ops. Teardown is `./stop.sh [--yes]`; volumes hold the data and survive container removal.

## Scope

Operate the environment and run things against it. Extending the module set, changing bootstrap
internals, or descriptor surgery beyond digest pinning are changes to `eureka-platform-bootstrap`
itself — out of scope; the failure snapshot of `./start.sh` plus its `AGENTS.md` govern there.
