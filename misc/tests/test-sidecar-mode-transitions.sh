#!/usr/bin/env bash
#
# Sidecar runtime-mode transitions must be real. Native and JVM sidecars share
# the one configured image tag, so "arm64 image present" is NOT proof of the
# requested runtime: a native run replaces the tag contents with the GraalVM
# binary, and a later plain (JVM) run must not silently keep running it.
#
# Discriminators:
#   - build.sh (ARM queue): JVM mode + arm64 image whose entrypoint is the
#     native binary -> the sidecar is ENQUEUED and rebuilt from master, not
#     skipped as "already native" (the pre-fix behavior).
#   - build.sh (ARM queue): JVM mode + arm64 JVM image -> reused, no rebuild
#     (warm-rerun idempotency preserved).
#   - image plan: the sidecar row reports build/pull instead of "present".
#   - ensure_jvm_sidecar_image (amd64 path): restores the tag with a pull.
#   - native path: native_sidecar_reusable rejects a JVM image under the tag
#     (JVM -> native rebuilds) and accepts a native one (same-mode reuse).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

stub_bin="$(mktemp -d)"
output_file="$(mktemp)"
git_log="$(mktemp)"
docker_log="$(mktemp)"
trap 'rm -rf "${stub_bin}" "${output_file}" "${git_log}" "${docker_log}"' EXIT

# docker stub: architecture always arm64; the entrypoint format answer is
# per-image so the sidecar runtime type is switchable via SIDECAR_ENTRYPOINT_STUB.
cat >"${stub_bin}/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "image inspect" ]]; then
  case "$*" in
    *'{{.Architecture}}'*) printf 'arm64\n'; exit 0 ;;
    *'{{json .Config.Entrypoint}}'*)
      if [[ "$*" == *folio-module-sidecar* ]]; then
        printf '%s\n' "${SIDECAR_ENTRYPOINT_STUB:-[\"./run-java.sh\"]}"
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
if [[ "$1" == "pull" && -n "${DOCKER_PULL_FAILS:-}" ]]; then
  exit 1
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

run_build() {
  local sidecar_entrypoint="$1"
  : >"${git_log}"
  set +e
  (
    cd "${PROJECT_ROOT}"
    PATH="${stub_bin}:${PATH}" \
      GIT_INVOCATION_LOG="${git_log}" \
      SIDECAR_ENTRYPOINT_STUB="${sidecar_entrypoint}" \
      REBUILD_BUILT_IMAGES=false \
      SIDECAR_MODE=jvm \
      FOLIO_MODULE_SIDECAR_IMAGE=folioci/folio-module-sidecar:latest \
      bash misc/images-builder/build.sh
  ) >"${output_file}" 2>&1
  local status=$?
  set -e
  [[ ${status} -eq 0 ]] || { cat "${output_file}" >&2; fail "build.sh failed (entrypoint ${sidecar_entrypoint})"; }
}

# Native -> JVM on ARM: the tag holds the native binary (arm64 + ./application).
# The JVM sidecar must be enqueued and rebuilt from master; before the fix the
# arm64 check alone skipped it and Compose kept running the native binary.
run_build '["./application"]'
grep -q 'clone .*--branch master .*folio-module-sidecar' "${git_log}" \
  || { sed 's/^/git: /' "${git_log}" >&2; cat "${output_file}" >&2; \
       fail 'native image under the JVM tag was skipped instead of rebuilt'; }

# Same-mode warm reuse: JVM mode + arm64 JVM image (run-java.sh) is reused —
# no sidecar clone, the build stays idempotent.
run_build '["./run-java.sh"]'
if grep -q 'folio-module-sidecar' "${git_log}"; then
  sed 's/^/git: /' "${git_log}" >&2
  fail 'JVM sidecar was rebuilt despite a reusable arm64 JVM image'
fi

# Unit level: the image plan and the native/JVM decision helpers agree with the
# builder on what counts as the requested runtime.
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
  # the JVM image is restored with a pull; no pull for a JVM image.
  : >"${docker_log}"
  SIDECAR_MODE=jvm BUILD_ARM_IMAGES=false FOLIO_MODULE_SIDECAR_IMAGE="${SIDECAR_IMAGE}" \
    SIDECAR_ENTRYPOINT_STUB='["./application"]' DOCKER_INVOCATION_LOG="${docker_log}" \
    ensure_jvm_sidecar_image
  grep -q -- "pull ${SIDECAR_IMAGE}" "${docker_log}" \
    || fail 'ensure_jvm_sidecar_image did not restore the JVM image with a pull'
  : >"${docker_log}"
  SIDECAR_MODE=jvm BUILD_ARM_IMAGES=false FOLIO_MODULE_SIDECAR_IMAGE="${SIDECAR_IMAGE}" \
    SIDECAR_ENTRYPOINT_STUB='["./run-java.sh"]' DOCKER_INVOCATION_LOG="${docker_log}" \
    ensure_jvm_sidecar_image
  grep -q 'pull' "${docker_log}" \
    && fail 'ensure_jvm_sidecar_image pulled an already-JVM image'
  # The ARM path must NOT pull (published folioci images are amd64-only).
  : >"${docker_log}"
  SIDECAR_MODE=jvm BUILD_ARM_IMAGES=true FOLIO_MODULE_SIDECAR_IMAGE="${SIDECAR_IMAGE}" \
    SIDECAR_ENTRYPOINT_STUB='["./application"]' DOCKER_INVOCATION_LOG="${docker_log}" \
    ensure_jvm_sidecar_image
  grep -q 'pull' "${docker_log}" \
    && fail 'ensure_jvm_sidecar_image pulled on the ARM path (builder owns the rebuild)'

  # A failed restore must fail loudly instead of silently running the native binary.
  set +e
  (
    SIDECAR_MODE=jvm BUILD_ARM_IMAGES=false FOLIO_MODULE_SIDECAR_IMAGE="${SIDECAR_IMAGE}" \
      SIDECAR_ENTRYPOINT_STUB='["./application"]' DOCKER_PULL_FAILS=1 \
      ensure_jvm_sidecar_image
  ) >/dev/null 2>&1
  restore_status=$?
  set -e
  [[ ${restore_status} -ne 0 ]] || fail 'failed JVM restore exited 0'

  # JVM mode + a tag with no JVM build path (e.g. ':native': no git ref, no
  # registry JVM build) must halt with the mode/tag conflict, not enqueue a
  # build that can only die later at branch derivation.
  : >"${docker_log}"
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
    || { cat "${output_file}" >&2; fail 'unbuildable JVM sidecar tag did not halt'; }
  grep -q 'no way to produce a JVM image under this tag' "${output_file}" \
    || { cat "${output_file}" >&2; fail 'conflict halt lacks the actionable message'; }
  grep -q 'docker pull' "${docker_log}" \
    && fail 'conflict halt attempted a pull on the ARM path'

  # A semver tag with the native binary under it still routes to the ARM
  # rebuild (the builder derives vX.Y.Z), not to the conflict halt.
  : >"${docker_log}"
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
    || { cat "${output_file}" >&2; fail 'semver JVM sidecar tag wrongly halted'; }
) >"${output_file}" 2>&1 || { cat "${output_file}" >&2; fail 'unit-level sidecar checks failed'; }

printf 'ok  sidecar mode transitions: native->JVM rebuilds, JVM->native rebuilds, same-mode reuse kept\n'
