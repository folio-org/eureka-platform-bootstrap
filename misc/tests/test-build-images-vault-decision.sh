#!/usr/bin/env bash
#
# Hermetic checks for misc/build-images.sh Vault image decision output.
# No real Docker or network: docker and shasum are stubbed on PATH.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

stub_bin="$(mktemp -d)"
output_file="$(mktemp)"
trap 'rm -rf "${stub_bin}" "${output_file}"' EXIT

previous_hash="$(<"${PROJECT_ROOT}/misc/vault/.build-context.sha256")"

cat >"${stub_bin}/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  'image inspect --format {{.Architecture}} folio-vault:1.13.3')
    printf 'arm64\n'
    ;;
  'image inspect folio-vault:1.13.3')
    exit 0
    ;;
  build\ -t\ folio-vault:1.13.3\ *)
    printf 'stub docker build failed while loading metadata\n' >&2
    exit 17
    ;;
  *)
    printf 'unexpected docker call: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "${stub_bin}/docker"

cat >"${stub_bin}/shasum" <<'EOF'
#!/usr/bin/env bash
while IFS= read -r _line; do :; done
printf '%s  -\n' "${STUB_HASH:?}"
EOF
chmod +x "${stub_bin}/shasum"

set +e
(
  cd "${PROJECT_ROOT}"
  PATH="${stub_bin}:${PATH}" STUB_HASH='changed-context-hash' bash misc/build-images.sh
) >"${output_file}" 2>&1
status=$?
set -e

[[ ${status} -ne 0 ]] || fail 'changed Vault context build unexpectedly succeeded'
grep -q 'Vault image decision: local=present arch=arm64 context=changed action=rebuild' "${output_file}" \
  || { cat "${output_file}" >&2; fail 'changed-context decision line missing'; }
grep -q 'Vault support image rebuild failed.' "${output_file}" \
  || { cat "${output_file}" >&2; fail 'operator rebuild failure explanation missing'; }
grep -q 'stub docker build failed while loading metadata' "${output_file}" \
  || fail 'raw docker failure output was not preserved'

set +e
(
  cd "${PROJECT_ROOT}"
  PATH="${stub_bin}:${PATH}" STUB_HASH="${previous_hash}" bash misc/build-images.sh
) >"${output_file}" 2>&1
status=$?
set -e

[[ ${status} -eq 0 ]] || { cat "${output_file}" >&2; fail 'matched Vault context did not skip successfully'; }
grep -q 'Vault image decision: local=present arch=arm64 context=matched action=skip' "${output_file}" \
  || { cat "${output_file}" >&2; fail 'matched-context decision line missing'; }
if grep -q 'stub docker build failed' "${output_file}"; then
  cat "${output_file}" >&2
  fail 'matched-context path attempted a rebuild'
fi

printf 'ok  build-images.sh explains Vault image rebuild decisions\n'
