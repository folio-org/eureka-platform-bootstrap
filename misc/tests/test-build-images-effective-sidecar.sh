#!/usr/bin/env bash
#
# Hermetic proof that ARM image preparation uses the effective sidecar image ref
# instead of a hardcoded folioci/folio-module-sidecar:latest.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

stub_bin="$(mktemp -d)"
output_file="$(mktemp)"
trap 'rm -rf "${stub_bin}" "${output_file}"' EXIT

cat > "${stub_bin}/git" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  clone)
    target="${@: -1}"
    case "$target" in
      http*|*.git) target="$(basename "$target" .git)" ;;
    esac
    mkdir -p "$target"
    ;;
esac
EOF

cat > "${stub_bin}/docker" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "buildx version") exit 0 ;;
  "buildx build")
    printf 'docker buildx build %s\n' "$*"
    exit 0
    ;;
  "image inspect")
    image="${@: -1}"
    case "$image" in
      folioci/folio-module-sidecar:latest)
        printf 'unexpected hardcoded latest inspect: %s\n' "$image" >&2
        exit 42
        ;;
      folioorg/folio-module-sidecar:4.0.0)
        exit 1
        ;;
      *)
        printf 'arm64\n'
        exit 0
        ;;
    esac
    ;;
  *) exit 0 ;;
esac
EOF

cat > "${stub_bin}/mvn" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "${stub_bin}/git" "${stub_bin}/docker" "${stub_bin}/mvn"

set +e
(
  cd "${PROJECT_ROOT}"
  PATH="${stub_bin}:${PATH}" \
    FOLIO_MODULE_SIDECAR_IMAGE=folioorg/folio-module-sidecar:4.0.0 \
    bash misc/images-builder/build.sh
) > "${output_file}" 2>&1
run_status=$?
set -e

[[ ${run_status} -eq 0 ]] || { cat "${output_file}" >&2; fail "build.sh failed"; }
grep -q "folioorg/folio-module-sidecar:4.0.0" "${output_file}" \
  || { cat "${output_file}" >&2; fail "effective sidecar image was not used"; }
if grep -q "folioci/folio-module-sidecar:latest" "${output_file}"; then
  cat "${output_file}" >&2
  fail "hardcoded sidecar latest was used"
fi

printf 'ok  build.sh uses effective sidecar image ref\n'
