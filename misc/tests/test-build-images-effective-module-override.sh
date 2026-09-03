#!/usr/bin/env bash
#
# Hermetic proof that ARM image preparation uses an effective module image
# override instead of the descriptor-derived image ref that Compose would not run.

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
      folioorg/mod-users:19.6.0)
        printf 'unexpected descriptor image inspect: %s\n' "$image" >&2
        exit 42
        ;;
      custom/mod-users:test)
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
    MOD_USERS_IMAGE=custom/mod-users:test \
    bash misc/images-builder/build.sh
) > "${output_file}" 2>&1
run_status=$?
set -e

[[ ${run_status} -eq 0 ]] || { cat "${output_file}" >&2; fail "build.sh failed"; }
grep -q "custom/mod-users:test" "${output_file}" \
  || { cat "${output_file}" >&2; fail "effective module image override was not used"; }
if grep -q "folioorg/mod-users:19.6.0" "${output_file}"; then
  cat "${output_file}" >&2
  fail "descriptor image was used despite module override"
fi

printf 'ok  build.sh uses effective module image override\n'
