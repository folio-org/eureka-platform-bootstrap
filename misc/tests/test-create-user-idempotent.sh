#!/usr/bin/env bash
#
# Hermetic checks for create-user.sh's idempotent re-run and capability-set
# assignment, plus the jq-guard reachability fix. The curl stub on PATH drives the
# "already provisioned" responses a second `./start.sh` would see:
#   - user POST -> 409, then the existing-user GET -> 200 (the .users[0].id path)
#   - credentials -> 422 (already set), role lookup -> existing role
#   - capability-sets NON-EMPTY -> PUT /roles/<id>/capability-sets (204)
#   - role-to-user -> 409 (already assigned)
# A BAD_LOGIN toggle returns a non-JSON login body to prove the guarded token
# extraction surfaces the structured "Login failed" error, not a raw jq abort.
# No real Docker/network: SECRET_STORE_VAULT_TOKEN is injected; curl is stubbed.

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
    printf '{"data":{"data":{"m2m-client":"tenant-secret"}}}\n200\n' ;;
  http://localhost:8080/*/protocol/openid-connect/token)
    printf '{"access_token":"tenant-token"}\n' ;;
  */users-keycloak/users)
    # User already exists on a re-run.
    printf '{"errors":[{"message":"already exists"}]}\n409\n' ;;
  */users-keycloak/users\?query=username==*)
    printf '{"users":[{"id":"user-id"}]}\n200\n' ;;
  */authn/credentials)
    # Credentials already configured.
    printf '{}\n422\n' ;;
  */roles\?query=*)
    printf '{"roles":[{"id":"role-id"}],"totalRecords":1}\n200\n' ;;
  */capabilities\?limit=2000)
    printf '{"capabilities":[{"id":"cap-id"}],"totalRecords":1}\n200\n' ;;
  */roles/role-id/capabilities)
    printf '\n204\n' ;;
  */capability-sets\?limit=2000)
    printf '{"capabilitySets":[{"id":"cs-id"}],"totalRecords":1}\n200\n' ;;
  */roles/role-id/capability-sets)
    printf '\n204\n' ;;
  */roles/users)
    # Role already assigned to the user.
    printf '{"errors":[{"message":"Relation already exists"}]}\n409\n' ;;
  */authn/login)
    if [[ "${BAD_LOGIN:-}" == 1 ]]; then
      printf '<html>502 Bad Gateway</html>\n502\n'
    else
      printf '{"okapiToken":"login-token"}\n201\n'
    fi ;;
  */users-keycloak/_self)
    printf '{"permissions":{"permissions":["all"]}}\n200\n' ;;
  *)
    printf 'unexpected curl URL: %s\n' "$url" >&2
    exit 9 ;;
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
      SECRET_STORE_VAULT_TOKEN='test-token' \
      "$@" \
      bash misc/create-user.sh folio folio
  ) >"${output_file}" 2>&1
}

# --- Scenario 1: fully-provisioned re-run succeeds idempotently --------------
if ! run_create_user env; then
  cat "${output_file}" >&2
  fail 'idempotent re-run did not exit 0'
fi
grep -q 'users-keycloak/users?query=username==folio' "${url_log}" \
  || { cat "${url_log}" >&2; fail 'did not take the 409 existing-user lookup path'; }
grep -q '/roles/role-id/capability-sets' "${url_log}" \
  || { cat "${url_log}" >&2; fail 'did not PUT the non-empty capability-set assignment'; }
grep -q 'Admin user ready: folio' "${output_file}" \
  || { cat "${output_file}" >&2; fail 'idempotent re-run did not report success'; }

# --- Scenario 2: non-JSON login body -> structured error, not a jq abort -----
if run_create_user env BAD_LOGIN=1; then
  cat "${output_file}" >&2
  fail 'a non-JSON login body should make create-user.sh exit non-zero'
fi
grep -q 'Login failed with HTTP 502' "${output_file}" \
  || { cat "${output_file}" >&2; fail 'non-JSON login did not surface the structured error'; }
grep -qi 'parse error' "${output_file}" \
  && { cat "${output_file}" >&2; fail 'non-JSON login leaked a raw jq parse error (guard not effective)'; }

echo "ok  create-user.sh re-runs idempotently and guards non-JSON bodies"
