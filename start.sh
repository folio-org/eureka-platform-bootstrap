#!/usr/bin/env bash

set -o pipefail
set -e

# Function to check if a command exists
command_exists () {
    command -v "$1" >/dev/null 2>&1
}

# Check for required tools
echo "Checking installed tools..."

REQUIRED_COMMANDS=("docker" "docker-compose" "python3" "java" "mvn" "jq" "curl")

for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command_exists "$cmd"; then
        echo "Error: Command '$cmd' not found. Please install it before proceeding."
        exit 1
    fi
done

echo "All required tools are installed."

# Check tool versions
echo "Checking tool versions..."

# Docker
DOCKER_VERSION=$(docker --version | awk '{print $3}' | sed 's/,//')
echo "Docker version: $DOCKER_VERSION"

# Docker Compose
DOCKER_COMPOSE_VERSION=$(docker compose version --short)
echo "Docker Compose version: $DOCKER_COMPOSE_VERSION"

# Python
PYTHON_VERSION=$(python3 --version | awk '{print $2}')
echo "Python version: $PYTHON_VERSION"

# Java
JAVA_VERSION=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}')
echo "Java version: $JAVA_VERSION"

# Maven
MAVEN_VERSION=$(mvn -version | head -n 1 | awk '{print $3}')
echo "Maven version: $MAVEN_VERSION"

# Check minimum versions
REQUIRED_PYTHON="3.10"
REQUIRED_JAVA="17"

