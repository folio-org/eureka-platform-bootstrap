# Architecture

How `eureka-platform-bootstrap` works inside. For operating it, read the root
`README.md` first; this document adds the model behind it.

## What this repository is

A Compose-centered definition of a local FOLIO Eureka `app-platform-minimal`
environment plus a thin bootstrap that assembles it: `./start.sh` prepares
config and images, starts the stack in dependency order, registers the bundled
application, and creates tenant `diku` with an admin user; `./stop.sh` tears it
down. `docker/` is the visible runtime definition — the scripts orchestrate it,
they do not replace it.

## Runtime layers

Every service is gated behind a Compose profile, and the bootstrap starts them
in dependency order:

1. `core` — PostgreSQL, Kafka (KRaft, no Zookeeper), Vault, Kafka UI, and the
   Keycloak access layer (nginx front door + `keycloak-s0`; scale by
   uncommenting `keycloak-sN` services — health waiting is dynamic).
2. `mgr-components` — `mgr-applications`, `mgr-tenants`,
   `mgr-tenant-entitlements`.
3. `app-platform-minimal` — the `mod-*` modules and `sc-*` sidecars declared by
   the bundled descriptor; started by explicit service name, not by profile.

`docker/compose.yaml` includes the layer files in a fixed order. The gateway
file (`docker-compose.kong.yml` or `docker-compose.apisix.yml`) is NOT in the
include list: `start.sh`/`stop.sh` append it via `COMPOSE_FILE` based on
`APIGW_TYPE` (default `kong`), because exactly one gateway service may be
active. Both gateways publish the proxy on host port 8000.

## Configuration model

Precedence, highest wins: shell environment > `docker/.env.local.credentials` >
`docker/.env.local` > `docker/.env`. The loader in
`misc/lib/folio-common.sh` sources the files high-precedence-first and restores
any value that was already set, so earlier layers beat later defaults. Service
environment variables live inline in the Compose files, not in `env_file`s.

`APIGW_TYPE` and `SIDECAR_MODE` are runtime choices resolved from flags or the
shell before any config file is loaded, so they cannot leak in from
`.env.local`.

## Descriptor-driven modules

`descriptors/app-platform-minimal/descriptor.json` is the single source for the
module set. `misc/docker-module-updater/run.py` derives from it:

- `discovery.json` (module discovery metadata, regenerated),
- the Compose service list (`--services`),
- `MOD_<MODULE>_IMAGE` / `MOD_<MODULE>_VERSION` exports (`--module-env`) that
  `start.sh` places in the environment for Compose interpolation,
- cleanup of superseded generated module state in `docker/.env.local`.

`--actualize` first refreshes descriptor versions from the FOLIO registry
(`misc/module-version-actualizer.py`), then re-syncs. Adding a module is a
descriptor change plus matching Compose services — never a runtime option.

## Guards and warm-run semantics

Every step is idempotent; recovery from any failure is a plain `./start.sh`
re-run. On top of that, two halts protect warm runs from silent corruption:

- **Descriptor/image skew**: if an effective `MOD_*_IMAGE` tag disagrees with
  the descriptor version (e.g. a stale `.env.local` override), the run halts
  before containers start and names the module and both recovery paths.
  Digest-pinned refs are exempt.
- **Gateway route loss**: a registered application whose module routes are
  missing from the active gateway's store (classic gateway switch with kept
  volumes) fails fast with recovery paths instead of opaque 404s later.

A warm `--actualize` bumps module versions and the application id; discovery
then falls back to per-module registration (the bulk endpoint rejects mixed
batches), and entitlement goes through the upgrade operation (PUT) rather than
a fresh POST, which managers reject for an already-enabled application name.

## Images and architectures

On ARM hosts (Apple Silicon) the published `folioci/*` images are amd64-only,
so `start.sh` routes every FOLIO-buildable image (including the active
gateway's) through `misc/images-builder/build.sh`, which rebuilds them natively
for arm64; already-native images are skipped, so warm re-runs build nothing.
The native sidecar mode (`--native-sidecar`) reuses the sidecar's configured
tag and builds a GraalVM native image under it via
`misc/build-native-sidecar.sh`. Both sidecar runtimes share that one tag, so
architecture alone cannot prove reuse: the entrypoint (`./application` vs
`./run-java.sh`) is the discriminator, and a mode switch rebuilds the image
(ARM) or re-pulls it from the registry (x86_64) so the requested runtime is
what runs. The image plan table printed during "Prepare config" shows each
image's provenance and the decided action.

## Failure model

Any hard failure triggers a bounded diagnostic snapshot (`docker-health.sh`):
compose status, error lines from broken containers' logs (surfaced above
shutdown noise), an OOM hint only on OOM evidence, and the failing phase/step.
The health wait is scoped to this Compose project, fails fast when a monitored
container crashes or the daemon disappears, and gives the api-gateway exactly
one bounded recovery window before timing out.

## Invariants

- Compose stays the visible, human-inspectable runtime definition.
- `./start.sh` / `./stop.sh` remain the only operator entrypoints; everything
  under `misc/` is internal machinery they invoke.
- Descriptor, discovery, Compose services, and the version-sync scripts stay
  aligned.
- Presentation never writes to stdout (it is reserved for captured values),
  emits no ANSI escapes when piped or `NO_COLOR`, and never prints a number
  that was not measured.
