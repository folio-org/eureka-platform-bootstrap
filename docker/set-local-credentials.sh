#!/usr/bin/env bash

cd "$(dirname "$0")" || exit

localConfigFile=".env.local.credentials"
echo "This script will configure local $localConfigFile for folio platform installation"

if [[ -f "$localConfigFile" ]]; then
  source "$localConfigFile"
fi

# Database configuration (default)
defaultPostgresPassword=${POSTGRES_PASSWORD:-postgres_admin}
defaultOkapiDbPassword=${OKAPI_DB_PASSWORD:-okapi_admin}
defaultKongDbPassword=${KONG_DB_PASSWORD:-kong_admin}

# mgr-components configuration (default)
defaultMgrApplicationsDbPassword=${MGR_APPLICATIONS_DB_PASSWORD:-mgr_applications_admin}
defaultMgrApplicationsValidationMode=${MGR_APPLICATIONS_VALIDATION_MODE:-basic}
defaultMgrTenantsDbPassword=${MGR_TENANTS_DB_PASSWORD:-mgr_tenants_admin}
defaultMgrTenantEntitlementsDbPassword=${MGR_TENANT_ENTITLEMENTS_DB_PASSWORD:-mgr_tenant_entitlements_admin}

# Keycloak configuration
defaultKeycloakDbPassword=${KC_DB_PASSWORD:-keycloak_admin}
defaultKeycloakAdminPassword=${KC_ADMIN_PASSWORD:-keycloak_system_admin}
defaultKeycloakAdminClientSecret=${KC_ADMIN_CLIENT_SECRET:-be-admin-client-secret}

echo "### Database configuration"

read -p "Master database password [$defaultPostgresPassword]: " -r postgresPassword
read -p "Keycloak database password [$defaultKeycloakDbPassword]: " -r keycloakDbPassword
read -p "Okapi database password [$defaultOkapiDbPassword]: " -r okapiDbPassword
read -p "Kong database password [$defaultKongDbPassword]: " -r kongDbPassword
read -p "mgr-applications database password [$defaultMgrApplicationsDbPassword]: " -r mgrApplicationsDbPassword
read -p "mgr-tenants database password [$defaultMgrTenantsDbPassword]: " -r mgrTenantsDbPassword
read -p "mgr-tenant-entitlements database password [$defaultMgrTenantEntitlementsDbPassword]: " -r mgrTenantEntitlementsDbPassword

echo
echo "### Keycloak configuration"
read -p "Keycloak admin password [$defaultKeycloakAdminPassword]: " -r keycloakAdminPassword
read -p "Keycloak folio admin client secret [$defaultKeycloakAdminClientSecret]: " -r keycloakAdminClientSecret


cat > $localConfigFile <<- EOM
### Database credentials
export POSTGRES_PASSWORD=${postgresPassword:-${defaultPostgresPassword}}
export KC_DB_PASSWORD=${keycloakDbPassword:-${defaultKeycloakDbPassword}}
export OKAPI_DB_PASSWORD=${okapiDbPassword:-${defaultOkapiDbPassword}}
export KONG_DB_PASSWORD=${kongDbPassword:-${defaultKongDbPassword}}
export MGR_APPLICATIONS_DB_PASSWORD=${mgrApplicationsDbPassword:-${defaultMgrApplicationsDbPassword}}
export MGR_TENANTS_DB_PASSWORD=${mgrTenantsDbPassword:-${defaultMgrTenantsDbPassword}}
export MGR_TENANT_ENTITLEMENTS_DB_PASSWORD=${mgrTenantEntitlementsDbPassword:-${defaultMgrTenantEntitlementsDbPassword}}

### Keycloak credentials
export KC_ADMIN_PASSWORD=${keycloakAdminPassword:-${defaultKeycloakAdminPassword}}
export KC_ADMIN_CLIENT_SECRET=${keycloakAdminClientSecret:-${defaultKeycloakAdminClientSecret}}
EOM