# Function to compare versions
version_ge() {
    # Returns 0 if $1 >= $2
    # Returns 1 otherwise
    [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

if ! version_ge "$PYTHON_VERSION" "$REQUIRED_PYTHON"; then
    echo "Error: Python version $REQUIRED_PYTHON or higher is required."
    exit 1
fi

if [[ "${JAVA_VERSION%%.*}" -lt "$REQUIRED_JAVA" ]]; then
    echo "Error: Java version $REQUIRED_JAVA or higher is required."
    exit 1
fi

echo "Tool versions meet the requirements."

# Change to docker directory
echo "Changing to the docker directory..."
cd docker || { echo "Error: 'docker' directory not found."; exit 1; }

# Setup environment variables
echo "Setting up environment variables..."

# Create .env.local.credentials if it doesn't exist
if [ ! -f .env.local.credentials ]; then
    echo "Creating .env.local.credentials file with default variables..."
    cat <<EOL > .env.local.credentials
POSTGRES_PASSWORD=postgres_admin
KC_DB_PASSWORD=keycloak_admin
KONG_DB_PASSWORD=kong_admin
OKAPI_DB_PASSWORD=okapi_admin
MGR_APPLICATIONS_DB_PASSWORD=mgr_applications_admin
MGR_TENANTS_DB_PASSWORD=mgr_tenants_admin
MGR_TENANT_ENTITLEMENTS_DB_PASSWORD=mgr_tenant_entitlements_admin
KC_ADMIN_PASSWORD=admin
KC_ADMIN_CLIENT_SECRET=be-admin-client-secret
EOL
else
    echo ".env.local.credentials file already exists. Skipping creation."
fi

# Create .env.local if it doesn't exist
if [ ! -f .env.local ]; then
    echo "Creating .env.local file with default variables..."
    cat <<EOL > .env.local
KC_LOGIN_CLIENT_SUFFIX=-login-app
KC_SERVICE_CLIENT_ID=m2m-client
KC_ADMIN_CLIENT_ID=be-admin-client
MGR_TENANTS_VERSION=latest
MGR_TENANTS_REPOSITORY=folioci/mgr-tenants
MGR_APPLICATIONS_VERSION=latest
MGR_APPLICATIONS_REPOSITORY=folioci/mgr-applications
MGR_TENANT_ENTITLEMENTS_VERSION=latest
MGR_TENANT_ENTITLEMENTS_REPOSITORY=folioci/mgr-tenant-entitlements
FOLIO_MODULE_SIDECAR_VERSION=latest
FOLIO_MODULE_SIDECAR_REPOSITORY=folioci/folio-module-sidecar
EOL
else
    echo ".env.local file already exists. Skipping creation."
fi

# Export variables from files
export $(grep -v '^#' .env.local.credentials | xargs)
export $(grep -v '^#' .env.local | xargs)

echo "Environment variables are set."

# Update /etc/hosts file
echo "Updating /etc/hosts file..."

HOST_ENTRIES=("127.0.0.1 keycloak" "127.0.0.1 kafka")

for entry in "${HOST_ENTRIES[@]}"; do
    if ! grep -q "$entry" /etc/hosts; then
        echo "Adding '$entry' to /etc/hosts..."
        echo "$entry" | sudo tee -a /etc/hosts
    else
        echo "Entry '$entry' already exists in /etc/hosts. Skipping."
    fi
done

echo "/etc/hosts file updated."

# Build additional Docker images
echo "Building additional Docker images..."
bash ../misc/build-images.sh
echo "Additional Docker images built."

# Generate local credentials and configuration
echo "Generating local credentials and configuration..."
bash ./set-default-local-credentials.sh
echo "Local credentials and configuration generated."

# Update module version in application descriptor
read -p "Actualize module versions in application descriptor? (y/n): " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    python3 ../misc/module-version-actualizer.py
  fi

# Update module versions
echo "Updating module versions..."
python3 ../misc/docker-module-updater/run.py
echo "Module versions updated."

# Check architecture
arch=$(uname -m)
if [[ "$arch" == "arm64" || "$arch" == "aarch64" ]]; then
  read -p "ARM detected. Build ARM-compatible Docker images locally? (y/n): " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    cd ..
    bash misc/images-builder/build.sh
    cd docker
  else
    echo "Skipping building ARM-compatible Docker images."
  fi
fi

wait_for_healthy() {
  echo "⏳ Waiting for all containers with healthcheck to become healthy..."

  spin='-\|/'
  i=0

  while true; do
    unhealthy=$(docker ps -q | xargs -r docker inspect --format '{{.State.Health.Status}}' 2>/dev/null | grep -Ev 'healthy$|<no value>' || true)

    if [ -z "$unhealthy" ]; then
      printf "\r✅ All containers with healthcheck are healthy          \n"
      break
    fi

    spin_char="${spin:i++%${#spin}:1}"
    printf "\r[%c] Waiting for containers to become healthy..." "$spin_char"

    sleep 0.2
  done

  echo -n "⏳ Waiting for routes and DNS to be ready "
  countdown=5
  j=0
  while [ $countdown -gt 0 ]; do
    spin_char="${spin:j++%${#spin}:1}"
    printf "\r[%c] Waiting for routes and DNS to be ready... [%d]" "$spin_char" "$countdown"
    sleep 1
    countdown=$((countdown - 1))
  done

  echo -e "\r✅ Routes and DNS should be ready now                \n"
}

# Deploy core services
echo "Deploying core services..."
./start-docker-containers.sh -p core

wait_for_healthy

# Deploy mgr-components
echo "Deploying mgr-components..."

# Populate Vault token
sh ./misc/populate-vault-token.sh

./start-docker-containers.sh -p mgr-components

wait_for_healthy

echo "mgr-components deployed."

echo "Obtaining system access token..."

export KC_ADMIN_CLIENT_ID=be-admin-client
export KC_ADMIN_CLIENT_SECRET=be-admin-client-secret

systemAccessToken=$(curl -X POST --silent --fail \
    --header "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "client_id=${KC_ADMIN_CLIENT_ID}" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_secret=${KC_ADMIN_CLIENT_SECRET}" \
    "http://keycloak:8080/realms/master/protocol/openid-connect/token" | jq -r ".access_token")

if [ -z "$systemAccessToken" ] || [ "$systemAccessToken" == "null" ]; then
    echo "Error: Failed to obtain system access token."
    exit 1
fi

echo "System access token obtained."

# Register application descriptor
echo "Registering application descriptor for app-platform-minimal..."

response=$(curl -sS -w "\n%{http_code}" -X POST \
  --header "Content-Type: application/json" \
  --header "x-okapi-token: ${systemAccessToken}" \
  --data "@../descriptors/app-platform-minimal/descriptor.json" \
  "http://localhost:8000/applications")

body=$(echo "$response" | sed '$d')
code=$(echo "$response" | tail -n1)

if [ "$code" -eq 409 ]; then
  echo "$body" | jq
  echo "Skipping this error."
elif [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; then
  echo "$body" | jq
else
  echo "Request failed with HTTP code $code:"
  echo "$body" | jq
  exit 1
fi

# Register discovery information
echo "Registering discovery information for app-platform-minimal..."

response=$(curl -s -w "\n%{http_code}" -X POST \
  --header "Content-Type: application/json" \
  --header "x-okapi-token: ${systemAccessToken}" \
  --data "@../descriptors/app-platform-minimal/discovery.json" \
  "http://localhost:8000/modules/discovery")

body=$(echo "$response" | sed '$d')
code=$(echo "$response" | tail -n1)

if [ "$code" -eq 409 ]; then
  echo "$body" | jq
  echo "Skipping this error."
elif [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; then
  echo "$body" | jq
else
  echo "Request failed with HTTP code $code:"
  echo "$body" | jq
  exit 1
fi

echo "Application descriptor and discovery information registered."

# Deploy app-platform-minimal
echo "Deploying app-platform-minimal application..."
./start-docker-containers.sh -p app-platform-minimal

wait_for_healthy

echo ""

echo "app-platform-minimal application deployed."

systemAccessToken=$(curl -X POST -s \
    --header "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "client_id=${KC_ADMIN_CLIENT_ID}" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_secret=${KC_ADMIN_CLIENT_SECRET}" \
    "http://keycloak:8080/realms/master/protocol/openid-connect/token" | jq -r ".access_token")

if [ -z "$systemAccessToken" ] || [ "$systemAccessToken" == "null" ]; then
    echo "Error: Failed to obtain system access token."
    exit 1
fi

# Create tenant
echo "Creating tenant 'test'..."

response=$(curl -s -w "\n%{http_code}" -X POST \
  --header "Content-Type: application/json" \
  --header "x-okapi-token: ${systemAccessToken}" \
  --data '{"name": "test", "description": "Test Tenant"}' \
  "http://localhost:8000/tenants")

body=$(echo "$response" | sed '$d')
code=$(echo "$response" | tail -n1)

if [ "$code" -ge 400 ] && [ "$code" -lt 500 ]; then
  echo "$body" | jq
  echo "Skipping this error."
elif [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; then
  echo "Tenant 'test' created:"
  echo "$body" | jq
else
  echo "Tenant creation failed with HTTP code $code:"
  echo "$body" | jq
  exit 1
fi

# Get tenant ID
testTenantId=$(curl -X GET -s \
  --header "Content-Type: application/json" \
  --header "x-okapi-token: ${systemAccessToken}" \
  "http://localhost:8000/tenants?query=name==test" | jq -r ".tenants[0].id")

if [ -z "$testTenantId" ] || [ "$testTenantId" == "null" ]; then
    echo "Error: Failed to obtain ID for tenant 'test'."
    exit 1
fi

echo "Tenant 'test' ID: $testTenantId"

systemAccessToken=$(curl -X POST -s \
    --header "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "client_id=${KC_ADMIN_CLIENT_ID}" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_secret=${KC_ADMIN_CLIENT_SECRET}" \
    "http://keycloak:8080/realms/master/protocol/openid-connect/token" | jq -r ".access_token")

if [ -z "$systemAccessToken" ] || [ "$systemAccessToken" == "null" ]; then
    echo "Error: Failed to obtain system access token."
    exit 1
fi

echo "Enabling (entitling) app-platform-minimal for tenant 'test'..."

response=$(curl -s -w "\n%{http_code}" -X POST \
  --header "Content-Type: application/json" \
  --header "x-okapi-token: ${systemAccessToken}" \
  --data '{"tenantId": "'"${testTenantId}"'", "applications": [ "'"$(jq -r '.id' ../descriptors/app-platform-minimal/descriptor.json)"'" ] }' \
  "http://localhost:8000/entitlements?ignoreErrors=true")

body=$(echo "$response" | sed '$d')
code=$(echo "$response" | tail -n1)

if [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; then
  echo "Application enabled for tenant."
  echo "$body" | jq
elif [ "$code" -eq 400 ]; then
  echo "$body" | jq
  echo "Skipping this error."
else
  echo "Failed to enable application (HTTP $code):"
  echo "$body" | jq
  exit 1
fi

echo "Deployment completed successfully!"
