#!/usr/bin/env bash
#
# Normal stop output should fold noisy docker compose teardown narration.

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
  compose\ down\ --remove-orphans)
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
  PATH="${stub_bin}:${PATH}" NO_COLOR=1 TERM=dumb ./stop.sh --yes
) >"${output_file}" 2>&1

if grep -q 'Container noisy-service' "${output_file}"; then
  cat "${output_file}" >&2
  fail 'stop.sh leaked normal docker compose teardown output'
fi
grep -q 'Removing containers (volumes kept)' "${output_file}" \
  || { cat "${output_file}" >&2; fail 'stop.sh did not show folded removal step'; }
grep -q 'Containers removed. Volumes kept.' "${output_file}" \
  || { cat "${output_file}" >&2; fail 'stop.sh did not show concise result'; }

printf 'ok  stop.sh folds normal compose teardown output\n'
