# Principles

This document captures the main principles that shape the repository today and the guardrails that should be preserved during its evolution.

It is not a debt log. The purpose is to identify the foundation worth keeping.

## Current Foundational Principles

### 1. Repository as orchestration boundary

The repository is the boundary that assembles a local FOLIO environment. It coordinates images, config, descriptors, and bootstrap workflows in one place.

This foundation should be preserved.

### 2. Compose-centered runtime definition

The runtime is expressed primarily through Docker Compose service definitions.

Compose is the current visible model of:

- which services exist
- which ports are exposed
- which profiles group related runtime slices
- which environment files and variables shape service behavior

This is an important transparency property of the repository.

### 3. Layered environment assembly

The runtime is intentionally layered:

- infrastructure first
- manager components second
- application services third
- optional UI last

This layering captures real dependencies in the local environment and provides a useful mental model for operators.

### 4. Descriptor-backed application composition

The minimal application is represented explicitly through committed descriptor and discovery files.

This means the repository does not rely only on running containers. It also stores application metadata that can be registered into the management plane.

### 5. Sidecar-mediated module access

Backend modules are not exposed directly as the primary integration surface. Each module is fronted by a sidecar that handles tenant-aware and auth-aware behavior.

This is a defining part of the Eureka platform model represented by the repository.

### 6. Local-first configurability

The repository keeps committed defaults and allows local overrides.

Current examples:

- committed defaults in `docker/.env`
- local overrides in `docker/.env.local`
- local secrets in `docker/.env.local.credentials`

Even though the current implementation can be simplified, the principle of local-first flexibility should remain.

### 7. Scriptable operations

The repository is not only declarative. It also supports scripted operational flows such as:

- startup
- shutdown
- version synchronization
- user creation
- UI build

That scriptability is useful and should be retained, even if the internal structure changes.

### 8. Optional experience layers

The UI is modeled as an optional layer instead of a mandatory part of backend bootstrap.

This principle keeps the environment usable in headless or API-first workflows.

## Invariants Worth Preserving

The following invariants should survive refactoring:

- the repository must remain the visible definition of the local environment
- the runtime model must remain inspectable by humans in version control
- application metadata must remain explicit and traceable
- local overrides must remain possible without forking the repository
- optional layers must remain optional

## Evolution Guardrails

The future transformation should be guided by these guardrails.

### Simplicity first

The repository should become easier to read, operate, and extend.

### Transparent configuration provenance

A maintainer or contributor should be able to answer three questions quickly:

- where a value comes from
- where it is used
- what the default is

### Thin tooling over explicit definitions

If a future CLI, `npx` command, or lightweight UI is introduced, it should sit on top of explicit service definitions and documented configuration, not hide them behind opaque behavior.

### Research before locking dynamic composition

The repository will likely evolve toward dynamic application/service selection, but the final mechanism should be chosen only after explicit research and comparison.

### Preserve the core idea while improving the operator experience

The target state is not a brand-new unrelated product. The target state is a better-structured, more user-friendly version of the same core repository idea.
