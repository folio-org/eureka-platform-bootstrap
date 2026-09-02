#!/usr/bin/env bash
#
# create-user.sh - Create a FOLIO admin user in the local dev environment.
#
# Thin CLI over named provisioning steps. The HTTP plumbing (api_request),
# response parsing (extract_api_message / print_api_payload), tenant token
# lookup (obtain_tenant_access_token), config loading, and logging all come from
# the shared libraries, so this script only expresses the user-creation flow.
#
# Verbosity follows the bootstrap convention: quiet by default, full detail with
# DEBUG=true (per-step headers and response bodies via debug()).
#
# Usage:
#   ./create-user.sh [username] [password]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/folio-common.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/folio-api.sh"

# Preserve an operator-supplied host gateway before loading docker/.env, whose
# OKAPI_URL default is container-internal and not reachable from this host script.
HOST_OKAPI_URL="${OKAPI_URL:-}"

# Load local config with the same precedence as start.sh:
# shell env > .env.local.credentials > .env.local.
load_folio_config

# create-user.sh runs on the host; docker/.env's OKAPI_URL is container-internal.
API_GATEWAY_URL="${API_GATEWAY_URL:-${KONG_URL:-${FOLIO_KONG_URL:-${HOST_OKAPI_URL:-http://localhost:8000}}}}"
TENANT="${TENANT:-diku}"
ADMIN_ROLE_NAME='Admin'

usage() {
  cat <<EOF
Usage: $0 [username] [password]

Create a FOLIO admin user in the local dev environment.

Arguments:
  username    Username (default: folio)
  password    Password (default: folio)

Examples:
  $0                  # create 'folio' user with admin role
  $0 admin pass123    # create 'admin' user with admin role
EOF
}

# Print a one-line failure detail (always) plus the full body (debug only), then
# abort. Collapses the repeated summary/response/error trio onto one call.
fail_with() {
  local context="$1" body="$2" detail
  detail="$(extract_api_message "${body}")"
  [[ -n "${detail}" ]] && ui_warn "${detail}"
  is_debug && print_api_payload "${body}" stderr
  error "${context}"
}

# Resolve the tenant service access token (Vault client-secret lookup + Keycloak
# token, via the shared helper the rest of the bootstrap uses).
obtain_token() {
  ui_debug 'Obtaining tenant service access token'
  ACCESS_TOKEN="$(obtain_tenant_access_token "${TENANT}")"
}

create_user() {
  ui_debug "Creating user '${USERNAME}'"
  local body
  body="$(jq -n --arg u "${USERNAME}" \
    '{active: true, type: "patron", username: $u,
      personal: {lastName: "User", firstName: "Admin", email: ($u + "@example.com")}}')"

  api_request POST "${API_GATEWAY_URL}/users-keycloak/users" \
    -H "x-okapi-tenant: ${TENANT}" \
    -H "x-okapi-token: ${ACCESS_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d "${body}"

  case "${API_RESPONSE_CODE}" in
    201)
      USER_ID="$(printf '%s' "${API_RESPONSE_BODY}" | jq -r '.id // empty' 2>/dev/null || true)"
      [[ -n "${USER_ID}" ]] || error 'Failed to extract user ID'
      ;;
    409)
      ui_debug 'User already exists; fetching existing user'
      api_request GET "${API_GATEWAY_URL}/users-keycloak/users?query=username==${USERNAME}" \
        -H "x-okapi-tenant: ${TENANT}" \
        -H "x-okapi-token: ${ACCESS_TOKEN}"
      [[ "${API_RESPONSE_CODE}" == 200 ]] \
        || fail_with "Failed to fetch existing user with HTTP ${API_RESPONSE_CODE}" "${API_RESPONSE_BODY}"
      USER_ID="$(printf '%s' "${API_RESPONSE_BODY}" | jq -r '.users[0].id // empty')"
      [[ -n "${USER_ID}" ]] || error "User exists but couldn't fetch ID"
      ;;
    *)
      fail_with "User creation failed with HTTP ${API_RESPONSE_CODE}" "${API_RESPONSE_BODY}"
      ;;
  esac
  ui_ok "Account ready: ${USERNAME} (${USER_ID})"
}

