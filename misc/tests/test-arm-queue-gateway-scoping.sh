#!/usr/bin/env bash
#
# Hermetic proof that the generic ARM builder queues only the selected
# gateway's image. Both gateway images are enqueued from docker/.env defaults,
# so without scoping a Kong run tries to build folioci/folio-apisix from
# upstream master — whose Dockerfile has required the subscription-walled
# dhi.io/apisix base since 289fea7 (2026-07-10) — and a single failing gateway
# build fails the whole bootstrap (observed live as the P1 cold-run failure).
# The apisix side must also clone the pinned last-public revision instead of
# the master tip.
#
# REBUILD_BUILT_IMAGES=true forces everything into the queue (nothing is
# skipped as already native), so the git stub's invocation log is a real
# discriminator: red before the scoping fix (folio-apisix cloned on a kong
# run), green after.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

stub_bin="$(mktemp -d)"
git_log_kong="$(mktemp)"
git_log_apisix="$(mktemp)"
output_file="$(mktemp)"
trap 'rm -rf "${stub_bin}"; rm -f "${git_log_kong}" "${git_log_apisix}" "${output_file}"' EXIT

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
  local git_log="$1" apigw_type="$2"
  set +e
  (
    cd "${PROJECT_ROOT}"
    PATH="${stub_bin}:${PATH}" \
    GIT_INVOCATION_LOG="${git_log}" \
    REBUILD_BUILT_IMAGES=true \
    SIDECAR_MODE=jvm \
    APIGW_TYPE="${apigw_type}" \
    FOLIO_MODULE_SIDECAR_IMAGE=folioci/folio-module-sidecar:latest \
    bash misc/images-builder/build.sh
  ) > "${output_file}" 2>&1
  local status=$?
  set -e
  [[ ${status} -eq 0 ]] || { cat "${output_file}" >&2; fail "build.sh failed (${apigw_type} gateway)"; }
}

# Kong run (the default): the kong image is built, the apisix image is not
# touched at all (no clone, no pinned fetch).
run_build "${git_log_kong}" kong
grep -q 'clone .*folio-kong' "${git_log_kong}" \
  || { sed 's/^/git: /' "${git_log_kong}" >&2; fail 'kong run did not build the kong image'; }
if grep -q 'folio-apisix' "${git_log_kong}"; then
  sed 's/^/git: /' "${git_log_kong}" >&2
  fail 'kong run touched the folio-apisix build (must be scoped out)'
fi

# APISIX run: the apisix image is built from the pinned public revision, and
# the kong image stays out of the queue.
run_build "${git_log_apisix}" apisix
grep -q 'clone .*folio-apisix' "${git_log_apisix}" \
  || { sed 's/^/git: /' "${git_log_apisix}" >&2; fail 'apisix run did not build the apisix image'; }
grep -q 'fetch --depth 1 --quiet origin 159ad2f55dc34d364bbbdc660b019b297f894c45' "${git_log_apisix}" \
  || { sed 's/^/git: /' "${git_log_apisix}" >&2; fail 'apisix build did not fetch the pinned public revision'; }
if grep -q 'folio-kong' "${git_log_apisix}"; then
  sed 's/^/git: /' "${git_log_apisix}" >&2
  fail 'apisix run touched the folio-kong build (must be scoped out)'
fi

printf 'ok  ARM queue builds only the selected gateway; apisix clones the pinned public revision\n'
