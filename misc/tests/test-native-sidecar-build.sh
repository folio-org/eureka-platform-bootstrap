#!/usr/bin/env bash
#
# Hermetic proof of misc/build-native-sidecar.sh behavior:
#   - the git ref is derived from the EFFECTIVE image tag: a semver tag builds
#     its upstream vX.Y.Z and tags the image verbatim; non-semver tags fall
#     back to master; a missing semver tag is a hard error (never build master
#     and label it with the requested version);
#   - a failed tag query (offline) is reported as a query failure, not as
#     "tag does not exist";
#   - the build is immune to the operator shell environment: start.sh exports
#     docker/.env (set -a), so SECRET_STORE_* is stripped before mvn, and every
#     maven test phase is skipped (failsafe ignores -DskipTests);
#   - a real mvn failure surfaces the bounded tail plus fallback guidance;
#   - both build branches are exercised: Mandrel container and local GraalVM.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

stub_bin="$(mktemp -d)"
graalvm_bin="$(mktemp -d)"
output_file="$(mktemp)"
docker_log="$(mktemp)"
mvn_log="$(mktemp)"
trap 'rm -rf "${stub_bin}" "${graalvm_bin}" "${output_file}" "${docker_log}" "${mvn_log}"' EXIT

cat > "${stub_bin}/git" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  ls-remote)
    if [[ -n "${GIT_LS_REMOTE_FAILS:-}" ]]; then
      printf 'git ls-remote: could not read from remote repository\n' >&2
      exit 128
    fi
    # Last arg is the refs/tags/<ref> pattern; only v4.0.1 "exists" upstream.
    ref="${@: -1}"
    if [[ "$ref" == "refs/tags/v4.0.1" ]]; then
      printf 'deadbeef\t%s\n' "$ref"
    fi
    ;;
  clone)
    target="${@: -1}"
    mkdir -p "$target/docker"
    : > "$target/docker/Dockerfile.native-micro"
    printf 'git clone %s\n' "$*"
    ;;
esac
EOF

cat > "${stub_bin}/mvn" <<'EOF'
#!/usr/bin/env bash
if [[ "${MVN_FAIL:-false}" == "true" ]]; then
  printf 'stub maven failure\n' >&2
  exit 42
fi
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
case "$1" in
  build)
    [[ -n "${DOCKER_INVOCATION_LOG:-}" ]] && printf 'build %s\n' "$*" >> "${DOCKER_INVOCATION_LOG}"
    ;;
esac
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

