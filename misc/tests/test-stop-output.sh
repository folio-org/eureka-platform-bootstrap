#!/usr/bin/env bash
#
# Normal stop output should fold noisy docker compose teardown narration, and
# an empty environment must get an honest no-op instead of fake removal lines.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

stub_bin="$(mktemp -d)"
output_file="$(mktemp)"
trap 'rm -rf "${stub_bin}" "${output_file}"' EXIT

cat >"${stub_bin}/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  compose\ ps\ -aq)
    if [[ -n "${STOP_PS_FAILS:-}" ]]; then
      printf 'Cannot connect to the Docker daemon\n' >&2
      exit 1
    fi
    # Empty output with exit 0 is the real no-container behavior.
    if [[ -n "${STOP_HAS_CONTAINERS:-}" ]]; then
      printf 'cid1\n'
    fi
    exit 0
    ;;
  compose\ down\ --remove-orphans)
    if [[ -z "${STOP_HAS_CONTAINERS:-}" ]]; then
      printf 'unexpected compose down with no containers\n' >&2
      exit 2
    fi
    printf 'Container noisy-service Stopping\n'
    printf 'Container noisy-service Removed\n'
    ;;
  *)
    printf 'unexpected docker call: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "${stub_bin}/docker"

(
  cd "${PROJECT_ROOT}"
  PATH="${stub_bin}:${PATH}" NO_COLOR=1 TERM=dumb STOP_HAS_CONTAINERS=1 ./stop.sh --yes
) >"${output_file}" 2>&1

if grep -q 'Container noisy-service' "${output_file}"; then
  cat "${output_file}" >&2
  fail 'stop.sh leaked normal docker compose teardown output'
fi
grep -q 'Removing containers (volumes kept)' "${output_file}" \
  || { cat "${output_file}" >&2; fail 'stop.sh did not show folded removal step'; }
grep -q 'Containers removed. Volumes kept.' "${output_file}" \
  || { cat "${output_file}" >&2; fail 'stop.sh did not show concise result'; }

# Empty environment: honest no-op — no teardown narration, no compose down call.
(
  cd "${PROJECT_ROOT}"
  PATH="${stub_bin}:${PATH}" NO_COLOR=1 TERM=dumb ./stop.sh --yes
) >"${output_file}" 2>&1

grep -q 'Nothing to stop' "${output_file}" \
  || { cat "${output_file}" >&2; fail 'stop.sh did not report the honest no-op'; }
if grep -Eq 'Containers removed|Removing containers' "${output_file}"; then
  cat "${output_file}" >&2
  fail 'stop.sh printed removal messaging for an empty environment'
fi

# Exited-only stack (ps -aq sees it even though nothing runs) still tears down.
(
  cd "${PROJECT_ROOT}"
  PATH="${stub_bin}:${PATH}" NO_COLOR=1 TERM=dumb STOP_HAS_CONTAINERS=exited ./stop.sh --yes
) >"${output_file}" 2>&1
grep -q 'Containers removed. Volumes kept.' "${output_file}" \
  || { cat "${output_file}" >&2; fail 'exited-only stack was treated as a no-op'; }

# A daemon failure must be a loud error, never a fake clean no-op.
set +e
(
  cd "${PROJECT_ROOT}"
  PATH="${stub_bin}:${PATH}" NO_COLOR=1 TERM=dumb STOP_PS_FAILS=1 ./stop.sh --yes
) >"${output_file}" 2>&1
ps_fail_status=$?
set -e
[[ ${ps_fail_status} -ne 0 ]] || fail 'stop.sh exited 0 when docker compose ps failed'
grep -q 'cannot determine the environment state' "${output_file}" \
  || { cat "${output_file}" >&2; fail 'stop.sh did not report the ps failure'; }
if grep -q 'Nothing to stop' "${output_file}"; then
  cat "${output_file}" >&2
  fail 'stop.sh reported a no-op while the daemon was unreachable'
fi

printf 'ok  stop.sh folds teardown output, no-ops honestly when empty, and fails loudly on ps errors\n'
