#!/usr/bin/env bash

cd "$(dirname "$0")" || exit

localConfigFile=".env.local"
echo "This script will configure local $localConfigFile for folio platform installation"

if [[ -f .env.local ]]; then
  source .env.local
fi

# mgr components configuration
defaultMgrComponentsKeycloakIntegrationEnabled=${MGR_COMPONENTS_KC_INTEGRATION_ENABLED:-true}
defaultMgrComponentsKongIntegrationEnabled=${MGR_COMPONENTS_KONG_INTEGRATION_ENABLED:-true}
defaultMgrComponentsOkapiIntegrationEnabled=${MGR_COMPONENTS_OKAPI_INTEGRATION_ENABLED:-false}
defaultMgrComponentsSecurityEnabled=${MGR_COMPONENTS_SECURITY_ENABLED:-false}
defaultMgrComponentsKeycloakImportEnabled=${MGR_COMPONENTS_KEYCLOAK_IMPORT_ENABLED:-true}

# Database configuration (default)
defaultPostgresPassword=${POSTGRES_PASSWORD:-postgres_admin}
defaultOkapiDbPassword=${OKAPI_DB_PASSWORD:-okapi_admin}
defaultKongDbPassword=${KONG_DB_PASSWORD:-kong_admin}

# mgr-components configuration (default)
defaultMgrApplicationsDbPassword=${MGR_APPLICATIONS_DB_PASSWORD:-app_manager_admin}
defaultMgrApplicationsValidationMode=${MGR_APPLICATIONS_VALIDATION_MODE:-basic}
defaultMgrTenantsDbPassword=${MGR_TENANTS_DB_PASSWORD:-tenant_manager_admin}
defaultMgrTenantEntitlementsDbPassword=${MGR_TENANT_ENTITLEMENTS_DB_PASSWORD:-tenant_entitlement_admin}

# Keycloak configuration
defaultKeycloakDbPassword=${KC_DB_PASSWORD:-keycloak_admin}
defaultKeycloakAdminPassword=${KC_ADMIN_PASSWORD:-keycloak_system_admin}
defaultKeycloakAdminClientId=${KC_ADMIN_CLIENT_ID:-be-admin-client}
defaultKeycloakAdminClientSecret=${KC_ADMIN_CLIENT_SECRET:-be-admin-client-secret}
defaultKeycloakServiceClientId=${KC_SERVICE_CLIENT_ID:-m2m-client}
defaultKeycloakLoginClientSuffix=${KC_LOGIN_CLIENT_SUFFIX:--login-app}

echo
echo "### mgr-component configuration"
read -p "mgr components security enabled [$defaultMgrComponentsSecurityEnabled]: " -r mgrComponentsSecurityEnabled
read -p "mgr components keycloak import enabled [$defaultMgrComponentsKeycloakImportEnabled]: " -r mgrComponentsKeycloakImportEnabled

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
read -p "Keycloak folio admin client id [$defaultKeycloakAdminClientId]: " -r keycloakAdminClientId
read -p "Keycloak folio admin client secret [$defaultKeycloakAdminClientSecret]: " -r keycloakAdminClientSecret
read -p "Keycloak service (module-to-module) client id [$defaultKeycloakServiceClientId]: " -r keycloakServiceClientId
read -p "Keycloak login client suffix [$defaultKeycloakLoginClientSuffix]: " -r keycloakLoginClientSuffix


cat > $localConfigFile <<- EOM
### mgr-components-configuration
export MGR_COMPONENTS_SECURITY_ENABLED=${mgrComponentsSecurityEnabled:-${defaultMgrComponentsSecurityEnabled}}
export MGR_COMPONENTS_KEYCLOAK_IMPORT_ENABLED=${mgrComponentsKeycloakImportEnabled:-${defaultMgrComponentsKeycloakImportEnabled}}

### Database configuration
export POSTGRES_PASSWORD=${postgresPassword:-${defaultPostgresPassword}}
export KC_DB_PASSWORD=${keycloakDbPassword:-${defaultKeycloakDbPassword}}
export OKAPI_DB_PASSWORD=${okapiDbPassword:-${defaultOkapiDbPassword}}
export KONG_DB_PASSWORD=${kongDbPassword:-${defaultKongDbPassword}}
export MGR_APPLICATIONS_DB_PASSWORD=${mgrApplicationsDbPassword:-${defaultMgrApplicationsDbPassword}}
export MGR_TENANTS_DB_PASSWORD=${mgrTenantsDbPassword:-${defaultMgrTenantsDbPassword}}
export MGR_TENANT_ENTITLEMENTS_DB_PASSWORD=${mgrTenantEntitlementsDbPassword:-${defaultMgrTenantEntitlementsDbPassword}}

### Keycloak configuration
export KC_ADMIN_PASSWORD=${keycloakAdminPassword:-${defaultKeycloakAdminPassword}}
export KC_ADMIN_CLIENT_ID=${keycloakAdminClientId:-${defaultKeycloakAdminClientId}}
export KC_ADMIN_CLIENT_SECRET=${keycloakAdminClientSecret:-${defaultKeycloakAdminClientSecret}}
export KC_SERVICE_CLIENT_ID=${keycloakServiceClientId:-${defaultKeycloakServiceClientId}}
export KC_LOGIN_CLIENT_SUFFIX=${keycloakLoginClientSuffix:-${defaultKeycloakLoginClientSuffix}}
EOM
