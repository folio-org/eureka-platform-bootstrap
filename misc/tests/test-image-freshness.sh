#!/usr/bin/env bash
#
# Hermetic checks for the image-freshness additions in bootstrap-engine.sh:
# image_age renders a present image's age and "-" when absent; prompt_image_refresh
# does not arm a rebuild when there is nothing to refresh or --yes was given;
# refresh_amd64_images pulls the planned folio refs and tolerates a failed pull.
# No real Docker: docker is stubbed on PATH. Cross-platform date math is asserted
# to go through python3 (no GNU-only `date -d`).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

DEBUG=false
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/misc/lib/folio-common.sh"
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/misc/bootstrap-engine.sh"

stub_bin="$(mktemp -d)"
pull_log="$(mktemp)"
trap 'rm -rf "${stub_bin}" "${pull_log}"' EXIT

# Stubbed docker:
#  - image inspect --format '{{.Created}}' <ref>: a ~10-day-old timestamp for a
#    ref containing "present", empty (absent) otherwise.
#  - image inspect --format '{{json .Config.Entrypoint}}' <ref>: native-like
#    entrypoint for refs containing "native-entrypoint", JVM-like otherwise.
#  - pull <ref>: log the ref; fail for a ref containing "boom".
cat > "${stub_bin}/docker" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "image" && "\$2" == "inspect" ]]; then
  fmt="\$4"; ref="\$5"
  if [[ "\$fmt" == *Created* && "\$ref" == *present* ]]; then
    python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=10)).strftime("%Y-%m-%dT%H:%M:%S.000000000Z"))'
  elif [[ "\$fmt" == *Architecture* && "\$ref" == *arm* ]]; then
    printf 'arm64\n'
  elif [[ "\$fmt" == *Entrypoint* && "\$ref" == *native-entrypoint* ]]; then
    printf '["./application","-Dquarkus.http.host=0.0.0.0"]\n'
  elif [[ "\$fmt" == *Entrypoint* ]]; then
    printf '["java","-jar","/usr/verticles/folio-module-sidecar.jar"]\n'
  fi
  exit 0
fi
if [[ "\$1" == "pull" ]]; then
  printf '%s\n' "\$2" >> "${pull_log}"
  [[ "\$2" == *boom* ]] && exit 1
  exit 0
fi
exit 0
EOF
chmod +x "${stub_bin}/docker"
export PATH="${stub_bin}:${PATH}"

# --- image_age ---------------------------------------------------------------
age="$(image_age 'folioci/present-mod:latest')"
[[ "${age}" =~ ^[0-9]+d\ ago$ ]] || fail "present image age not rendered as 'Nd ago' (got '${age}')"

age="$(image_age 'folioci/missing-mod:latest')"
[[ "${age}" == '-' ]] || fail "absent image age not rendered as '-' (got '${age}')"

# --- prompt_image_refresh gating --------------------------------------------
# Nothing to refresh -> never arms a rebuild.
( IMAGE_REFRESH_AVAILABLE=false; REBUILD_BUILT_IMAGES=false
  prompt_image_refresh </dev/null
  [[ "${REBUILD_BUILT_IMAGES}" == 'false' ]] || fail 'prompt armed a rebuild with nothing to refresh'
) || exit 1

# Refreshable but --yes -> unattended runs never auto-refresh.
( IMAGE_REFRESH_AVAILABLE=true; ASSUME_YES=true; REBUILD_BUILT_IMAGES=false
  prompt_image_refresh </dev/null
  [[ "${REBUILD_BUILT_IMAGES}" == 'false' ]] || fail '--yes unexpectedly armed an image refresh'
) || exit 1

# Refreshable, interactive prompt, but non-tty stdin -> skipped (no hang).
( IMAGE_REFRESH_AVAILABLE=true; ASSUME_YES=false; REBUILD_BUILT_IMAGES=false
  prompt_image_refresh </dev/null
  [[ "${REBUILD_BUILT_IMAGES}" == 'false' ]] || fail 'non-interactive prompt armed a refresh'
) || exit 1

