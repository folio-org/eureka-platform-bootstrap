#!/usr/bin/env bash
# FOLIO / Keycloak command helpers.
#
# Authentication (system + tenant tokens), application descriptor / discovery
# registration, tenant entitlement, capability waiting, and the post-bootstrap
# smoke check. These talk to the api-gateway (localhost:8000), Keycloak
# (localhost:8080), and Vault (localhost:8200).
#
# Relies on globals set by the bootstrap flow: APP_NAME, APP_ID,
# APP_DESCRIPTOR_PATH, APP_DISCOVERY_PATH, SECRET_STORE_VAULT_TOKEN.
# Requires the output helpers from folio-common.sh (step/ok/warn).

[[ -n "${_FOLIO_API_SOURCED:-}" ]] && return 0
readonly _FOLIO_API_SOURCED=1

GW_URL="${API_GATEWAY_URL:-http://localhost:8000}"

################################################################################
# Response helpers
################################################################################

print_api_payload() {
  local body="$1"
  local destination="${2:-stderr}"

  if printf '%s\n' "$body" | jq '.' >/dev/null 2>&1; then
    if [[ "$destination" == 'stderr' ]]; then
      printf '%s\n' "$body" | jq '.' >&2
    else
      printf '%s\n' "$body" | jq '.'
    fi
    return 0
  fi

  [[ -n "$body" ]] || return 0
  if [[ "$destination" == 'stderr' ]]; then
    printf '%s\n' "$body" >&2
  else
    printf '%s\n' "$body"
  fi
}

extract_api_message() {
  local body="$1"
  local message

  message="$(printf '%s\n' "$body" | jq -r '.errors[0].message // .message // .error // .title // empty' 2>/dev/null || true)"
  if [[ -n "$message" && "$message" != 'null' ]]; then
    printf '%s' "$message"
    return 0
  fi

  sed -n '/[^[:space:]]/ {p;q;}' <<< "$body"
}

extract_total_records_count() {
  local body="$1"
  local count

  count="$(printf '%s\n' "$body" | jq -r '.totalRecords // .total_records // 0' 2>/dev/null || true)"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  printf '%s' "$count"
}

print_api_notice() {
  local prefix="$1"
  local body="$2"
  local message

  message="$(extract_api_message "$body")"
  if [[ -n "$message" ]]; then
    ui_info "${prefix}: ${message}"
  else
    ui_info "${prefix}."
  fi
}

# Issue a FOLIO API request and split the response into two globals:
#   API_RESPONSE_CODE  - the HTTP status
#   API_RESPONSE_BODY  - the response body (status line stripped)
# Callers pass the method, URL, then any extra curl args (headers, -d <json>),
# replacing the hand-rolled `curl -w` + grep/sed splitting that was duplicated
# across the supported helpers. Same split convention as the rest of this library.
api_request() {
  local method="$1" url="$2"
  shift 2
  local response
  response="$(curl -s -w '\n%{http_code}' -X "${method}" "$@" "${url}")"
  API_RESPONSE_CODE="$(printf '%s\n' "${response}" | tail -n1)"
  API_RESPONSE_BODY="$(printf '%s\n' "${response}" | sed '$d')"
}

################################################################################
# Tokens
################################################################################

obtain_system_access_token() {
  local token

  export KC_ADMIN_CLIENT_ID="${KC_ADMIN_CLIENT_ID:-folio-backend-admin-client}"
  export KC_ADMIN_CLIENT_SECRET="${KC_ADMIN_CLIENT_SECRET:-folio-backend-admin-client-secret}"

  token="$(curl -X POST --silent --fail \
    --header 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "client_id=${KC_ADMIN_CLIENT_ID}" \
    --data-urlencode 'grant_type=client_credentials' \
    --data-urlencode "client_secret=${KC_ADMIN_CLIENT_SECRET}" \
    'http://localhost:8080/realms/master/protocol/openid-connect/token' | jq -r '.access_token')"

  if [[ -z "$token" || "$token" == "null" ]]; then
    ui_error 'Failed to obtain system access token.'
    exit 1
  fi

  printf '%s' "$token"
}

