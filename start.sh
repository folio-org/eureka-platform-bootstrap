#!/usr/bin/env bash
#
# eureka-platform-bootstrap — bootstrap entrypoint.
#
# Brings up the bundled local FOLIO Eureka app-platform-minimal environment:
# prepares config, starts core + manager + application services,
# registers the descriptor, creates tenant `diku` and a default `folio/folio`
# admin user, then runs a short smoke check.
#
# This script is intentionally thin: it parses arguments, asks a couple of
# questions, checks tools, and runs the bootstrap flow. The actual logic lives in
# focused libraries:
#   misc/lib/folio-common.sh   logging, config loading, output helpers
#   misc/lib/folio-api.sh      tokens, registration, entitlement, smoke check
#   misc/lib/docker-health.sh  container / route readiness waits
#   misc/bootstrap-engine.sh   phase orchestration (run_bootstrap_flow)
#
# Usage:
#   ./start.sh [--actualize [--pre-release]] [--native-sidecar]
#              [--apisix] [--yes] [--debug]

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="${SCRIPT_DIR}"
readonly DOCKER_DIR="${PROJECT_ROOT}/docker"
readonly DEFAULT_APP_DESCRIPTOR_PATH="${PROJECT_ROOT}/descriptors/app-platform-minimal/descriptor.json"

# Configuration (repo-defined descriptor, then flags/prompts for runtime choices).
APP_DESCRIPTOR_PATH="${APP_DESCRIPTOR_PATH:-${DEFAULT_APP_DESCRIPTOR_PATH}}"
APP_DISCOVERY_PATH=""
SIDECAR_MODE="${SIDECAR_MODE:-jvm}"
BUILD_ARM_IMAGES="${BUILD_ARM_IMAGES:-false}"
ACTUALIZE_MODULES="${ACTUALIZE_MODULES:-false}"
PRE_RELEASE_MODE="${PRE_RELEASE_MODE:-false}"
APIGW_TYPE="${APIGW_TYPE:-kong}"
export DEBUG="${DEBUG:-false}"
ASSUME_YES="${ASSUME_YES:-false}"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/misc/lib/folio-common.sh"
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/misc/bootstrap-engine.sh"

usage() {
  ui_note "$(cat <<EOF
Usage: $0 [options]

Options:
  --actualize        Refresh module versions from the FOLIO registry first
  --pre-release      With --actualize, select latest SNAPSHOT versions
  --native-sidecar   Use the native folio-module-sidecar image; the pipeline builds
                     it (GraalVM native binary in a lightweight image) if it is missing
  --rebuild-native-sidecar
                     Force a fresh native sidecar build (implies --native-sidecar)
  --apisix           Use Apache APISIX as the API gateway instead of Kong
                     (equivalent to APIGW_TYPE=apisix)
  --yes, -y          Assume "yes" for prompts (non-interactive)
  --debug            Stream all helper output instead of folding it
  -h, --help         Show this help

Keycloak runs as a single node by default. To scale the cluster, uncomment the
keycloak-sN services in docker/docker-compose.keycloak.yml and the matching
upstreams in docker/nginx/keycloak-nginx.conf, then rerun - health waiting is
dynamic and adapts automatically.
EOF
)"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --actualize)      ACTUALIZE_MODULES=true; shift ;;
      --pre-release)    PRE_RELEASE_MODE=true; shift ;;
      --native-sidecar) SIDECAR_MODE=native; shift ;;
      --rebuild-native-sidecar) SIDECAR_MODE=native; REBUILD_NATIVE_SIDECAR=true; shift ;;
      --apisix)         APIGW_TYPE=apisix; shift ;;
      --yes|-y)         ASSUME_YES=true; shift ;;
      --debug)          DEBUG=true; shift ;;
      -h|--help)        usage; exit 0 ;;
      *)
        ui_error "Unknown argument: $1"
        ui_note ''
        usage
        exit 1
        ;;
    esac
  done

  if [[ "${PRE_RELEASE_MODE}" == true && "${ACTUALIZE_MODULES}" != true ]]; then
    ui_error '--pre-release requires --actualize.'
    exit 1
  fi
}

# On ARM hosts (Apple Silicon), the published folioci/* images are amd64-only and
# would run under emulation — turning ~8s startups into ~800s and hanging the
# environment. So we always build native arm64 images here instead of emulating.
# The build itself is idempotent (already-native images are skipped), so forcing
# this on is cheap on warm re-runs.
select_architecture_build() {
  local arch
  arch="$(uname -m)"
  if [[ "${arch}" == arm64 || "${arch}" == aarch64 ]]; then
    BUILD_ARM_IMAGES=true
  fi
}