# --- arm_image_refresh (the "yes" effect) ------------------------------------
# The tty-gated read cannot be driven in a non-interactive test, so the armed
# effect is verified directly: a "yes" must both request a rebuild and route the
# arm build to its live-output branch.
( REBUILD_BUILT_IMAGES=false; IMAGE_BUILD_PENDING=false
  arm_image_refresh
  [[ "${REBUILD_BUILT_IMAGES}" == 'true' ]] || fail 'arm_image_refresh did not set REBUILD_BUILT_IMAGES'
  [[ "${IMAGE_BUILD_PENDING}" == 'true' ]] || fail 'arm_image_refresh did not set IMAGE_BUILD_PENDING'
) || exit 1

# --- native_sidecar_reusable (the widened refresh condition) ------------------
# arm64 native-image entrypoint, no refresh requested -> reuse.
( REBUILD_NATIVE_SIDECAR=false; REBUILD_BUILT_IMAGES=false
  native_sidecar_reusable 'folioci/folio-module-sidecar-arm-native-entrypoint:native' \
    || fail 'arm64 native sidecar image with no refresh requested should be reusable'
) || exit 1

# arm64 image, but a refresh was requested -> must NOT reuse (rebuild).
( REBUILD_NATIVE_SIDECAR=false; REBUILD_BUILT_IMAGES=true
  if native_sidecar_reusable 'folioci/folio-module-sidecar-arm-native-entrypoint:native'; then
    fail 'REBUILD_BUILT_IMAGES=true must force a native sidecar rebuild'
  fi
) || exit 1

# arm64 image, explicit sidecar rebuild flag -> must NOT reuse.
( REBUILD_NATIVE_SIDECAR=true; REBUILD_BUILT_IMAGES=false
  if native_sidecar_reusable 'folioci/folio-module-sidecar-arm-native-entrypoint:native'; then
    fail 'REBUILD_NATIVE_SIDECAR=true must force a native sidecar rebuild'
  fi
) || exit 1

# arm64 JVM image under the same tag -> must NOT reuse as native.
( REBUILD_NATIVE_SIDECAR=false; REBUILD_BUILT_IMAGES=false
  if native_sidecar_reusable 'folioci/folio-module-sidecar-arm-jvm:native'; then
    fail 'an arm64 JVM sidecar image must not be reused as native'
  fi
) || exit 1

# non-arm64 (e.g. a pulled amd64) image -> must NOT reuse even with no flags.
( REBUILD_NATIVE_SIDECAR=false; REBUILD_BUILT_IMAGES=false
  if native_sidecar_reusable 'folioci/folio-module-sidecar-amd-native-entrypoint:native'; then
    fail 'a non-arm64 image must not be reused (would run under emulation)'
  fi
) || exit 1

# --- refresh_amd64_images ----------------------------------------------------
( REBUILD_BUILT_IMAGES=true
  PLAN_IMAGE_REFS=('folioci/present-mod:latest' 'folioci/boom-mod:latest')
  refresh_amd64_images >/dev/null 2>&1 || fail 'refresh_amd64_images failed despite a tolerated pull error'
)
grep -q 'folioci/present-mod:latest' "${pull_log}" || fail 'refresh did not pull the present ref'
grep -q 'folioci/boom-mod:latest' "${pull_log}" || fail 'refresh did not attempt the failing ref'

# No-op when not requested.
: > "${pull_log}"
( REBUILD_BUILT_IMAGES=false
  PLAN_IMAGE_REFS=('folioci/present-mod:latest')
  refresh_amd64_images >/dev/null 2>&1
)
[[ -s "${pull_log}" ]] && fail 'refresh pulled images without REBUILD_BUILT_IMAGES'

# --- cross-platform guard ----------------------------------------------------
grep -q 'date -d' "${PROJECT_ROOT}/misc/bootstrap-engine.sh" \
  && fail 'bootstrap-engine.sh uses GNU-only `date -d` for age math'

printf 'ok  image freshness: age column, refresh prompt gating, and amd64 pull\n'