obtain_tenant_access_token() {
  local tenant="$1"
  local client_id="${KC_SERVICE_CLIENT_ID:-m2m-client}"
  local vault_response vault_body vault_code client_secret token

  vault_response="$(curl -s -w '\n%{http_code}' -X GET \
    -H "X-Vault-Token: ${SECRET_STORE_VAULT_TOKEN}" \
    "http://localhost:8200/v1/secret/data/folio/${tenant}")"

  vault_body="$(printf '%s\n' "$vault_response" | sed '$d')"
  vault_code="$(printf '%s\n' "$vault_response" | tail -n1)"

  if [[ "$vault_code" != '200' ]]; then
    ui_error "Failed to obtain tenant secret for ${tenant} (HTTP ${vault_code})."
    printf '%s\n' "$vault_body" | jq >&2 || true
    exit 1
  fi

  client_secret="$(printf '%s\n' "$vault_body" | jq -r ".data.data.\"${client_id}\" // empty")"
  if [[ -z "$client_secret" ]]; then
    ui_error "Failed to extract tenant client secret for ${tenant}."
    exit 1
  fi

  token="$(curl -X POST --silent --fail \
    --header 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "client_id=${client_id}" \
    --data-urlencode 'grant_type=client_credentials' \
    --data-urlencode "client_secret=${client_secret}" \
    "http://localhost:8080/realms/${tenant}/protocol/openid-connect/token" | jq -r '.access_token')"

  if [[ -z "$token" || "$token" == 'null' ]]; then
    ui_error "Failed to obtain tenant access token for ${tenant}."
    exit 1
  fi

  printf '%s' "$token"
}

################################################################################
# Registration
################################################################################

register_application_descriptor() {
  local system_access_token="$1"
  local max_retries=3 retry_count=0 registration_success=false

  ui_step "Registering application descriptor for ${APP_NAME}"
  while [[ $retry_count -lt $max_retries ]]; do
    if [[ $retry_count -gt 0 ]]; then
      ui_warn "Retry attempt ${retry_count} of ${max_retries} (waiting 15s for DNS cache refresh)..."
      sleep 15
    fi

    api_request POST "${GW_URL}/applications" \
      --header 'Content-Type: application/json' \
      --header "x-okapi-token: ${system_access_token}" \
      --data "@${APP_DESCRIPTOR_PATH}"

    if [[ "$API_RESPONSE_CODE" -eq 409 ]]; then
      print_api_notice 'Application descriptor is already registered' "$API_RESPONSE_BODY"
      registration_success=true
      break
    elif [[ "$API_RESPONSE_CODE" -ge 200 && "$API_RESPONSE_CODE" -lt 300 ]]; then
      ui_ok "Application descriptor registered for ${APP_NAME}."
      registration_success=true
      break
    elif [[ "$API_RESPONSE_CODE" -eq 503 || "$API_RESPONSE_CODE" -eq 504 ]]; then
      ui_warn "Descriptor registration temporarily unavailable (HTTP ${API_RESPONSE_CODE}) - upstream warming up or DNS not resolved yet"
      print_api_payload "$API_RESPONSE_BODY" stderr
      retry_count=$((retry_count + 1))
    else
      ui_error "Request failed with HTTP code ${API_RESPONSE_CODE}:"
      print_api_payload "$API_RESPONSE_BODY" stderr
      exit 1
    fi
  done

  if [[ "$registration_success" == false ]]; then
    ui_error "Failed to register application descriptor after ${max_retries} attempts."
    ui_info 'This usually indicates Kong cannot resolve mgr-applications via DNS.'
    exit 1
  fi
}

