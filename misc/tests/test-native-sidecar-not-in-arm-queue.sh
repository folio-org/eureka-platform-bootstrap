#!/usr/bin/env bash
#
# Hermetic proof that in native sidecar mode the already-built native sidecar is
# NOT re-queued into the generic ARM module builder. The generic builder derives
# a git branch from the image tag, so a `:native` tag would become `--branch
# vnative` (a branch that does not exist) and fail the whole build phase. The
# native sidecar is owned by ensure_native_sidecar_image, not build.sh.
#
# The bug only surfaces when REBUILD_BUILT_IMAGES=true (the refresh-to-latest
# path), because otherwise the freshly built arm64 image is skipped as present.
# The test therefore sets it, so it is a real discriminator: red before the fix
# (sidecar cloned as `vnative`), green after. JVM mode must still build the
# sidecar from master, so an over-broad exclusion would break that assertion.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

stub_bin="$(mktemp -d)"
git_log_native="$(mktemp)"
git_log_jvm="$(mktemp)"
output_file="$(mktemp)"
trap 'rm -rf "${stub_bin}"; rm -f "${git_log_native}" "${git_log_jvm}" "${output_file}"' EXIT

# git stub: record every invocation (so we can assert what was cloned) and make
# clones succeed by creating the target directory.
cat > "${stub_bin}/git" <<'EOF'
#!/usr/bin/env bash
[[ -n "${GIT_INVOCATION_LOG:-}" ]] && printf '%s\n' "$*" >> "${GIT_INVOCATION_LOG}"
case "$1" in
  clone)
    target="${@: -1}"
    case "$target" in
      http*|*.git) target="$(basename "$target" .git)" ;;
    esac
    mkdir -p "$target"
    # The base JRE build cd's into a nested folio-tools path after cloning.
    [[ "$target" == "folio-tools" ]] && mkdir -p "$target/folio-java-docker/openjdk21"
    ;;
esac
exit 0
EOF

cat > "${stub_bin}/docker" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "buildx version") exit 0 ;;
  "buildx build") exit 0 ;;
  "image inspect") printf 'arm64\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF

cat > "${stub_bin}/mvn" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "${stub_bin}/git" "${stub_bin}/docker" "${stub_bin}/mvn"

run_build() {
  local git_log="$1" sidecar_mode="$2" sidecar_image="$3"
  set +e
  (
    cd "${PROJECT_ROOT}"
    PATH="${stub_bin}:${PATH}" \
      GIT_INVOCATION_LOG="${git_log}" \
      REBUILD_BUILT_IMAGES=true \
      SIDECAR_MODE="${sidecar_mode}" \
      FOLIO_MODULE_SIDECAR_IMAGE="${sidecar_image}" \
      bash misc/images-builder/build.sh
  ) > "${output_file}" 2>&1
  local status=$?
  set -e
  [[ ${status} -eq 0 ]] || { cat "${output_file}" >&2; fail "build.sh failed (${sidecar_mode} mode)"; }
}

# Native mode: the sidecar must NOT be cloned by the generic builder.
run_build "${git_log_native}" native folioci/folio-module-sidecar:native
if grep -q 'folio-module-sidecar' "${git_log_native}"; then
  sed 's/^/git: /' "${git_log_native}" >&2
  fail 'native sidecar was re-queued into the ARM builder (would derive vnative)'
fi

# JVM mode: the sidecar must still be built from master (guard against an
# over-broad exclusion).
run_build "${git_log_jvm}" jvm folioci/folio-module-sidecar:latest
grep -q 'clone .*folio-module-sidecar' "${git_log_jvm}" \
  || { sed 's/^/git: /' "${git_log_jvm}" >&2; fail 'JVM sidecar was not built from source'; }
grep -q 'branch master .*folio-module-sidecar' "${git_log_jvm}" \
  || { sed 's/^/git: /' "${git_log_jvm}" >&2; fail 'JVM sidecar clone did not use branch master'; }

# Safety-net: a non-release image tag (not latest/SNAPSHOT/semver) must fail
# clearly at branch derivation instead of blindly cloning `--branch v<tag>` (the
# defense that generalizes the vnative fix). Override one module to a bogus tag.
set +e
(
  cd "${PROJECT_ROOT}"
  PATH="${stub_bin}:${PATH}" \
    REBUILD_BUILT_IMAGES=true \
    SIDECAR_MODE=jvm \
    MOD_CONFIGURATION_IMAGE=folioci/mod-configuration:weird \
    bash misc/images-builder/build.sh
) > "${output_file}" 2>&1
weird_status=$?
set -e
[[ ${weird_status} -ne 0 ]] || { cat "${output_file}" >&2; fail 'non-release tag did not fail the build'; }
grep -q 'branch failed' "${output_file}" \
  || { cat "${output_file}" >&2; fail 'non-release tag: expected a clear "branch failed" row'; }
grep -q 'cannot derive a git branch for non-release tag' "${output_file}" \
  || { cat "${output_file}" >&2; fail 'non-release tag: missing the explanatory log message'; }

printf 'ok  native sidecar stays out of the ARM queue; JVM builds from master; non-release tag fails clearly\n'
