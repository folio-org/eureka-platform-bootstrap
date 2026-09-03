#!/usr/bin/env bash

readonly LOCAL_CREDENTIALS_FILE='.env.local.credentials'

local_credentials_print_export() {
  local variable_name="$1"
  local variable_value="$2"

  printf 'export %s=%q\n' "${variable_name}" "${variable_value}"
}

load_existing_local_credentials() {
  if [[ -f "${LOCAL_CREDENTIALS_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${LOCAL_CREDENTIALS_FILE}"
  fi
}

load_local_credentials_defaults() {
  LOCAL_CREDENTIALS_DEFAULT_POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres_admin}"
  LOCAL_CREDENTIALS_DEFAULT_OKAPI_DB_PASSWORD="${OKAPI_DB_PASSWORD:-okapi_admin}"
  LOCAL_CREDENTIALS_DEFAULT_KONG_DB_PASSWORD="${KONG_DB_PASSWORD:-kong_admin}"
  LOCAL_CREDENTIALS_DEFAULT_MGR_APPLICATIONS_DB_PASSWORD="${MGR_APPLICATIONS_DB_PASSWORD:-mgr_applications_admin}"
  LOCAL_CREDENTIALS_DEFAULT_MGR_TENANTS_DB_PASSWORD="${MGR_TENANTS_DB_PASSWORD:-mgr_tenants_admin}"
  LOCAL_CREDENTIALS_DEFAULT_MGR_TENANT_ENTITLEMENTS_DB_PASSWORD="${MGR_TENANT_ENTITLEMENTS_DB_PASSWORD:-mgr_tenant_entitlements_admin}"
  LOCAL_CREDENTIALS_DEFAULT_KC_DB_PASSWORD="${KC_DB_PASSWORD:-keycloak_admin}"
  LOCAL_CREDENTIALS_DEFAULT_KC_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD:-admin}"
  LOCAL_CREDENTIALS_DEFAULT_KC_ADMIN_CLIENT_SECRET="${KC_ADMIN_CLIENT_SECRET:-folio-backend-admin-client-secret}"
  LOCAL_CREDENTIALS_DEFAULT_SECRET_STORE_VAULT_TOKEN="${SECRET_STORE_VAULT_TOKEN:-}"
}

write_local_credentials_file() {
  local postgres_password="$1"
  local keycloak_db_password="$2"
  local okapi_db_password="$3"
  local kong_db_password="$4"
  local mgr_applications_db_password="$5"
  local mgr_tenants_db_password="$6"
  local mgr_tenant_entitlements_db_password="$7"
  local keycloak_admin_password="$8"
  local keycloak_admin_client_secret="$9"
  local secret_store_vault_token="${10:-}"

  {
    printf '### Database credentials\n'
    local_credentials_print_export 'POSTGRES_PASSWORD' "${postgres_password}"
    local_credentials_print_export 'KC_DB_PASSWORD' "${keycloak_db_password}"
    local_credentials_print_export 'OKAPI_DB_PASSWORD' "${okapi_db_password}"
    local_credentials_print_export 'KONG_DB_PASSWORD' "${kong_db_password}"
    local_credentials_print_export 'MGR_APPLICATIONS_DB_PASSWORD' "${mgr_applications_db_password}"
    local_credentials_print_export 'MGR_TENANTS_DB_PASSWORD' "${mgr_tenants_db_password}"
    local_credentials_print_export 'MGR_TENANT_ENTITLEMENTS_DB_PASSWORD' "${mgr_tenant_entitlements_db_password}"
    printf '\n### Keycloak credentials\n'
    local_credentials_print_export 'KC_ADMIN_PASSWORD' "${keycloak_admin_password}"
    local_credentials_print_export 'KC_ADMIN_CLIENT_SECRET' "${keycloak_admin_client_secret}"
  } > "${LOCAL_CREDENTIALS_FILE}"

  if [[ -n "${secret_store_vault_token}" ]]; then
    {
      printf '\n### Vault token\n'
      local_credentials_print_export 'SECRET_STORE_VAULT_TOKEN' "${secret_store_vault_token}"
    } >> "${LOCAL_CREDENTIALS_FILE}"
  fi
}

write_default_local_credentials_file() {
  load_local_credentials_defaults

  write_local_credentials_file \
    "${LOCAL_CREDENTIALS_DEFAULT_POSTGRES_PASSWORD}" \
    "${LOCAL_CREDENTIALS_DEFAULT_KC_DB_PASSWORD}" \
    "${LOCAL_CREDENTIALS_DEFAULT_OKAPI_DB_PASSWORD}" \
    "${LOCAL_CREDENTIALS_DEFAULT_KONG_DB_PASSWORD}" \
    "${LOCAL_CREDENTIALS_DEFAULT_MGR_APPLICATIONS_DB_PASSWORD}" \
    "${LOCAL_CREDENTIALS_DEFAULT_MGR_TENANTS_DB_PASSWORD}" \
    "${LOCAL_CREDENTIALS_DEFAULT_MGR_TENANT_ENTITLEMENTS_DB_PASSWORD}" \
    "${LOCAL_CREDENTIALS_DEFAULT_KC_ADMIN_PASSWORD}" \
    "${LOCAL_CREDENTIALS_DEFAULT_KC_ADMIN_CLIENT_SECRET}" \
    "${LOCAL_CREDENTIALS_DEFAULT_SECRET_STORE_VAULT_TOKEN}"
}

read_vault_root_token() {
  local token

  token="$(docker logs vault 2>/dev/null \
    | grep 'Root VAULT TOKEN is:' \
    | sed -E 's/^.*Root VAULT TOKEN is: (.+)$/\1/' \
    | tail -n 1 || true)"

  if [[ -z "${token}" ]]; then
    ui_error "could not read the Vault root token from 'docker logs vault'."
    ui_info "Is the 'vault' container running and initialized?"
    return 1
  fi

  printf '%s\n' "${token}"
}

persist_vault_root_token() {
  local vault_token="$1"

  if [[ -z "${vault_token//[[:space:]]/}" ]]; then
    ui_error "refusing to write an empty Vault token to ${LOCAL_CREDENTIALS_FILE}."
    return 1
  fi

  load_existing_local_credentials
  SECRET_STORE_VAULT_TOKEN="${vault_token}"
  write_default_local_credentials_file
}
