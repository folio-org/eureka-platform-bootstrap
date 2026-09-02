#!/usr/bin/env bash
#
# Offline regression check for host-side create-user.sh gateway resolution.
#
# create-user.sh runs on the host, while docker/.env's OKAPI_URL is intentionally
# a Compose-internal URL for containers. This test proves the helper does not
# inherit that container URL for its host HTTP calls.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }

stub_bin="$(mktemp -d)"
url_log="$(mktemp)"
output_file="$(mktemp)"
trap 'rm -rf "${stub_bin}" "${url_log}" "${output_file}"' EXIT

cat > "${stub_bin}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

url=''
for arg in "$@"; do
  case "$arg" in
    http://*|https://*) url="$arg" ;;
  esac
done

printf '%s\n' "$url" >> "${CURL_URL_LOG:?}"

case "$url" in
  http://localhost:8200/*)
    printf '{"data":{"data":{"m2m-client":"tenant-secret"}}}\n200\n'
    ;;
  http://localhost:8080/*/protocol/openid-connect/token)
    printf '{"access_token":"tenant-token"}\n'
    ;;
  */users-keycloak/users)
    printf '{"id":"user-id"}\n201\n'
    ;;
  */authn/credentials)
    printf '{}\n201\n'
    ;;
  */roles\?query=*)
    printf '{"roles":[{"id":"role-id"}],"totalRecords":1}\n200\n'
    ;;
  */capabilities\?limit=2000)
    printf '{"capabilities":[{"id":"cap-id"}],"totalRecords":1}\n200\n'
    ;;
  */roles/role-id/capabilities)
    printf '\n204\n'
    ;;
  */capability-sets\?limit=2000)
    printf '{"capabilitySets":[],"totalRecords":0}\n200\n'
    ;;
  */roles/users)
    printf '{}\n201\n'
    ;;
  */authn/login)
    printf '{"okapiToken":"login-token"}\n201\n'
    ;;
  */users-keycloak/_self)
    printf '{"permissions":{"permissions":["all"]}}\n200\n'
    ;;
  *)
    printf 'unexpected curl URL: %s\n' "$url" >&2
    exit 9
    ;;
esac
EOF
chmod +x "${stub_bin}/curl"

run_create_user() {
  : > "${url_log}"
  : > "${output_file}"
  (
    cd "${PROJECT_ROOT}"
    PATH="${stub_bin}:${PATH}" \
      CURL_URL_LOG="${url_log}" \
      START_OUTPUT_MODE=normal \
      bash misc/create-user.sh folio folio
  ) >"${output_file}" 2>&1
}

assert_host_gateway_used() {
  local expected_gateway="$1"

  grep -q "${expected_gateway}/users-keycloak/users" "${url_log}" \
    || { cat "${url_log}" >&2; cat "${output_file}" >&2; fail "create-user.sh did not use ${expected_gateway}"; }
  if grep -q 'http://api-gateway:8000' "${url_log}"; then
    cat "${url_log}" >&2
    fail "create-user.sh used Compose-internal api-gateway URL from docker/.env"
  fi
}

run_create_user
assert_host_gateway_used 'http://localhost:8000'

OKAPI_URL='http://okapi.example.test:18000' run_create_user
assert_host_gateway_used 'http://okapi.example.test:18000'

FOLIO_KONG_URL='http://folio-kong.example.test:18000' run_create_user
assert_host_gateway_used 'http://folio-kong.example.test:18000'

KONG_URL='http://kong.example.test:18000' \
  FOLIO_KONG_URL='http://folio-kong.example.test:18000' \
  run_create_user
assert_host_gateway_used 'http://kong.example.test:18000'

API_GATEWAY_URL='http://gateway.example.test:18000' run_create_user
assert_host_gateway_used 'http://gateway.example.test:18000'

echo "ok  create-user.sh uses a host gateway URL and honors host gateway overrides"
