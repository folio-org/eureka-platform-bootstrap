#!/usr/bin/env bash
#
# Hermetic proof that select_sidecar_resources derives the sidecar resource
# envelope from SIDECAR_MODE: native mode lowers the memory limit and blanks the
# (inert) JAVA_OPTIONS, JVM mode leaves the compose defaults in place, and an
# operator override always wins.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DOCKER_DIR="${PROJECT_ROOT}/docker"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Source the libraries the engine needs, then the engine itself, in a quiet,
# side-effect-free way (we only call the one function under test).
DEBUG=false
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/misc/lib/folio-common.sh"
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/misc/bootstrap-engine.sh"

# Case 1: native mode, no operator override -> leaner memory + blank JAVA_OPTIONS.
(
  SIDECAR_MODE=native
  unset SIDECAR_MEMORY_LIMIT SIDECAR_JAVA_OPTIONS
  select_sidecar_resources
  [[ "${SIDECAR_MEMORY_LIMIT:-}" == "${NATIVE_SIDECAR_MEMORY_LIMIT}" ]] \
    || fail "native mode did not lower memory limit (got '${SIDECAR_MEMORY_LIMIT:-<unset>}')"
  # Must be set-but-empty so the compose '-' fallback passes it through.
  [[ -z "${SIDECAR_JAVA_OPTIONS+x}" ]] && fail "native mode left JAVA_OPTIONS unset (compose would re-apply JVM default)"
  [[ -z "${SIDECAR_JAVA_OPTIONS}" ]] || fail "native mode did not blank JAVA_OPTIONS (got '${SIDECAR_JAVA_OPTIONS}')"
) || exit 1

# Case 2: native mode, operator override -> both values preserved.
(
  SIDECAR_MODE=native
  SIDECAR_MEMORY_LIMIT=512m
  SIDECAR_JAVA_OPTIONS='-Xmx256m'
  select_sidecar_resources
  [[ "${SIDECAR_MEMORY_LIMIT}" == "512m" ]] || fail "native mode overrode operator memory limit"
  [[ "${SIDECAR_JAVA_OPTIONS}" == "-Xmx256m" ]] || fail "native mode overrode operator JAVA_OPTIONS"
) || exit 1

# Case 3: JVM mode -> function is a no-op; compose defaults stay in force.
(
  SIDECAR_MODE=jvm
  unset SIDECAR_MEMORY_LIMIT SIDECAR_JAVA_OPTIONS
  select_sidecar_resources
  [[ -z "${SIDECAR_MEMORY_LIMIT:-}" ]] || fail "JVM mode unexpectedly set memory limit"
  [[ -z "${SIDECAR_JAVA_OPTIONS+x}" ]] || fail "JVM mode unexpectedly set JAVA_OPTIONS"
) || exit 1

printf 'ok  select_sidecar_resources derives the sidecar envelope from SIDECAR_MODE\n'
