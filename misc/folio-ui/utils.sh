#!/usr/bin/env bash
# Utility functions for FOLIO UI Builder
# Adapted for eureka-platform-bootstrap

UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${UTILS_DIR}/../.." && pwd)"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/misc/lib/folio-common.sh"

START_OUTPUT_MODE="${START_OUTPUT_MODE:-normal}"

run_ui_helper() {
  if [[ "${START_OUTPUT_MODE}" == 'debug' ]]; then
    "$@"
    return 0
  fi

  "$@" >/dev/null
}

validate_required_vars() {
  local missing=()
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("$var")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    ui_error "Missing required environment variables: ${missing[*]}"
    ui_error "Please set them in .env.local, a supported config path, or the shell environment"
    exit 1
  fi
}

# Manage the platform-complete cache clone. NOTE: repo_dir is a disposable,
# agent-owned cache. When should_update is true this hard-resets it to
# origin/<branch>, discarding any local changes — never store manual edits here.
manage_repository() {
  local repo_url="$1"
  local repo_dir="$2"
  local branch="$3"
  local should_update="$4"

  mkdir -p "$(dirname "$repo_dir")"

  if [[ -d "$repo_dir/.git" ]]; then
    if [[ "$should_update" == "true" ]]; then
      ui_info "Updating existing repository at $repo_dir"
      (
        cd "$repo_dir"
        run_ui_helper git fetch origin
        run_ui_helper git checkout "$branch"
        run_ui_helper git reset --hard "origin/$branch"
      )
      ui_ok "Repository updated to branch: $branch"
    else
      ui_info "Using existing repository at $repo_dir (skipping update)"
      (
        cd "$repo_dir"
        run_ui_helper git checkout "$branch" 2>/dev/null || ui_warn "Branch $branch not found, using current branch"
      )
    fi
  else
    ui_info "Cloning repository to $repo_dir"
    run_ui_helper git clone --branch "$branch" "$repo_url" "$repo_dir"
    ui_ok "Repository cloned: $repo_url (branch: $branch)"
  fi
}
