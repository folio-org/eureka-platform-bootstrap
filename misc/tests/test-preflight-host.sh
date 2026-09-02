#!/usr/bin/env bash
#
# Hermetic proof for the host preflight checks in misc/bootstrap-engine.sh:
# check_docker_memory warns below the threshold and stays silent at/above it or
# on an unreadable value; check_host_ports warns only for a port held by a
# non-Docker process (a warm re-run of our own stack must not raise a false
# alarm). No real Docker, no real listener: docker is stubbed on PATH and the
# port predicates are redefined after sourcing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

DEBUG=false
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/misc/lib/folio-common.sh"
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/misc/bootstrap-engine.sh"

stub_bin="$(mktemp -d)"
trap 'rm -rf "${stub_bin}"' EXIT

# Stubbed docker: `info --format` echoes whatever DOCKER_MEM_BYTES holds.
cat > "${stub_bin}/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "info" ]]; then
  printf '%s\n' "${DOCKER_MEM_BYTES:-}"
  exit 0
fi
exit 0
EOF
chmod +x "${stub_bin}/docker"
export PATH="${stub_bin}:${PATH}"

# --- check_docker_memory -----------------------------------------------------
GB=$(( 1024 * 1024 * 1024 ))

# Case 1: below threshold -> warns.
out="$( DOCKER_MEM_BYTES=$(( 4 * GB )) MIN_DOCKER_MEMORY_GB=12 check_docker_memory 2>&1 )"
[[ "${out}" == *recommended* ]] \
  || fail "low memory did not warn (got '${out}')"

# Case 2: at/above threshold -> silent.
out="$( DOCKER_MEM_BYTES=$(( 16 * GB )) MIN_DOCKER_MEMORY_GB=12 check_docker_memory 2>&1 )"
[[ -z "${out}" ]] || fail "sufficient memory unexpectedly warned (got '${out}')"

# Case 3: unreadable value -> silent (no guess).
out="$( DOCKER_MEM_BYTES='' MIN_DOCKER_MEMORY_GB=12 check_docker_memory 2>&1 )"
[[ -z "${out}" ]] || fail "unreadable memory unexpectedly warned (got '${out}')"

# --- check_host_ports --------------------------------------------------------
# Case 4: only 8000 open and NOT held by docker -> warns about 8000 alone.
# (The static hint text names both ports, so assert on the busy list, not the
# whole message.)
out="$({
  host_port_in_use() { [[ "$1" == 8000 ]]; }
  host_port_held_by_docker() { return 1; }
  HOST_REQUIRED_PORTS='8000 8080' check_host_ports
} 2>&1)"
busy_line="$(printf '%s\n' "${out}" | head -n1)"
[[ "${busy_line}" == *"in use"* ]] || fail "foreign port holder did not warn (got '${out}')"
busy_ports="${busy_line#*process: }"
busy_ports="${busy_ports%% (*}"
[[ "${busy_ports}" == "8000" ]] || fail "expected only 8000 busy, got '${busy_ports}'"

# Case 5: port open but held by docker (warm re-run) -> silent.
out="$({
  host_port_in_use() { return 0; }
  host_port_held_by_docker() { return 0; }
  HOST_REQUIRED_PORTS='8000 8080' check_host_ports
} 2>&1)"
[[ -z "${out}" ]] || fail "our own stack's port raised a false alarm (got '${out}')"

printf 'ok  preflight_host warns on low Docker memory and foreign port holders only\n'
