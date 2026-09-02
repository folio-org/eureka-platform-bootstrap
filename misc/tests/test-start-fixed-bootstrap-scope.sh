#!/usr/bin/env bash
#
# Public start.sh contract: this repo bootstraps its bundled app-platform-minimal
# environment. Descriptor selection is not an operator-facing option.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

help_output="$("${PROJECT_ROOT}/start.sh" --help 2>&1)"
if grep -q -- '--app' <<<"${help_output}"; then
  printf '%s\n' "${help_output}" | sed 's/^/help: /' >&2
  fail 'start.sh help still advertises custom application descriptors'
fi
if grep -qi -- 'descriptor to bootstrap' <<<"${help_output}"; then
  printf '%s\n' "${help_output}" | sed 's/^/help: /' >&2
  fail 'start.sh help still describes descriptor selection as an operator feature'
fi

set +e
app_output="$("${PROJECT_ROOT}/start.sh" --app descriptors/app-platform-minimal/descriptor.json 2>&1)"
app_status=$?
set -e

[[ ${app_status} -ne 0 ]] || fail 'start.sh --app unexpectedly succeeded'
grep -q -- 'Unknown argument: --app' <<<"${app_output}" || {
  printf '%s\n' "${app_output}" | sed 's/^/out: /' >&2
  fail 'start.sh --app did not fail through the normal unknown-argument path'
}

printf 'ok  start.sh public scope is fixed to the bundled Eureka bootstrap\n'
