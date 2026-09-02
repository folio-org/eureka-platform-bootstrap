#!/usr/bin/env bash
#
# Offline check for the internal Vault token retrieval/persistence path.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }

work="$(mktemp -d)"
stub_bin="$(mktemp -d)"
trap 'rm -rf "${work}" "${stub_bin}"' EXIT

creds_file="${work}/.env.local.credentials"

cat > "${stub_bin}/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == 'logs' ]]; then
  printf '%s\n' "${DOCKER_VAULT_LOGS:-}"
fi
EOF
chmod +x "${stub_bin}/docker"
export PATH="${stub_bin}:${PATH}"

read_token() (
  cd "${work}"
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/misc/lib/folio-common.sh"
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/docker/lib/local-credentials.sh"
  read_vault_root_token
)

persist_token() (
  cd "${work}"
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/misc/lib/folio-common.sh"
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/docker/lib/local-credentials.sh"
  persist_vault_root_token "$1"
)

set +e
DOCKER_VAULT_LOGS='vault: starting in dev mode' read_token >/dev/null 2>&1
status=$?
set -e
[[ ${status} -ne 0 ]] || fail 'read_vault_root_token exited 0 with no token in logs'

set +e
persist_token '' >/dev/null 2>&1
status=$?
set -e
[[ ${status} -ne 0 ]] || fail 'persist_vault_root_token accepted an empty token'
if [[ -f "${creds_file}" ]] && grep -q 'SECRET_STORE_VAULT_TOKEN' "${creds_file}"; then
  fail 'persist_vault_root_token wrote a token despite an empty input'
fi

expected_token='s.testRootToken123'
out="$(DOCKER_VAULT_LOGS="some line
Root VAULT TOKEN is: ${expected_token}
trailing line" read_token)"
[[ "${out}" == "${expected_token}" ]] || fail "reader returned '${out}', expected '${expected_token}'"

persist_token "${expected_token}" >/dev/null 2>&1
grep -q "SECRET_STORE_VAULT_TOKEN=${expected_token}" "${creds_file}" \
  || { cat "${creds_file}" >&2; fail 'credentials file is missing the expected token'; }

echo 'ok  vault token reader fails on empty input and persists a real token'
