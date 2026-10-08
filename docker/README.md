# Docker Compose Layers

This directory contains the FOLIO platform Docker Compose configuration organized as layered profiles.

## Runtime lifecycle

For full bootstrap, descriptor registration, tenant creation, and user setup,
use `./start.sh` from the repository root. Use `./stop.sh` for teardown.

This directory also exposes the standard Docker Compose manifest for low-level
operator work. Native commands are intentionally not a second supported
bootstrap workflow; operators supply any required local configuration
themselves (`./start.sh` exports descriptor-derived `MOD_*_IMAGE` values — a
raw `docker compose up` does not have them).

## Compose files

| File | Purpose | Profile |
|------|---------|---------|
| `docker-compose.core.yml` | PostgreSQL, Kafka (KRaft), Vault, Kafka UI | `core` |
| `docker-compose.keycloak.yml` | Keycloak behind an nginx front door | `core` |
| `docker-compose.kong.yml` | Kong API gateway (default) | `gw-kong` |
| `docker-compose.apisix.yml` | Apache APISIX gateway + etcd | `gw-apisix` |
| `docker-compose.mgmt.yml` | Manager components | `mgr-components` |
| `docker-compose.minimal.module.yml` | Backend modules | `app-platform-minimal` |
| `docker-compose.minimal.sidecar.yml` | Module sidecars | `app-platform-minimal` |

`compose.yaml` explicitly includes the non-gateway files in the listed order.
The gateway file is **not** in the include list: exactly one gateway may be
active, so `./start.sh` and `./stop.sh` append `docker-compose.kong.yml` or
`docker-compose.apisix.yml` to `COMPOSE_FILE` based on `APIGW_TYPE` (default
`kong`). Both gateways publish the proxy on host port 8000.

## Startup order

1. **core + gateway** — PostgreSQL, Kafka, Vault, Keycloak, and the selected
   gateway (`gw-kong` or `gw-apisix`)
2. **mgr-components** — Manager services (depends on db, keycloak)
3. **app-platform-minimal** — Modules + sidecars, started by service name

## Configuration

- `.env` — Default environment variables (committed)
- `.env.local` — Local overrides (not committed)
- `.env.local.credentials` — Runtime Vault token (never committed)

All environment variables are defined inline in Compose files. See `.env` for default values.

## Native Compose operations

```bash
# View running services
docker compose ps

# View logs for a service
docker compose logs -f <service>

# Restart a service
docker compose restart <service>

# Execute command in container
docker compose exec <service> <command>
```

A bare `docker compose down` no-ops: every service is profile-gated. Teardown
is `./stop.sh`, which activates all profiles.

## Network

All services connect to `fpm-net` (folio-platform-minimal bridge network).