# Seed the exact leak start.sh produces: docker/.env is exported set -a around
# the build, so SECRET_STORE_* reaches this script's environment.
run_build() {
  local path_prefix="$1" image="$2"
  : > "${docker_log}"; : > "${mvn_log}"
  set +e
  (
    cd "${PROJECT_ROOT}"
    PATH="${path_prefix}:/usr/bin:/bin" \
      DOCKER_INVOCATION_LOG="${docker_log}" \
      MVN_INVOCATION_LOG="${mvn_log}" \
      FOLIO_MODULE_SIDECAR_IMAGE="${image}" \
      SECRET_STORE_TYPE=VAULT \
      SECRET_STORE_VAULT_ADDRESS=http://vault:8200 \
      SECRET_STORE_VAULT_TOKEN=leaked-token \
      bash misc/build-native-sidecar.sh
  ) > "${output_file}" 2>&1
  local status=$?
  set -e
  [[ ${status} -eq 0 ]] || { cat "${output_file}" >&2; fail "native sidecar build failed for ${image}"; }
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

# Mandrel container branch (no native-image on PATH), explicit semver tag:
# build from the matching upstream git tag and tag the effective image.
run_build "${stub_bin}" "custom/folio-module-sidecar:4.0.1"
grep -q -- "-t custom/folio-module-sidecar:4.0.1" "${docker_log}" \
  || { cat "${output_file}" >&2; fail "native build did not tag the effective image"; }
grep -q -- "git clone .*--branch v4.0.1" "${output_file}" \
  || { cat "${output_file}" >&2; fail "native build did not clone the versioned git tag"; }
if grep -q -- "-t folioci/folio-module-sidecar:native" "${docker_log}"; then
  cat "${output_file}" >&2
  fail "native build used hardcoded tag"
fi
assert_mvn_is_skipped_and_clean "container branch"

# Local GraalVM branch (native-image on PATH), non-semver tag: fall back to
# master source; the environment hygiene holds on this branch too.
run_build "${graalvm_bin}:${stub_bin}" "custom/folio-module-sidecar:native"
grep -q -- "git clone .*--branch master" "${output_file}" \
  || { cat "${output_file}" >&2; fail "non-semver tag did not fall back to master"; }
assert_mvn_is_skipped_and_clean "local GraalVM branch"

# An explicit semver whose upstream git tag does not exist must FAIL clearly,
# never build master and label the result with the requested version (the
# tag is the single source of truth for what gets built).
: > "${docker_log}"
set +e
(
  cd "${PROJECT_ROOT}"
  PATH="${stub_bin}:/usr/bin:/bin" \
    FOLIO_MODULE_SIDECAR_IMAGE="custom/folio-module-sidecar:9.9.9" \
    bash misc/build-native-sidecar.sh
) > "${output_file}" 2>&1
missing_status=$?
set -e
[[ ${missing_status} -ne 0 ]] \
  || { cat "${output_file}" >&2; fail "missing semver tag unexpectedly succeeded"; }
grep -q 'requires upstream git tag v9.9.9' "${output_file}" \
  || { cat "${output_file}" >&2; fail "missing semver tag: no clear failure naming the tag"; }
if grep -q -- '--branch master' "${output_file}"; then
  cat "${output_file}" >&2
  fail "missing semver tag silently built master"
fi
if grep -q -- '-t custom/folio-module-sidecar:9.9.9' "${docker_log}"; then
  fail "missing semver tag produced an image falsely labelled 9.9.9"
fi

# A failed upstream tag QUERY (offline/unreachable) is a different error than
# an absent tag: it must not claim the tag "does not exist".
: > "${docker_log}"
set +e
(
  cd "${PROJECT_ROOT}"
  PATH="${stub_bin}:/usr/bin:/bin" \
    GIT_LS_REMOTE_FAILS=1 \
    FOLIO_MODULE_SIDECAR_IMAGE="custom/folio-module-sidecar:9.9.9" \
    bash misc/build-native-sidecar.sh
) > "${output_file}" 2>&1
query_status=$?
set -e
[[ ${query_status} -ne 0 ]] \
  || { cat "${output_file}" >&2; fail "failed tag query unexpectedly succeeded"; }
grep -q 'Could not query the upstream tags' "${output_file}" \
  || { cat "${output_file}" >&2; fail "failed tag query: no query-failure message"; }
if grep -q 'does not exist' "${output_file}"; then
  cat "${output_file}" >&2
  fail "failed tag query misreported as an absent tag"
fi

# A real mvn failure surfaces the bounded tail and the fallback guidance.
set +e
(
  cd "${PROJECT_ROOT}"
  PATH="${stub_bin}:/usr/bin:/bin" \
    MVN_FAIL=true \
    FOLIO_MODULE_SIDECAR_IMAGE="custom/folio-module-sidecar:4.0.1" \
    bash misc/build-native-sidecar.sh
) > "${output_file}" 2>&1
mvnfail_status=$?
set -e
[[ ${mvnfail_status} -ne 0 ]] \
  || { cat "${output_file}" >&2; fail "mvn failure unexpectedly succeeded"; }
grep -q -- "stub maven failure" "${output_file}" \
  || { cat "${output_file}" >&2; fail "native build failure did not surface the real mvn error (bounded tail)"; }
grep -q -- "Consider using JVM sidecar instead" "${output_file}" \
  || { cat "${output_file}" >&2; fail "native build failure did not print fallback guidance"; }

printf 'ok  native sidecar builder: tag-derived ref, honest query errors, clean env, surfaced failures\n'
