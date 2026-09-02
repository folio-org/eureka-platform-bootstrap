#!/usr/bin/env bash
#
# Offline proof of the supported config precedence (GAP-002).
#
# Pins the contract that load_folio_config enforces:
#   shell environment  >  .env.local.credentials  >  .env.local  >  .env
#
# Hermetic: it points FOLIO_DOCKER_DIR at a temp dir with crafted env files and
# calls the real loader. No Docker, no network.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/misc/lib/folio-common.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

cat > "${tmp}/.env" <<'EOF'
export TEST_PREC_SHARED=from_defaults
export TEST_PREC_CRED_ONLY=from_defaults
export TEST_PREC_LOCAL_ONLY=from_defaults
export TEST_PREC_DEFAULT_ONLY=from_defaults
export TEST_PREC_SHELL=from_defaults
EOF

cat > "${tmp}/.env.local.credentials" <<'EOF'
export TEST_PREC_SHARED=from_credentials
export TEST_PREC_CRED_ONLY=from_credentials
EOF

cat > "${tmp}/.env.local" <<'EOF'
export TEST_PREC_SHARED=from_local
export TEST_PREC_CRED_ONLY=from_local
export TEST_PREC_LOCAL_ONLY=from_local
export TEST_PREC_SHELL=from_local
EOF

# Highest-precedence layer: a value already in the shell environment.
TEST_PREC_SHELL=from_shell

FOLIO_DOCKER_DIR="${tmp}"
load_folio_config

[[ "${TEST_PREC_SHELL}" == "from_shell" ]] \
  || fail "shell env should beat both files (got '${TEST_PREC_SHELL}')"
[[ "${TEST_PREC_CRED_ONLY}" == "from_credentials" ]] \
  || fail "credentials should beat local (got '${TEST_PREC_CRED_ONLY}')"
[[ "${TEST_PREC_SHARED}" == "from_credentials" ]] \
  || fail "credentials should beat local for shared var (got '${TEST_PREC_SHARED}')"
[[ "${TEST_PREC_LOCAL_ONLY}" == "from_local" ]] \
  || fail "local-only value should load (got '${TEST_PREC_LOCAL_ONLY}')"
[[ "${TEST_PREC_DEFAULT_ONLY}" == "from_defaults" ]] \
  || fail "default-only value should load (got '${TEST_PREC_DEFAULT_ONLY}')"

echo "ok  config precedence: shell > credentials > local > defaults"
