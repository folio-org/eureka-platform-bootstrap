# Supported Workflows

The boundary between the two supported operator commands and their internal
implementation. Prefer the operator surface; treat all workers as building blocks.

## Support levels

| Level | Meaning |
| --- | --- |
| supported workflow | primary operator path that should remain documented and stable |
| internal helper / library | implementation detail used by supported workflows |
| unsupported diagnostic | retained for debugging, not part of the support contract |

## Supported workflows

### Full bootstrap (primary)

```bash
./start.sh
```

Options: `--actualize [--pre-release]`, `--native-sidecar` (builds the native
sidecar image in-pipeline if it is missing), `--rebuild-native-sidecar` (force a
fresh native build), `--yes`
(non-interactive), `--debug` (stream helper output).

`./start.sh` is the single entrypoint. It prepares config, starts core →
mgr-components → bundled `app-platform-minimal` services, registers the bundled
descriptor and discovery metadata, creates tenant `diku` and the default
`folio/folio` user, and ends with a smoke check.

### Stop and reset

```bash
./stop.sh         # prompts: remove containers (default yes), clear volumes (default no)
./stop.sh --yes   # non-interactive: remove containers, keep volumes
```

## Native Docker access

`docker/compose.yaml` is a standard Compose manifest. Operators may use native
`docker compose` commands after supplying their own required environment values;
this is intentionally not a second supported bootstrap workflow.

## Validation

```bash
bash misc/tests/run.sh                 # offline: shell syntax + python unit tests
# ./start.sh exports descriptor-derived module image variables, starts the
# complete runtime, and finishes with its smoke check.
./start.sh --yes
```

The end-to-end proof is a real `./start.sh` run; its built-in smoke check confirms
api-gateway reachability, a tenant token, tenant `diku`, and capabilities. There is
no separate verification subsystem.

## Internal helpers and libraries

| Path | Role |
| --- | --- |
| `misc/bootstrap-engine.sh` | bootstrap phase orchestration (sourced by `start.sh`) |
| `misc/lib/folio-common.sh` | logging, config loading, output helpers, dependency checks |
| `misc/lib/folio-api.sh` | tokens, descriptor/discovery registration, entitlement, smoke check |
| `misc/lib/docker-health.sh` | container health and HTTP route readiness waits |
| `docker/compose.yaml` | standard Compose manifest that includes the runtime layers |
| `docker/lib/local-credentials.sh` | local credential and Vault-token persistence |
| `misc/vault/scripts/*` | Vault image-internal boot scripts |

## What should remain stable

- the single `./start.sh` entrypoint and its flags
- the layered runtime model: `core`, `mgr-components`, `app-platform-minimal`
- the local configuration file structure in `docker/`
- descriptor-backed registration for the bundled `app-platform-minimal` application

Internal helper/library implementation may change freely as long as the above holds.