register_discovery_information() {
  local system_access_token="$1"
  local max_retries=3 retry_count=0 discovery_success=false

  ui_step "Registering discovery information for ${APP_NAME}"
  while [[ $retry_count -lt $max_retries ]]; do
    if [[ $retry_count -gt 0 ]]; then
      ui_warn "Retry attempt ${retry_count} of ${max_retries} (waiting 15s for DNS cache refresh)..."
      sleep 15
    fi

    api_request POST "${GW_URL}/modules/discovery" \
      --header 'Content-Type: application/json' \
      --header "x-okapi-token: ${system_access_token}" \
      --data "@${APP_DISCOVERY_PATH}"

    if [[ "$API_RESPONSE_CODE" -eq 409 ]]; then
      print_api_notice 'Discovery information is already registered' "$API_RESPONSE_BODY"
      discovery_success=true
      break
    elif [[ "$API_RESPONSE_CODE" -ge 200 && "$API_RESPONSE_CODE" -lt 300 ]]; then
      ui_ok "Discovery information registered for ${APP_NAME}."
      discovery_success=true
      break
    elif [[ "$API_RESPONSE_CODE" -eq 503 || "$API_RESPONSE_CODE" -eq 504 ]]; then
      ui_warn "Discovery registration temporarily unavailable (HTTP ${API_RESPONSE_CODE}) - upstream warming up or DNS not resolved yet"
      print_api_payload "$API_RESPONSE_BODY" stderr
      retry_count=$((retry_count + 1))
    else
      ui_error "Request failed with HTTP code ${API_RESPONSE_CODE}:"
      print_api_payload "$API_RESPONSE_BODY" stderr
      exit 1
    fi
  done

  if [[ "$discovery_success" == false ]]; then
    ui_error "Failed to register discovery information after ${max_retries} attempts."
    ui_info 'This usually indicates Kong cannot resolve mgr-applications via DNS.'
    exit 1
  fi

  ui_ok "Application descriptor and discovery information are ready for ${APP_NAME}."
}

################################################################################
# Tenant entitlement
################################################################################

# Poll until the tenant has registered capabilities, refreshing the token when
# it expires.
wait_for_capabilities() {
  local tenant_access_token cap_count elapsed_ms
  local cap_wait=0 max_cap_wait=60
  local token_refreshes=0 max_token_refreshes=5
  local si=0 spin_char

  ui_timer_start capabilities_wait
  tenant_access_token="$(obtain_tenant_access_token diku)"
  ui_activity_start 'Waiting for capabilities'
  while [[ $cap_wait -lt $max_cap_wait ]]; do
    api_request GET "${GW_URL}/capabilities?limit=1" \
      --header 'Content-Type: application/json' \
      --header 'x-okapi-tenant: diku' \
      --header "x-okapi-token: ${tenant_access_token}"

    if [[ "$API_RESPONSE_CODE" == '401' || "$API_RESPONSE_CODE" == '403' ]]; then
      token_refreshes=$((token_refreshes + 1))
      if [[ $token_refreshes -gt $max_token_refreshes ]]; then
        ui_activity_finish fail 'Capabilities token refresh failed' "$(ui_timer_read capabilities_wait 2>/dev/null || printf 0)"
        ui_warn "Capabilities check keeps returning HTTP ${API_RESPONSE_CODE} after ${max_token_refreshes} token refreshes; continuing."
        return 0
      fi
      sleep 2
      cap_wait=$((cap_wait + 2))
      ui_spinner_clear
      tenant_access_token="$(obtain_tenant_access_token diku)"
      continue
    fi

    cap_count="$(extract_total_records_count "$API_RESPONSE_BODY")"
    if [[ "$cap_count" -gt 0 ]]; then
      elapsed_ms="$(ui_timer_read capabilities_wait)"
      ui_activity_finish ok "Capabilities registered (found ${cap_count})" "${elapsed_ms}"
      return 0
    fi

    spin_char="$(_ui_spin_frame "$((si++))")"
    ui_activity_tick "$spin_char" 'Waiting for capabilities' '' "$(ui_timer_read capabilities_wait)"
    sleep 5
    cap_wait=$((cap_wait + 5))
  done

  ui_activity_finish fail 'Capabilities not registered' "$(ui_timer_read capabilities_wait 2>/dev/null || printf 0)"
  ui_warn "No capabilities found after ${max_cap_wait}s; the default user may lack permissions."
}

