#!/usr/bin/env bash
#
# Sidecar runtime-mode decisions must be real. Native and JVM sidecars share
# the one configured image tag, so "arm64 image present" is NOT proof of the
# requested runtime: a native run replaces the tag contents with the GraalVM
# binary, and a later plain (JVM) run must not silently keep running it.
#
# Discriminators (consolidates the sidecar coverage around one harness):
#   - build.sh (ARM queue): JVM mode + arm64 image whose entrypoint is the
#     native binary -> the sidecar is ENQUEUED and rebuilt from master, not
#     skipped as "already native" (the pre-fix behavior).
#   - build.sh (ARM queue): JVM mode + arm64 JVM image -> reused, no rebuild
#     (warm-rerun idempotency preserved).
#   - build.sh (ARM queue): the effective FOLIO_MODULE_SIDECAR_IMAGE ref is
#     used, and an explicit semver tag builds from its upstream vX.Y.Z.
#   - build.sh (ARM queue): in native mode the sidecar is never enqueued
#     (a :native tag would derive the branch "vnative" and fail the phase).
#   - build.sh (ARM queue): a non-release tag fails branch derivation clearly.
#   - image plan / reusable checks: the runtime type, not the architecture,
#     decides present vs rebuild (JVM -> native rebuilds, same-mode reuses).
#   - ensure_jvm_sidecar_image (amd64): restores the tag with a pull and
#     verifies the pulled image really is the JVM one; a pull that leaves the
#     native binary in place (or fails) halts loudly.
#   - select_sidecar_resources: native mode lowers memory and blanks
#     JAVA_OPTIONS; operator overrides win; JVM mode is a no-op.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

stub_bin="$(mktemp -d)"
output_file="$(mktemp)"
git_log="$(mktemp)"
docker_log="$(mktemp)"
pull_state="$(mktemp)"
export DOCKER_PULL_STATE="${pull_state}"
trap 'rm -rf "${stub_bin}" "${output_file}" "${git_log}" "${docker_log}" "${pull_state}"' EXIT

# docker stub: architecture always arm64; the entrypoint answer is per-image so
# the sidecar runtime type is switchable via SIDECAR_ENTRYPOINT_STUB. A
# successful pull flips the sidecar tag to the JVM image (the registry model);
# DOCKER_PULL_KEEPS_NATIVE models a tag that publishes only the native binary
# again, and DOCKER_PULL_FAILS models an offline registry.
cat >"${stub_bin}/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "image inspect" ]]; then
  case "$*" in
    *'{{.Architecture}}'*) printf 'arm64\n'; exit 0 ;;
    *'{{json .Config.Entrypoint}}'*)
      if [[ "$*" == *folio-module-sidecar* ]]; then
        if [[ -n "${DOCKER_PULL_STATE:-}" && -s "${DOCKER_PULL_STATE}" && -z "${DOCKER_PULL_KEEPS_NATIVE:-}" ]]; then
          printf '%s\n' '["./run-java.sh"]'
        else
          printf '%s\n' "${SIDECAR_ENTRYPOINT_STUB:-[\"./run-java.sh\"]}"
        fi
      else
        printf 'null\n'
      fi
      exit 0
      ;;
  esac
fi
case "$1 $2" in
  'buildx version'|'buildx build') exit 0 ;;
esac
[[ -n "${DOCKER_INVOCATION_LOG:-}" ]] && printf '%s\n' "$*" >> "${DOCKER_INVOCATION_LOG}"
if [[ "$1" == "pull" ]]; then
  [[ -n "${DOCKER_PULL_FAILS:-}" ]] && exit 1
  if [[ -z "${DOCKER_PULL_KEEPS_NATIVE:-}" && -n "${DOCKER_PULL_STATE:-}" ]]; then
    printf 'jvm\n' > "${DOCKER_PULL_STATE}"
  fi
fi
exit 0
EOF

cat >"${stub_bin}/git" <<'EOF'
#!/usr/bin/env bash
[[ -n "${GIT_INVOCATION_LOG:-}" ]] && printf '%s\n' "$*" >> "${GIT_INVOCATION_LOG}"
case "$1" in
  clone)
    target="${@: -1}"
    case "$target" in
      http*|*.git) target="$(basename "$target" .git)" ;;
    esac
    mkdir -p "$target"
    [[ "$target" == "folio-tools" ]] && mkdir -p "$target/folio-java-docker/openjdk21"
    ;;
esac
exit 0
EOF

cat >"${stub_bin}/mvn" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "${stub_bin}/docker" "${stub_bin}/git" "${stub_bin}/mvn"

