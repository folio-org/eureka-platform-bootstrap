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
  compose\ ps\ -qq)
    [[ -n "${STOP_HAS_CONTAINERS:-}" ]] && printf 'cid1\n'
    ;;
  compose\ down\ --remove-orphans)
    if [[ -z "${STOP_HAS_CONTAINERS:-}" ]]; then
      printf 'unexpected compose down on an empty environment\n' >&2
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

printf 'ok  stop.sh folds teardown output and no-ops honestly on an empty environment\n'
