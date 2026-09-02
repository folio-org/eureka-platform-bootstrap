#!/usr/bin/env bash
#
# Offline failure-propagation check for misc/images-builder/build.sh.
#
# GAP-001: the image builder used to record failed module builds but still exit 0,
# so the bootstrap continued with missing images. This test proves the builder now
# exits non-zero and lists the failed modules.
#
# It is fully hermetic: git/docker/mvn are stubbed on PATH (no Docker, no network).
# The real jq and the real descriptor drive the module loop.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }

stub_bin="$(mktemp -d)"
output_file="$(mktemp)"
trap 'rm -rf "${stub_bin}" "${output_file}"' EXIT

# Fake git: every clone fails, so every module is recorded as failed. No network.
cat > "${stub_bin}/git" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  clone) echo "stub git: clone refused" >&2; exit 1 ;;
  *) exit 0 ;;
esac
EOF

# Fake docker: report the base openjdk images as native arm64 (so the base image
# build is skipped — no clone, no buildx), and report every other image as absent
# so module builds are attempted (and then fail at the stubbed git clone).
cat > "${stub_bin}/docker" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "buildx version") exit 0 ;;
  "buildx build") exit 0 ;;
  "image inspect")
    for arg in "$@"; do
      case "$arg" in *openjdk*) echo "arm64"; exit 0 ;; esac
    done
    exit 1
    ;;
  *) exit 0 ;;
esac
EOF

# Fake mvn: unreached (git clone fails first), but present so command -v passes.
cat > "${stub_bin}/mvn" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "${stub_bin}/git" "${stub_bin}/docker" "${stub_bin}/mvn"

# Run the builder from the repo root (as the bootstrap does) with stubs first on
# PATH. Real jq/mktemp/sort/etc. remain available via the inherited PATH.
set +e
(
  cd "${PROJECT_ROOT}"
  PATH="${stub_bin}:${PATH}" bash misc/images-builder/build.sh
) > "${output_file}" 2>&1
status=$?
set -e

[[ ${status} -ne 0 ]] || fail "build.sh exited 0 despite failed module builds"
grep -q "The following modules failed to build:" "${output_file}" \
  || { cat "${output_file}" >&2; fail "build.sh did not list failed modules"; }

# Build logs are folded into per-module files; on failure the failing module's
# log tail must still reach the console so the operator sees the real error.
grep -q "build log (last 40 lines):" "${output_file}" \
  || { cat "${output_file}" >&2; fail "build.sh did not surface a failed module's log"; }
grep -q "stub git: clone refused" "${output_file}" \
  || { cat "${output_file}" >&2; fail "captured build log content did not reach the output"; }

# Piped output must stay escape-free (console-UI contract): no spinner leaks.
if grep -q $'\033' "${output_file}"; then
  cat "${output_file}" >&2
  fail "piped build.sh output contains escape bytes"
fi

echo "ok  build.sh fails non-zero, lists failed modules, and surfaces their logs"
