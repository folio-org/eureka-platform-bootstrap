#!/usr/bin/env bash
#
# Hermetic proof that the native sidecar build is immune to the operator shell
# environment: start.sh exports docker/.env (set -a), so the build script must
# strip SECRET_STORE_* before mvn and must skip every maven test phase (failsafe
# ignores -DskipTests; the sidecar pom wires surefire's skip to skipSurefireTests
# and its native profile re-enables ITs via skipITs=false).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

stub_bin="$(mktemp -d)"
graalvm_bin="$(mktemp -d)"
output_file="$(mktemp)"
mvn_log="$(mktemp)"
trap 'rm -rf "${stub_bin}" "${graalvm_bin}" "${output_file}" "${mvn_log}"' EXIT

cat > "${stub_bin}/git" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  clone)
    # Create the clone dir with the Dockerfile the packaging step expects,
    # otherwise `cd "$BUILD_DIR"` fails under set -e.
    target="${@: -1}"
    mkdir -p "$target/docker"
    : > "$target/docker/Dockerfile.native-micro"
    ;;
esac
EOF

cat > "${stub_bin}/mvn" <<'EOF'
#!/usr/bin/env bash
# Record the argv and the observed SECRET_STORE_* values so assertions survive
# ui_run folding the mvn output on success. "<unset>" proves the variable is
# truly absent; an empty value would still override MicroProfile config.
[[ -n "${MVN_INVOCATION_LOG:-}" ]] || exit 0
{
  printf 'mvn %s\n' "$*"
  for var in SECRET_STORE_TYPE SECRET_STORE_VAULT_ADDRESS SECRET_STORE_VAULT_TOKEN; do
    printf '%s=%s\n' "${var}" "${!var-<unset>}"
  done
} >> "${MVN_INVOCATION_LOG}"
exit 0
EOF

cat > "${stub_bin}/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "${stub_bin}/uname" <<'EOF'
#!/usr/bin/env bash
printf 'arm64\n'
EOF

# Only placed on PATH for the local-GraalVM run; its presence selects
# CONTAINER_BUILD=false (build-native-sidecar.sh checks `command -v native-image`).
cat > "${graalvm_bin}/native-image" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "${stub_bin}/git" "${stub_bin}/mvn" "${stub_bin}/docker" "${stub_bin}/uname" \
  "${graalvm_bin}/native-image"

run_build() {
  local path_prefix="$1"
  : > "${mvn_log}"
  set +e
  (
    cd "${PROJECT_ROOT}"
    # Seed the exact leak start.sh produces, on a trimmed PATH so the
    # container/local branch selection does not depend on the host toolchain.
    PATH="${path_prefix}:/usr/bin:/bin" \
      MVN_INVOCATION_LOG="${mvn_log}" \
      FOLIO_MODULE_SIDECAR_IMAGE="custom/folio-module-sidecar:native" \
      SECRET_STORE_TYPE=VAULT \
      SECRET_STORE_VAULT_ADDRESS=http://vault:8200 \
      SECRET_STORE_VAULT_TOKEN=leaked-token \
      bash misc/build-native-sidecar.sh
  ) > "${output_file}" 2>&1
  local status=$?
  set -e
  [[ ${status} -eq 0 ]] || { cat "${output_file}" >&2; fail "native sidecar build failed"; }
}

assert_mvn_is_skipped_and_clean() {
  local label="$1"
  grep -q -- "-DskipITs" "${mvn_log}" \
    || { cat "${output_file}" "${mvn_log}" >&2; fail "${label}: mvn did not receive -DskipITs"; }
  grep -q -- "-DskipSurefireTests" "${mvn_log}" \
    || { cat "${output_file}" "${mvn_log}" >&2; fail "${label}: mvn did not receive -DskipSurefireTests"; }
  grep -q "^SECRET_STORE_TYPE=<unset>$" "${mvn_log}" \
    || { cat "${mvn_log}" >&2; fail "${label}: SECRET_STORE_TYPE leaked into the mvn environment"; }
  grep -q "^SECRET_STORE_VAULT_ADDRESS=<unset>$" "${mvn_log}" \
    || { cat "${mvn_log}" >&2; fail "${label}: SECRET_STORE_VAULT_ADDRESS leaked into the mvn environment"; }
  grep -q "^SECRET_STORE_VAULT_TOKEN=<unset>$" "${mvn_log}" \
    || { cat "${mvn_log}" >&2; fail "${label}: SECRET_STORE_VAULT_TOKEN leaked into the mvn environment"; }
}

# Container branch: no native-image on PATH -> Mandrel container build.
run_build "${stub_bin}"
assert_mvn_is_skipped_and_clean "container branch"

# Local GraalVM branch: native-image on PATH -> local native build.
run_build "${graalvm_bin}:${stub_bin}"
assert_mvn_is_skipped_and_clean "local GraalVM branch"

printf 'ok  native sidecar build strips SECRET_STORE_* and skips all maven test phases\n'
