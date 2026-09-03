#!/usr/bin/env bash
#
# Hermetic proof that the native sidecar builder tags the image selected by the
# effective runtime environment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

stub_bin="$(mktemp -d)"
output_file="$(mktemp)"
docker_log="$(mktemp)"
trap 'rm -rf "${stub_bin}" "${output_file}" "${docker_log}"' EXIT

cat > "${stub_bin}/git" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  ls-remote)
    # Last arg is the refs/tags/<ref> pattern; only v4.0.1 "exists" upstream.
    ref="${@: -1}"
    if [[ "$ref" == "refs/tags/v4.0.1" ]]; then
      printf 'deadbeef\t%s\n' "$ref"
    fi
    ;;
  clone)
    printf 'git clone %s\n' "$*"
    target="${@: -1}"
    mkdir -p "$target/docker"
    : > "$target/docker/Dockerfile.native-micro"
    ;;
esac
EOF

cat > "${stub_bin}/mvn" <<'EOF'
#!/usr/bin/env bash
if [[ "${MVN_FAIL:-false}" == "true" ]]; then
  printf 'stub maven failure\n' >&2
  exit 42
fi
exit 0
EOF

cat > "${stub_bin}/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  build)
    # Record invocations to a log so the assertion survives ui_run folding the
    # docker output on success.
    [[ -n "${DOCKER_INVOCATION_LOG:-}" ]] && printf 'build %s\n' "$*" >> "${DOCKER_INVOCATION_LOG}"
    printf 'docker build %s\n' "$*"
    exit 0
    ;;
  images)
    printf 'custom/folio-module-sidecar native\n'
    exit 0
    ;;
  *) exit 0 ;;
esac
EOF

cat > "${stub_bin}/uname" <<'EOF'
#!/usr/bin/env bash
printf 'arm64\n'
EOF

chmod +x "${stub_bin}/git" "${stub_bin}/mvn" "${stub_bin}/docker" "${stub_bin}/uname"

run_build() {
  local image="$1"
  : > "${docker_log}"
  set +e
  (
    cd "${PROJECT_ROOT}"
    PATH="${stub_bin}:${PATH}" \
      DOCKER_INVOCATION_LOG="${docker_log}" \
      FOLIO_MODULE_SIDECAR_IMAGE="${image}" \
      bash misc/build-native-sidecar.sh
  ) > "${output_file}" 2>&1
  local status=$?
  set -e
  [[ ${status} -eq 0 ]] || { cat "${output_file}" >&2; fail "native sidecar build script failed for ${image}"; }
}

run_build_expect_failure() {
  local image="$1"
  set +e
  (
    cd "${PROJECT_ROOT}"
    PATH="${stub_bin}:${PATH}" \
      MVN_FAIL=true \
      FOLIO_MODULE_SIDECAR_IMAGE="${image}" \
      bash misc/build-native-sidecar.sh
  ) > "${output_file}" 2>&1
  local status=$?
  set -e
  [[ ${status} -ne 0 ]] || { cat "${output_file}" >&2; fail "native sidecar build unexpectedly succeeded for ${image}"; }
}

# Semver image tag -> build from the matching upstream git tag, tag the same image.
run_build "custom/folio-module-sidecar:4.0.1"
grep -q -- "-t custom/folio-module-sidecar:4.0.1" "${docker_log}" \
  || { cat "${output_file}" >&2; fail "native build did not tag the effective image"; }
grep -q -- "git clone .*--branch v4.0.1" "${output_file}" \
  || { cat "${output_file}" >&2; fail "native build did not clone the versioned git tag"; }
if grep -q -- "-t folioci/folio-module-sidecar:native" "${docker_log}"; then
  cat "${output_file}" >&2
  fail "native build used hardcoded tag"
fi

# Non-semver tag (native/latest) -> fall back to master source.
run_build "custom/folio-module-sidecar:native"
grep -q -- "git clone .*--branch master" "${output_file}" \
  || { cat "${output_file}" >&2; fail "non-semver tag did not fall back to master"; }

run_build_expect_failure "custom/folio-module-sidecar:4.0.1"
grep -q -- "stub maven failure" "${output_file}" \
  || { cat "${output_file}" >&2; fail "native build failure did not surface the real mvn error (bounded tail)"; }
grep -q -- "Consider using JVM sidecar instead" "${output_file}" \
  || { cat "${output_file}" >&2; fail "native build failure did not print fallback guidance"; }

printf 'ok  native sidecar builder derives git ref from effective image tag\n'
