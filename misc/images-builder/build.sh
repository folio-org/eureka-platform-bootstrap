#!/bin/bash

REPO_URL="https://github.com/folio-org/folio-tools.git"
CLONE_DIR="folio-tools"
DOCKERFILE_PATH="Dockerfile"
NEW_LINE="FROM eclipse-temurin:21-jre-alpine"
IMAGE_NAME_openjdk17="folioci/alpine-jre-openjdk17:latest"
IMAGE_NAME_openjdk21="folioci/alpine-jre-openjdk21:latest"
DESCRIPTOR_FILE="descriptors/app-platform-minimal/descriptor.json"
BASE_URL="https://github.com/folio-org"
FAILED_MODULES=()

# Check for required commands
for cmd in jq docker mvn; do
    if ! command -v $cmd &> /dev/null; then
        echo "$cmd is not installed. Please install $cmd to run this script."
        exit 1
    fi
done

# Clone and modify Dockerfile
git clone $REPO_URL
cd folio-tools/folio-java-docker/openjdk17

# Portable sed command that works on both macOS and Ubuntu
sed "1s|.*|$NEW_LINE|" "$DOCKERFILE_PATH" > "${DOCKERFILE_PATH}.tmp" && mv "${DOCKERFILE_PATH}.tmp" "$DOCKERFILE_PATH"

docker build --no-cache -t $IMAGE_NAME_openjdk17 .
docker build --no-cache -t $IMAGE_NAME_openjdk21 .

cd ../../..
rm -rf $CLONE_DIR

# Check for descriptor file
if [ ! -f "$DESCRIPTOR_FILE" ]; then
    echo "File $DESCRIPTOR_FILE not found!"
    exit 1
fi

modules=$(jq -c '.modules[]' "$DESCRIPTOR_FILE")

# Function to build a module
build_module() {
    local name=$1
    local version=$2
    local skip_maven=$3

    echo "Building $name:$version"
    git clone --quiet "$BASE_URL/$name.git"
    if [ $? -ne 0 ]; then
        echo "Failed to clone repository $name"
        FAILED_MODULES+=("$name")
        return
    fi

    cd "$name" || exit

    if [[ "$version" == *"SNAPSHOT"* ]] || [[ "$version" == "latest" ]]; then
        git checkout master --quiet
    else
        git checkout "v$version" --quiet
    fi

    if [ "$skip_maven" != "true" ]; then
        mvn clean install -q -DskipTests
        if [ $? -ne 0 ]; then
            echo "Maven build failed for $name"
            FAILED_MODULES+=("$name")
            cd ..
            rm -rf "$name"
            return
        fi
    fi

    if [[ "$version" == *"SNAPSHOT"* ]] || [[ "$version" == "latest" ]]; then
        docker build --no-cache -t "folioci/$name:$version" .
    else
        docker build --no-cache -t "folioorg/$name:$version" .
    fi
    if [ $? -ne 0 ]; then
        echo "Docker build failed for $name"
        FAILED_MODULES+=("$name")
        cd ..
        rm -rf "$name"
        return
    fi

    cd ..
    rm -rf "$name"
}

# Process modules from descriptor.json
for module in $modules; do
    name=$(echo "$module" | jq -r '.name')
    version=$(echo "$module" | jq -r '.version')
    build_module "$name" "$version" "false"
done

# Additional repositories to build from master branch
additional_repos=(
    "mgr-tenants"
    "mgr-tenant-entitlements"
    "mgr-applications"
    "folio-module-sidecar"
)

for repo in "${additional_repos[@]}"; do
    build_module "$repo" "latest" "false"
done

# Repositories to build without Maven
repos_without_maven=(
    "folio-kong"
    "folio-keycloak"
)

for repo in "${repos_without_maven[@]}"; do
    build_module "$repo" "latest" "true"
done

echo "Script completed."

if [ ${#FAILED_MODULES[@]} -ne 0 ]; then
    echo "The following modules failed to build:"
    for module in "${FAILED_MODULES[@]}"; do
        echo "- $module"
    done
else
    echo "All modules built successfully."
fi
