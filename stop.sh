#!/usr/bin/env bash
#
# eureka-platform-bootstrap — teardown entrypoint.
#
# Tears down the local FOLIO Eureka environment. Asks two questions:
#   1. Remove containers (stop and delete the stack)?   default: Yes
#   2. Clear volumes (delete all project data)?         default: No
#
# Defaults mirror Docker's own model: `down` (remove containers) is reversible,
# so it defaults on; clearing volumes is destructive, so it defaults off.
# Clearing volumes implies removing containers — a named volume cannot be
# dropped while a container references it.
#
# Volume clearing is gateway-independent: the selected gateway is session-local
# (a later plain ./stop.sh may default to the Kong model while the previous run
# used APISIX), so `compose down --volumes` against the active model could miss
# volumes declared only in the other gateway's file (APISIX's etcd-data).
# Volumes are therefore discovered by the Compose project label
# (com.docker.compose.project) and removed by name — every volume this project
# owns, regardless of which gateway model declared it, and even when the
# containers are already gone. Volumes without the project label are never
# touched.
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
  Remove containers (stop and delete the stack)?       [Y/n]  default: Yes
  Clear volumes (DELETES all project data volumes)?    [y/N]  default: No
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

# Remove every named volume belonging to this Compose project, discovered via
# the Compose project label rather than by name. This catches volumes declared
# only in the gateway file that is NOT part of the active Compose model (APISIX
# etcd-data under a Kong teardown and vice versa) as well as volumes left after
# the containers are already gone. Unrelated volumes never carry this label.
clear_project_volumes() {
  local project="${COMPOSE_PROJECT_NAME:-folio-platform-minimal}"
  local volumes volume_count

  if ! volumes="$(docker volume ls -q --filter "label=com.docker.compose.project=${project}" 2>/dev/null)"; then
    ui_error 'docker volume ls failed; cannot discover project volumes (is Docker running?).'
    return 1
  fi

  if [[ -z "${volumes}" ]]; then
    ui_ok 'No project volumes present.'
    return 0
  fi

  volume_count="$(printf '%s\n' "${volumes}" | grep -c .)"
  # shellcheck disable=SC2086  # Compose volume names cannot contain spaces
  ui_run "Removing ${volume_count} project volume(s) (${project})" docker volume rm ${volumes}
}

main() {
  parse_args "$@"

  # Defaults: remove containers (reversible), keep volumes (destructive).
  # STOP_CLEAR_VOLUMES is a non-interactive seam for hermetic tests (same
  # pattern as HEALTH_WAIT_TIMEOUT_SECONDS): it cannot be answered through a
  # prompt when stdin is not a tty.
  local remove_containers=true
  local clear_volumes="${STOP_CLEAR_VOLUMES:-false}"

  if [[ "${ASSUME_YES}" != true && -t 0 ]]; then
    ui_prompt "Remove containers (stop and delete the stack)?" y || remove_containers=false
    ui_prompt "Clear volumes (DELETES all project data volumes, irreversible)?" n && clear_volumes=true
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

  # Include the active gateway Compose file so COMPOSE_PROFILES='*' covers the
  # gateway service (gw-kong or gw-apisix) when tearing down. Container removal
  # also covers the other gateway's containers via --remove-orphans, and volume
  # removal below is gateway-independent.
  APIGW_TYPE="${APIGW_TYPE:-kong}"
  export COMPOSE_FILE="${DOCKER_DIR}/compose.yaml:${DOCKER_DIR}/docker-compose.${APIGW_TYPE}.yml"

  cd "${DOCKER_DIR}"

  # Honest no-op: skip the teardown narration only when the project has no
  # containers in ANY state (running or exited — `ps` defaults to running
  # only, and a crashed stack still deserves a real down). A clear-volumes
  # request is never a no-op: named project volumes outlive containers, so
  # they must still be discovered and removed. The ps status is captured
  # separately: a daemon failure is an error, never a clean no-op.
  local ps_output ps_status
  ps_output="$(COMPOSE_PROFILES='*' docker compose ps -aq 2>/dev/null)" && ps_status=0 || ps_status=$?
  if [[ ${ps_status} -ne 0 ]]; then
    ui_error 'docker compose ps failed; cannot determine the environment state (is Docker running?).'
    return 1
  fi
  if [[ -z "${ps_output}" && "${clear_volumes}" != true ]]; then
    ui_title "Nothing to stop — the environment is not running."
    return 0
  fi

  ui_title "Tearing down the local FOLIO Eureka environment"

  if [[ -n "${ps_output}" ]]; then
    if [[ "${clear_volumes}" == true ]]; then
      COMPOSE_PROFILES='*' ui_run "Removing containers (project volumes removed next)" \
        docker compose down --remove-orphans
    else
      COMPOSE_PROFILES='*' ui_run "Removing containers (volumes kept)" docker compose down --remove-orphans
      ui_ok "Containers removed. Volumes kept."
      return 0
    fi
  else
    ui_ok 'No containers present.'
  fi

  clear_project_volumes
  ui_ok "Containers and project volumes removed."
}

main "$@"
