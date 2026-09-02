#!/usr/bin/env bash
# Configure Keycloak client redirect URIs for FOLIO UI
# This script ensures the login client has proper redirect URIs configured
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/folio-common.sh"

# Load environment using the shared precedence rules, then apply UI-specific env.
load_folio_config

# Defaults
: "${TENANT_IDS:=diku}"
: "${KEYCLOAK_URL:=${KEYCLOAK_BASE_URL:-${FOLIO_KEYCLOAK_URL:-http://localhost:8080}}}"
: "${KC_LOGIN_CLIENT_SUFFIX:=-login-app}"
: "${PLATFORM_COMPLETE_URL:=http://localhost:3000}"
: "${KC_ADMIN_CLIENT_ID:=folio-backend-admin-client}"
: "${KC_ADMIN_CLIENT_SECRET:=folio-backend-admin-client-secret}"

ui_title "Keycloak UI Redirect Configuration"

# Get admin access token
ui_step "Getting Keycloak admin token"
ADMIN_TOKEN=$(curl -s -X POST \
  --header "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "client_id=${KC_ADMIN_CLIENT_ID}" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_secret=${KC_ADMIN_CLIENT_SECRET}" \
  "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
  | jq -r '.access_token')

if [[ -z "$ADMIN_TOKEN" || "$ADMIN_TOKEN" == "null" ]]; then
  ui_error "Failed to obtain admin access token"
  ui_info "Make sure Keycloak is running and credentials are correct"
  exit 1
fi

ui_ok "Admin token obtained"

# Process each tenant
IFS=',' read -ra TENANTS <<< "$TENANT_IDS"
for tenant in "${TENANTS[@]}"; do
  tenant=$(echo "$tenant" | xargs) # trim whitespace
  CLIENT_ID="${tenant}${KC_LOGIN_CLIENT_SUFFIX}"

  ui_step "Configuring client: ${CLIENT_ID} for realm: ${tenant}"

  # Get client UUID
  CLIENT_UUID=$(curl -s -X GET \
    --header "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${KEYCLOAK_URL}/admin/realms/${tenant}/clients?clientId=${CLIENT_ID}" \
    | jq -r '.[0].id // empty')

  if [[ -z "$CLIENT_UUID" ]]; then
    ui_warn "Client not found: ${CLIENT_ID} in realm ${tenant}"
    ui_info "   Make sure tenant entitlement is complete"
    ui_info ""
    continue
  fi

  ui_ok "Found client UUID: ${CLIENT_UUID}"

  # Get current client configuration
  CURRENT_CONFIG=$(curl -s -X GET \
    --header "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${KEYCLOAK_URL}/admin/realms/${tenant}/clients/${CLIENT_UUID}")

  # Extract current redirect URIs
  CURRENT_URIS=$(echo "$CURRENT_CONFIG" | jq -r '.redirectUris[]' 2>/dev/null || echo "")

  ui_info "Current redirect URIs:"
  if [[ -n "$CURRENT_URIS" ]]; then
    printf '%s\n' "$CURRENT_URIS" | while read -r uri; do ui_info "  - ${uri}"; done
  else
    ui_info "  (none)"
  fi

  # Build updated configuration for localhost-only access
  # OAuth flow: User at UI → Keycloak login → back to UI
  # Redirect URIs should ONLY include UI URL (where user returns after auth)
  REDIRECT_URIS='["'${PLATFORM_COMPLETE_URL}'/*"]'
  WEB_ORIGINS='["'${PLATFORM_COMPLETE_URL}'"]'
  POST_LOGOUT_REDIRECT="${PLATFORM_COMPLETE_URL}/*"

  ui_info ""
  ui_info "Setting configuration:"
  ui_info "  - rootUrl: ${PLATFORM_COMPLETE_URL}"
  ui_info "  - baseUrl: ${PLATFORM_COMPLETE_URL}"
  ui_info "  - adminUrl: ${PLATFORM_COMPLETE_URL}"
  ui_info "  - redirectUris: ${REDIRECT_URIS}"
  ui_info "  - webOrigins: ${WEB_ORIGINS}"
  ui_info "  - post.logout.redirect.uris: ${POST_LOGOUT_REDIRECT}"

  # Build updated configuration matching eureka-cli implementation
  UPDATED_CONFIG=$(echo "$CURRENT_CONFIG" | jq \
    --arg root "$PLATFORM_COMPLETE_URL" \
    --arg base "$PLATFORM_COMPLETE_URL" \
    --arg admin "$PLATFORM_COMPLETE_URL" \
    --argjson redirects "$REDIRECT_URIS" \
    --argjson origins "$WEB_ORIGINS" \
    --arg postLogout "$POST_LOGOUT_REDIRECT" \
    '.rootUrl = $root |
     .baseUrl = $base |
     .adminUrl = $admin |
     .redirectUris = $redirects |
     .webOrigins = $origins |
     .authorizationServicesEnabled = true |
     .serviceAccountsEnabled = true |
     .attributes["post.logout.redirect.uris"] = $postLogout |
     .attributes["login_theme"] = "custom-theme"')

  # Update client configuration
  UPDATE_RESULT=$(curl -s -w "\n%{http_code}" -X PUT \
    --header "Authorization: Bearer ${ADMIN_TOKEN}" \
    --header "Content-Type: application/json" \
    --data "$UPDATED_CONFIG" \
    "${KEYCLOAK_URL}/admin/realms/${tenant}/clients/${CLIENT_UUID}")

  HTTP_CODE=$(echo "$UPDATE_RESULT" | tail -n1)

  if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
    ui_ok "Client redirect URIs updated successfully"
  else
    ui_error "Error updating client (HTTP ${HTTP_CODE})"
    ui_info "$(printf '%s\n' "$UPDATE_RESULT" | sed '$d')"
  fi

  ui_info ""
done

ui_title "Configuration complete!"
ui_info "You can now access the UI at: ${PLATFORM_COMPLETE_URL}"
ui_info "Default credentials: folio / folio"