set_password() {
  ui_debug 'Setting password'
  sleep 2  # give Keycloak time to sync the new user
  local body
  body="$(jq -n --arg u "${USERNAME}" --arg id "${USER_ID}" --arg p "${PASSWORD}" \
    '{username: $u, userId: $id, password: $p}')"

  api_request POST "${API_GATEWAY_URL}/authn/credentials" \
    -H "x-okapi-tenant: ${TENANT}" \
    -H "x-okapi-token: ${ACCESS_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d "${body}"

  case "${API_RESPONSE_CODE}" in
    201|409|422)
      ;;
    400)
      # Distinguish "credentials already exist" / a backend Keycloak-admin auth
      # blip (both effectively "password already set") from a real failure.
      local msg cause
      msg="$(printf '%s' "${API_RESPONSE_BODY}" | jq -r '.errors[0].message // empty' 2>/dev/null)"
      cause="$(printf '%s' "${API_RESPONSE_BODY}" | jq -r '.errors[0].parameters[]? | select(.key=="cause") | .value' 2>/dev/null)"
      if [[ "${msg}" == *'already exists'* ]]; then
        ui_debug 'Password already configured (continuing)'
      elif [[ "${msg}" == *'Failed to create auth credentials'* && "${cause}" == *'401 Unauthorized'* ]]; then
        ui_warn 'Backend auth blip while setting password (likely already set, continuing)'
      else
        fail_with "Password setting failed with HTTP ${API_RESPONSE_CODE}" "${API_RESPONSE_BODY}"
      fi
      ;;
    *)
      fail_with "Password setting failed with HTTP ${API_RESPONSE_CODE}" "${API_RESPONSE_BODY}"
      ;;
  esac
  ui_ok 'Password ready'
}

ensure_admin_role() {
  ui_debug "Finding or creating the ${ADMIN_ROLE_NAME} role"
  api_request GET "${API_GATEWAY_URL}/roles?query=name==${ADMIN_ROLE_NAME}" \
    -H "x-okapi-tenant: ${TENANT}" \
    -H "x-okapi-token: ${ACCESS_TOKEN}"
  ROLE_ID="$(printf '%s' "${API_RESPONSE_BODY}" | jq -r '.roles[0].id // empty' 2>/dev/null || true)"

  if [[ -z "${ROLE_ID}" ]]; then
    ui_debug "Creating the ${ADMIN_ROLE_NAME} role"
    local body
    body="$(jq -n --arg n "${ADMIN_ROLE_NAME}" \
      '{name: $n, description: "Administrator role with all permissions"}')"
    api_request POST "${API_GATEWAY_URL}/roles" \
      -H "x-okapi-tenant: ${TENANT}" \
      -H "x-okapi-token: ${ACCESS_TOKEN}" \
      -H 'Content-Type: application/json' \
      -d "${body}"
    [[ "${API_RESPONSE_CODE}" == 201 ]] \
      || fail_with "Role creation failed with HTTP ${API_RESPONSE_CODE}" "${API_RESPONSE_BODY}"
    ROLE_ID="$(printf '%s' "${API_RESPONSE_BODY}" | jq -r '.id // empty')"
    [[ -n "${ROLE_ID}" ]] || error 'Failed to extract role ID'
  fi
  ui_ok "Admin role ready: ${ADMIN_ROLE_NAME}"
}

# Assign every item from a collection endpoint to the admin role via the matching
# PUT (idempotent: replaces the role's set). Shared by capabilities and
# capability-sets, which differ only in their path and id field names.
assign_collection_to_role() {
  local label="$1" list_path="$2" list_key="$3" assign_path="$4" body_key="$5"
  local ids count body display

  # Capitalize the first letter for outcome lines without the bash-4
  # case-modification expansion (a parse error on macOS stock bash 3.2).
  # Portable substring slicing + tr instead.
  display="$(printf '%s' "${label:0:1}" | tr '[:lower:]' '[:upper:]')${label:1}"

  ui_debug "Assigning ${label} to the role"
  api_request GET "${API_GATEWAY_URL}/${list_path}?limit=2000" \
    -H "x-okapi-tenant: ${TENANT}" \
    -H "x-okapi-token: ${ACCESS_TOKEN}"
  [[ "${API_RESPONSE_CODE}" == 200 ]] \
    || fail_with "Failed to fetch ${label} with HTTP ${API_RESPONSE_CODE}" "${API_RESPONSE_BODY}"

  count="$(extract_total_records_count "${API_RESPONSE_BODY}")"
  if [[ "${count}" -eq 0 ]]; then
    ui_warn "No ${label} found in the system; role will have none assigned"
    ui_ok "${display} assigned: 0"
    return 0
  fi

  ids="$(printf '%s' "${API_RESPONSE_BODY}" | jq -r "[.${list_key}[].id]")"
  body="$(jq -n --argjson ids "${ids}" --arg key "${body_key}" '{($key): $ids}')"
  api_request PUT "${API_GATEWAY_URL}/roles/${ROLE_ID}/${assign_path}" \
    -H "x-okapi-tenant: ${TENANT}" \
    -H "x-okapi-token: ${ACCESS_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d "${body}"
  [[ "${API_RESPONSE_CODE}" == 204 ]] \
    || fail_with "${display} assignment failed with HTTP ${API_RESPONSE_CODE}" "${API_RESPONSE_BODY}"
  ui_ok "${display} assigned: ${count}"
}