# Run build.sh with the effective sidecar ref switched via the environment; any
# further KEY=VALUE arguments override the base scenario (REBUILD_BUILT_IMAGES,
# SIDECAR_MODE, module overrides).
run_build() {
  local sidecar_entrypoint="$1" sidecar_image="$2"
  shift 2
  : >"${git_log}"
  set +e
  (
    cd "${PROJECT_ROOT}"
    export PATH="${stub_bin}:${PATH}" \
      GIT_INVOCATION_LOG="${git_log}" \
      SIDECAR_ENTRYPOINT_STUB="${sidecar_entrypoint}" \
      FOLIO_MODULE_SIDECAR_IMAGE="${sidecar_image}" \
      REBUILD_BUILT_IMAGES=false SIDECAR_MODE=jvm
    if (( $# )); then export "$@"; fi
    bash misc/images-builder/build.sh
  ) >"${output_file}" 2>&1
  local status=$?
  set -e
  [[ ${status} -eq 0 ]] \
    || { cat "${output_file}" >&2; fail "build.sh failed (entrypoint ${sidecar_entrypoint}, image ${sidecar_image})"; }
}

# Native -> JVM on ARM: the tag holds the native binary (arm64 + ./application).
# The JVM sidecar must be enqueued and rebuilt from master; before the fix the
# arm64 check alone skipped it and Compose kept running the native binary.
run_build '["./application"]' folioci/folio-module-sidecar:latest
grep -q 'clone .*--branch master .*folio-module-sidecar' "${git_log}" \
  || { sed 's/^/git: /' "${git_log}" >&2; cat "${output_file}" >&2; \
       fail 'native image under the JVM tag was skipped instead of rebuilt'; }

# Same-mode warm reuse: JVM mode + arm64 JVM image (run-java.sh) is reused —
# no sidecar clone, the build stays idempotent.
run_build '["./run-java.sh"]' folioci/folio-module-sidecar:latest
if grep -q 'folio-module-sidecar' "${git_log}"; then
  sed 's/^/git: /' "${git_log}" >&2
  fail 'JVM sidecar was rebuilt despite a reusable arm64 JVM image'
fi

# Effective ref + explicit semver: the configured folioorg/...:4.0.0 tag is
# built from its upstream v4.0.0 and tagged verbatim — no hardcoded
# folioci/...:latest anywhere.
run_build '["./application"]' folioorg/folio-module-sidecar:4.0.0
grep -q 'clone .*--branch v4.0.0 .*folio-module-sidecar' "${git_log}" \
  || { sed 's/^/git: /' "${git_log}" >&2; fail 'semver sidecar tag did not build from v4.0.0'; }
grep -q 'folioorg/folio-module-sidecar:4.0.0' "${output_file}" \
  || { cat "${output_file}" >&2; fail 'effective sidecar image ref was not used'; }
if grep -q 'folioci/folio-module-sidecar' "${output_file}" "${git_log}"; then
  cat "${output_file}" >&2
  fail 'hardcoded folioci sidecar ref leaked into the build'
fi

# Native mode: the sidecar must NOT be re-queued into the generic ARM builder
# even on the refresh path (REBUILD_BUILT_IMAGES=true), where its :native tag
# would derive the nonexistent branch "vnative" and fail the whole phase.
run_build '["./application"]' folioci/folio-module-sidecar:native \
  SIDECAR_MODE=native REBUILD_BUILT_IMAGES=true
if grep -q 'folio-module-sidecar' "${git_log}"; then
  sed 's/^/git: /' "${git_log}" >&2
  fail 'native sidecar was re-queued into the ARM builder (would derive vnative)'
fi

# Safety-net: a non-release image tag (not latest/SNAPSHOT/semver) must fail
# clearly at branch derivation instead of blindly cloning `--branch v<tag>`.
set +e
(
  cd "${PROJECT_ROOT}"
  export PATH="${stub_bin}:${PATH}" \
    REBUILD_BUILT_IMAGES=true SIDECAR_MODE=jvm \
    MOD_CONFIGURATION_IMAGE=folioci/mod-configuration:weird
  bash misc/images-builder/build.sh
) >"${output_file}" 2>&1
weird_status=$?
set -e
[[ ${weird_status} -ne 0 ]] || { cat "${output_file}" >&2; fail 'non-release tag did not fail the build'; }
grep -q 'branch failed' "${output_file}" \
  || { cat "${output_file}" >&2; fail 'non-release tag: expected a clear "branch failed" row'; }
grep -q 'cannot derive a git branch for non-release tag' "${output_file}" \
  || { cat "${output_file}" >&2; fail 'non-release tag: missing the explanatory log message'; }

# Unit level: the image plan, the reuse decision, the amd64 restore and the
# sidecar resource envelope agree with the builder on what the modes mean.
(
  PATH="${stub_bin}:${PATH}" NO_COLOR=1 TERM=dumb
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/misc/lib/folio-common.sh"
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/misc/bootstrap-engine.sh"

  SIDECAR_IMAGE=folioci/folio-module-sidecar:latest

  check_action() {
    local expected="$1" mode="$2" entrypoint="$3" arm="${4:-true}"
    SIDECAR_MODE="${mode}"
    BUILD_ARM_IMAGES="${arm}"
    export SIDECAR_ENTRYPOINT_STUB="${entrypoint}"
    action="$(image_plan_action folio-module-sidecar "${SIDECAR_IMAGE}")"
    [[ "${action}" == "${expected}" ]] \
      || fail "image_plan_action(${mode}, ${entrypoint}) = '${action}', expected '${expected}'"
  }

  check_action 'native arm64 present' native '["./application"]'
  check_action 'will build native'     native '["./run-java.sh"]'
  check_action 'will build arm64'      jvm    '["./application"]'
  check_action 'native arm64 present'  jvm    '["./run-java.sh"]'
  check_action 'will pull or may emulate' jvm '["./application"]' false

  REBUILD_NATIVE_SIDECAR=false REBUILD_BUILT_IMAGES=false SIDECAR_ENTRYPOINT_STUB='["./application"]' \
    native_sidecar_reusable "${SIDECAR_IMAGE}" \
    || fail 'native mode must reuse an arm64 native image'
  REBUILD_NATIVE_SIDECAR=false REBUILD_BUILT_IMAGES=false SIDECAR_ENTRYPOINT_STUB='["./run-java.sh"]' \
    native_sidecar_reusable "${SIDECAR_IMAGE}" \
    && fail 'native mode must rebuild when the tag holds the JVM image'

  # amd64 restore path: BUILD_ARM_IMAGES=false + native binary under the tag ->
  # the JVM image is restored with a pull, and the pull really transitions the
  # tag to the JVM image (the stub only answers run-java.sh AFTER the pull, so
  # the restored status proves the postcondition was checked and held).
  : >"${docker_log}"; : >"${pull_state}"
  SIDECAR_MODE=jvm BUILD_ARM_IMAGES=false FOLIO_MODULE_SIDECAR_IMAGE="${SIDECAR_IMAGE}" \
    SIDECAR_ENTRYPOINT_STUB='["./application"]' DOCKER_INVOCATION_LOG="${docker_log}" \
    ensure_jvm_sidecar_image
  grep -q -- "pull ${SIDECAR_IMAGE}" "${docker_log}" \
    || fail 'ensure_jvm_sidecar_image did not restore the JVM image with a pull'
  grep -q 'JVM sidecar image restored' "${output_file}" \
    || fail 'JVM restore did not report success'

  # No restore churn when the tag already holds the JVM image.
  : >"${docker_log}"; : >"${pull_state}"
  SIDECAR_MODE=jvm BUILD_ARM_IMAGES=false FOLIO_MODULE_SIDECAR_IMAGE="${SIDECAR_IMAGE}" \
    SIDECAR_ENTRYPOINT_STUB='["./run-java.sh"]' DOCKER_INVOCATION_LOG="${docker_log}" \
    ensure_jvm_sidecar_image
  grep -q 'pull' "${docker_log}" \
    && fail 'ensure_jvm_sidecar_image pulled an already-JVM image'

  # The ARM path must NOT pull (published folioci images are amd64-only).
  : >"${docker_log}"; : >"${pull_state}"
  SIDECAR_MODE=jvm BUILD_ARM_IMAGES=true FOLIO_MODULE_SIDECAR_IMAGE="${SIDECAR_IMAGE}" \
    SIDECAR_ENTRYPOINT_STUB='["./application"]' DOCKER_INVOCATION_LOG="${docker_log}" \
    ensure_jvm_sidecar_image
  grep -q 'pull' "${docker_log}" \
    && fail 'ensure_jvm_sidecar_image pulled on the ARM path (builder owns the rebuild)'

  # A failed restore must fail loudly instead of silently running the native binary.
  : >"${pull_state}"
  set +e
  (
    SIDECAR_MODE=jvm BUILD_ARM_IMAGES=false FOLIO_MODULE_SIDECAR_IMAGE="${SIDECAR_IMAGE}" \
      SIDECAR_ENTRYPOINT_STUB='["./application"]' DOCKER_PULL_FAILS=1 \
      ensure_jvm_sidecar_image
  ) >/dev/null 2>&1
  restore_status=$?
  set -e
  [[ ${restore_status} -ne 0 ]] || fail 'failed JVM restore exited 0'

  # A pull that leaves the native binary under the tag must also fail loudly:
  # pulling is only a restore if the registry actually delivered the JVM image.
  : >"${docker_log}"; : >"${pull_state}"
  set +e
  (
    SIDECAR_MODE=jvm BUILD_ARM_IMAGES=false FOLIO_MODULE_SIDECAR_IMAGE="${SIDECAR_IMAGE}" \
      SIDECAR_ENTRYPOINT_STUB='["./application"]' DOCKER_PULL_KEEPS_NATIVE=1 \
      DOCKER_INVOCATION_LOG="${docker_log}" \
      ensure_jvm_sidecar_image
  ) >"${output_file}" 2>&1
  keeps_status=$?
  set -e
  [[ ${keeps_status} -ne 0 ]] \
    || fail 'native-after-pull passed as a restored JVM image'
  grep -q 'still holds the native sidecar binary' "${output_file}" \
    || fail 'native-after-pull lacks the actionable message'
  grep -q -- "pull ${SIDECAR_IMAGE}" "${docker_log}" \
    || fail 'native-after-pull case did not reach the pull (failure came from elsewhere)'

  # JVM mode + a tag with no JVM build path (e.g. ':native': no git ref, no
  # registry JVM build) must halt with the mode/tag conflict, not enqueue a
  # build that can only die later at branch derivation.
  : >"${docker_log}"; : >"${pull_state}"
  set +e
  (
    SIDECAR_MODE=jvm BUILD_ARM_IMAGES=true \
      FOLIO_MODULE_SIDECAR_IMAGE=folioci/folio-module-sidecar:native \
      SIDECAR_ENTRYPOINT_STUB='["./application"]' \
      ensure_jvm_sidecar_image
  ) >"${output_file}" 2>&1
  conflict_status=$?
  set -e
  [[ ${conflict_status} -ne 0 ]] \
    || fail 'unbuildable JVM sidecar tag did not halt'
  grep -q 'no way to produce a JVM image under this tag' "${output_file}" \
    || fail 'conflict halt lacks the actionable message'
  grep -q 'docker pull' "${docker_log}" \
    && fail 'conflict halt attempted a pull on the ARM path'

  # A semver tag with the native binary under it still routes to the ARM
  # rebuild (the builder derives vX.Y.Z), not to the conflict halt.
  : >"${docker_log}"; : >"${pull_state}"
  set +e
  (
    SIDECAR_MODE=jvm BUILD_ARM_IMAGES=true \
      FOLIO_MODULE_SIDECAR_IMAGE=folioorg/folio-module-sidecar:4.0.1 \
      SIDECAR_ENTRYPOINT_STUB='["./application"]' \
      ensure_jvm_sidecar_image
  ) >"${output_file}" 2>&1
  semver_status=$?
  set -e
  [[ ${semver_status} -eq 0 ]] \
    || fail 'semver JVM sidecar tag wrongly halted'

  # select_sidecar_resources: native mode lowers memory and blanks (not
  # unsets) JAVA_OPTIONS; an operator value wins; JVM mode is a no-op.
  (
    SIDECAR_MODE=native
    unset SIDECAR_MEMORY_LIMIT SIDECAR_JAVA_OPTIONS
    select_sidecar_resources
    [[ "${SIDECAR_MEMORY_LIMIT:-}" == "${NATIVE_SIDECAR_MEMORY_LIMIT}" ]] \
      || fail "native mode did not lower memory limit (got '${SIDECAR_MEMORY_LIMIT:-<unset>}')"
    [[ -z "${SIDECAR_JAVA_OPTIONS+x}" ]] \
      && fail 'native mode left JAVA_OPTIONS unset (compose would re-apply JVM default)'
    [[ -z "${SIDECAR_JAVA_OPTIONS}" ]] \
      || fail "native mode did not blank JAVA_OPTIONS (got '${SIDECAR_JAVA_OPTIONS}')"
  ) || exit 1
  (
    SIDECAR_MODE=native
    SIDECAR_MEMORY_LIMIT=512m
    SIDECAR_JAVA_OPTIONS='-Xmx256m'
    select_sidecar_resources
    [[ "${SIDECAR_MEMORY_LIMIT}" == "512m" ]] || fail 'native mode overrode operator memory limit'
    [[ "${SIDECAR_JAVA_OPTIONS}" == '-Xmx256m' ]] || fail 'native mode overrode operator JAVA_OPTIONS'
  ) || exit 1
  (
    SIDECAR_MODE=jvm
    unset SIDECAR_MEMORY_LIMIT SIDECAR_JAVA_OPTIONS
    select_sidecar_resources
    [[ -z "${SIDECAR_MEMORY_LIMIT:-}" ]] || fail 'JVM mode unexpectedly set memory limit'
    [[ -z "${SIDECAR_JAVA_OPTIONS+x}" ]] || fail 'JVM mode unexpectedly set JAVA_OPTIONS'
  ) || exit 1
) >"${output_file}" 2>&1 || { cat "${output_file}" >&2; fail 'unit-level sidecar checks failed'; }

printf 'ok  sidecar mode transitions: native->JVM rebuilds, JVM->native rebuilds, same-mode reuse kept, pull restore verified\n'
