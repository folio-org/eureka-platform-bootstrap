# eureka-platform-bootstrap

Compose-centered local FOLIO Eureka `app-platform-minimal` environment definition
and bootstrap repository.

## Requirements

- Docker with Compose v2.24+ (allocate 12GB+ memory; the bootstrap warns below that)
- Python 3.10+
- Java 17+
- Maven
- `jq`
- `curl`

## Quick start

```bash
./start.sh
```

`./start.sh` is the single entrypoint. It:

- checks required tools
- asks at most a couple of questions (actualize module versions; on Apple Silicon,
  build ARM images)
- creates or updates local env files (`docker/.env.local`, `docker/.env.local.credentials`)
- starts `core`, then `mgr-components`, then the bundled `app-platform-minimal`
  services by name
- registers the bundled application descriptor and discovery metadata
- creates tenant `diku` and the default admin user `folio/folio`
- finishes with a short smoke check (api-gateway reachable, tenant token, `diku`
  exists, capabilities reachable)

### Options

```bash
./start.sh --actualize [--pre-release]       # refresh module versions first (SNAPSHOT with --pre-release)
./start.sh --native-sidecar                  # native folio-module-sidecar image (built if missing)
./start.sh --rebuild-native-sidecar          # force a fresh native sidecar build
./start.sh --apisix                          # use APISIX as the API gateway instead of Kong
./start.sh --yes                             # non-interactive (assume defaults / yes)
./start.sh --debug                           # stream all helper output
```

## How it is organized

`start.sh` stays thin; the logic lives in focused libraries:

| File | Responsibility |
| --- | --- |
| `start.sh` | argument parsing, prompts, tool checks, run the flow |
| `misc/bootstrap-engine.sh` | phase orchestration (`run_bootstrap_flow`) and local setup |
| `misc/lib/folio-common.sh` | logging, config loading, output helpers, dependency checks |
| `misc/lib/folio-api.sh` | tokens, descriptor/discovery registration, entitlement, smoke check |
| `misc/lib/docker-health.sh` | container health and HTTP route readiness waits |

The bundled application metadata lives in
`descriptors/app-platform-minimal/{descriptor,discovery}.json`. Extending the
local runtime with more modules is a code change to the descriptor and matching
Compose module/sidecar services, not a `./start.sh` runtime option.

## Native Docker access

`./start.sh` and `./stop.sh` are the supported runtime lifecycle. Operators who
need low-level Docker access can work directly from `docker/` with native
`docker compose` commands and their own environment configuration.

## Stop and reset

```bash
./stop.sh         # prompts: remove containers (default yes), clear volumes (default no)
./stop.sh --yes   # non-interactive: remove containers, keep volumes
```

## Keycloak topology

Keycloak runs as a **single node** by default. To scale the cluster, uncomment the
`keycloak-sN` services in `docker/docker-compose.keycloak.yml` and the matching
`server keycloak-sN` upstreams in `docker/nginx/keycloak-nginx.conf`, then rerun.
No script changes are needed — health waiting is dynamic and adapts to however many
nodes are running.

## API gateway

Kong is the default API gateway. Apache APISIX is a fully supported alternative:

```bash
./start.sh --apisix     # select APISIX for this run
```

Both gateways expose the proxy on **host port 8000** — existing Postman collections
and curl commands work unchanged.

The gateway image defaults can be overridden in `docker/.env` or via shell env:

| Variable | Default |
| --- | --- |
| `FOLIO_KONG_IMAGE` | `folioci/folio-kong:latest` |
| `FOLIO_APISIX_IMAGE` | `folioci/folio-apisix:latest` |

## Configuration model

- `docker/.env` — committed defaults
- `docker/.env.local` — local non-secret overrides (image tags, generated versions)
- `docker/.env.local.credentials` — local secrets and Vault token state

Service-level environment variables are defined inline in the Compose files.

## Validation

```bash
bash misc/tests/run.sh                 # offline: shell syntax + python unit tests
# `./start.sh --yes` validates the full runtime model and runs its smoke check.
# A raw `docker compose` invocation needs descriptor-derived MOD_*_IMAGE values
# supplied by the operator.
./start.sh --yes
```

## Agent skill

The source of the `local-eureka-env` agent Skill lives in
[`skills/local-eureka-env/`](skills/local-eureka-env/SKILL.md). It teaches coding
agents to operate this environment from any FOLIO repository: run Karate or
integration tests against it, deploy locally built module images, attach
debuggers, and reproduce or verify issues.

Install it from the repository root:

```bash
npx skills add .                                  # interactive: select local-eureka-env
npx skills add . --skill local-eureka-env --global --agent claude-code --agent opencode
```

## Documentation

- Architecture overview: `docs/architecture/README.md`
- Supported workflows: `docs/architecture/supported-workflows.md`
- Roadmap: `docs/roadmap/README.md`
