#!/usr/bin/env bash
# Prepare stripes.config.js from template with environment variable substitution
# Adapted for eureka-platform-bootstrap
set -euo pipefail

# Get repository directory from argument
REPO_DIR="${1:?Repository directory is required}"

# Source utility functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

TEMPLATE_SOURCE="$REPO_DIR/eureka-tpl/stripes.config.js"
CONFIG_TARGET="$REPO_DIR/stripes.config.js"

ui_info "Preparing stripes.config.js from template"

# Verify template exists
if [[ ! -f "$TEMPLATE_SOURCE" ]]; then
  ui_error "Template not found: $TEMPLATE_SOURCE"
  ui_error "Make sure platform-complete repository is cloned correctly"
  exit 1
fi

# Copy template
cp "$TEMPLATE_SOURCE" "$CONFIG_TARGET"
ui_info "Copied template from eureka-tpl/stripes.config.js"

# Generate tenant options JSON
generate_tenant_options() {
  local tenant_ids="${TENANT_IDS:-}"
  local client_suffix="${KC_LOGIN_CLIENT_SUFFIX:--login-app}"
  local options=""

  if [[ -z "$tenant_ids" ]]; then
    ui_error "TENANT_IDS environment variable is required"
    exit 1
  fi

  IFS=',' read -ra TENANTS <<< "$tenant_ids"
  for tenant in "${TENANTS[@]}"; do
    tenant=$(echo "$tenant" | xargs) # trim whitespace
    if [[ -n "$options" ]]; then
      options+=", "
    fi
    options+="$tenant: {name: \"$tenant\", displayName: \"$tenant\", clientId: \"$tenant$client_suffix\"}"
  done

  echo "{$options}"
}

TENANT_OPTIONS=$(generate_tenant_options)
ui_info "Generated tenant options for: $TENANT_IDS"

# Perform replacements
# Using sed with backup file for macOS compatibility
sed -i.bak \
  -e "s|\${kongUrl}|$KONG_URL|g" \
  -e "s|\${tenantUrl}|$PLATFORM_COMPLETE_URL|g" \
  -e "s|\${keycloakUrl}|$KEYCLOAK_URL|g" \
  -e "s|\${hasAllPerms}|$HAS_ALL_PERMS|g" \
  -e "s|\${isSingleTenant}|$IS_SINGLE_TENANT|g" \
  -e "s|\${enableEcsRequests}|$ENABLE_ECS_REQUESTS|g" \
  -e "s|\${tenantOptions}|$TENANT_OPTIONS|g" \
  "$CONFIG_TARGET"

# Remove backup file
rm -f "$CONFIG_TARGET.bak"

# Add consortia-settings module if not present
# This matches the eureka-cli behavior from ui_svc_stripes_config.go line 61
if grep -q "'@folio/users' : {}" "$CONFIG_TARGET"; then
  sed -i.bak "s|'@folio/users' : {}|'@folio/users' : {},\\
    '@folio/consortia-settings' : {}|" "$CONFIG_TARGET"
  rm -f "$CONFIG_TARGET.bak"
  ui_info "Added @folio/consortia-settings module"
fi

ui_ok "stripes.config.js prepared successfully"
ui_info "Configuration summary:"
ui_info "  - Kong URL: $KONG_URL"
ui_info "  - Keycloak URL: $KEYCLOAK_URL"
ui_info "  - Platform URL: $PLATFORM_COMPLETE_URL"
ui_info "  - Single Tenant: $IS_SINGLE_TENANT"
ui_info "  - Tenant(s): $TENANT_IDS"
