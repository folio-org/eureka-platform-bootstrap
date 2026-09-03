#!/usr/bin/env bash
# Bootstrap orchestration library.
#
# Sourced by ./start.sh. Defines the bootstrap phase sequence (run_bootstrap_flow)
# and the local setup helpers around it. FOLIO/Keycloak API logic lives in
# misc/lib/folio-api.sh; readiness waits in misc/lib/docker-health.sh; logging
# and config loading in misc/lib/folio-common.sh.
#
# Expected globals (set by the caller, with sane defaults below):
#   APP_DESCRIPTOR_PATH, APP_DISCOVERY_PATH, SIDECAR_MODE, ACTUALIZE_MODULES,
#   PRE_RELEASE_MODE, BUILD_ARM_IMAGES

[[ -n "${_BOOTSTRAP_ENGINE_SOURCED:-}" ]] && return 0
readonly _BOOTSTRAP_ENGINE_SOURCED=1

: "${PROJECT_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${DOCKER_DIR:=${PROJECT_ROOT}/docker}"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/misc/lib/folio-common.sh"
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/misc/lib/folio-api.sh"
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/misc/lib/docker-health.sh"
# shellcheck source=/dev/null
source "${DOCKER_DIR}/lib/local-credentials.sh"

SIDECAR_MODE="${SIDECAR_MODE:-jvm}"
REBUILD_NATIVE_SIDECAR="${REBUILD_NATIVE_SIDECAR:-false}"
REBUILD_BUILT_IMAGES="${REBUILD_BUILT_IMAGES:-false}"
ACTUALIZE_MODULES="${ACTUALIZE_MODULES:-false}"
PRE_RELEASE_MODE="${PRE_RELEASE_MODE:-false}"
BUILD_ARM_IMAGES="${BUILD_ARM_IMAGES:-false}"
APIGW_TYPE="${APIGW_TYPE:-kong}"
GATEWAY_PROFILE="gw-${APIGW_TYPE}"

APP_NAME="${APP_NAME:-}"
APP_ID="${APP_ID:-}"
APP_SERVICES=()
INITIAL_IMAGE_ENV_NAMES="${INITIAL_IMAGE_ENV_NAMES:-}"

################################################################################
# Local setup helpers
################################################################################

# Configure COMPOSE_FILE and GATEWAY_PROFILE based on APIGW_TYPE.
# Must be called before the first `docker compose` invocation so that all
# subsequent compose commands automatically include the right gateway file.
select_gateway_config() {
  APIGW_TYPE="${APIGW_TYPE:-kong}"
  GATEWAY_PROFILE="gw-${APIGW_TYPE}"

  # COMPOSE_FILE is respected by every docker compose invocation in this
  # session. The gateway file is NOT listed in compose.yaml to prevent
  # conflicts between the two gateway service definitions.
  export COMPOSE_FILE="${DOCKER_DIR}/compose.yaml:${DOCKER_DIR}/docker-compose.${APIGW_TYPE}.yml"

  # Export APIGW_URL so docker compose interpolates it into x-mgmt-env.
  # APIGW_API_KEY is wired directly to APISIX_ADMIN_KEY in docker-compose.mgmt.yml.
  if [[ "${APIGW_TYPE}" == "apisix" ]]; then
    export APIGW_URL=http://api-gateway:9180
    export OKAPI_URL=http://api-gateway:9080
  else
    export APIGW_URL=http://api-gateway:8001
    export OKAPI_URL=http://api-gateway:8000
  fi

  ui_debug "API gateway: ${APIGW_TYPE} (profile ${GATEWAY_PROFILE}, url ${APIGW_URL})"
}

build_arm_images() {
  (
    cd "${PROJECT_ROOT}"
    REBUILD_BUILT_IMAGES="${REBUILD_BUILT_IMAGES}" SIDECAR_MODE="${SIDECAR_MODE}" \
      bash misc/images-builder/build.sh
  )
}

