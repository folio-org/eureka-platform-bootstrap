#!/usr/bin/env bash
#
# Offline regression check for FOLIO UI host/browser gateway resolution.
#
# build-folio-ui.sh prepares browser-facing config. It must not use the
# Compose-internal OKAPI_URL inherited from docker/.env as the browser Kong URL.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

repo_dir="$(mktemp -d)"
output_file="$(mktemp)"
trap 'rm -rf "${repo_dir}" "${output_file}"' EXIT

mkdir -p "${repo_dir}/.git" "${repo_dir}/eureka-tpl"
cat > "${repo_dir}/eureka-tpl/stripes.config.js" <<'EOF'
module.exports = {
  okapi: '${kongUrl}',
  tenantUrl: '${tenantUrl}',
  config: { keycloakUrl: '${keycloakUrl}' },
  tenantOptions: ${tenantOptions},
  modules: {
    '@folio/users' : {}
  }
};
EOF
cat > "${repo_dir}/package.json" <<'EOF'
{
  "dependencies": {},
  "scripts": {}
}
EOF

run_build_folio_ui() {
  : > "${output_file}"
  (
    cd "${PROJECT_ROOT}"
    REPO_DIR="${repo_dir}" \
      UPDATE_REPO=false \
      SKIP_BUILD=true \
      TENANT_IDS=diku \
      OKAPI_URL='http://api-gateway:8000' \
      "$@"
  ) >"${output_file}" 2>&1
}

assert_stripes_gateway() {
  local expected="$1"

  grep -q "okapi: '${expected}'" "${repo_dir}/stripes.config.js" \
    || { cat "${repo_dir}/stripes.config.js" >&2; cat "${output_file}" >&2; fail "UI config did not use ${expected}"; }
  if grep -q 'http://api-gateway:8000' "${repo_dir}/stripes.config.js"; then
    cat "${repo_dir}/stripes.config.js" >&2
    fail "UI config used Compose-internal OKAPI_URL"
  fi
}

run_build_folio_ui bash misc/build-folio-ui.sh
assert_stripes_gateway 'http://localhost:8000'

KONG_URL='http://gateway.example.test:18000' run_build_folio_ui bash misc/build-folio-ui.sh
assert_stripes_gateway 'http://gateway.example.test:18000'

printf 'ok  build-folio-ui.sh uses host/browser gateway URLs\n'
