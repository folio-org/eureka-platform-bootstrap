# Docker Compose Layers

This directory contains the FOLIO platform Docker Compose configuration organized as layered profiles.

## Runtime lifecycle

For full bootstrap, descriptor registration, tenant creation, and user setup,
use `./start.sh` from the repository root. Use `./stop.sh` for teardown.

This directory also exposes the standard Docker Compose manifest for low-level
operator work. Native commands are intentionally not a second supported
bootstrap workflow; operators supply any required local configuration themselves.

## Compose Files

| File | Purpose | Profile |
|------|---------|---------|
| `docker-compose.core.yml` | Database, Kafka, Vault, Kong | `core` |
| `docker-compose.keycloak.yml` | Keycloak auth service | `core` |
| `docker-compose.mgmt.yml` | Manager components | `mgr-components` |
| `docker-compose.minimal.module.yml` | Backend modules | `app-platform-minimal` |
| `docker-compose.minimal.sidecar.yml` | Module sidecars | `app-platform-minimal` |
| `docker-compose.ui.yml` | FOLIO UI | `ui` |

`compose.yaml` explicitly includes these files in the listed order, so native
`docker compose` resolves one deterministic project definition.

## Startup Order

1. **core** — Database, Kafka, Vault, Kong, and Keycloak (Keycloak runs within the `core` profile)
2. **mgr-components** — Manager services (depends on db, keycloak)
3. **app-platform-minimal** — Modules + sidecars (depends on mgr-components)
4. **ui** — FOLIO UI (depends on kong, keycloak)

## Configuration

- `.env` — Default environment variables (committed)
- `.env.local` — Local overrides (not committed)
- `.env.local.credentials` — Local secrets (never committed)

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

## Network

All services connect to `fpm-net` (folio-platform-minimal bridge network).