resolve_absolute_path() {
  local input_path="$1"
  local directory_path file_name

  input_path="${input_path/#\~/${HOME}}"
  if [[ "$input_path" != /* ]]; then
    input_path="${PWD}/${input_path}"
  fi

  file_name="$(basename "$input_path")"
  directory_path="$(dirname "$input_path")"

  if ! directory_path="$(cd "$directory_path" 2>/dev/null && pwd -P)"; then
    ui_error "Unable to resolve path: ${input_path}"
    exit 1
  fi

  printf '%s/%s\n' "$directory_path" "$file_name"
}

load_app_metadata() {
  APP_NAME="$(jq -r '.name // .id // empty' "${APP_DESCRIPTOR_PATH}")"
  APP_ID="$(jq -r '.id // empty' "${APP_DESCRIPTOR_PATH}")"

  if [[ -z "$APP_NAME" || "$APP_NAME" == "null" ]]; then
    APP_NAME="$(basename "$(dirname "${APP_DESCRIPTOR_PATH}")")"
  fi

  if [[ -z "$APP_ID" || "$APP_ID" == "null" ]]; then
    ui_error "Failed to resolve application id from ${APP_DESCRIPTOR_PATH}."
    exit 1
  fi
}

resolve_app_services() {
  local app_services_output

  app_services_output="$(python3 "${PROJECT_ROOT}/misc/docker-module-updater/run.py" --app "${APP_DESCRIPTOR_PATH}" --services)"
  read -r -a APP_SERVICES <<< "${app_services_output}"

  if [[ "${#APP_SERVICES[@]}" -eq 0 ]]; then
    ui_error "No application services resolved from ${APP_DESCRIPTOR_PATH}."
    exit 1
  fi
}

refresh_local_credentials() {
  # Load in effective-precedence order before writing the generated credentials
  # file. This keeps a first-run docker/.env.local override from being replaced
  # by the fallback embedded in local-credentials.sh.
  load_folio_config credentials
  load_folio_config local
  load_folio_config defaults

  (
    cd "${DOCKER_DIR}"
    write_default_local_credentials_file
  )
}

# The sidecar image (and its tag) is owned entirely by docker/.env(.local) —
# there is no native-mode tag override. Native mode reuses the same versioned tag
# (e.g. folioorg/folio-module-sidecar:4.0.1) and rebuilds it locally from the
# matching upstream git tag; misc/build-native-sidecar.sh derives the git ref from
# this tag. That keeps a single source of truth (the image tag) and means the built
# image is never mislabelled. We never write or rewrite .env.local here.

capture_initial_image_env_names() {
  local line name
  local names=()

  while IFS= read -r line; do
    name="${line%%=*}"
    case "${name}" in
      *_IMAGE|MOD_*_VERSION) names+=("${name}") ;;
    esac
  done < <(env)

  INITIAL_IMAGE_ENV_NAMES="$(printf '%s\n' "${names[@]}")"
}

initial_env_has_name() {
  local name="$1"
  printf '%s\n' "${INITIAL_IMAGE_ENV_NAMES}" | grep -qx "${name}"
}

env_file_has_name() {
  local file_path="$1"
  local name="$2"
  [[ -r "${file_path}" ]] || return 1
  grep -Eq "^(export[[:space:]]+)?${name}=" "${file_path}"
}

image_source_for_var() {
  local name="$1"
  local fallback_source="$2"

  if initial_env_has_name "${name}"; then
    printf 'shell override'
  elif env_file_has_name "${DOCKER_DIR}/.env.local.credentials" "${name}"; then
    printf 'credentials'
  elif env_file_has_name "${DOCKER_DIR}/.env.local" "${name}"; then
    printf 'local override'
  elif env_file_has_name "${DOCKER_DIR}/.env" "${name}"; then
    printf 'default'
  else
    printf '%s' "${fallback_source}"
  fi
}

image_ref_is_folio_buildable() {
  local image_ref="$1"
  case "${image_ref}" in
    folioorg/*|folioci/*) return 0 ;;
    *) return 1 ;;
  esac
}

local_image_is_arm64() {
  local image_ref="$1"
  local arch
  arch="$(docker image inspect --format '{{.Architecture}}' "${image_ref}" 2>/dev/null || true)"
  [[ "${arch}" == "arm64" ]]
}

sidecar_image_is_native_binary() {
  local image_ref="$1"
  local entrypoint
  entrypoint="$(docker image inspect --format '{{json .Config.Entrypoint}}' "${image_ref}" 2>/dev/null || true)"
  case "${entrypoint}" in
    *'"./application"'*|*'"/application"'*) return 0 ;;
    *) return 1 ;;
  esac
}

image_plan_action() {
  local name="$1"
  local image_ref="$2"

  if [[ "${SIDECAR_MODE}" == "native" && "${name}" == "folio-module-sidecar" ]]; then
    if local_image_is_arm64 "${image_ref}" && sidecar_image_is_native_binary "${image_ref}"; then
      printf 'native arm64 present'
    else
      printf 'will build native'
    fi
  elif local_image_is_arm64 "${image_ref}"; then
    printf 'native arm64 present'
  elif [[ "${BUILD_ARM_IMAGES}" == "true" ]] && image_ref_is_folio_buildable "${image_ref}"; then
    printf 'will build arm64'
  elif [[ "${BUILD_ARM_IMAGES}" == "true" ]]; then
    printf 'will pull or may emulate'
  else
    printf 'not applicable on non-arm64'
  fi
}

# Human-readable age of a locally-present image ("8d ago", "3h ago", "12m ago"),
# or "-" when the image is absent or carries no usable timestamp. The date math
# goes through python3 (a required dependency); GNU-only date(1) extensions are
# avoided deliberately because they break on macOS.
image_age() {
  local image_ref="$1" created
  created="$(docker image inspect --format '{{.Created}}' "${image_ref}" 2>/dev/null || true)"
  [[ -n "${created}" ]] || { printf '-'; return 0; }
  python3 - "${created}" <<'PY' 2>/dev/null || printf '-'
import sys, re, datetime
m = re.match(r'(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})', sys.argv[1].strip())
if not m:
    print('-'); raise SystemExit
created = datetime.datetime.strptime(m.group(1), '%Y-%m-%dT%H:%M:%S').replace(tzinfo=datetime.timezone.utc)
secs = max(0, (datetime.datetime.now(datetime.timezone.utc) - created).total_seconds())
if secs < 3600:
    print(f"{int(secs // 60)}m ago")
elif secs < 86400:
    print(f"{int(secs // 3600)}h ago")
else:
    print(f"{int(secs // 86400)}d ago")
PY
}

# Collect one display row into PLAN_ROWS and tally present/build counts. The
# image plan is a sub-panel of "Prepare config", not a numbered phase, so the
# rows are rendered together as a box after every row is gathered.
# Short, fixed-width display label for the ACTION column. Derived from the verbose
# image_plan_action string, which is kept intact for the build-decision case below
# (and is asserted verbatim by the capture test).
image_action_label() {
  local name="$1"
  local action="$2"
  case "${action}" in
    'native arm64 present')
      if [[ "${SIDECAR_MODE}" == "native" && "${name}" == "folio-module-sidecar" ]]; then
        printf 'native'
      else
        printf 'present'
      fi
      ;;
    'not applicable on non-arm64') printf 'n/a' ;;
    'will build native'|'will build arm64') printf 'build' ;;
    'will pull or may emulate')  printf 'pull' ;;
    *)                           printf '%s' "${action}" ;;
  esac
}

image_source_label() {
  case "$1" in
    'shell override') printf 'shell' ;;
    'local override') printf 'local' ;;
    'native sidecar') printf 'native' ;;
    credentials)      printf 'creds' ;;
    default)          printf 'default' ;;
    descriptor)       printf 'descriptor' ;;
    *)                printf '%s' "$1" ;;
  esac
}

set_image_plan_column_widths() {
  local inner fixed remaining

  PLAN_AGE_WIDTH=4
  PLAN_SOURCE_WIDTH=10
  PLAN_ACTION_WIDTH=7
  inner="$(ui_box_inner_width 2>/dev/null || printf 74)"
  fixed=$((PLAN_AGE_WIDTH + PLAN_SOURCE_WIDTH + PLAN_ACTION_WIDTH + 4))
  remaining=$((inner - fixed))
  (( remaining < 36 )) && remaining=36

  PLAN_NAME_WIDTH=$((remaining / 3))
  (( PLAN_NAME_WIDTH < 23 )) && PLAN_NAME_WIDTH=23
  (( PLAN_NAME_WIDTH > 28 )) && PLAN_NAME_WIDTH=28
  PLAN_IMAGE_WIDTH=$((remaining - PLAN_NAME_WIDTH))
  if (( PLAN_IMAGE_WIDTH < 24 )); then
    PLAN_IMAGE_WIDTH=24
    PLAN_NAME_WIDTH=$((remaining - PLAN_IMAGE_WIDTH))
    (( PLAN_NAME_WIDTH < 12 )) && PLAN_NAME_WIDTH=12
  fi
}

print_image_plan_row() {
  local name="$1"
  local image_ref="$2"
  local source="$3"
  local action age age_display source_display row
  local name_width="${PLAN_NAME_WIDTH:-18}"
  local image_width="${PLAN_IMAGE_WIDTH:-26}"
  local age_width="${PLAN_AGE_WIDTH:-4}"
  local source_width="${PLAN_SOURCE_WIDTH:-10}"
  local action_width="${PLAN_ACTION_WIDTH:-7}"

  [[ -n "${image_ref}" ]] || return 0
  action="$(image_plan_action "${name}" "${image_ref}")"
  age="$(image_age "${image_ref}")"
  # Any action other than "already present" / "not applicable" means build.sh has
  # real work to do; track it so the orchestration step can fold its output when
  # there is nothing to build.
  case "${action}" in
    'native arm64 present'|'not applicable on non-arm64') ;;
    *) IMAGE_BUILD_PENDING=true; PLAN_BUILD_COUNT=$((PLAN_BUILD_COUNT + 1)) ;;
  esac
  # A present, locally-buildable folio image is something the refresh prompt can
  # act on; record it and its ref for an optional amd64 pull.
  if [[ "${age}" != '-' ]] && image_ref_is_folio_buildable "${image_ref}"; then
    IMAGE_REFRESH_AVAILABLE=true
    PLAN_IMAGE_REFS+=("${image_ref}")
  fi
  PLAN_TOTAL_COUNT=$((PLAN_TOTAL_COUNT + 1))
  [[ "${age}" != '-' ]] && PLAN_PRESENT_COUNT=$((PLAN_PRESENT_COUNT + 1))
  # Display-only compaction so the columns fit the box (width derived from
  # ui_box_inner_width / ui_content_width) without truncation: drop image_age's
  # " ago" suffix ("1h ago" -> "1h", "-" stays "-") and use a short ACTION label.
  # The underlying age/action values above are unchanged.
  age_display="${age% ago}"
  source_display="$(image_source_label "${source}")"
  printf -v row '%-*s %-*s %-*s %-*s %-*s' \
    "${name_width}" "$(ui_trunc "${name}" "${name_width}")" \
    "${image_width}" "$(ui_trunc_left "${image_ref}" "${image_width}")" \
    "${age_width}" "$(ui_trunc "${age_display}" "${age_width}")" \
    "${source_width}" "$(ui_trunc "${source_display}" "${source_width}")" \
    "${action_width}" "$(ui_trunc "$(image_action_label "${name}" "${action}")" "${action_width}")"
  PLAN_ROWS+=("${row}")
}

print_image_plan() {
  local module_name module_version prefix image_var image_ref source row

  IMAGE_BUILD_PENDING=false
  IMAGE_REFRESH_AVAILABLE=false
  PLAN_IMAGE_REFS=()
  PLAN_ROWS=()
  PLAN_TOTAL_COUNT=0
  PLAN_PRESENT_COUNT=0
  PLAN_BUILD_COUNT=0
  SKEW_MODULES=()
  SKEW_DESCRIPTOR_VERSIONS=()
  SKEW_IMAGE_TAGS=()
  set_image_plan_column_widths

  print_image_plan_row 'mgr-applications' "${MGR_APPLICATIONS_IMAGE:-}" "$(image_source_for_var MGR_APPLICATIONS_IMAGE default)"
  print_image_plan_row 'mgr-tenants' "${MGR_TENANTS_IMAGE:-}" "$(image_source_for_var MGR_TENANTS_IMAGE default)"
  print_image_plan_row 'mgr-tenant-entitlements' "${MGR_TENANT_ENTITLEMENTS_IMAGE:-}" "$(image_source_for_var MGR_TENANT_ENTITLEMENTS_IMAGE default)"
  print_image_plan_row 'folio-keycloak' "${FOLIO_KEYCLOAK_IMAGE:-}" "$(image_source_for_var FOLIO_KEYCLOAK_IMAGE default)"
  if [[ "${APIGW_TYPE:-kong}" == "apisix" ]]; then
    print_image_plan_row 'folio-apisix' "${FOLIO_APISIX_IMAGE:-}" "$(image_source_for_var FOLIO_APISIX_IMAGE default)"
  else
    print_image_plan_row 'folio-kong' "${FOLIO_KONG_IMAGE:-}" "$(image_source_for_var FOLIO_KONG_IMAGE default)"
  fi
  source="$(image_source_for_var FOLIO_MODULE_SIDECAR_IMAGE default)"
  if [[ "${SIDECAR_MODE}" == "native" && "${source}" == "default" ]]; then
    source='native sidecar'
  fi
  print_image_plan_row 'folio-module-sidecar' "${FOLIO_MODULE_SIDECAR_IMAGE:-}" "${source}"

  while IFS=$'\t' read -r module_name module_version; do
    [[ -n "${module_name}" ]] || continue
    prefix="$(printf '%s' "${module_name}" | tr '[:lower:]-' '[:upper:]_')"
    image_var="${prefix}_IMAGE"
    image_ref="${!image_var:-}"
    print_image_plan_row "${module_name}" "${image_ref}" "$(image_source_for_var "${image_var}" descriptor)"

    # Skew detection: compare the descriptor version against the effective
    # image tag. Only assess refs that carry a tag (contain a colon) and are
    # not digest-pinned — tagless/digest refs cannot be version-compared.
    if [[ -n "${image_ref}" && "${image_ref}" == *:* && "${image_ref}" != *@sha256:* ]]; then
      local image_tag="${image_ref##*:}"
      if [[ "${image_tag}" != "${module_version}" ]]; then
        SKEW_MODULES+=("${module_name}")
        SKEW_DESCRIPTOR_VERSIONS+=("${module_version}")
        SKEW_IMAGE_TAGS+=("${image_tag}")
      fi
    fi
  done < <(jq -r '.modules[] | [.name, .version] | @tsv' "${APP_DESCRIPTOR_PATH}")

  local plan_sep header_row; plan_sep="$(ui_glyph bullet)"
  printf -v header_row '%-*s %-*s %-*s %-*s %-*s' \
    "${PLAN_NAME_WIDTH}" 'NAME' \
    "${PLAN_IMAGE_WIDTH}" 'IMAGE' \
    "${PLAN_AGE_WIDTH}" 'AGE' \
    "${PLAN_SOURCE_WIDTH}" 'SRC' \
    "${PLAN_ACTION_WIDTH}" 'ACTION'
  ui_box_top 'image plan' "${PLAN_TOTAL_COUNT} images ${plan_sep} ${PLAN_PRESENT_COUNT} present ${plan_sep} ${PLAN_BUILD_COUNT} build"
  ui_box_row "${header_row}"
  for row in "${PLAN_ROWS[@]}"; do
    ui_box_row "${row}"
  done
  ui_box_bottom
}

# Arm a refresh-to-latest: rebuild built images instead of reusing local ones, and
# route the arm build through its live-output branch (not the folded "already
# present" verify branch). Factored out so the effect is unit-testable without a tty.
arm_image_refresh() {
  REBUILD_BUILT_IMAGES=true
  IMAGE_BUILD_PENDING=true
}

# Local FOLIO images are reused as "latest" no matter how old they are: the arm
# build only checks "is it arm64", and amd64 Compose never re-pulls a present tag.
# After the operator has seen the ages in the Image plan, offer one refresh. It
# only appears when there is a present folio image to refresh, the session is
# interactive, and --yes was not given — a cold first run (nothing present) stays
# silent. Default is No: reuse local, which keeps startup fast, offline-safe, and
# reproducible. On Yes the arm path rebuilds from source and the amd64 path pulls.
prompt_image_refresh() {
  [[ "${IMAGE_REFRESH_AVAILABLE:-false}" == 'true' ]] || return 0
  [[ "${ASSUME_YES:-false}" == 'true' ]] && return 0
  [[ -t 0 ]] || return 0

  ui_prompt 'Refresh local FOLIO images to latest?' n && arm_image_refresh
  return 0
}

# amd64 refresh action: pull the present folio/mgr image tags so the following
# `up` recreates containers on the newer digest. Reuses the refs gathered by the
# Image plan; third-party images (postgres/kafka/...) are never in that set.
# Offline or a failed pull is non-fatal — startup must still work on local images.
refresh_amd64_images() {
  [[ "${REBUILD_BUILT_IMAGES}" == 'true' ]] || return 0
  [[ "${#PLAN_IMAGE_REFS[@]}" -gt 0 ]] || return 0

  local ref
  ui_step 'Refreshing local FOLIO images (docker pull)'
  for ref in "${PLAN_IMAGE_REFS[@]}"; do
    if ! docker pull "${ref}" >/dev/null 2>&1; then
      ui_warn "Could not refresh ${ref}; using the local image."
    fi
  done
}

# True when the present native sidecar image may be reused as-is. Native and JVM
# sidecars can share the same configured tag, so architecture alone is not enough:
# reuse only when the local image is arm64 and has the native binary entrypoint.
# Factored out so the decision is unit-testable without a real build.
native_sidecar_reusable() {
  local image="$1"
  [[ "${REBUILD_NATIVE_SIDECAR}" != "true" && "${REBUILD_BUILT_IMAGES}" != "true" ]] \
    && local_image_is_arm64 "${image}" \
    && sidecar_image_is_native_binary "${image}"
}

# In native mode the :native tag selected above does not exist until we build it:
# compile folio-module-sidecar to a GraalVM native binary and package it into a
# lightweight image (misc/build-native-sidecar.sh). This is idempotent — if the
# image is already present locally we reuse it, mirroring the build-images.sh/vault
# skip pattern — unless REBUILD_NATIVE_SIDECAR forces a fresh build. The build is
# long (5-10 min) and chatty; build-native-sidecar.sh folds its mvn/docker output
# under a spinner (ui_run), showing the last lines only on failure. A native build
# failure is fatal: the selected :native image would be missing, so we
# abort with guidance instead of letting Compose fail on a non-existent image.
ensure_native_sidecar_image() {
  [[ "${SIDECAR_MODE}" == "native" ]] || return 0

  local image="${FOLIO_MODULE_SIDECAR_IMAGE:-folioci/folio-module-sidecar:native}"

  if native_sidecar_reusable "${image}"; then
    ui_ok "Native sidecar image present: ${image} (reusing; force a rebuild with --rebuild-native-sidecar)"
    return 0
  fi

  ui_step "Building native sidecar image (GraalVM): ${image}"
  if ! bash "${PROJECT_ROOT}/misc/build-native-sidecar.sh"; then
    error 'Native sidecar build failed. Rerun ./start.sh without --native-sidecar to use the JVM sidecar.'
  fi
}

# A native (GraalVM) sidecar is a different runtime from the JVM sidecar, so its
# resource envelope differs: it ignores JAVA_OPTIONS entirely (the ZGC/heap/jdwp
# flags are inert) and its resident footprint is a fraction of the JVM's. In
# native mode we therefore blank SIDECAR_JAVA_OPTIONS and lower the per-sidecar
# memory limit. SIDECAR_MODE is the single source for this — we derive from it
# rather than adding a second switch. An operator value (shell or
# docker/.env(.local), already sourced by load_folio_config) always wins. JVM mode
# is untouched: the compose defaults apply.
NATIVE_SIDECAR_MEMORY_LIMIT='128m'

select_sidecar_resources() {
  [[ "${SIDECAR_MODE}" == "native" ]] || return 0

  if [[ -z "${SIDECAR_MEMORY_LIMIT:-}" ]]; then
    export SIDECAR_MEMORY_LIMIT="${NATIVE_SIDECAR_MEMORY_LIMIT}"
    ui_debug "Native sidecar: memory limit ${SIDECAR_MEMORY_LIMIT}"
  fi
  if [[ -z "${SIDECAR_JAVA_OPTIONS+x}" ]]; then
    export SIDECAR_JAVA_OPTIONS=''
    ui_debug 'Native sidecar: cleared JAVA_OPTIONS (inert for a native binary)'
  fi
}

# Ensure the localhost aliases the bootstrap relies on exist. Adding them needs
# sudo, so this runs as an up-front preflight (see start.sh) rather than mid-flow.
# A non-interactive run (no tty) must never block on a hidden password prompt, so
# in that case we print the exact commands and continue instead of calling sudo.
ensure_host_entries() {
  local hostname
  local host_entries=("keycloak" "kafka" "kong")
  local missing=()

  for hostname in "${host_entries[@]}"; do
    grep -qE "^127\.0\.0\.1[[:space:]]+${hostname}([[:space:]]|$)" /etc/hosts \
      || missing+=("$hostname")
  done
  [[ "${#missing[@]}" -eq 0 ]] && return 0

  if [[ ! -t 0 ]]; then
    ui_warn "Missing /etc/hosts aliases (${missing[*]}); add them before a non-interactive run:"
    for hostname in "${missing[@]}"; do
      ui_info "    echo \"127.0.0.1 ${hostname}\" | sudo tee -a /etc/hosts"
    done
    return 0
  fi

  ui_step "Adding /etc/hosts aliases (sudo): ${missing[*]}"
  for hostname in "${missing[@]}"; do
    printf '127.0.0.1 %s\n' "$hostname" | sudo tee -a /etc/hosts >/dev/null
  done
}

# Surface host-readiness problems before any long-running step, so the operator
# sees a clear cause up front instead of a confusing failure mid-bootstrap. Both
# checks are warn-only on purpose: on Linux `docker info` MemTotal is host RAM
# (not an allocatable limit), and a busy port is often just a warm re-run of this
# same stack — neither should hard-block the supported flow.
MIN_DOCKER_MEMORY_GB="${MIN_DOCKER_MEMORY_GB:-12}"
HOST_REQUIRED_PORTS="${HOST_REQUIRED_PORTS:-8000 8080}"

# Warn when Docker has less memory than the minimal platform realistically needs.
# A non-numeric/empty reading (old daemon, permission, format change) is skipped
# silently rather than guessed at.
check_docker_memory() {
  local mem_bytes min_bytes mem_gb
  mem_bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null || true)"
  [[ "${mem_bytes}" =~ ^[0-9]+$ ]] || return 0
  min_bytes=$(( MIN_DOCKER_MEMORY_GB * 1024 * 1024 * 1024 ))
  (( mem_bytes >= min_bytes )) && return 0
  # Record the low-memory state so a later failure snapshot can surface the hint
  # without re-running `docker info`.
  export DOCKER_MEMORY_LOW=true
  mem_gb=$(( mem_bytes / 1024 / 1024 / 1024 ))
  ui_warn "Docker reports ~${mem_gb}GB memory; ${MIN_DOCKER_MEMORY_GB}GB+ recommended for this stack."
  ui_warn 'Raise it in Docker Desktop -> Settings -> Resources (modules may OOM or thrash otherwise).'
}

# True when a TCP listener already answers on the host port. /dev/tcp is a bash
# builtin: no lsof/nc dependency, works on Linux, macOS, and git-bash.
host_port_in_use() {
  local port="$1"
  ( exec 3<>"/dev/tcp/127.0.0.1/${port}" ) 2>/dev/null
}

# True when a running Docker container publishes the port — i.e. almost certainly
# this stack on a warm re-run, not a foreign process worth warning about.
host_port_held_by_docker() {
  local port="$1"
  [[ -n "$(docker ps --filter "publish=${port}" --quiet 2>/dev/null)" ]]
}

# Warn only about ports held by a non-Docker process: a warm re-run of our own
# stack legitimately holds 8000/8080 and must not raise a false alarm.
check_host_ports() {
  local port busy=()
  for port in ${HOST_REQUIRED_PORTS}; do
    if host_port_in_use "${port}" && ! host_port_held_by_docker "${port}"; then
      busy+=("${port}")
    fi
  done
  [[ "${#busy[@]}" -eq 0 ]] && return 0
  ui_warn "Host port(s) already in use by a non-Docker process: ${busy[*]} (api-gateway needs 8000, Keycloak 8080)."
  ui_warn 'Free them or stop the conflicting service, then rerun.'
}

preflight_host() {
  check_docker_memory
  check_host_ports
}

host_api_gateway_url() {
  printf '%s\n' "${API_GATEWAY_URL:-${KONG_URL:-${FOLIO_KONG_URL:-http://localhost:8000}}}"
}

create_default_admin_user() {
  local max_retries=3 retry_count=0
  local gateway_url

  gateway_url="$(host_api_gateway_url)"

  while [[ $retry_count -lt $max_retries ]]; do
    if [[ $retry_count -gt 0 ]]; then
      ui_warn "Retry attempt ${retry_count} of ${max_retries}..."
      sleep 10
    fi

    if API_GATEWAY_URL="${gateway_url}" bash "${PROJECT_ROOT}/misc/create-user.sh" folio folio; then
      return 0
    fi
    retry_count=$((retry_count + 1))
  done

  ui_warn "User creation failed after ${max_retries} attempts; rerun ./start.sh after the platform stabilizes."
  return 1
}

################################################################################
# Bootstrap flow
################################################################################

# Print the run banner: the title and one dim identity line (version · app · arch).
# Called from start.sh at the very top, above the Configure phase. The sidecar/module
# choices are resolved later (the interactive prompts run inside the Configure phase),
# so they are surfaced by print_run_mode rather than crammed into this banner.
print_run_banner() {
  local app_label arch banner_meta version sep
  app_label="$(basename "$(dirname "${APP_DESCRIPTOR_PATH}")")"
  arch="$(uname -m)"
  sep="$(ui_glyph bullet)"
  banner_meta="${app_label} ${sep} ${arch}"
  version="$(git -C "${PROJECT_ROOT}" describe --tags 2>/dev/null || true)"
  [[ -n "${version}" ]] && banner_meta="${version} ${sep} ${banner_meta}"

  ui_title 'eureka platform bootstrap'
  ui_note "  ${banner_meta}"
}

# One dim line summarizing the resolved run choices, printed inside the Configure
# phase once the prompts have settled: the sidecar runtime and whether module
# versions were actualized. It carries the sidecar token that used to live in the
# banner (the banner now prints before the prompts, so it cannot show a chosen mode).
print_run_mode() {
  local sep modules
  sep="$(ui_glyph bullet)"
  [[ "${ACTUALIZE_MODULES}" == 'true' ]] && modules='actualized' || modules='pinned'
  ui_info "$(ui_c dim "${sep}") sidecar ${SIDECAR_MODE} $(ui_c dim "${sep}") modules ${modules} $(ui_c dim "${sep}") gateway ${APIGW_TYPE:-kong}"
}

print_final_summary() {
  local final_status="$1"
  local run_total="$2"
  local smoke_status="${3:-not run}"
  local final_next_step="${4:-}"

  ui_box_top "Bootstrap complete - ${final_status}" "total ${run_total}" done
  ui_box_kv 'API gateway' 'http://localhost:8000'
  ui_box_kv 'Keycloak' 'http://localhost:8080'
  ui_box_kv 'Tenant' 'diku'
  ui_box_kv 'User' 'folio / folio'
  ui_box_kv 'Smoke check' "${smoke_status}"
  [[ -n "${final_next_step}" ]] && ui_box_kv_wrapped 'Next step' "${final_next_step}"
  ui_box_bottom
}

# Re-reads the descriptor, regenerates discovery.json, cleans the managed
# .env.local block, re-resolves services, and force-re-exports descriptor
# module config (unset first so the "already set" guard in
# export_descriptor_module_config does not skip the new values). Called once
# during Prepare config and again after a skew-driven actualize.
sync_descriptor_runtime() {
  local line assignment name

  if [[ "${ACTUALIZE_MODULES}" == 'true' ]]; then
    ui_run 'actualizing module versions' \
      python3 "${PROJECT_ROOT}/misc/module-version-actualizer.py" --app "${APP_DESCRIPTOR_PATH}" --pre-release "${PRE_RELEASE_MODE}"
  else
    ui_debug 'Skipping module version actualization.'
  fi

  ui_run 'syncing runtime metadata' \
    python3 "${PROJECT_ROOT}/misc/docker-module-updater/run.py" --app "${APP_DESCRIPTOR_PATH}"

  resolve_app_services

  # Force re-export: unset descriptor-derived MOD_*_IMAGE and MOD_*_VERSION so
  # export_descriptor_module_config's "already set" guard does not skip them.
  while IFS= read -r line; do
    [[ "${line}" == export\ *=* ]] || continue
    assignment="${line#export }"
    name="${assignment%%=*}"
    case "${name}" in
      *_IMAGE|MOD_*_VERSION) unset "${name}" ;;
    esac
  done < <(python3 "${PROJECT_ROOT}/misc/docker-module-updater/run.py" --app "${APP_DESCRIPTOR_PATH}" --module-env)

  export_descriptor_module_config "${APP_DESCRIPTOR_PATH}"
  print_image_plan
}

# Detects descriptor/image version skew (populated by print_image_plan) and
# either interactively actualizes+resyncs (then re-checks) or hard-halts.
# Must run AFTER print_image_plan and BEFORE any containers start.
check_and_handle_descriptor_image_skew() {
  local count=${#SKEW_MODULES[@]}
  [[ ${count} -eq 0 ]] && return 0

  local i
  ui_warn "Descriptor module versions do not match effective image tags (${count} module(s)):"
  for (( i = 0; i < count; i++ )); do
    ui_info "  ${SKEW_MODULES[i]}: descriptor ${SKEW_DESCRIPTOR_VERSIONS[i]} vs image ${SKEW_IMAGE_TAGS[i]}"
  done

  # Interactive path: offer actualize + resync. Non-interactive (--yes / not
  # a TTY) goes straight to the hard halt below.
  if [[ "${ASSUME_YES:-false}" != 'true' && -t 0 ]]; then
    if ui_prompt "Actualize module versions from the FOLIO registry now?" n; then
      ACTUALIZE_MODULES=true
      if [[ "${PRE_RELEASE_MODE}" != 'true' ]]; then
        ui_prompt "Use latest SNAPSHOT (pre-release) versions?" n && PRE_RELEASE_MODE=true
      fi
      sync_descriptor_runtime
      # Re-check: actualize may not resolve skew if a standalone .env.local
      # override survived cleanup_module_runtime_metadata.
      count=${#SKEW_MODULES[@]}
      if [[ ${count} -eq 0 ]]; then
        ui_ok "Descriptor and image versions aligned after actualize."
        return 0
      fi
      ui_warn "Skew persists for ${count} module(s) after actualize — a standalone override in docker/.env.local likely survived cleanup."
    fi
  fi

  # Hard halt: actionable message naming the cause and the two recovery paths.
  ui_error "Descriptor/image version skew prevents a reliable bootstrap."
  ui_info "  Affected module(s):"
  for (( i = 0; i < ${#SKEW_MODULES[@]}; i++ )); do
    ui_info "    ${SKEW_MODULES[i]}: descriptor ${SKEW_DESCRIPTOR_VERSIONS[i]} vs image ${SKEW_IMAGE_TAGS[i]}"
  done
  ui_info "  Recovery options:"
  ui_info "    1. Run ./start.sh --actualize [--pre-release] to refresh descriptor versions from the registry."
  ui_info "    2. Remove or align the matching MOD_*_IMAGE override in docker/.env.local."
  ui_info "  Note: a plain ./start.sh --yes re-run will NOT recover from this — the override persists."
  exit 1
}

run_bootstrap_flow() {
  local system_access_token
  local final_status='Ready'
  local final_next_step=''
  local smoke_status='not run'

  cd "${DOCKER_DIR}"

  # Any hard failure below exits via set -e. Surface a bounded diagnostic snapshot
  # first, then propagate the original exit code. A clean run (rc 0) is a no-op.
  # Recovery is a plain re-run of ./start.sh — every step is idempotent.
  trap 'rc=$?; [[ $rc -ne 0 ]] && dump_failure_diagnostics || true; exit $rc' EXIT

  # Set COMPOSE_FILE, GATEWAY_PROFILE, APIGW_URL, and APIGW_API_KEY based on
  # APIGW_TYPE before the first docker compose call.
  select_gateway_config

  # run_total is started in start.sh's main() as phase 01 (Configure) opens, so the
  # completion box's total spans every numbered phase; here we continue into the next.
  ui_phase 'Prepare config'
  capture_initial_image_env_names
  ui_run 'refreshing local credentials and defaults' refresh_local_credentials
  select_sidecar_resources

  ui_run 'preparing support images' bash "${PROJECT_ROOT}/misc/build-images.sh"

  sync_descriptor_runtime
  check_and_handle_descriptor_image_skew
  prompt_image_refresh
  ensure_native_sidecar_image

  if [[ "${BUILD_ARM_IMAGES}" == 'true' ]]; then
    if [[ "${IMAGE_BUILD_PENDING}" == 'true' ]]; then
      ui_step 'Building ARM-compatible Docker images'
      build_arm_images
    else
      # Nothing to build: the Image plan above already shows every image as
      # present, so fold build.sh's per-image "Skipping ..." narration and
      # surface its full log only if the verification unexpectedly fails.
      ui_run 'verifying ARM images' build_arm_images
      ui_ok 'ARM-compatible images already present'
    fi
  else
    ui_debug 'Skipping ARM-compatible Docker image build.'
    refresh_amd64_images
  fi

  load_app_metadata
  ui_ok "Prepared application ${APP_NAME}."
  ui_debug "Resolved application services for ${APP_NAME}: ${APP_SERVICES[*]}"

  ui_phase 'Start core services'
  docker compose --profile core --profile "${GATEWAY_PROFILE}" up -d
  wait_for_all_healthy
  recover_api_gateway_if_needed
  wait_for_gateway_admin_ready
  wait_for_http_ready 'http://localhost:8000/' 'api-gateway proxy' '200 404'

  SECRET_STORE_VAULT_TOKEN="$(read_vault_root_token)"
  export SECRET_STORE_VAULT_TOKEN

  ui_phase 'Start manager services'
  ui_run 'refreshing the local Vault token' persist_vault_root_token "${SECRET_STORE_VAULT_TOKEN}"
  docker compose --profile mgr-components --profile "${GATEWAY_PROFILE}" up -d
  wait_for_all_healthy
  recover_api_gateway_if_needed
  wait_for_gateway_admin_ready
  wait_for_http_ready 'http://localhost:8000/applications' 'applications route' '200 401 403 404 405'
  wait_for_http_ready 'http://localhost:8000/tenants' 'tenants route' '200 401 403 404 405'
  wait_for_http_ready 'http://localhost:8000/entitlements' 'entitlements route' '200 401 403 404 405'

  ui_phase 'Register application'
  ui_step 'Obtaining system access token'
  system_access_token="$(obtain_system_access_token)"
  register_application_descriptor "$system_access_token"
  register_discovery_information "$system_access_token"

  ui_phase 'Start application services'
  ui_step "Deploying ${APP_NAME} services"
  ui_debug "Application services: ${APP_SERVICES[*]}"
  docker compose up -d "${APP_SERVICES[@]}"
  wait_for_all_healthy
  wait_for_http_ready 'http://localhost:8000/capabilities?limit=1' 'capabilities route' '200 401 403 404 405'
  ui_ok "Application services deployed for ${APP_NAME}."

  ui_phase 'Finalize tenant setup'
  system_access_token="$(obtain_system_access_token)"
  create_tenant_and_enable_application "$system_access_token"

  ui_phase 'Create default admin user'
  if ! create_default_admin_user; then
    final_status='Partially ready'
    final_next_step='Rerun ./start.sh after the platform stabilizes.'
  fi

  if smoke_check; then
    smoke_status='passed'
  else
    smoke_status='failed'
    final_status='Partially ready'
  fi

  local run_total
  run_total="$(ui_fmt_duration "$(ui_timer_read run_total 2>/dev/null || printf 0)")"
  ui_phase_finish done
  ui_recap "${run_total}"

  print_final_summary "${final_status}" "${run_total}" "${smoke_status}" "${final_next_step}"
  return 0
}
