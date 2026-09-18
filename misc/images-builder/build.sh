#!/usr/bin/env bash

set -euo pipefail

# Speed knobs (override via env if needed)
NUM_JOBS="${NUM_JOBS:-4}"             # parallel module builds

export DOCKER_BUILDKIT=1
export BUILDKIT_PROGRESS=plain

REPO_URL="https://github.com/folio-org/folio-tools.git"
CLONE_DIR="folio-tools"
IMAGE_NAME_openjdk17="folioci/alpine-jre-openjdk17:latest"
IMAGE_NAME_openjdk21="folioci/alpine-jre-openjdk21:latest"
BASE_URL="https://github.com/folio-org"
# Last anonymously buildable folio-apisix revision: master's Dockerfile has
# required the subscription-walled dhi.io/apisix base image since 289fea7
# (2026-07-10), which fails anonymous base-image pulls with 401. Used only by
# the arm64 gateway build below; drop the pin once upstream master builds
# anonymously again.
FOLIO_APISIX_BUILD_REF="159ad2f55dc34d364bbbdc660b019b297f894c45"

# Resolve repo-relative inputs to absolute paths before we cd into a throwaway
# working directory, so the script is location-independent.
PROJECT_ROOT="$(pwd)"
DESCRIPTOR_FILE="${PROJECT_ROOT}/descriptors/app-platform-minimal/descriptor.json"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/misc/lib/folio-common.sh"
load_folio_config
export_descriptor_module_config "${DESCRIPTOR_FILE}"

# All clones (folio-tools base image + every module) happen inside one disposable
# work dir, so an interrupted build never litters the repo root. Per-module build
# logs and completion status files live under it too, and go away with the trap.
WORK_DIR="$(mktemp -d)"
LOG_DIR="${WORK_DIR}/logs"
STATUS_DIR="${WORK_DIR}/status"
mkdir -p "${LOG_DIR}" "${STATUS_DIR}"
trap 'rm -rf "${WORK_DIR}"' EXIT
cd "${WORK_DIR}"

image_name_from_ref() {
    local image_ref="$1"
    local image_name

    image_ref="${image_ref%%@*}"
    image_name="${image_ref##*/}"
    image_name="${image_name%%:*}"
    printf '%s\n' "${image_name}"
}

image_tag_from_ref() {
    local image_ref="$1"
    local image_name

    image_ref="${image_ref%%@*}"
    image_name="${image_ref##*/}"
    if [[ "${image_name}" == *:* ]]; then
        printf '%s\n' "${image_name#*:}"
    else
        printf 'latest\n'
    fi
}

# True when a locally-present image is already built for arm64, so we can skip
# rebuilding it. Returns non-zero when the image is missing or a different arch.
# This makes the whole build idempotent: a warm re-run rebuilds nothing.
# REBUILD_BUILT_IMAGES forces a full rebuild (the refresh-to-latest path): nothing
# counts as native, so the base JRE and every module are rebuilt from source.
# The folio-module-sidecar tag is shared by both sidecar runtimes: in JVM mode an
# arm64 image under that tag is reusable only when it is NOT the native binary
# (a previous native run replaces the tag contents), so a same-tag native image
# is rebuilt here instead of skipped — that is what makes native → JVM real.
image_is_native() {
  local image_ref="$1" arch
  [[ "${REBUILD_BUILT_IMAGES:-false}" == "true" ]] && return 1
  arch="$(docker image inspect --format '{{.Architecture}}' "$image_ref" 2>/dev/null || true)"
  [[ "$arch" == "arm64" ]] || return 1
  if [[ "${SIDECAR_MODE:-jvm}" != "native" ]] \
     && [[ "$(image_name_from_ref "$image_ref")" == "folio-module-sidecar" ]] \
     && sidecar_image_is_native_binary "$image_ref"; then
    return 1
  fi
  return 0
}

# Check for required commands
for cmd in jq docker mvn git; do
    if ! command -v $cmd &> /dev/null; then
        ui_error "$cmd is not installed. Please install $cmd to run this script."
        exit 1
    fi
done

# Ensure docker buildx is available
if ! docker buildx version >/dev/null 2>&1; then
    ui_error "docker buildx is not available. Please install/enable Docker Buildx."
    exit 1
fi

