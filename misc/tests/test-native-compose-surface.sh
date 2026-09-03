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

for removed in \
  docker/dc.sh \
  docker/start-docker-containers.sh \
  docker/set-local-credentials.sh \
  docker/set-default-local-credentials.sh \
  docker/misc/get-vault-token.sh \
  docker/misc/populate-vault-token.sh \
  docker/docker-compose.ui.yml \
  misc/build-folio-ui.sh \
  misc/folio-ui \
  misc/configure-ui-redirect.sh; do
  [[ ! -e "${PROJECT_ROOT}/${removed}" ]] || fail "removed path still present: ${removed}"
done

grep -q '^COMPOSE_PROJECT_NAME=folio-platform-minimal$' "${DOCKER_DIR}/.env" \
  || fail 'Compose project name is no longer declared in docker/.env'
if grep -q '^COMPOSE_PATH_SEPARATOR=' "${DOCKER_DIR}/.env"; then
  fail 'docker/.env still configures the removed COMPOSE_FILE wrapper path'
fi

grep -Fq 'Docker Compose 2.24+ is required' "${PROJECT_ROOT}/start.sh" \
  || fail 'start.sh does not enforce the Compose include minimum version'
grep -Fq 'docker compose --profile core up -d' "${PROJECT_ROOT}/misc/bootstrap-engine.sh" \
  || fail 'bootstrap no longer starts core through native Compose'
grep -Fq 'docker compose down --remove-orphans' "${PROJECT_ROOT}/stop.sh" \
  || fail 'stop.sh does not tear down through native Compose'

if git -C "${PROJECT_ROOT}" grep -n -F \
  -e './dc.sh' \
  -e 'start-docker-containers.sh' \
  -e 'set-default-local-credentials.sh' \
  -e 'set-local-credentials.sh' \
  -e 'get-vault-token.sh' \
  -e 'populate-vault-token.sh' \
  -- \
  . \
  ':(exclude)misc/tests/test-native-compose-surface.sh' >/dev/null; then
  fail 'tracked runtime/docs references to removed wrappers remain'
fi

printf 'ok  native Compose surface has no repository-specific lifecycle wrappers\n'