create_tenant_and_enable_application() {
  local system_access_token="$1"
  local diku_tenant_id entitlement_flow_id status existing_entitlement_count entitlement_finished=false
  local entitlement_elapsed
  local max_wait=120 elapsed=0
  local si=0 spin_char

  ui_step "Creating tenant 'diku'"
  api_request POST "${GW_URL}/tenants" \
    --header 'Content-Type: application/json' \
    --header "x-okapi-token: ${system_access_token}" \
    --data '{"name": "diku", "description": "Diku Tenant"}'

  if [[ "$API_RESPONSE_CODE" -ge 400 && "$API_RESPONSE_CODE" -lt 500 ]]; then
    print_api_notice 'Tenant creation skipped' "$API_RESPONSE_BODY"
  elif [[ "$API_RESPONSE_CODE" -ge 200 && "$API_RESPONSE_CODE" -lt 300 ]]; then
    ui_ok "Tenant 'diku' created."
  else
    ui_error "Tenant creation failed with HTTP code ${API_RESPONSE_CODE}:"
    print_api_payload "$API_RESPONSE_BODY" stderr
    exit 1
  fi

  api_request GET "${GW_URL}/tenants?query=name==diku" \
    --header 'Content-Type: application/json' \
    --header "x-okapi-token: ${system_access_token}"
  diku_tenant_id="$(printf '%s\n' "$API_RESPONSE_BODY" | jq -r '.tenants[0].id')"

  if [[ -z "$diku_tenant_id" || "$diku_tenant_id" == "null" ]]; then
    ui_error "Failed to obtain ID for tenant 'diku'."
    exit 1
  fi
  ui_kv "Tenant 'diku' ID" "$diku_tenant_id"

  system_access_token="$(obtain_system_access_token)"
  api_request GET "${GW_URL}/entitlements/diku/applications?limit=500" \
    --header 'Content-Type: application/json' \
    --header 'x-okapi-tenant: diku' \
    --header "x-okapi-token: ${system_access_token}"
  existing_entitlement_count="$(printf '%s\n' "$API_RESPONSE_BODY" | jq -r --arg id "${APP_ID}" 'if type == "array" then map(select(.id == $id or .applicationId == $id)) | length elif .applicationDescriptors? != null then [.applicationDescriptors[]? | select(.id == $id or .applicationId == $id)] | length elif .applications? != null then [.applications[]? | select(.id == $id or .applicationId == $id)] | length else 0 end')"

  if [[ "${existing_entitlement_count}" -gt 0 ]]; then
    ui_info "Application ${APP_NAME} is already enabled for tenant 'diku' (skipping entitlement)."
    wait_for_capabilities
    return 0
  fi

  ui_step "Enabling (entitling) ${APP_NAME} for tenant 'diku'"
  api_request POST "${GW_URL}/entitlements?ignoreErrors=false&async=true&tenantParameters=loadSample=true,loadReference=true" \
    --header 'Content-Type: application/json' \
    --header "x-okapi-token: ${system_access_token}" \
    --data "{\"tenantId\": \"${diku_tenant_id}\", \"applications\": [ \"${APP_ID}\" ] }"

  if [[ "$API_RESPONSE_CODE" -ge 200 && "$API_RESPONSE_CODE" -lt 300 ]]; then
    ui_ok 'Application enabled for tenant.'
    entitlement_flow_id="$(printf '%s\n' "$API_RESPONSE_BODY" | jq -r '.flowId // empty')"

    if [[ -n "$entitlement_flow_id" ]]; then
      ui_timer_start entitlement_wait
      ui_activity_start 'Waiting for entitlement'
      while [[ $elapsed -lt $max_wait ]]; do
        spin_char="$(_ui_spin_frame "$((si++))")"
        ui_activity_tick "$spin_char" 'Waiting for entitlement' '' "$(ui_timer_read entitlement_wait)"
        sleep 5
        elapsed=$((elapsed + 5))

        api_request GET "${GW_URL}/entitlement-flows/${entitlement_flow_id}?includeStages=true" \
          --header 'Content-Type: application/json' \
          --header "x-okapi-token: ${system_access_token}"

        status="$(printf '%s\n' "$API_RESPONSE_BODY" | jq -r '.status // empty')"

        if [[ "$status" == 'finished' ]]; then
          entitlement_elapsed="$(ui_timer_read entitlement_wait)"
          ui_activity_finish ok 'Entitlement completed successfully' "${entitlement_elapsed}"
          entitlement_finished=true
          break
        elif [[ "$status" == 'failed' || "$status" == 'cancelled' ]]; then
          ui_activity_finish fail 'Entitlement failed' "$(ui_timer_read entitlement_wait 2>/dev/null || printf 0)"
          ui_error 'Entitlement failed:'
          print_api_payload "$API_RESPONSE_BODY" stderr
          exit 1
        fi
      done

      if [[ "${entitlement_finished}" != true && $elapsed -ge $max_wait ]]; then
        ui_activity_finish fail 'Entitlement still in progress' "$(ui_timer_read entitlement_wait 2>/dev/null || printf 0)"
        ui_warn "Entitlement still in progress after ${max_wait}s, continuing anyway..."
      fi
    else
      ui_note '  (Could not get entitlement ID, waiting 30s...)'
      sleep 30
    fi

    wait_for_capabilities
  elif [[ "$API_RESPONSE_CODE" -eq 400 ]]; then
    print_api_notice 'Application enablement skipped' "$API_RESPONSE_BODY"
  else
    ui_error "Failed to enable application (HTTP ${API_RESPONSE_CODE}):"
    print_api_payload "$API_RESPONSE_BODY" stderr
    exit 1
  fi
}

