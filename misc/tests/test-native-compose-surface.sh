#!/usr/bin/env bash
#
# The runtime lifecycle must use Docker Compose directly through the standard
# docker/compose.yaml manifest. No repository-specific Compose CLI wrappers are
# part of the supported surface.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DOCKER_DIR="${PROJECT_ROOT}/docker"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

manifest="${DOCKER_DIR}/compose.yaml"
[[ -f "${manifest}" ]] || fail 'docker/compose.yaml is missing'

for file in \
  docker-compose.core.yml \
  docker-compose.keycloak.yml \
  docker-compose.mgmt.yml \
  docker-compose.minimal.module.yml \
  docker-compose.minimal.sidecar.yml; do
  grep -Fq -- "- path: ${file}" "${manifest}" \
    || fail "compose manifest does not include ${file}"
done

grep -q '^COMPOSE_PROJECT_NAME=folio-platform-minimal$' "${DOCKER_DIR}/.env" \
  || fail 'Compose project name is no longer declared in docker/.env'

grep -Fq 'Docker Compose 2.24+ is required' "${PROJECT_ROOT}/start.sh" \
  || fail 'start.sh does not enforce the Compose include minimum version'
grep -Fq 'docker compose --profile core --profile "${GATEWAY_PROFILE}" up -d' "${PROJECT_ROOT}/misc/bootstrap-engine.sh" \
  || fail 'bootstrap no longer starts core through native Compose'
grep -Fq 'docker compose down --remove-orphans' "${PROJECT_ROOT}/stop.sh" \
  || fail 'stop.sh does not tear down through native Compose'

kong_manifest="${DOCKER_DIR}/docker-compose.kong.yml"
[[ -f "${kong_manifest}" ]] || fail 'docker/docker-compose.kong.yml is missing'
grep -Fq 'APIGW_URL: http://api-gateway:8001' "${kong_manifest}" \
  || fail 'kong gateway compose no longer provides APIGW_URL to the mgr services'
grep -Fq 'KONG_ADMIN_URL: http://api-gateway:8001' "${kong_manifest}" \
  || fail 'kong gateway compose lost the KONG_ADMIN_URL transition alias for pre-rename mgr images'

printf 'ok  native Compose surface has no repository-specific lifecycle wrappers\n'
