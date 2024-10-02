# eureka-platform-bootstrap

Provides docker-based minimal eureka platform

# Table of contents

<!-- TOC -->
* [eureka-platform-bootstrap](#eureka-platform-bootstrap)
* [Table of contents](#table-of-contents)
* [Run applications in docker](#run-applications-in-docker)
  * [Script environment variables](#script-environment-variables)
    * [Module versions](#module-versions)
  * [Hosts file configuration](#hosts-file-configuration)
  * [Additional images build](#additional-images-build)
    * [[Temporary step] Keycloak image build](#temporary-step-keycloak-image-build)
      * [Download of folio-keycloak repository](#download-of-folio-keycloak-repository)
      * [Install and build docker image](#install-and-build-docker-image)
    * [[Temporary step] Kong image build](#temporary-step-kong-image-build)
      * [Download of folio-kong repository](#download-of-folio-kong-repository)
      * [Install and build docker image](#install-and-build-docker-image-1)
  * [Generate local credentials and configuration](#generate-local-credentials-and-configuration)
  * [Update module versions](#update-module-versions)
  * [Deploying core services](#deploying-core-services)
  * [Deploying mgr-components](#deploying-mgr-components)
  * [app-platform-minimal application registration](#app-platform-minimal-application-registration)
  * [Registration of application descriptor](#registration-of-application-descriptor)
    * [app-platform-minimal discovery information](#app-platform-minimal-discovery-information)
  * [app-platform-minimal deployment](#app-platform-minimal-deployment)
    * [Running containers](#running-containers)
  * [Create a tenant](#create-a-tenant)
    * [Enable (entitle) app-platform-minimal for tenant](#enable-entitle-app-platform-minimal-for-tenant)
  * [Creating a user](#creating-a-user)
    * [Generate a module-to-module client secret](#generate-a-module-to-module-client-secret)
      * [Vault service client secret retrieval](#vault-service-client-secret-retrieval)
      * [Keycloak service client retrieval](#keycloak-service-client-retrieval)
      * [Generating service access token](#generating-service-access-token)
    * [Create a user: folio](#create-a-user-folio)
    * [Create folio user credentials](#create-folio-user-credentials)
    * [Login folio user](#login-folio-user)
* [Additional images](#additional-images)
  * [folio-module-sidecar](#folio-module-sidecar)
* [Miscellaneous scripts](#miscellaneous-scripts)
  * [module-updater](#module-updater)
  * [Verified versions](#verified-versions)
      * [Docker version](#docker-version)
      * [Docker-compose CLI version](#docker-compose-cli-version)
      * [Python](#python)
<!-- TOC -->

# Run applications in docker

Required tools:

- Docker
- Python v3.10+ and pip
- Java 17
- Maven

## Script environment variables

This variables can be overwritten in `.env.local.credentials`

| Variable                               | Default value                 | Description                                                                                    |
|----------------------------------------|-------------------------------|------------------------------------------------------------------------------------------------|
| POSTGRES_PASSWORD                      | postgres_admin                | Postgres Database password                                                                     |
| KC_DB_PASSWORD                         | keycloak_admin                | Keycloak database password                                                                     |
| KONG_DB_PASSWORD                       | kong_admin                    | Kong database password                                                                         |
| OKAPI_DB_PASSWORD                      | okapi_admin                   | Okapi database password (all modules will use this database to create tenant specific schemas) |
| MGR_APPLICATIONS_DB_PASSWORD           | mgr_applications_admin        | mgr-applications database password                                                             |
| MGR_TENANTS_DB_PASSWORD                | mgr_tenants_admin             | mgr-tenants database password                                                                  |
| MGR_TENANT_ENTITLEMENTS_DB_PASSWORD    | mgr_tenant_entitlements_admin | mgr-tenant-entitlements database password                                                      |
| KC_ADMIN_PASSWORD                      | keycloak_system_admin         | Keycloak admin password                                                                        |
| KC_ADMIN_CLIENT_SECRET                 | be-admin-client-secret        | Keycloak admin client secret                                                                   |

> **_NOTE:_**  _It is recommended to generate your own set of credentials for a new deployment instead of using default
> values, see how to generate [deployment credentials](#generate-local-credentials-and-configuration)._

This variables can be overwritten in `.env.local`:

### Module versions
| Variable                           | Default value                   | Description                                                                                  |
|------------------------------------|---------------------------------|----------------------------------------------------------------------------------------------|
| KC_LOGIN_CLIENT_SUFFIX             | -login-app                      | a suffix for a tenant client that will perform all authentication and authorization requests |
| KC_SERVICE_CLIENT_ID               | m2m-client                      | Name of service client (participated in module-to-module requests)                           |
| KC_ADMIN_CLIENT_ID                 | be-admin-client                 | Keycloak admin client id                                                                     |
| MGR_TENANTS_VERSION                | latest                          | Docker image version for `mgr-tenants`                                                       |
| MGR_TENANTS_VERSION                | latest                          | Docker image version for `mgr-tenants`                                                       |
| MGR_TENANTS_REPOSITORY             | folioci/mgr-tenants             | Docker repository for `mgr-tenants`                                                          |
| MGR_APPLICATIONS_VERSION           | latest                          | Docker image version for `mgr-applications`                                                  |
| MGR_APPLICATIONS_REPOSITORY        | folioci/mgr-applications        | Docker repository for `mgr-applications`                                                     |
| MGR_TENANT_ENTITLEMENTS_VERSION    | latest                          | Docker image version for `mgr-tenant-entitlements`                                           |
| MGR_TENANT_ENTITLEMENTS_REPOSITORY | folioci/mgr-tenant-entitlements | Docker repository for `mgr-tenant-entitlements`                                              |
| FOLIO_MODULE_SIDECAR_VERSION       | latest                          | Docker image version for `folio-module-sidecar`                                              |
| FOLIO_MODULE_SIDECAR_REPOSITORY    | folioci/folio-module-sidecar    | Docker repository for `folio-module-sidecar`                                                 |

> **_NOTE:_** _Folio module versions are populated with the following script (based on application descriptor):_
> ```shell
> python ./misc/docker-module-updater/run.py
> ```

## Hosts file configuration

Keycloak and kafka uses specific settings in this deployment that prevents them accessing locally. To make it possible,
`hosts` file must be updated with following lines:

```text
127.0.0.1     keycloak
127.0.0.1     kafka
```

## Additional images build

Additional images are required to built before running `eureka-platform-bootstrap` in docker.

This command will build custom vault image, with autoconfiguration for initial credentials:

```shell
sh ./misc/build-images.sh
```

### [Temporary step] Keycloak image build

Public Folio docker [repository](https://hub.docker.com/u/folioorg) does not contain image for the `folio-keycloak`,
so it must be built manually

#### Download of folio-keycloak repository

> **_NOTE:_** _This step is optional and if you already have this project - skip it_

```shell
git clone git@github.com:folio-org/folio-keycloak.git /path/to/your/folio/projects
```

#### Install and build docker image

This step must be executed in folio-keycloak directory

```shell
docker build -t folio-keycloak:25.0.1 .
```

### [Temporary step] Kong image build

Public Folio docker [repository](https://hub.docker.com/u/folioorg) does not contain image for the `folio-kong`,
so it must be built manually

#### Download of folio-kong repository

> **_NOTE:_** _This step is optional and if you already have this project - skip it_

```shell
git clone git@github.com:folio-org/folio-kong.git /path/to/your/folio/projects
```

#### Install and build docker image

This step must be executed in folio-kong directory

```shell
docker build -t folio-kong:3.7.1-ubuntu .
```

Before all the steps, make sure that you are in the `docker` directory:

```shell
cd docker
```

## Generate local credentials and configuration

To set local credentials and configuration a following script must be executed:

```shell
sh ./set-local-credentials.sh
```

> **_NOTE:_** _This step is optional, however it will provide more secure deployment for local development_
> In addition, once credentials is set and core profile is running - changing them will break deployment, and the
> workaround is to manually update them in `.env.local.crendentials` and in corresponding container or to start
> deployment from scratch by removing docker volumes (before executing a script - deployment must be stopped with
> ```./stop-docker-containers.sh```):
> ```shell
> docker volume rm -f folio-platform-minimal_db folio-platform-minimal_kafka-data folio-platform-minimal_vault-data
> ```

## Update module versions

> **_NOTE:_** _This step is optional, execute the following command only if you have modified app-platform-miniaml
module
> descriptor_

```shell
python ../misc/docker-module-updater/run.py
```

## Deploying core services

Executing the following command will run containers for core infrastructure for Eureka deployment:

- Database (PosgreSQL with configured databases and credentials)
- api-gateway: Kong
- Keycloak (cluster deployment 1 node + load balancer (nginx))
- Apache Kafka + Kafka UI

```shell
./start-docker-containers.sh -p core
```

_Checklist before going to the next step:_

1. _Database must be available with configured admin client (credentials: `postgres:{{POSTGRES_PASSWORD}}`):_
   ```
   jdbc:postgresql://localhost:5432/postgres
   ```

2. _Check Keycloak admin dashboard (credentials: `admin:{{KC_ADMIN_PASSWORD}}`):_
   ```
   http://localhost:8080
   ```
   > **_NOTE:_**  _If keycloak is not available (502 Bad Gateway), try to execute:\
   > `./dc.sh restart keycloak`_

3. _Check Kong Manager Dashboard:_
   ```
   http://localhost:8002
   ```
   > **_NOTE:_** _If kong is not available, removing it by ```./dc.sh down api-gateway``` and then enabling it again
   > with ```./dc.sh up --data api-gateway``` should resolve this issue_

4. _Check Kafka UI:_
   ```
   http://localhost:9080
   ```
5. _Check Vault:_
  ```
  http://localhost:8200/
  ```
  _Unseal token can be retrieved with script:_
  ```
  sh ./misc/get-vault-token.sh
  ```

## Deploying mgr-components

Before initializing `mgr-components`, Vault access must be provided via env variable - `SECRET_STORE_VAULT_TOKEN`. The
following script will populate it in `.env.local`:

```
sh ./misc/populate-vault-token.sh
```

> **_NOTE:_** _All local configuration lives in `.env.local` file, in the `docker/` directory, if you want to customize
> deployment - use this file, it is excluded from git, so pulling latest changes from master or other branches will be
> simple._

> **_NOTE:_** _mgr-components versions can be re-configured with following env variables in `.env.local`:_
> ```
> export MGR_TENANTS_VERSION={{newVersion}}
> export MGR_TENANTS_REPOSITORY={{newRepositoryName}}
> export MGR_APPLICATIONS_VERSION={{newVersion}}
> export MGR_APPLICATIONS_REPOSITORY={{newRepositoryName}}
> export MGR_TENANT_ENTITLEMENTS_VERSION={{newVersion}}
> export MGR_TENANT_ENTITLEMENTS_REPOSITORY={{newRepositoryName}}
> ```
> _`eureka-platform-bootstrap` uses the latest tag from folioci docker public registry, to update and pull the latest
> tags `sh ./docker/dc.sh pull` can be used._

Executing this command will run containers for:

- mgr-tenants (tenant management)
- mgr-applications (application management + discovery management)
- mgr-tenant-entitlements (tenant application management)

```shell
./start-docker-containers.sh -p mgr-components
```

Adding a new application to `mgr-applications` will require following steps:

* To expose your pre-defined variables to current terminal
  ```shell
  source .env.local
  ```

* Get system access token:\
  _This token is used to communicate with mgr-components_
  ```shell
  export KC_ADMIN_CLIENT_ID={{value from .env.local, if not defined - from .env}}
  export KC_ADMIN_CLIENT_SECRET={value from .env.local.credentials, if not defined - from .env}
  ```
  ```shell
  systemAccessToken=$(curl -X POST --silent \
    --header "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "client_id=${KC_ADMIN_CLIENT_ID}" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_secret=${KC_ADMIN_CLIENT_SECRET}" \
    "http://keycloak:8080/realms/master/protocol/openid-connect/token" \
    | jq -r ".access_token")
  ```
  > **_NOTE:_** _Access token lifespan can be increased in Keycloak to 30 minutes:_
  > - Login to keycloak
  > - Select master realm
  > - Then go to Realm Settings -> Tokens -> Access Tokens
  > - Increase the value of `Access Token Lifespan`

  The following command will print access token value (Optional):
  ```shell
  echo "$systemAccessToken"
  ```

* Verify that mgr-components are available (Optional)
  ```shell
  curl -X GET --silent \
    --header "Content-Type: application/json" \
    --header "x-okapi-token: ${systemAccessToken}" \
    "http://localhost:8000/tenants" | jq
  ```

  ```shell
  curl -X GET --silent \
    --header "Content-Type: application/json" \
    --header "x-okapi-token: ${systemAccessToken}" \
    "http://localhost:8000/applications" | jq
  ```

  ```shell
  curl -X GET --silent \
    --header "Content-Type: application/json" \
    --header "x-okapi-token: ${systemAccessToken}" \
    "http://localhost:8000/entitlements" | jq
  ```

  > **_NOTE:_** _Responses must be `200 OK`, if not - check the container logs to find the issue_

## app-platform-minimal application registration

`app-platform-minimal` contains basic functionality for Eureka platform:

* User and AuthUsers management (`mod-users-keycloak` + `mod-users` + `mod-users-bl`)
* Authentication and authorization (`keycloak` + `mod-login-keycloak` + sidecars)
* Capability/Role/Policy management (`mod-roles-keycloak`)
* Scheduled timers support (`mod-scheduler`)
* Notes (`mod-notes`)
* Tenant settings management (`mod-settings`)

When the previous step is finished, `mgr-applications` is ready to accept applications, and sidecars will require
pre-defined application to load bootstrap information.

## Registration of application descriptor

This command adds app-platform-minimal to `mgr-applications`:

```shell
curl -X POST --silent \
  --header "Content-Type: application/json" \
  --header "x-okapi-token: ${systemAccessToken}" \
  --data "@../descriptors/app-platform-minimal/descriptor.json" \
  "http://localhost:8000/applications" | jq
```

> **_NOTE:_** Created application can be retrieved using the following command:
>
> ```shell
> curl -X GET --silent \
>   --header "Content-Type: application/json" \
>   --header "x-okapi-token: ${systemAccessToken}" \
>   "http://localhost:8000/applications/app-platform-minimal-0.0.17-SNAPSHOT.2?full=true" | jq
> ```

### app-platform-minimal discovery information

This command will provide discovery information for all modules in `app-platform-minimal`:

```shell
curl -X POST --silent \
  --header "Content-Type: application/json" \
  --header "x-okapi-token: ${systemAccessToken}" \
  --data "@../descriptors/app-platform-minimal/discovery.json" \
  "http://localhost:8000/modules/discovery" | jq
```

> **_NOTE:_** Created application discovery data can be retrieved using the following command:
>
>
> (Optional) Stored application discovery information
> ```shell
> curl -X GET --silent \
>   --header "Content-Type: application/json" \
>   --header "x-okapi-token: ${systemAccessToken}" \
>   "http://localhost:8000/applications/app-platform-minimal-0.0.17-SNAPSHOT.2/discovery?limit=100" | jq
> ```

## app-platform-minimal deployment

> **_NOTE:_** _it's also possible to run native image build by following the instruction in `folio-module-sidecar`
project, image values can be customized in `.env.local`_:
> ```shell
> export FOLIO_MODULE_SIDECAR_VERSION={{folio-module-sidecar-version}}
> export FOLIO_MODULE_SIDECAR_REPOSITORY={{folio-module-sidecar-repostitory}}
> ```

### Running containers

The following command will run containers that belongs to `app-platform-minimal`:

```shell
./start-docker-containers.sh -p app-platform-minimal
```

> **_NOTE:_** _Verify manually that all containers started without any errors by checking logs of each container and
> sidecars (`mod-` and `sc-` prefixes in search)_

## Create a tenant

The following command will create and save tenant id as variable:

```shell
curl -X POST --silent \
  --header "Content-Type: application/json" \
  --header "x-okapi-token: ${systemAccessToken}" \
  --data '{"name": "test", "description": "Test Tenant"}' \
  "http://localhost:8000/tenants" | jq
```

Command to get test tenant id:

```shell
testTenantId=$(curl -X GET --silent \
  --header "Content-Type: application/json" \
  --header "x-okapi-token: ${systemAccessToken}" \
  "http://localhost:8000/tenants?query=name==test" | jq -r ".tenants[0].id")
```

This command should print tenant identifier

```shell
echo "${testTenantId}"
```

### Enable (entitle) app-platform-minimal for tenant

The following command will install `app-platform-minimal` for prepared `test` tenant:

```shell
curl -X POST --silent \
  --header "Content-Type: application/json" \
  --header "x-okapi-token: ${systemAccessToken}" \
  --data '{"tenantId": "'"${testTenantId}"'", "applications": [ "app-platform-minimal-0.0.17-SNAPSHOT.2" ] }' \
  "http://localhost:8000/entitlements?ignoreErrors=true" | jq
```

Await for successful result, entitlements for tenant can be checked with command

```shell
curl -X GET --silent \
  --header "Content-Type: application/json" \
  --header "x-okapi-token: ${systemAccessToken}" \
  "http://localhost:8000/entitlements?query=tenantId=${testTenantId}" | jq
```

## Creating a user

### Generate a module-to-module client secret

This JWT token provides admin access to folio system (all permissions included)


> **_NOTE:_** _By default name of client is: ```sidecar-module-access-client```, but it can be redefined by
variable: ```KC_SERVICE_CLIENT_ID```_

`{{KC_SERVICE_CLIENT_SECRET}}` can be obtained from Vault or from Keycloak.

#### Vault service client secret retrieval

To retrieve service client secret from vault

- Open Vault at ```http://localhost:8200/ui/vault/secrets```
- Open following folder in sequence: `secret/` -> `folio/` -> `test/`
- Copy data from `${KC_SERVICE_CLIENT_ID}` field (`m2m-client` by default)

#### Keycloak service client retrieval

To retrieve service token from Keycloak:

- Login to keycloak
- Select `test` realm
- Then go to Clients -> `${KC_SERVICE_CLIENT_ID}` Client (`m2m-client` by default) -> Credentials
- Copy value from `Client Secret` field

#### Generating service access token

export environment variables:

```shell
export KC_SERVICE_CLIENT_ID={{value from .env.local, if not defined - from .env}}
export KC_SERVICE_CLIENT_SECRET={{value from previous step}}
```

```shell
accessToken=$(curl -X POST --silent \
  --header "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "client_id=${KC_SERVICE_CLIENT_ID}" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_secret=${KC_SERVICE_CLIENT_SECRET}" \
  "http://keycloak:8080/realms/test/protocol/openid-connect/token" \
  | jq -r ".access_token")
```

### Create a user: folio

```shell
curl -X POST --silent \
--header 'x-okapi-tenant: test' \
--header 'Content-Type: application/json' \
--header "x-okapi-token: ${accessToken}" \
--data-raw '{
    "active": true,
    "departments": [],
    "proxyFor": [],
    "type": "patron",
    "username": "folio",
    "personal": {
      "lastName": "Test",
      "firstName": "Test",
      "email": "test_user@example.com",
      "addresses": []
    }
  }' \
  'http://localhost:8000/users-keycloak/users' | jq
```

### Create folio user credentials

```shell
curl -X POST --silent  \
  --header 'x-okapi-tenant: test' \
  --header 'Content-Type: application/json' \
  --header "x-okapi-token: ${accessToken}" \
  --data '{ "username": "folio", "password": "folio" }' \
  'http://localhost:8000/authn/credentials' | jq
```

### Login folio user

```shell
curl -X POST --silent  \
  --header 'x-okapi-tenant: test' \
  --header 'Content-Type: application/json' \
  --data '{ "username": "folio", "password": "folio" }' \
  'http://localhost:8000/authn/login' | jq
```

# Additional images

Additional images are build with the following command:

```shell
sh ./misc/build-images.sh
```

This image provides HashiCorp Vault container (with some automation) to store secret for Folio platform

## folio-module-sidecar

# Miscellaneous scripts

## module-updater

Updates docker deployment and discovery information versions according
to the [Application Descriptor](descriptors/app-platform-minimal/descriptor.json)

```shell
python ./misc/docker-module-updater/run.py
```

## Verified versions

#### Docker version

```shell
> docker version

Client: Docker Engine - Community
 Version:           27.1.1

Server: Docker Engine - Community
 Engine:
  Version:          27.1.1
  API version:      1.46 (minimum version 1.24)
```

#### Docker-compose CLI version

```shell
> docker compose version
Docker Compose version v2.29.1
```

#### Python

```shell
> python --version
Python 3.10.12
```
