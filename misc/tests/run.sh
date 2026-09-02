#!/usr/bin/env bash
#
# Lightweight, offline test runner for eureka-platform-bootstrap.
#
# Runs cheap gates that need no running environment:
#   1. Bash syntax check (`bash -n`) over the entrypoint and libraries.
#   2. Python unit tests for the descriptor-driven helpers.
#   3. Shell functional tests (e.g. .env.local rerun idempotency).
#
# This is the regression net for refactors. The full proof is still a real
# `./start.sh` run with the post-bootstrap smoke check.
#
# Usage: bash misc/tests/run.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${PROJECT_ROOT}"

failures=0

echo "==> Bash syntax checks"
# Discover every tracked shell script so coverage never drifts as scripts are
# added or moved. Bash 3.2-safe (no mapfile); git ls-files works offline.
shell_targets=()
while IFS= read -r target; do
  shell_targets+=("${target}")
done < <(git ls-files '*.sh' 2>/dev/null)
if [[ ${#shell_targets[@]} -eq 0 ]]; then
  # Fallback for non-git checkouts.
  while IFS= read -r target; do
    shell_targets+=("${target}")
  done < <(find . -type f -name '*.sh' -not -path './.git/*' | sort)
fi
for target in "${shell_targets[@]}"; do
  [[ -f "${target}" ]] || continue
  if bash -n "${target}"; then
    echo "  ok  ${target}"
  else
    echo "  FAIL ${target}"
    failures=$((failures + 1))
  fi
done

echo "==> Bash 3.2 portability guard"
# Case-modification parameter expansions (uppercase/lowercase-first) are bash 4.0+
# and a PARSE error on macOS stock bash 3.2 -- which `bash -n` under a newer bash
# will not catch. A caret or comma immediately after a parameter name can only be
# case-mod, so this scan is prose-safe (no false positives from words like mapfile
# or declare appearing in comments).
if bad="$(grep -En '\$\{[A-Za-z_][A-Za-z0-9_]*(\^|,)' "${shell_targets[@]}" 2>/dev/null)"; then
  echo "  FAIL bash 4.0+ case-modification expansion(s) found (break macOS bash 3.2):"
  printf '%s\n' "${bad}" | sed 's/^/    /'
  failures=$((failures + 1))
else
  echo "  ok  no bash 4.0+ case-modification expansions"
fi

echo "==> Python compile checks"
python_targets=(
  misc/module-version-actualizer.py
  misc/docker-module-updater/run.py
)
for target in "${python_targets[@]}"; do
  if python3 -m py_compile "${target}"; then
    echo "  ok  ${target}"
  else
    echo "  FAIL ${target}"
    failures=$((failures + 1))
  fi
done

echo "==> Python unit tests"
if python3 -m unittest discover -s misc/tests -p 'test_*.py' -v; then
  echo "  ok  unit tests"
else
  echo "  FAIL unit tests"
  failures=$((failures + 1))
fi

echo "==> Shell functional tests"
shell_tests=(
  misc/tests/test-bootstrap-create-user-gateway.sh
  misc/tests/test-bootstrap-ui-gateway.sh
  misc/tests/test-build-folio-ui-host-gateway.sh
  misc/tests/test-build-images-effective-sidecar.sh
  misc/tests/test-build-images-effective-module-override.sh
  misc/tests/test-build-images-vault-decision.sh
  misc/tests/test-create-user-host-gateway.sh
  misc/tests/test-create-user-idempotent.sh
  misc/tests/test-native-sidecar-effective-tag.sh
  misc/tests/test-preflight-host.sh
  misc/tests/test-sidecar-resources.sh
  misc/tests/test-build-images-failure.sh
  misc/tests/test-native-sidecar-not-in-arm-queue.sh
  misc/tests/test-image-freshness.sh
  misc/tests/test-vault-token.sh
  misc/tests/test-credentials-initialization.sh
  misc/tests/test-config-precedence.sh
  misc/tests/test-start-fixed-bootstrap-scope.sh
  misc/tests/test-start-descriptor-path-override.sh
  misc/tests/test-descriptor-image-skew.sh
  misc/tests/test-ui-stream-contract.sh
  misc/tests/test-ui-spin-frame.sh
  misc/tests/test-ui-run-errexit-restore.sh
  misc/tests/test-ui-run-tail.sh
  misc/tests/test-ui-capture-contract.sh
  misc/tests/test-stop-output.sh
  misc/tests/test-stop-profile-activation.sh
  misc/tests/test-native-compose-surface.sh
)
for target in "${shell_tests[@]}"; do
  if bash "${target}"; then
    echo "  ok  ${target}"
  else
    echo "  FAIL ${target}"
    failures=$((failures + 1))
  fi
done

echo
if [[ ${failures} -eq 0 ]]; then
  echo "All checks passed."
else
  echo "${failures} check group(s) failed."
  exit 1
fi
