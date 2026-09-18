#!/usr/bin/env bash
# Local secrets persistence for the bootstrap.
#
# docker/.env.local.credentials holds exactly the runtime-generated Vault root
# token — the only secret the environment generates at runtime. Deterministic
# development defaults for everything else (database and Keycloak passwords)
# live committed in docker/.env; operator overrides go in the shell environment
# or docker/.env.local. Operator lines added to this file are preserved.

readonly LOCAL_CREDENTIALS_FILE='.env.local.credentials'

read_vault_root_token() {
  local token

  token="$(docker logs vault 2>/dev/null \
    | grep 'Root VAULT TOKEN is:' \
    | sed -E 's/^.*Root VAULT TOKEN is: (.+)$/\1/' \
    | tail -n 1 || true)"

  if [[ -z "${token}" ]]; then
    ui_error "could not read the Vault root token from 'docker logs vault'."
    ui_info "Is the 'vault' container running and initialized?"
    return 1
  fi

  printf '%s\n' "${token}"
}

persist_vault_root_token() {
  local vault_token="$1"
  local tmp

  if [[ -z "${vault_token//[[:space:]]/}" ]]; then
    ui_error "refusing to write an empty Vault token to ${LOCAL_CREDENTIALS_FILE}."
    return 1
  fi

  # Rewrite the file with every non-token line kept as-is (operator-added
  # secrets survive), creating it with a header on first persistence.
  tmp="$(mktemp)"
  {
    if [[ -f "${LOCAL_CREDENTIALS_FILE}" ]]; then
      grep -Ev '^(export[[:space:]]+)?SECRET_STORE_VAULT_TOKEN=' "${LOCAL_CREDENTIALS_FILE}" || true
    else
      printf '### Vault token (bootstrap-managed)\n'
    fi
    printf 'export SECRET_STORE_VAULT_TOKEN=%q\n' "${vault_token}"
  } >"${tmp}"
  mv "${tmp}" "${LOCAL_CREDENTIALS_FILE}"
}
