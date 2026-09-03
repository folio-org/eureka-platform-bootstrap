# Current-State Architecture Overview

This documentation set describes `eureka-platform-bootstrap` as it exists today.

The primary subject is the repository itself as a local-environment tool. The deployed services matter, but they are the managed output of this repository rather than the only architectural subject.

## What This Repository Is

`eureka-platform-bootstrap` is a Docker- and script-driven repository for assembling, configuring, bootstrapping, and operating the bundled local FOLIO Eureka `app-platform-minimal` environment.

It combines:

- Docker Compose service definitions for infrastructure and application services
- environment-variable layers and local overrides
- application descriptors and discovery metadata
- Bash and Python automation for startup, bootstrap, and helper operations

## What This Repository Is Responsible For

Today, the repository owns five major responsibilities:

1. Define the local runtime topology.
   - Core infrastructure such as PostgreSQL, Kafka, Vault, Kong, and Keycloak.
   - Manager components such as `mgr-applications`, `mgr-tenants`, and `mgr-tenant-entitlements`.
   - The `app-platform-minimal` application services: `mod-*` backends and
     matching `sc-*` sidecars declared in this repository.

2. Provide the local configuration model.
   - Default values in `docker/.env`.
   - Local overrides in `docker/.env.local`.
   - Local credentials in `docker/.env.local.credentials`.
   - Service environment variables defined inline in Compose files.

3. Bootstrap the runtime after containers exist.
   - Populate Vault token state.
   - Register application descriptors and discovery metadata.
   - Create a tenant and entitle an application.
   - Create default users.

4. Keep the minimal FOLIO application definition available in-repo.
   - `descriptors/app-platform-minimal/descriptor.json`
   - `descriptors/app-platform-minimal/discovery.json`

5. Provide helper automation for local operations.
   - image building
   - module version synchronization
   - user and tenant helpers

## What This Repository Does Not Own

The repository does not own:

- the implementation of FOLIO backend modules themselves
- the implementation of Keycloak, Kong, Vault, Kafka, or PostgreSQL
- a generic production deployment system for all FOLIO environments

It is a local-environment orchestration repository, not the source repository for the platform services it runs.

## Current Runtime Shape

The current environment is organized around a layered runtime model:

- `core` profile - infrastructure and access layers
- `mgr-components` profile - platform management services
- `app-platform-minimal` profile - backend modules and sidecars for the bundled minimal application

The repository can drive this layered model through the single `./start.sh` entrypoint, or through lower-level staged commands inside `docker/`.

## Architecture Views In This Set

This set follows a practical C4-style structure:

- `system-context.md` - repository boundary, users, external systems
- `runtime-containers.md` - the managed runtime and its major deployable groups
- `repository-components.md` - repository internals and file-level responsibilities
- `key-flows.md` - the main flows performed by the repository
- `principles.md` - current design principles and what must be preserved during evolution
- `supported-workflows.md` - the current operator-facing support boundary
- `console-ui.md` - the operator console UI/UX design cookbook (color, glyphs, phases, boxes, spinners) that all `misc/lib/ui.sh` output must follow

## Current-State Summary

In its current form, the repository behaves like a combination of:

- a Compose-based runtime definition
- a single `./start.sh` operator entrypoint over focused libraries
- a set of manual operational entrypoints inside `docker/`
- a bundled `app-platform-minimal` descriptor/discovery registration bundle

The repository is therefore both:

- a source-controlled definition of a local FOLIO environment, and
- an operator-facing tool that assembles and bootstraps that environment.

That dual role is the core idea to preserve while the repository is improved.
