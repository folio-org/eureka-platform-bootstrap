# FOLIO UI Build Scripts

This directory contains scripts for building FOLIO platform-complete UI Docker images for eureka-platform-bootstrap.

## Overview

The FOLIO UI build process:
1. Clones/updates the platform-complete repository (into a disposable cache)
2. Generates `stripes.config.js` from template with environment variables
3. Updates `package.json` with required modules
4. Builds Docker image using platform-complete's own `docker/Dockerfile` (Node.js → NGINX)
5. Optionally deploys the container

## Why a local build instead of eureka-cli?

This repo keeps a small local build rather than calling the upstream
`eureka-cli` (`folio-org/eureka-setup`). That was a deliberate decision, not an
oversight:

- `eureka-cli` is a **Go binary** that requires the **Go toolchain** to build and
  install, assumes **Rancher Desktop**, and carries its own `~/.eureka/` config
  model. Adopting it would add those technologies to a repo that otherwise needs
  only `git` + `docker`.
- It now builds **platform-lsp**, not the **platform-complete** this bootstrap is
  built around, and pulls a pre-built platform-lsp image from DockerHub.

By contrast this local path is self-contained and reuses the **stock
platform-complete `docker/Dockerfile`** unchanged. The only custom work is minimal
config prep (`prepare-stripes-config.sh`, `prepare-package-json.sh`), which mirrors
eureka-cli's UI service logic. If the bootstrap later migrates to platform-lsp /
eureka-cli wholesale, revisit this.

## Cache contract

The platform-complete clone is a **disposable, agent-owned cache** at
`misc/.cache/platform-complete` (gitignored via `misc/.cache/`). On each run with
`UPDATE_REPO=true` it is **hard-reset** to `origin/<branch>` — any manual edits
there are discarded. Override the location with `REPO_DIR` if needed.

## Scripts

### utils.sh
Utility functions used by all scripts:
- **validate_required_vars()**: Check required variables exist
- **manage_repository()**: Clone or update git repository

### prepare-stripes-config.sh
Generates `stripes.config.js` from template:
- Copies template from `platform-complete/eureka-tpl/stripes.config.js`
- Replaces placeholders: `${kongUrl}`, `${keycloakUrl}`, `${tenantUrl}`, etc.
- Generates tenant options JSON from `TENANT_IDS`
- Adds `@folio/consortia-settings` module

**Usage**: `./prepare-stripes-config.sh <repo_dir>`

### prepare-package-json.sh
Updates `package.json` with required modules and build configuration:
- Ensures 4 core modules are present:
  - `@folio/consortia-settings`
  - `@folio/authorization-policies`
  - `@folio/authorization-roles`
  - `@folio/plugin-select-application`
- Updates build script with NODE_OPTIONS (8GB heap)
- Uses `jq` for safe JSON manipulation

**Usage**: `./prepare-package-json.sh <repo_dir>`

## Environment Variables

### Required:
- `TENANT_IDS` - Comma-separated tenant IDs (e.g., `diku` or `diku,college,university`)

### Optional (with defaults):
- `KONG_URL` - Kong Gateway URL (default: `http://localhost:8000`; falls back to `FOLIO_KONG_URL` if set)
- `KEYCLOAK_URL` - Keycloak URL (default: `http://localhost:8080`; falls back to `FOLIO_KEYCLOAK_URL` or `KEYCLOAK_BASE_URL` if set)
- `PLATFORM_COMPLETE_URL` - UI URL (default: `http://localhost:3000`)
- `PLATFORM_COMPLETE_BRANCH` - Git branch (default: `snapshot`)
- `IS_SINGLE_TENANT` - Single vs multi-tenant (default: `true`)
- `HAS_ALL_PERMS` - Bypass permissions (default: `false`)
- `ENABLE_ECS_REQUESTS` - Enable ECS (default: `false`)
- `KC_LOGIN_CLIENT_SUFFIX` - Client ID suffix (default: `-login-app`)
- `FOLIO_UI_IMAGE` - Docker image reference (default: `folioci/folio-ui:latest`)

## Integration with eureka-platform-bootstrap

These scripts are called by `../build-folio-ui.sh`, which:
1. Loads local config via `folio-common.sh`
2. Validates required variables
3. Orchestrates the build process
4. Builds Docker image
5. Optionally deploys container

The resulting image is used by the `docker-compose.ui.yml` service.

## Template Variables

From `stripes.config.js` template:
```javascript
${kongUrl}           → KONG_URL
${tenantUrl}         → PLATFORM_COMPLETE_URL
${keycloakUrl}       → KEYCLOAK_URL
${hasAllPerms}       → HAS_ALL_PERMS (boolean)
${isSingleTenant}    → IS_SINGLE_TENANT (boolean)
${enableEcsRequests} → ENABLE_ECS_REQUESTS (boolean)
${tenantOptions}     → Generated from TENANT_IDS
```

### Tenant Options Format

**Single Tenant**:
```javascript
{diku: {name: "diku", displayName: "diku", clientId: "diku-login-app"}}
```

**Multi-Tenant**:
```javascript
{
  diku: {name: "diku", displayName: "diku", clientId: "diku-login-app"},
  college: {name: "college", displayName: "college", clientId: "college-login-app"},
  university: {name: "university", displayName: "university", clientId: "university-login-app"}
}
```

## Dependencies

- **bash** 4.0+ - For scripts
- **git** 2.0+ - For cloning repository
- **docker** 20.10+ - For building images
- **jq** 1.5+ - For JSON manipulation

## Build Process Details

### Multi-Stage Docker Build

**Stage 1: Build** (node:20-alpine)
- Install dependencies (yarn install)
- Build UI (yarn build)
- Time: 10-15 minutes
- Size: ~2GB (not included in final image)

**Stage 2: Serve** (nginx:stable-alpine)
- Copy only `/output` directory from stage 1
- Configure NGINX for SPA routing
- Final size: ~20-30MB
- Runtime memory: ~35-64MB

### Resource Requirements

**Build Time**:
- First build: 10-15 minutes
- Subsequent builds: 5-10 minutes (with cache)

**Build Resources**:
- Memory: 8GB heap (NODE_OPTIONS)
- Disk: ~2GB temporary, ~30MB final

**Runtime Resources**:
- Memory: 35-64MB (NGINX)
- CPU: 1 core
- Disk: 20-30MB

## Troubleshooting

### Missing jq
```bash
# macOS
brew install jq

# Debian/Ubuntu
sudo apt-get install jq

# RHEL/CentOS
sudo yum install jq
```

### Template Not Found
Ensure platform-complete is cloned correctly (clearing the disposable cache):
```bash
rm -rf misc/.cache/platform-complete
./start.sh --ui
```

### Docker Build Fails
- Ensure Docker has enough memory (8GB+ recommended)
- Check network connectivity
- Verify platform-complete repository is accessible

## References

Based on:
- **FOLIO platform-complete**: https://github.com/folio-org/platform-complete
- **Eureka CLI UI service**: Reverse-engineered from Go implementation
- **Stripes Framework**: FOLIO's UI framework

## License

Apache-2.0 (same as FOLIO platform-complete)
