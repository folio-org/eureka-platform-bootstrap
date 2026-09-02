#!/usr/bin/env bash
# Prepare package.json with required modules and optimized build script
# Adapted for eureka-platform-bootstrap
set -euo pipefail

# Get repository directory from argument
REPO_DIR="${1:?Repository directory is required}"

# Source utility functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

PACKAGE_JSON="$REPO_DIR/package.json"

ui_info "Preparing package.json"

# Check if package.json exists
if [[ ! -f "$PACKAGE_JSON" ]]; then
  ui_error "package.json not found: $PACKAGE_JSON"
  exit 1
fi

# Check jq availability
if ! command -v jq &> /dev/null; then
  ui_error "jq is required but not installed"
  ui_error "Install with:"
  ui_error "  macOS:         brew install jq"
  ui_error "  Debian/Ubuntu: sudo apt-get install jq"
  ui_error "  RHEL/CentOS:   sudo yum install jq"
  exit 1
fi

# Modules to ensure (from ui_svc_package.go lines 26-31)
MODULES=(
  "@folio/consortia-settings"
  "@folio/authorization-policies"
  "@folio/authorization-roles"
  "@folio/plugin-select-application"
)

ui_info "Ensuring required modules are present"

# Build JQ filter to add modules if missing
JQ_FILTER=''
for module in "${MODULES[@]}"; do
  JQ_FILTER+=".dependencies[\"$module\"] //= \">=1.0.0\" | "
done

# Update build script with NODE_OPTIONS (from ui_svc_package.go line 24)
BUILD_SCRIPT='export DEBUG=stripes*; export NODE_OPTIONS=\"--max-old-space-size=8000 $NODE_OPTIONS\"; stripes build stripes.config.js --languages en --sourcemap=false --no-minify'
JQ_FILTER+=".scripts.build = \"$BUILD_SCRIPT\""

ui_info "Updating package.json with required modules and build script"

# Apply transformations
jq "$JQ_FILTER" "$PACKAGE_JSON" > "$PACKAGE_JSON.tmp"

# Verify the transformation succeeded
if [[ ! -s "$PACKAGE_JSON.tmp" ]]; then
  ui_error "Failed to update package.json (empty output)"
  rm -f "$PACKAGE_JSON.tmp"
  exit 1
fi

# Replace original with updated version
mv "$PACKAGE_JSON.tmp" "$PACKAGE_JSON"

ui_ok "package.json prepared successfully"
ui_info "Added/verified modules:"
for module in "${MODULES[@]}"; do
  ui_info "  - $module"
done
ui_info "Updated build script with 8GB heap memory"