# Build the arm64 base JRE image that every module Dockerfile inherits from.
# Upstream folio-tools already bases on eclipse-temurin:21-jre-alpine (multi-arch),
# so no Dockerfile patching is needed — we just build it for arm64 under the
# folioci/alpine-jre-openjdk* tags so the published amd64-only images are shadowed.
# Subshell body: ui_run invokes it in-process, so the cd must not leak.
build_base_jre_image() (
  set -e
  git clone --depth 1 --quiet "$REPO_URL"
  cd folio-tools/folio-java-docker/openjdk21

  docker buildx build \
    --platform linux/arm64 \
    -t "$IMAGE_NAME_openjdk21" \
    -t "$IMAGE_NAME_openjdk17" \
    --load .

  cd ../../..
  rm -rf $CLONE_DIR
)

if image_is_native "$IMAGE_NAME_openjdk21" && image_is_native "$IMAGE_NAME_openjdk17"; then
  ui_info "Skipping base image build — native arm64 images already present"
else
  ui_run "building base JRE image (${IMAGE_NAME_openjdk21})" build_base_jre_image
fi

# Check for descriptor file
if [ ! -f "$DESCRIPTOR_FILE" ]; then
    ui_error "File $DESCRIPTOR_FILE not found!"
    exit 1
fi

################################################################################
# Job queue — collect everything to build first, run second. The skip checks
# (native image present, non-FOLIO override) happen at enqueue time, so the
# dispatcher below deals only with real work and owns the terminal alone.
################################################################################

QUEUE_NAMES=()
QUEUE_VERSIONS=()
QUEUE_SKIP_MAVEN=()
QUEUE_TAGS=()
QUEUE_COUNT=0
NATIVE_SKIP_COUNT=0
FAILED_MODULES=()
FAILED_COUNT=0

module_build_tag() {
    local name="$1" version="$2"
    if [[ "$version" == *"SNAPSHOT"* ]] || [[ "$version" == "latest" ]]; then
        printf 'folioci/%s:%s\n' "$name" "$version"
    else
        printf 'folioorg/%s:%s\n' "$name" "$version"
    fi
}

enqueue_module() {
    local name="$1" version="$2" skip_maven="$3" image_ref="${4:-}"
    local tag="${image_ref}" idx

    [[ -n "${tag}" ]] || tag="$(module_build_tag "$name" "$version")"

    if image_is_native "$tag"; then
        NATIVE_SKIP_COUNT=$((NATIVE_SKIP_COUNT + 1))
        return 0
    fi

    # One job (one log + one status file) per module name.
    for (( idx = 0; idx < QUEUE_COUNT; idx++ )); do
        [[ "${QUEUE_NAMES[$idx]}" == "$name" ]] && return 0
    done

    QUEUE_NAMES+=("$name")
    QUEUE_VERSIONS+=("$version")
    QUEUE_SKIP_MAVEN+=("$skip_maven")
    QUEUE_TAGS+=("$tag")
    QUEUE_COUNT=$((QUEUE_COUNT + 1))
}

