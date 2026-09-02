#!/usr/bin/env bash
# FOLIO UI Builder - Main build orchestration script
# Builds Docker image for FOLIO platform-complete UI with environment-based configuration
# Adapted for eureka-platform-bootstrap
set -euo pipefail

START_OUTPUT_MODE="${START_OUTPUT_MODE:-normal}"

# Get script and project directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load utilities
source "$SCRIPT_DIR/folio-ui/utils.sh"

ui_info "===================================================================="
ui_info "FOLIO UI Builder for eureka-platform-bootstrap"
ui_info "===================================================================="

# Load local overrides using the shared config search path.
load_folio_config local

# Default UI build URLs to local browser-facing endpoints unless explicitly set.
# OKAPI_URL is container/module runtime config in docker/.env and must not leak
# into generated browser config.
KONG_URL="${KONG_URL:-${FOLIO_KONG_URL:-http://localhost:8000}}"
KEYCLOAK_URL="${KEYCLOAK_URL:-${FOLIO_KEYCLOAK_URL:-${KEYCLOAK_BASE_URL:-http://localhost:8080}}}"

# Validate required environment variables
validate_required_vars "TENANT_IDS"

# Set defaults for optional variables
PLATFORM_COMPLETE_URL="${PLATFORM_COMPLETE_URL:-http://localhost:3000}"
PLATFORM_COMPLETE_BRANCH="${PLATFORM_COMPLETE_BRANCH:-snapshot}"
# Disposable, agent-owned cache. manage_repository hard-resets it to the upstream
# branch on every run, so anything edited here is discarded — do not keep manual
# changes in it. Lives under misc/.cache/ (gitignored) so the clone never pollutes
# the working tree.
REPO_DIR="${REPO_DIR:-$SCRIPT_DIR/.cache/platform-complete}"
IS_SINGLE_TENANT="${IS_SINGLE_TENANT:-true}"
HAS_ALL_PERMS="${HAS_ALL_PERMS:-false}"
ENABLE_ECS_REQUESTS="${ENABLE_ECS_REQUESTS:-false}"
KC_LOGIN_CLIENT_SUFFIX="${KC_LOGIN_CLIENT_SUFFIX:--login-app}"
FOLIO_UI_IMAGE="${FOLIO_UI_IMAGE:-folioci/folio-ui:latest}"
SKIP_BUILD="${SKIP_BUILD:-false}"
UPDATE_REPO="${UPDATE_REPO:-true}"
UI_PORT="${UI_PORT:-3000}"

# Export variables for subscripts
export KONG_URL KEYCLOAK_URL TENANT_IDS PLATFORM_COMPLETE_URL
export IS_SINGLE_TENANT HAS_ALL_PERMS ENABLE_ECS_REQUESTS KC_LOGIN_CLIENT_SUFFIX
export FOLIO_UI_IMAGE

if [[ "${START_OUTPUT_MODE}" == 'debug' ]]; then
  ui_info "Configuration:"
  ui_info "  Kong URL:           $KONG_URL"
  ui_info "  Keycloak URL:       $KEYCLOAK_URL"
  ui_info "  Platform URL:       $PLATFORM_COMPLETE_URL"
  ui_info "  Branch:             $PLATFORM_COMPLETE_BRANCH"
  ui_info "  Tenant(s):          $TENANT_IDS"
  ui_info "  Single Tenant Mode: $IS_SINGLE_TENANT"
  ui_info "  Repository:         $REPO_DIR"
  ui_info "  Image:              $FOLIO_UI_IMAGE"
  ui_info ""
fi

# Step 1: Clone or update platform-complete repository
ui_info "Step 1/4: Managing platform-complete repository"
ui_info "--------------------------------------------------------------------"
manage_repository \
  "https://github.com/folio-org/platform-complete.git" \
  "$REPO_DIR" \
  "$PLATFORM_COMPLETE_BRANCH" \
  "$UPDATE_REPO"
ui_info ""

# Step 2: Prepare stripes.config.js
ui_info "Step 2/4: Preparing stripes configuration"
ui_info "--------------------------------------------------------------------"
"$SCRIPT_DIR/folio-ui/prepare-stripes-config.sh" "$REPO_DIR"
ui_info ""

# Step 3: Prepare package.json
ui_info "Step 3/4: Preparing package.json"
ui_info "--------------------------------------------------------------------"
"$SCRIPT_DIR/folio-ui/prepare-package-json.sh" "$REPO_DIR"
ui_info ""

# Step 4: Build Docker image
if [[ "$SKIP_BUILD" == "true" ]]; then
  ui_warn "Skipping Docker build (SKIP_BUILD=true)"
  ui_ok "Repository prepared at: $REPO_DIR"
  ui_info "You can now:"
  ui_info "  1. Review the generated configuration in $REPO_DIR/stripes.config.js"
  ui_info "  2. Build manually with: docker build -f $REPO_DIR/docker/Dockerfile $REPO_DIR"
else
  ui_info "Step 4/4: Building Docker image"
  ui_info "--------------------------------------------------------------------"

  # Get primary tenant (first in comma-separated list)
  PRIMARY_TENANT=$(echo "$TENANT_IDS" | cut -d',' -f1)

  if [[ "${START_OUTPUT_MODE}" == 'debug' ]]; then
    ui_info "Building image with:"
    ui_info "  OKAPI_URL:  $KONG_URL"
    ui_info "  TENANT_ID:  $PRIMARY_TENANT"
    ui_info ""
  fi
  ui_warn "This may take 10-15 minutes on first build (downloading dependencies)"

  # Build Docker args
  BUILD_ARGS=(
    --build-arg OKAPI_URL="$KONG_URL"
    --build-arg TENANT_ID="$PRIMARY_TENANT"
    --tag "$FOLIO_UI_IMAGE"
    --file "$REPO_DIR/docker/Dockerfile"
  )

  if [[ "${START_OUTPUT_MODE}" == 'debug' ]]; then
    BUILD_ARGS+=(--progress=plain)
  fi

  # Only force clean build if explicitly requested
  if [[ "${FORCE_REBUILD:-false}" == "true" ]]; then
    BUILD_ARGS+=(--no-cache)
    ui_info "Force rebuild enabled (FORCE_REBUILD=true)"
  fi

  docker build "${BUILD_ARGS[@]}" "$REPO_DIR"

  ui_ok "Docker image built: $FOLIO_UI_IMAGE"

  # Show image info
  IMAGE_SIZE=$(docker images "$FOLIO_UI_IMAGE" --format "{{.Size}}")
  ui_info "Image size: $IMAGE_SIZE"
  ui_info ""
fi

# Final summary
ui_info "===================================================================="
ui_ok "Build process completed successfully!"
ui_info "===================================================================="

if [[ "$SKIP_BUILD" != "true" ]]; then
  ui_info "  Access UI at: http://localhost:$UI_PORT"
  ui_info "  Default credentials: folio / folio"
fi
