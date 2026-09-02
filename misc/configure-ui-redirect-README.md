# Keycloak UI Redirect Configuration Script

## Purpose

This script configures Keycloak client redirect URIs to enable proper authentication for the FOLIO UI.

## Problem

When the FOLIO UI attempts to authenticate users via Keycloak, it uses OAuth2/OIDC flow with redirect URIs. If the Keycloak client (e.g., `diku-login-app`) doesn't have the correct redirect URIs configured, authentication fails with:

```
Invalid parameter: redirect_uri
```

## Solution

This script automatically:
1. Obtains an admin access token from Keycloak
2. Finds the login client for each configured tenant
3. Updates the client's redirect URIs to include:
   - `http://localhost:3000/*`
   - `http://localhost:3000/`
   - Custom `PLATFORM_COMPLETE_URL` variations

## Usage

### Automatic (via start.sh)

The script is automatically executed when you build the UI via `start.sh`:

```bash
./start.sh
# ...
# At the end, select "Yes" to build UI
# Script will run automatically before UI build
```

### Manual Execution

If you need to fix redirect URIs after deployment:

```bash
cd <project-root>
./start.sh --ui
```

## Configuration

The script uses environment variables loaded via `misc/lib/folio-common.sh`:
- `docker/.env.local` - TENANT_IDS, KC_LOGIN_CLIENT_SUFFIX, PLATFORM_COMPLETE_URL
- `docker/.env.local.credentials` - KC_ADMIN_CLIENT_SECRET

### Required Variables

| Variable | Default | Description |
|----------|---------|-------------|
| TENANT_IDS | diku | Comma-separated tenant IDs |
| KC_LOGIN_CLIENT_SUFFIX | -login-app | Suffix for login client ID |
| PLATFORM_COMPLETE_URL | http://localhost:3000 | UI URL for redirect |
| KC_ADMIN_CLIENT_ID | folio-backend-admin-client | Admin client ID |
| KC_ADMIN_CLIENT_SECRET | folio-backend-admin-client-secret | Admin client secret |

## How It Works

1. **Get Admin Token**: Authenticates with Keycloak master realm using admin client credentials
2. **For Each Tenant**:
   - Constructs client ID: `{tenant}{KC_LOGIN_CLIENT_SUFFIX}` (e.g., `diku-login-app`)
   - Queries Keycloak Admin API to find client UUID
   - Retrieves current client configuration
   - Updates redirect URIs to include UI URL variations
   - Saves updated configuration back to Keycloak

3. **Redirect URIs Set**:
   ```json
   [
     "http://localhost:3000/*",
     "http://localhost:3000/",
     "{PLATFORM_COMPLETE_URL}/*",
     "{PLATFORM_COMPLETE_URL}/"
   ]
   ```

## Prerequisites

- Keycloak must be running and accessible at `http://keycloak:8080`
- Tenant must be created and entitlements enabled
- Admin client credentials must be valid
- `jq` command-line tool must be installed

## Output Example

```
=========================================
  Keycloak UI Redirect Configuration
=========================================

Getting Keycloak admin token...
✓ Admin token obtained

Configuring client: diku-login-app for realm: diku
---------------------------------------------
✓ Found client UUID: a1b2c3d4-e5f6-7890-abcd-ef1234567890
Current redirect URIs:
  (none)

Setting redirect URIs to:
  - http://localhost:3000/*
  - http://localhost:3000/
✓ Client redirect URIs updated successfully

=========================================
  Configuration complete!
=========================================

You can now access the UI at: http://localhost:3000
Default credentials: folio / folio
```

## Troubleshooting

### Error: Failed to obtain admin access token

**Cause**: Invalid admin client credentials or Keycloak not accessible

**Solution**:
1. Verify Keycloak is running: `docker ps | grep keycloak`
2. Check credentials in `docker/.env.local.credentials`
3. Verify `/etc/hosts` has entry: `127.0.0.1 keycloak`

### Warning: Client not found

**Cause**: Tenant entitlement not complete or client not created

**Solution**:
1. Verify tenant exists and is entitled
2. Check that app-platform-minimal is fully deployed
3. Wait for entitlement process to complete

### Error updating client (HTTP 4xx/5xx)

**Cause**: Insufficient permissions or invalid client configuration

**Solution**:
1. Verify admin client has realm-management role
2. Check Keycloak logs: `docker logs keycloak`
3. Try obtaining a fresh admin token

## Integration Points

- **Called by**: `start.sh` (before UI build/deploy)
- **Reads from**: `docker/.env.local`, `docker/.env.local.credentials` (via `folio-common.sh`)
- **Modifies**: Keycloak client configuration via Admin REST API
- **Required for**: FOLIO UI authentication to work properly

## Related Files

- `start.sh` - Calls this script before UI deployment
- `docker/.env.local` - Tenant, client, and UI configuration
- `docker/.env.local.credentials` - Secrets
- `README.md` - User documentation for UI deployment