# Ask the few questions master-style: only when interactive and not preset.
run_prompts() {
  if [[ "${ASSUME_YES}" == true || ! -t 0 ]]; then
    return 0
  fi

  if [[ "${ACTUALIZE_MODULES}" != true ]]; then
    if ui_prompt "Actualize module versions from the FOLIO registry?" n; then
      ACTUALIZE_MODULES=true
      ui_prompt "Use latest SNAPSHOT (pre-release) versions?" n && PRE_RELEASE_MODE=true
    fi
  fi

  # Only ask if native wasn't already requested via --native-sidecar /
  # --rebuild-native-sidecar. JVM stays the default; native is built in-pipeline if
  # the image is missing (a one-time 5-10 min GraalVM build).
  if [[ "${SIDECAR_MODE}" != native ]]; then
    ui_prompt "Use the native folio-module-sidecar image (built if missing, GraalVM)?" n \
      && SIDECAR_MODE=native
  fi

  # Only ask if not already set via --apisix or APIGW_TYPE env var. Kong is the
  # default; APISIX is the emerging replacement (see DR-000045).
  if [[ "${APIGW_TYPE}" != apisix ]]; then
    ui_prompt "Use Apache APISIX instead of Kong as API gateway?" n \
      && APIGW_TYPE=apisix
  fi

  # Always succeed: the trailing `ui_prompt && ...` above returns non-zero when the
  # user declines, which under `set -e` would abort the whole run.
  return 0
}

check_tools() {
  local cmd python_version java_version compose_version compose_major compose_minor
  local required=(docker python3 java mvn jq curl)

  ui_step 'Checking required tools'
  for cmd in "${required[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      ui_error "Command \"${cmd}\" not found. Please install it before proceeding."
      exit 1
    fi
  done

  compose_version="$(docker compose version --short 2>/dev/null || true)"
  compose_version="${compose_version#v}"
  if [[ ! "${compose_version}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    ui_error 'Docker Compose 2.24+ is required (the "docker compose" subcommand).'
    exit 1
  fi
  IFS=. read -r compose_major compose_minor _ <<< "${compose_version}"
  if (( compose_major < 2 || (compose_major == 2 && compose_minor < 24) )); then
    ui_error "Docker Compose 2.24+ is required (found ${compose_version})."
    exit 1
  fi

  python_version="$(python3 --version 2>&1 | awk '{print $2}')"
  if [[ "$(printf '%s\n3.10\n' "$python_version" | sort -V | head -n1)" != '3.10' ]]; then
    ui_error "Python 3.10 or higher is required (found ${python_version})."
    exit 1
  fi

  java_version="$(java -version 2>&1 | awk -F '"' '/version/ {print $2}')"
  if [[ "${java_version%%.*}" -lt 17 ]]; then
    ui_error "Java 17 or higher is required (found ${java_version})."
    exit 1
  fi

  ui_ok 'Required tools present'
}

main() {
  parse_args "$@"
  select_architecture_build

  APP_DESCRIPTOR_PATH="$(resolve_absolute_path "${APP_DESCRIPTOR_PATH}")"
  APP_DISCOVERY_PATH="$(dirname "${APP_DESCRIPTOR_PATH}")/discovery.json"

  if [[ ! -r "${APP_DESCRIPTOR_PATH}" ]]; then
    ui_error "Application descriptor not found or not readable: ${APP_DESCRIPTOR_PATH}"
    exit 1
  fi

  # Identity banner on top, then everything up to the bootstrap proper runs inside a
  # first "Configure" phase: the interactive decisions render as branches off its
  # gutter, and the tool/host preflight lines nest under it instead of floating
  # unattached. run_bootstrap_flow's first phase closes Configure and continues at 02.
  print_run_banner
  # Start the run clock as the first phase opens, so the completion box's total spans
  # every numbered phase (01 Configure included), not just phase 02 onward.
  ui_timer_start run_total
  ui_phase 'Configure'
  run_prompts
  check_tools
  # Preflight: warn early about host readiness (Docker memory, busy ports) so a
  # bad host surfaces a clear cause here, not a confusing failure mid-bootstrap.
  preflight_host
  # Preflight: settle the sudo-requiring /etc/hosts aliases up front, before any
  # long-running step, so an interactive run prompts here (not mid-bootstrap) and
  # a non-interactive run never blocks on a hidden password prompt.
  ensure_host_entries
  # Surface the resolved run choices (sidecar runtime, module actualization) that the
  # banner can no longer show, since it prints before these prompts settle.
  print_run_mode
  load_app_metadata
  run_bootstrap_flow
}

main "$@"
