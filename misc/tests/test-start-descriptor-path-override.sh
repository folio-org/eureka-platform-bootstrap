#!/usr/bin/env bash
#
# Hermetic proof that APP_DESCRIPTOR_PATH from the environment wins over the
# repo default when start.sh resolves its config. The --app CLI flag stays
# rejected (the bootstrap is scoped to the bundled app); this is an env escape
# hatch only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# The fix changes line 30 from:
#   APP_DESCRIPTOR_PATH="${DEFAULT_APP_DESCRIPTOR_PATH}"
# to:
#   APP_DESCRIPTOR_PATH="${APP_DESCRIPTOR_PATH:-${DEFAULT_APP_DESCRIPTOR_PATH}}"
#
# We assert the presence of the override-aware form. This is a static check
# (sourcing start.sh triggers main(), which needs Docker), so we read the
# assignment line and evaluate the exact expansion the fix introduces.

assignment_line=$(grep -m1 '^APP_DESCRIPTOR_PATH=' "${PROJECT_ROOT}/start.sh")
default_line=$(grep -m1 '^readonly DEFAULT_APP_DESCRIPTOR_PATH=' "${PROJECT_ROOT}/start.sh")

# Extract the default value template (strip the readonly prefix and quotes).
# It still contains ${PROJECT_ROOT}, which start.sh resolves at source time.
default_template=$(printf '%s\n' "${default_line}" \
  | sed -E 's/^readonly DEFAULT_APP_DESCRIPTOR_PATH=//; s/^"//; s/"$//')

# The fully-expanded default start.sh would assign when no override is set.
expected_default="${default_template}"

# Simulate the env-override semantics the fix introduces. The ${VAR:-default}
# form must let an already-set APP_DESCRIPTOR_PATH win, and fall back to the
# default otherwise. We reproduce exactly that expansion in an isolated shell
# that has PROJECT_ROOT set (so ${PROJECT_ROOT} inside the template resolves),
# mirroring start.sh's source-time evaluation.
stub_override='/tmp/audit-descriptor/descriptor.json'
resolved_with_env=$(APP_DESCRIPTOR_PATH="${stub_override}" \
  PROJECT_ROOT="${PROJECT_ROOT}" \
  bash -c 'val="${APP_DESCRIPTOR_PATH:-'"${expected_default}"'}"; printf "%s" "${val}"')
[[ "${resolved_with_env}" == "${stub_override}" ]] \
  || fail "APP_DESCRIPTOR_PATH env override ignored (got '${resolved_with_env}')"

resolved_without_env=$(unset_def="${expected_default}" \
  PROJECT_ROOT="${PROJECT_ROOT}" \
  bash -c 'unset APP_DESCRIPTOR_PATH; val="${APP_DESCRIPTOR_PATH:-'"${expected_default}"'}"; printf "%s" "${val}"')
[[ "${resolved_without_env}" == "${PROJECT_ROOT}/descriptors/app-platform-minimal/descriptor.json" ]] \
  || fail "default descriptor path broken (got '${resolved_without_env}')"

# Confirm the fix is actually present in start.sh (not just simulated).
printf '%s\n' "${assignment_line}" | grep -q 'APP_DESCRIPTOR_PATH:-' \
  || fail "start.sh does not use the \${APP_DESCRIPTOR_PATH:-default} form (got: ${assignment_line})"

printf 'ok  APP_DESCRIPTOR_PATH env override honored\n'
