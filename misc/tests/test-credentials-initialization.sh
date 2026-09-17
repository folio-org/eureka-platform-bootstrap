#!/usr/bin/env bash
#
# docker/.env.local.credentials persistence:
#   - deterministic dev defaults are NOT seeded there (they live committed in
#     docker/.env; the generated file holds only the runtime Vault token);
#   - persisting a token preserves operator-added lines and replaces any
#     previous token in place.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

creds_file="${work}/.env.local.credentials"

persist_token() (
  cd "${work}"
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/misc/lib/folio-common.sh"
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/docker/lib/local-credentials.sh"
  persist_vault_root_token "$1"
)

# First persistence creates the file with the token and no seeded defaults.
persist_token 's.firstToken' >/dev/null 2>&1
grep -q 'export SECRET_STORE_VAULT_TOKEN=s.firstToken' "${creds_file}" \
  || { cat "${creds_file}" >&2; fail 'first persistence is missing the token'; }
if grep -Eq 'POSTGRES_PASSWORD|KC_ADMIN_PASSWORD' "${creds_file}"; then
  cat "${creds_file}" >&2
  fail 'first persistence seeded deterministic defaults (they belong in docker/.env)'
fi

# Operator-added secrets survive a token refresh, and an old token is replaced.
printf 'export POSTGRES_PASSWORD=operator-choice\n' >> "${creds_file}"
persist_token 's.secondToken' >/dev/null 2>&1
grep -qx 'export POSTGRES_PASSWORD=operator-choice' "${creds_file}" \
  || { cat "${creds_file}" >&2; fail 'operator-added secret did not survive a token refresh'; }
grep -q 'export SECRET_STORE_VAULT_TOKEN=s.secondToken' "${creds_file}" \
  || { cat "${creds_file}" >&2; fail 'refreshed token missing'; }
[[ "$(grep -c 'SECRET_STORE_VAULT_TOKEN=' "${creds_file}")" == '1' ]] \
  || { cat "${creds_file}" >&2; fail 'token appears more than once after refresh'; }
if grep -q 's.firstToken' "${creds_file}"; then
  cat "${creds_file}" >&2
  fail 'stale token survived the refresh'
fi

echo 'ok  credentials file holds only the Vault token and preserves operator lines'
