#!/usr/bin/env bash
# Hermetic proof that IMAGE and VERSION skew halt before container startup.
# Digest/tagless IMAGE exemptions never exempt the sidecar's VERSION value.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin" "${tmp}/docker"
stdout_file="${tmp}/stdout"
stderr_file="${tmp}/stderr"
export STARTUP_MARKER="${tmp}/started"

cat >"${tmp}/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  'image inspect --format {{.Architecture}} '*) printf 'arm64\n' ;;
  'compose up -d') printf 'started\n' >"${STARTUP_MARKER:?}" ;;
esac
EOF
chmod +x "${tmp}/bin/docker"
PATH="${tmp}/bin:${PATH}"
DEBUG=false
NO_COLOR=1
TERM=dumb

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/misc/bootstrap-engine.sh"

DOCKER_DIR="${tmp}/docker"
APP_DESCRIPTOR_PATH="${tmp}/descriptor.json"
cat >"${APP_DESCRIPTOR_PATH}" <<'EOF'
{"id":"app-test-1.0.0","name":"app-test","modules":[{"name":"mod-users","version":"19.6.0"}]}
EOF
SIDECAR_MODE=jvm
BUILD_ARM_IMAGES=false
ASSUME_YES=true
UI_UNICODE=false
UI_COLOR=false
export MOD_USERS_IMAGE='folioorg/mod-users:19.6.0'
export MOD_USERS_VERSION='19.6.0'
capture_initial_image_env_names

run_guard() {
  rm -f "${STARTUP_MARKER}"
  set +e
  (
    set -euo pipefail
    print_image_plan
    check_and_handle_descriptor_image_skew
    docker compose up -d
  ) >"${stdout_file}" 2>"${stderr_file}"
  run_status=$?
  set -e
  [[ ! -s "${stdout_file}" ]] || fail 'image plan or skew guard wrote to stdout'
}

assert_halt() {
  [[ ${run_status} -ne 0 && ! -e "${STARTUP_MARKER}" ]] \
    || { cat "${stderr_file}" >&2; fail "$1 did not halt before container startup"; }
  grep -q 'actualize' "${stderr_file}" || fail 'recovery does not mention actualize'
  grep -q '.env.local.credentials' "${stderr_file}" || fail 'recovery omits credentials overrides'
  [[ "$(grep -c 'mod-users: descriptor' "${stderr_file}")" == 1 ]] \
    || { cat "${stderr_file}" >&2; fail 'skew must produce one diagnostic per affected module'; }
}

# Matching IMAGE and VERSION proceed to the stubbed container-start boundary.
run_guard
[[ ${run_status} -eq 0 && -e "${STARTUP_MARKER}" ]] || fail 'matching runtime versions were rejected'

# These regressions must both fail against the former IMAGE-only guard.
missed_versions=0
for version in '19.0.0' ''; do
  MOD_USERS_VERSION="${version}"
  run_guard
  if [[ ${run_status} -eq 0 || -e "${STARTUP_MARKER}" ]]; then
    printf "FAIL: VERSION-only override '%s' reached container startup\n" "${version}" >&2
    missed_versions=$((missed_versions + 1))
  fi
done
[[ ${missed_versions} -eq 0 ]] || fail 'VERSION-only and empty overrides were not rejected'
assert_halt 'empty VERSION override'
grep -Fq "MOD_USERS_VERSION='' (shell override)" "${stderr_file}" \
  || fail 'empty VERSION diagnostic does not identify its value and source'

MOD_USERS_VERSION='19.0.0'
run_guard
assert_halt 'VERSION-only override'
grep -Fq "MOD_USERS_VERSION='19.0.0' (shell override)" "${stderr_file}" \
  || fail 'VERSION diagnostic does not identify its value and source'
grep -q 'descriptor 19.6.0' "${stderr_file}" || fail 'diagnostic omits expected descriptor version'
if grep -q 'MOD_USERS_IMAGE=' "${stderr_file}"; then
  fail 'matching IMAGE was incorrectly reported as mismatched'
fi

MOD_USERS_IMAGE='custom/mod-users:19.0.0'
MOD_USERS_VERSION='19.6.0'
run_guard
assert_halt 'IMAGE-only override'
grep -Fq "MOD_USERS_IMAGE='custom/mod-users:19.0.0' (shell override)" "${stderr_file}" \
  || fail 'IMAGE diagnostic does not identify its value and source'

MOD_USERS_VERSION='19.0.0'
run_guard
assert_halt 'IMAGE and VERSION overrides'
grep 'mod-users: descriptor' "${stderr_file}" | grep -q 'MOD_USERS_IMAGE=.*MOD_USERS_VERSION=' \
  || fail 'both mismatched variables were not reported in the same module diagnostic'

for image in 'folioorg/mod-users' 'folioorg/mod-users@sha256:abcdef'; do
  MOD_USERS_IMAGE="${image}"
  MOD_USERS_VERSION='19.6.0'
  run_guard
  [[ ${run_status} -eq 0 && -e "${STARTUP_MARKER}" ]] || fail "IMAGE exemption rejected ${image}"
  MOD_USERS_VERSION='19.0.0'
  run_guard
  assert_halt "VERSION override with ${image}"
  grep -q 'MOD_USERS_VERSION=' "${stderr_file}" || fail 'IMAGE exemption hid VERSION skew'
  if grep -q 'MOD_USERS_IMAGE=' "${stderr_file}"; then
    fail 'tagless/digest IMAGE was incorrectly reported as mismatched'
  fi
done

printf 'ok  descriptor/runtime skew halts before container startup with variable provenance\n'