################################################################################
# Smoke check
################################################################################

# Short post-bootstrap proof that the environment is actually usable. Results are
# gathered first, then rendered as a single "smoke check" panel.
smoke_check() {
  local failures=0 system_token tenant_token diku_count cap_body cap_count proxy_status
  local states=() texts=() rights=() idx right_label

  proxy_status="$(curl -sS -o /dev/null -w '%{http_code}' ${GW_URL}/ 2>/dev/null || true)"
  if [[ " 200 404 " == *" ${proxy_status} "* ]]; then
    states+=(ok); texts+=('api-gateway proxy reachable'); rights+=("HTTP ${proxy_status}")
  else
    states+=(fail); texts+=('api-gateway proxy reachable'); rights+=("HTTP ${proxy_status:-000}")
    failures=$((failures + 1))
  fi

  if system_token="$(obtain_system_access_token 2>/dev/null)" && [[ -n "$system_token" ]]; then
    states+=(ok); texts+=('System access token obtained'); rights+=('')
    diku_count="$(curl -s -X GET --header "x-okapi-token: ${system_token}" \
      "${GW_URL}/tenants?query=name==diku" | jq -r '.tenants | length' 2>/dev/null || echo 0)"
    if [[ "${diku_count:-0}" -gt 0 ]]; then
      states+=(ok); texts+=("Tenant 'diku' exists"); rights+=('')
    else
      states+=(fail); texts+=("Tenant 'diku' exists"); rights+=("${diku_count:-0} records"); failures=$((failures + 1))
    fi
  else
    states+=(fail); texts+=('System access token obtained'); rights+=('token failed'); failures=$((failures + 1))
  fi

  if tenant_token="$(obtain_tenant_access_token diku 2>/dev/null)" && [[ -n "$tenant_token" ]]; then
    cap_body="$(curl -s --header 'x-okapi-tenant: diku' --header "x-okapi-token: ${tenant_token}" \
      "${GW_URL}/capabilities?limit=1" 2>/dev/null || true)"
    cap_count="$(extract_total_records_count "$cap_body")"
    if [[ "${cap_count}" -gt 0 ]]; then
      states+=(ok); texts+=('Capabilities reachable'); rights+=("${cap_count}")
    else
      states+=(fail); texts+=('Capabilities reachable'); rights+=("${cap_count:-0} records"); failures=$((failures + 1))
    fi
  else
    states+=(fail); texts+=('Tenant access token obtained'); rights+=('token failed'); failures=$((failures + 1))
  fi

  if [[ $failures -eq 0 ]]; then right_label='passed'; else right_label="${failures} failed"; fi
  ui_box_top 'smoke check' "${right_label}"
  for idx in "${!states[@]}"; do
    ui_box_status_row "${states[$idx]}" "${texts[$idx]}" "${rights[$idx]}"
  done
  ui_box_bottom

  [[ $failures -eq 0 ]] && return 0
  return 1
}
