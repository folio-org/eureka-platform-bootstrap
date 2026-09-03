#!/usr/bin/env bash
#
# eureka-platform-bootstrap — teardown entrypoint.
#
# Tears down the local FOLIO Eureka environment. Asks two questions:
#   1. Remove containers (stop and delete the stack)?   default: Yes
#   2. Clear volumes (delete db / kafka / vault data)?  default: No
#
# Defaults mirror Docker's own model: `down` (remove containers) is reversible,
# so it defaults on; `--volumes` is destructive, so it defaults off. Clearing
# volumes implies removing containers — a named volume cannot be dropped while a
# container references it.
#
# Teardown runs through the standard docker/compose.yaml project, so
# `down --volumes` removes the named volumes declared in the Compose project
# (db, kafka-data, vault-data) without hardcoding their names.
#
# Every service in the stack is gated behind a Compose profile (core,
# mgr-components, app-platform-minimal). A bare `docker compose down` sees
# an empty default service set and silently no-ops, so teardown must activate
# all profiles. `COMPOSE_PROFILES='*'` is the wildcard form of "all profiles"
# (requires Docker Compose 2.24+, enforced by ./start.sh).
#
# Usage:
#   ./stop.sh [--yes|-y] [--help|-h]

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="${SCRIPT_DIR}"
readonly DOCKER_DIR="${PROJECT_ROOT}/docker"

ASSUME_YES="${ASSUME_YES:-false}"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/misc/lib/folio-common.sh"

usage() {
  cat <<'EOF'
Usage: ./stop.sh [options]

Tears down the local FOLIO Eureka environment.

Options:
  --yes, -y     Assume defaults for prompts (remove containers, keep volumes).
  --help, -h    Show this help and exit.

Prompts (interactive runs only):
  Remove containers (stop and delete the stack)?   [Y/n]  default: Yes
  Clear volumes (DELETES db / kafka / vault data)? [y/N]  default: No
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y)   ASSUME_YES=true; shift ;;
      --help|-h)  usage; exit 0 ;;
      *)          error "Unknown option: $1 (try --help)" ;;
    esac
  done
}

main() {
  parse_args "$@"

  # Defaults: remove containers (reversible), keep volumes (destructive).
  local remove_containers=true
  local clear_volumes=false

  if [[ "${ASSUME_YES}" != true && -t 0 ]]; then
    ui_prompt "Remove containers (stop and delete the stack)?" y || remove_containers=false
    ui_prompt "Clear volumes (DELETES db / kafka / vault data, irreversible)?" n && clear_volumes=true
  fi

  # Clearing volumes requires the containers to be gone first.
  if [[ "${clear_volumes}" == true && "${remove_containers}" != true ]]; then
    remove_containers=true
    ui_warn "Clearing volumes requires removing containers first — removing containers too."
  fi

  if [[ "${remove_containers}" != true && "${clear_volumes}" != true ]]; then
    ui_title "Nothing to do — leaving the environment untouched."
    return 0
  fi

  load_folio_config
  export_descriptor_module_config "${PROJECT_ROOT}/descriptors/app-platform-minimal/descriptor.json"
  cd "${DOCKER_DIR}"

  ui_title "Tearing down the local FOLIO Eureka environment"

  if [[ "${clear_volumes}" == true ]]; then
    COMPOSE_PROFILES='*' ui_run "Removing containers and volumes (db / kafka / vault data will be deleted)" \
      docker compose down --volumes --remove-orphans
    ui_ok "Containers and volumes removed."
  else
    COMPOSE_PROFILES='*' ui_run "Removing containers (volumes kept)" docker compose down --remove-orphans
    ui_ok "Containers removed. Volumes kept."
  fi
}

main "$@"