enqueue_effective_image_ref() {
    local image_ref="$1"
    local skip_maven="$2"
    local name version

    if [[ -z "${image_ref}" ]]; then
        return 0
    fi

    case "${image_ref}" in
      folioorg/*|folioci/*) ;;
      *)
        ui_info "Skipping ${image_ref} — non-FOLIO override; Docker will pull it or may emulate it"
        return 0
        ;;
    esac

    name="$(image_name_from_ref "${image_ref}")"
    version="$(image_tag_from_ref "${image_ref}")"
    enqueue_module "$name" "$version" "$skip_maven" "$image_ref"
}

module_image_var_name() {
    local module_name="$1"
    printf '%s_IMAGE\n' "$(printf '%s' "${module_name}" | tr '[:lower:]-' '[:upper:]_')"
}

################################################################################
# Workers — silent by design. All clone/maven/docker output is captured into the
# per-module log; completion is published as an atomic status file the dispatcher
# turns into one committed console row. The dispatcher is the single terminal
# writer, so parallel jobs can no longer interleave build noise.
################################################################################

# Clone -> maven -> docker pipeline for one image. Prints the failing stage name
# on stdout (empty on success); every other byte goes to stderr, which the job
# wrapper points at the per-module log (or streams under DEBUG).
build_module_steps() (
    set -e
    local name="$1" version="$2" skip_maven="$3" tag="$4"
    local branch_arg

    # Decide ref to fetch shallowly. SNAPSHOT/latest track master; a semver
    # release maps to its upstream vX.Y.Z tag. Any other tag (e.g. a :native
    # image tag that leaked in) has no derivable branch — fail clearly instead of
    # blindly cloning `--branch v<tag>` (which produced the vnative regression).
    if [[ "$version" == *"SNAPSHOT"* ]] || [[ "$version" == "latest" ]]; then
        branch_arg="--branch master"
    elif [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        branch_arg="--branch v$version"
    else
        printf 'cannot derive a git branch for non-release tag %q (module %q)\n' \
            "$version" "$name" >&2
        printf 'branch'
        exit 0
    fi

    if ! git clone --depth 1 --single-branch $branch_arg --quiet "$BASE_URL/$name.git" >&2; then
        printf 'clone'
        exit 0
    fi

    cd "$name"

    # folio-apisix only: build from the pinned revision (see the constant at the
    # top) instead of the derived branch tip. Any other module keeps the
    # tag-derived ref.
    if [[ "$name" == "folio-apisix" ]]; then
        if ! { git fetch --depth 1 --quiet origin "$FOLIO_APISIX_BUILD_REF" \
            && git checkout --quiet FETCH_HEAD; }; then
            printf 'pin' >&2
            printf 'pin'
            exit 0
        fi
    fi

    if [ "$skip_maven" != "true" ]; then
        if ! mvn -T 1C -q --no-transfer-progress -DskipTests -DskipITs -Dmaven.javadoc.skip=true clean install >&2; then
            printf 'maven'
            exit 0
        fi
    fi

    if ! docker buildx build \
          --platform linux/arm64 \
          -t "$tag" --load . >&2; then
        printf 'docker'
        exit 0
    fi
)

# One background job: run the pipeline captured, measure its elapsed, publish the
# status file atomically (temp name + mv) so the dispatcher never reads a partial
# write. Status format: "<ok|clone|maven|docker|build> <elapsed_seconds> <tag>".
build_module_job() {
    local name="$1" version="$2" skip_maven="$3" tag="$4"
    local start="${SECONDS}" stage elapsed

    if [[ "${DEBUG:-false}" == "true" ]]; then
        if ! stage="$(build_module_steps "$name" "$version" "$skip_maven" "$tag")"; then
            stage='build'
        fi
    else
        if ! stage="$(build_module_steps "$name" "$version" "$skip_maven" "$tag" 2>"${LOG_DIR}/${name}.log")"; then
            stage='build'
        fi
    fi
    elapsed=$(( SECONDS - start ))
    rm -rf "${WORK_DIR:?}/${name:?}"
    printf '%s %s %s\n' "${stage:-ok}" "${elapsed}" "${tag}" > "${STATUS_DIR}/.${name}.tmp"
    mv "${STATUS_DIR}/.${name}.tmp" "${STATUS_DIR}/${name}"
}

# Dispatcher + monitor: keep <= NUM_JOBS jobs running, tick one aggregate spinner
# line ([done/total] + the names currently building), and commit one permanent
# timed row per finished image. Append-only per the console-UI contract; in a
# pipe the ticks are silent and only the committed rows appear.
dispatch_builds() {
    local total="${QUEUE_COUNT}" next=0 done_count=0 idx
    local build_start="${SECONDS}" names state elapsed tag message
    local reported=()

    if (( total == 0 )); then
        return 0
    fi

    for (( idx = 0; idx < total; idx++ )); do reported[idx]=0; done

    ui_step "Building images"

    while (( done_count < total )); do
        while (( next < total )) && [ "$(jobs -p | wc -l)" -lt "${NUM_JOBS}" ]; do
            build_module_job "${QUEUE_NAMES[$next]}" "${QUEUE_VERSIONS[$next]}" \
                "${QUEUE_SKIP_MAVEN[$next]}" "${QUEUE_TAGS[$next]}" &
            next=$((next + 1))
        done

        for (( idx = 0; idx < next; idx++ )); do
            if [[ "${reported[$idx]}" != 0 || ! -f "${STATUS_DIR}/${QUEUE_NAMES[$idx]}" ]]; then
                continue
            fi
            reported[idx]=1
            done_count=$((done_count + 1))
            read -r state elapsed tag < "${STATUS_DIR}/${QUEUE_NAMES[$idx]}"
            if [[ "${state}" == "ok" ]]; then
                ui_ok "${QUEUE_NAMES[$idx]}:${QUEUE_VERSIONS[$idx]} -> ${tag} ($(ui_fmt_seconds "${elapsed}"))"
            else
                ui_fail "${QUEUE_NAMES[$idx]}:${QUEUE_VERSIONS[$idx]} ${UI_BULLET} ${state} failed ($(ui_fmt_seconds "${elapsed}"))"
                FAILED_MODULES+=("${QUEUE_NAMES[$idx]}")
                FAILED_COUNT=$((FAILED_COUNT + 1))
            fi
        done

        if (( done_count >= total )); then
            break
        fi

        # Safety net: every slot dispatched, no job left running, yet statuses are
        # missing — a job died without publishing. Fail the stragglers instead of
        # polling forever.
        if (( next >= total )) && [ "$(jobs -p | wc -l)" -eq 0 ]; then
            for (( idx = 0; idx < total; idx++ )); do
                if [[ "${reported[$idx]}" != 0 ]]; then
                    continue
                fi
                reported[idx]=1
                done_count=$((done_count + 1))
                ui_fail "${QUEUE_NAMES[$idx]}:${QUEUE_VERSIONS[$idx]} build failed (no status)"
                FAILED_MODULES+=("${QUEUE_NAMES[$idx]}")
                FAILED_COUNT=$((FAILED_COUNT + 1))
            done
            continue
        fi

        if [[ "${DEBUG:-false}" != "true" ]]; then
            names=''
            for (( idx = 0; idx < next; idx++ )); do
                if [[ "${reported[$idx]}" == 0 ]]; then
                    names="${names:+${names}, }${QUEUE_NAMES[$idx]}"
                fi
            done
            names="$(ui_trunc "${names}" 60)"
            message="Building images"
            [[ -n "${names}" ]] && message="${message}: ${names}"
            ui_progress "${message}" "${done_count}/${total}" "$(( SECONDS - build_start ))"
        fi
        sleep 0.3
    done
    wait

    local total_elapsed
    total_elapsed="$(ui_fmt_seconds "$(( SECONDS - build_start ))")"
    if (( FAILED_COUNT > 0 )); then
        ui_fail "Built $((done_count - FAILED_COUNT))/${total} images (${total_elapsed})"
    else
        ui_ok "Built ${total} images (${total_elapsed})"
    fi
}

# Process modules from descriptor.json
modules=$(jq -c '.modules[]' "$DESCRIPTOR_FILE")
for module in $modules; do
    name=$(echo "$module" | jq -r '.name')
    version=$(echo "$module" | jq -r '.version')
    image_var="$(module_image_var_name "$name")"
    image_ref="${!image_var:-}"
    if [[ -n "${image_ref}" ]]; then
        enqueue_effective_image_ref "${image_ref}" "false"
    else
        enqueue_module "$name" "$version" "false"
    fi
done

enqueue_effective_image_ref "${MGR_TENANTS_IMAGE:-}" "false"
enqueue_effective_image_ref "${MGR_TENANT_ENTITLEMENTS_IMAGE:-}" "false"
enqueue_effective_image_ref "${MGR_APPLICATIONS_IMAGE:-}" "false"
# In native sidecar mode the sidecar is compiled and packaged by the dedicated
# native builder (misc/build-native-sidecar.sh via ensure_native_sidecar_image),
# not here. Its :native tag is not a real git ref, so letting the generic builder
# derive a branch would produce `--branch vnative` and fail the whole phase. JVM
# mode still builds an arm64 sidecar from master (tag latest/SNAPSHOT).
if [[ "${SIDECAR_MODE:-jvm}" != "native" ]]; then
    enqueue_effective_image_ref "${FOLIO_MODULE_SIDECAR_IMAGE:-}" "false"
fi
enqueue_effective_image_ref "${FOLIO_KEYCLOAK_IMAGE:-}" "true"
# Only the selected gateway's image belongs in the arm64 queue — the Image plan
# in bootstrap-engine.sh scopes itself the same way, and building the unused
# gateway must never be able to fail the run.
if [[ "${APIGW_TYPE:-kong}" == "apisix" ]]; then
    # folioci/folio-apisix is published amd64-only; without an arm64 rebuild the
    # gateway runs under QEMU emulation on Apple Silicon.
    enqueue_effective_image_ref "${FOLIO_APISIX_IMAGE:-}" "true"
else
    enqueue_effective_image_ref "${FOLIO_KONG_IMAGE:-}" "true"
fi

if (( NATIVE_SKIP_COUNT > 0 )); then
    ui_info "Skipping ${NATIVE_SKIP_COUNT} image(s) — native arm64 images already present"
fi

dispatch_builds

if (( FAILED_COUNT > 0 )); then
    ui_error "The following modules failed to build:"
    for name in "${FAILED_MODULES[@]}"; do
        ui_info "- $name"
    done
    for name in "${FAILED_MODULES[@]}"; do
        if [ -s "${LOG_DIR}/${name}.log" ]; then
            ui_error "${name} build log (last 40 lines):"
            tail -n 40 "${LOG_DIR}/${name}.log" >&2
        fi
    done
    # Fail loudly: a partial image set must not be reported as a successful build,
    # otherwise the bootstrap starts containers that have no image.
    exit 1
fi

ui_ok "All modules built successfully."