assign_role_to_user() {
  ui_debug 'Assigning the admin role to the user'
  local body
  body="$(jq -n --arg id "${USER_ID}" --arg role "${ROLE_ID}" \
    '{userId: $id, roleIds: [$role]}')"
  api_request POST "${API_GATEWAY_URL}/roles/users" \
    -H "x-okapi-tenant: ${TENANT}" \
    -H "x-okapi-token: ${ACCESS_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d "${body}"

  case "${API_RESPONSE_CODE}" in
    200|201|409)
      ;;
    400)
      if printf '%s' "${API_RESPONSE_BODY}" | jq -e '.errors[0].message | contains("already exists")' >/dev/null 2>&1; then
        ui_debug 'Admin role already assigned (continuing)'
      else
        fail_with "Role assignment failed with HTTP ${API_RESPONSE_CODE}" "${API_RESPONSE_BODY}"
      fi
      ;;
    *)
      fail_with "Role assignment failed with HTTP ${API_RESPONSE_CODE}" "${API_RESPONSE_BODY}"
      ;;
  esac
  ui_ok 'Admin role assigned to user'
}

# Log in as the new user and confirm /_self returns a non-empty permission set,
# proving the role -> capabilities mapping actually took effect.
verify_login() {
  ui_debug 'Testing login'
  sleep 2
  local body token perm_count
  body="$(jq -n --arg u "${USERNAME}" --arg p "${PASSWORD}" '{username: $u, password: $p}')"
  api_request POST "${API_GATEWAY_URL}/authn/login" \
    -H "x-okapi-tenant: ${TENANT}" \
    -H 'Content-Type: application/json' \
    -d "${body}"
  token="$(printf '%s' "${API_RESPONSE_BODY}" | jq -r '.okapiToken // empty' 2>/dev/null || true)"
  if [[ -z "${token}" ]]; then
    fail_with "Login failed with HTTP ${API_RESPONSE_CODE}" "${API_RESPONSE_BODY}"
  fi

  api_request GET "${API_GATEWAY_URL}/users-keycloak/_self" \
    -H "x-okapi-tenant: ${TENANT}" \
    -H "x-okapi-token: ${token}"
  [[ "${API_RESPONSE_CODE}" == 200 ]] \
    || error "_self endpoint returned HTTP ${API_RESPONSE_CODE}"

  perm_count="$(printf '%s' "${API_RESPONSE_BODY}" | jq -r '.permissions.permissions | length' 2>/dev/null || echo 0)"
  [[ "${perm_count:-0}" -gt 0 ]] \
    || error 'Login succeeded but _self returned no permissions (role->capabilities mapping is not working)'
  ui_ok "Login verified: ${perm_count} permissions available"
}

main() {
  local username="${1:-folio}" password="${2:-folio}"
  if [[ "${username}" == '-h' || "${username}" == '--help' ]]; then
    usage
    exit 0
  fi

  USERNAME="${username}"
  PASSWORD="${password}"

  check_dependencies curl jq
  [[ -n "${SECRET_STORE_VAULT_TOKEN:-}" ]] \
    || error 'SECRET_STORE_VAULT_TOKEN not found. Run the bootstrap or check docker/.env.local.credentials'

  ui_debug "Creating admin user '${USERNAME}' on tenant '${TENANT}'"

  obtain_token
  create_user
  set_password
  ensure_admin_role
  assign_collection_to_role 'capabilities' 'capabilities' 'capabilities' 'capabilities' 'capabilityIds'
  assign_collection_to_role 'capability sets' 'capability-sets' 'capabilitySets' 'capability-sets' 'capabilitySetIds'
  assign_role_to_user
  verify_login

  ui_ok "Admin user ready: ${USERNAME} on tenant ${TENANT} (login verified)"
}

main "$@"
