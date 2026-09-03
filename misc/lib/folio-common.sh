#!/usr/bin/env bash
# FOLIO Common Library
#
# Shared configuration and dependency checks for the bootstrap scripts.
#
# Source it with:
#   source "${SCRIPT_DIR}/lib/folio-common.sh"

# Idempotent include guard (re-sourcing must not re-declare readonly constants).
[[ -n "${_FOLIO_COMMON_SOURCED:-}" ]] && return 0
readonly _FOLIO_COMMON_SOURCED=1

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ui.sh"

error() {
  ui_error "$*"
  exit 1
}

################################################################################
# Configuration loading
#
# Loads config from docker/.env.local.credentials, docker/.env.local, and
# docker/.env (resolved relative to this library, so it works from any working
# directory). Values already present in the shell environment are preserved.
################################################################################

FOLIO_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FOLIO_DOCKER_DIR="${FOLIO_REPO_ROOT}/docker"

# Effective precedence (highest wins):
#   shell environment  >  .env.local.credentials  >  .env.local  >  .env
#
# Files are loaded highest-precedence first, then lower-precedence defaults.
# Precedence is NOT "last file wins": _source_env_file_preserving_environment
# protects values already present in the environment, so once credentials/local
# are sourced their values survive the later docker/.env source. Shell values set
# before the first load survive all files.
#
# Usage:
#   load_folio_config            # credentials, local, and defaults
#   load_folio_config credentials
#   load_folio_config local
#   load_folio_config defaults
load_folio_config() {
  local config_type="${1:-all}"
  local files=()

  case "$config_type" in
    credentials) files=(".env.local.credentials") ;;
    local)       files=(".env.local") ;;
    defaults)    files=(".env") ;;
    all)         files=(".env.local.credentials" ".env.local" ".env") ;;
    *)
      ui_error "Unknown config type: ${config_type} (use: all, credentials, local, defaults)"
      return 1
      ;;
  esac

  local file full_path
  for file in "${files[@]}"; do
    full_path="${FOLIO_DOCKER_DIR}/${file}"
    if [[ -r "$full_path" ]]; then
      [[ "${VERBOSE:-false}" == true ]] && ui_info "[VERBOSE] Loading config: ${full_path}"
      _source_env_file_preserving_environment "$full_path"
    else
      [[ "${VERBOSE:-false}" == true ]] && ui_info "[VERBOSE] Config file not found: ${full_path}"
    fi
  done

  return 0
}

export_descriptor_module_config() {
  local descriptor_path="$1"
  local line assignment name value

  [[ -n "${descriptor_path}" ]] || return 0
  [[ -r "${descriptor_path}" ]] || return 0

  while IFS= read -r line; do
    [[ "${line}" == export\ *=* ]] || continue
    assignment="${line#export }"
    name="${assignment%%=*}"
    value="${assignment#*=}"
    [[ -n "${name}" ]] || continue

    if [[ ${!name+_} != _ ]]; then
      export "${name}=${value}"
    fi
  done < <(python3 "${FOLIO_REPO_ROOT}/misc/docker-module-updater/run.py" --app "${descriptor_path}" --module-env)
}

# Source a shell-compatible env file without overriding values already present in
# the current shell environment. It records the pre-source value of every var the
# file would set that is already in the environment, sources the file, then
# restores those recorded values. Because each earlier-loaded file's values are in
# the environment by the time the next file is sourced, earlier files (and the
# original shell environment) win — this is how credentials beats local without
# loading credentials last.
_source_env_file_preserving_environment() {
  local file_path="$1"
  local existing_vars_file

  existing_vars_file="$(mktemp)"

  while IFS='=' read -r name _; do
    [[ -z "$name" ]] && continue
    name="${name#export }"
    name="${name%%[[:space:]]*}"
    [[ -z "$name" ]] && continue

    # Indirect parameter expansion instead of `[[ -v ... ]]` keeps this loader
    # compatible with Bash 3.2 on macOS and other older Bash environments.
    if [[ ${!name+_} == _ ]]; then
      printf '%s=%q\n' "$name" "${!name}" >> "$existing_vars_file"
    fi
  done < <(grep -E '^(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "$file_path" || true)

  set -a
  # shellcheck source=/dev/null
  source "$file_path"
  set +a

  if [[ -s "$existing_vars_file" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$existing_vars_file"
    set +a
  fi

  rm -f "$existing_vars_file"
}

################################################################################
# Dependency checking
################################################################################

# check_dependencies curl jq    # checks the named commands
# check_dependencies            # defaults to curl and jq
check_dependencies() {
  local deps=("$@")
  [[ ${#deps[@]} -eq 0 ]] && deps=(curl jq)

  local missing=()
  local cmd
  for cmd in "${deps[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing required commands: ${missing[*]}"
  fi
}
