#!/usr/bin/env bash

set -e

SIDECAR_REPO="https://github.com/folio-org/folio-module-sidecar.git"
FOLIO_MODULE_SIDECAR_IMAGE="${FOLIO_MODULE_SIDECAR_IMAGE:-folioci/folio-module-sidecar:native}"
BUILD_DIR="folio-module-sidecar-native-build"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$SCRIPT_DIR"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/folio-common.sh"

ui_title "Building Native Sidecar Image"

# Derive the git ref to build from the image tag — the single source of truth.
# A semver tag (4.0.1) maps to the upstream git tag v4.0.1; anything else
# (native/latest/*-SNAPSHOT/no tag) falls back to master. We verify the tag
# exists upstream before using it so a typo degrades to a visible master build
# instead of a hard clone failure.
derive_sidecar_ref() {
    local image="$1"
    local tag="${image##*:}"

    # No ':' in the ref (or ends with '/') means no explicit tag.
    if [ "$tag" = "$image" ]; then
        tag=""
    fi

    if [[ "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        if git ls-remote --tags "$SIDECAR_REPO" "refs/tags/v${tag}" 2>/dev/null | grep -q .; then
            printf 'v%s' "$tag"
            return 0
        fi
        ui_warn "git tag v${tag} not found upstream; falling back to master"
    fi
    printf 'master'
}

SIDECAR_REF="$(derive_sidecar_ref "$FOLIO_MODULE_SIDECAR_IMAGE")"

# Cleanup function
cleanup() {
    if [ -d "$WORK_DIR/$BUILD_DIR" ]; then
        ui_info ""
        ui_info "Cleaning up build directory..."
        rm -rf "$WORK_DIR/$BUILD_DIR"
    fi
}

trap cleanup EXIT

ui_step "Cloning folio-module-sidecar repository"
ui_kv "Repository" "$SIDECAR_REPO"
ui_kv "Image tag" "$FOLIO_MODULE_SIDECAR_IMAGE"
ui_kv "Git ref" "$SIDECAR_REF"
ui_kv "Build directory" "$WORK_DIR/$BUILD_DIR"
ui_info ""

cd "$WORK_DIR"

if ! git clone --depth 1 --branch "$SIDECAR_REF" --quiet "$SIDECAR_REPO" "$BUILD_DIR"; then
    ui_error "Failed to clone repository"
    exit 1
fi

cd "$BUILD_DIR"

ui_ok "Repository cloned successfully"
ui_info ""

# Check if GraalVM is available
if ! command -v native-image >/dev/null 2>&1; then
    CONTAINER_BUILD=true
else
    CONTAINER_BUILD=false
fi

# The native profile in pom.xml already contains all necessary workarounds; just
# run the standard native build. Its huge mvn/Mandrel log is folded under the
# ui_run spinner (live elapsed instead of "please wait"); on failure only the last
# 40 lines are shown, with the full log kept on disk (UI_RUN_TAIL_LINES).
BUILD_RESULT=0
if [ "$CONTAINER_BUILD" = true ]; then
    UI_RUN_TAIL_LINES=40 ui_run 'building native sidecar (Mandrel container, ~5-10 min)' \
        mvn clean install -Pnative -Dcheckstyle.skip -DskipTests -q \
        -Dquarkus.native.container-build=true \
        -Dquarkus.native.builder-image=quay.io/quarkus/ubi9-quarkus-mandrel-builder-image:jdk-25 \
        || BUILD_RESULT=$?
else
    UI_RUN_TAIL_LINES=40 ui_run 'building native sidecar (local GraalVM, ~5-10 min)' \
        mvn clean install -Pnative -Dcheckstyle.skip -DskipTests -q \
        || BUILD_RESULT=$?
fi

if [ $BUILD_RESULT -ne 0 ]; then
    ui_info ""
    ui_info "Common issues:"
    ui_info "  1. Increase Docker memory to 8GB+ (Docker Desktop -> Settings -> Resources)"
    ui_info "  2. Missing GraalVM native-image (install GraalVM and run 'gu install native-image')"
    ui_info "  3. Check if folio-module-sidecar ref '$SIDECAR_REF' supports native build"
    ui_info ""
    ui_info "This is likely an upstream issue with folio-module-sidecar native build."
    ui_info "Consider using JVM sidecar instead (stable and proven)."
    ui_info ""
    exit 1
fi

# Auto-detect platform (no need to specify --platform, docker will use native arch)
ARCH=$(uname -m)
ui_kv "Detected architecture" "$ARCH"

# Package the native binary into the image. Folded under ui_run like the mvn step.
DOCKER_RESULT=0
UI_RUN_TAIL_LINES=40 ui_run 'packaging native sidecar image' \
    docker build -f docker/Dockerfile.native-micro -t "$FOLIO_MODULE_SIDECAR_IMAGE" . --no-cache \
    || DOCKER_RESULT=$?
if [ $DOCKER_RESULT -ne 0 ]; then
    ui_error "Docker build failed"
    exit 1
fi

ui_ok "Native sidecar image built successfully!"
ui_kv "  Image" "$FOLIO_MODULE_SIDECAR_IMAGE"
ui_kv "  Architecture" "$ARCH"
ui_info ""
ui_step "Verifying image"
docker image inspect "$FOLIO_MODULE_SIDECAR_IMAGE" >/dev/null 2>&1 || docker images | grep folio-module-sidecar | grep native >&2
ui_info ""
