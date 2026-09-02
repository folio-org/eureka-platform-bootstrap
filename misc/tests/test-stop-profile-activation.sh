#!/usr/bin/env bash
#
# Regression: every `docker compose down`/`stop` in stop.sh must activate
# Compose profiles. Every service in the stack is gated behind a profile
# (core, mgr-components, app-platform-minimal), so a bare
# `docker compose down` resolves to an empty default service set and
# silently no-ops (exit 0, no containers stopped) -- the script reports
# success while leaving the stack running. This test would have caught
# the original bug.
#
# Hermetic: static grep on stop.sh, no Docker, no network.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

stop_sh="${PROJECT_ROOT}/stop.sh"
[[ -f "${stop_sh}" ]] || fail 'stop.sh not found'

# Collect non-comment lines that invoke `docker compose down` or `stop`.
mapfile -t compose_lines < <(
  grep -nE 'docker[[:space:]]+compose[[:space:]]+(down|stop)' "${stop_sh}" \
    | grep -vE '^[0-9]+:[[:space:]]*#'
) || true

[[ ${#compose_lines[@]} -gt 0 ]] || fail 'no docker compose down/stop invocations found in stop.sh'

for entry in "${compose_lines[@]}"; do
  lineno="${entry%%:*}"
  text="${entry#*:}"

  # Accept either:
  #   (a) --profile <name> on the same line, or
  #   (b) COMPOSE_PROFILES= set on the same line (e.g. as a ui_run prefix) or
  #       on the immediately preceding non-comment line (line-continuation form).
  if [[ "${text}" == *'--profile'* ]]; then
    continue
  fi
  if [[ "${text}" == *'COMPOSE_PROFILES='* ]]; then
    continue
  fi

  prev_lineno=$((lineno - 1))
  if [[ ${prev_lineno} -gt 0 ]]; then
    prev_line="$(sed -n "${prev_lineno}p" "${stop_sh}")"
    if [[ "${prev_line}" == *'COMPOSE_PROFILES='* && "${prev_line}" != *'#'* ]]; then
      continue
    fi
  fi

  fail "docker compose down/stop at ${stop_sh}:${lineno} has no --profile and no COMPOSE_PROFILES= activation"
done

printf 'ok  stop.sh activates Compose profiles on every down/stop invocation\n'
