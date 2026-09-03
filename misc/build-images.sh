#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly VAULT_DIR="${SCRIPT_DIR}/vault"
readonly VAULT_IMAGE="folio-vault:1.13.3"
readonly VAULT_CONTEXT_HASH_FILE="${VAULT_DIR}/.build-context.sha256"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/folio-common.sh"

compute_vault_context_hash() {
  (
    cd "${VAULT_DIR}"
    find . -type f ! -name '.build-context.sha256' -print0 | sort -z | xargs -0 shasum -a 256
  ) | shasum -a 256 | awk '{print $1}'
}

current_hash="$(compute_vault_context_hash)"
previous_hash=""
vault_local_state="missing"
vault_arch="unknown"
vault_context_state="changed"
vault_action="rebuild"
build_output_file="$(mktemp)"
trap 'rm -f "${build_output_file}"' EXIT

if [[ -f "${VAULT_CONTEXT_HASH_FILE}" ]]; then
  previous_hash="$(<"${VAULT_CONTEXT_HASH_FILE}")"
fi

if docker image inspect "${VAULT_IMAGE}" >/dev/null 2>&1; then
  vault_local_state="present"
  vault_arch="$(docker image inspect --format '{{.Architecture}}' "${VAULT_IMAGE}" 2>/dev/null || printf 'unknown')"
  [[ -n "${vault_arch}" ]] || vault_arch="unknown"
fi

if [[ "${current_hash}" == "${previous_hash}" ]]; then
  vault_context_state="matched"
fi

if [[ "${vault_local_state}" == "present" && "${vault_context_state}" == "matched" ]]; then
  vault_action="skip"
  ui_info "Vault image decision: local=${vault_local_state} arch=${vault_arch} context=${vault_context_state} action=${vault_action}"
  ui_info "Vault image already exists and context is unchanged: ${VAULT_IMAGE} (skipping build)"
  exit 0
fi

ui_info "Vault image decision: local=${vault_local_state} arch=${vault_arch} context=${vault_context_state} action=${vault_action}"
if [[ "${vault_context_state}" == "changed" ]]; then
  ui_info "Rebuilding ${VAULT_IMAGE} because the Vault build context changed; Docker may need registry access for the base image."
fi

ui_step "Building Vault image"
set +e
docker build -t "${VAULT_IMAGE}" "${VAULT_DIR}" >"${build_output_file}" 2>&1
build_status=$?
set -e
if [[ ${build_status} -ne 0 ]]; then
  ui_error 'Vault support image rebuild failed.'
  ui_info "Local image: ${vault_local_state}; context: ${vault_context_state}; base metadata or network access may be unavailable."
  cat "${build_output_file}" >&2
  exit "${build_status}"
fi
printf '%s\n' "${current_hash}" > "${VAULT_CONTEXT_HASH_FILE}"
