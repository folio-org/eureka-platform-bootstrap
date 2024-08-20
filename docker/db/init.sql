ALTER SYSTEM SET max_connections = 500;

create database okapi;
\set okapi_db_password `echo $OKAPI_DB_PASSWORD`
create user okapi_rw with password :'okapi_db_password';
alter user okapi_rw with superuser;

create database mgr_applications;
\set mgr_applications_db_password `echo $MGR_APPLICATIONS_DB_PASSWORD`
create user mgr_applications_rw with password :'mgr_applications_db_password';
alter database mgr_applications owner to mgr_applications_rw;
grant connect on database mgr_applications to mgr_applications_rw;
grant all privileges on database mgr_applications to mgr_applications_rw;
\c mgr_applications
grant all privileges on schema public to mgr_applications_rw;
alter schema public owner to mgr_applications_rw;
\c postgres

create database mgr_tenants;
\set mgr_tenants_db_password `echo $MGR_TENANTS_DB_PASSWORD`
create user mgr_tenants_rw with password :'mgr_tenants_db_password';
alter database mgr_tenants owner to mgr_tenants_rw;
grant connect on database mgr_tenants to mgr_tenants_rw;
grant all privileges on database mgr_tenants to mgr_tenants_rw;
\c mgr_tenants
grant all privileges on schema public to mgr_tenants_rw;
alter schema public owner to mgr_tenants_rw;
\c postgres

create database mgr_tenant_entitlements;
\set mgr_tenant_entitlements_db_password `echo $MGR_TENANT_ENTITLEMENTS_DB_PASSWORD`
create user mgr_tenant_entitlements_rw with password :'mgr_tenant_entitlements_db_password';
alter database mgr_tenant_entitlements owner to mgr_tenant_entitlements_rw;
grant connect on database mgr_tenant_entitlements to mgr_tenant_entitlements_rw;
grant all privileges on database mgr_tenant_entitlements to mgr_tenant_entitlements_rw;
\c mgr_tenant_entitlements
grant all privileges on schema public to mgr_tenant_entitlements_rw;
alter schema public owner to mgr_tenant_entitlements_rw;
\c postgres

create database keycloak;
\set keycloak_db_password `echo $KC_DB_PASSWORD`
create user keycloak_rw with password :'keycloak_db_password';
alter database keycloak owner to keycloak_rw;
grant connect on database keycloak to keycloak_rw;
grant all privileges on database keycloak to keycloak_rw;
\c keycloak
grant all privileges on schema public to keycloak_rw;
alter schema public owner to keycloak_rw;
\c postgres

create database kong;
\set kong_db_password `echo $KONG_DB_PASSWORD`
create user kong_rw with password :'kong_db_password';
alter database kong owner to keycloak_rw;
grant connect on database kong to kong_rw;
grant all privileges on database kong to kong_rw;
\c kong
grant all privileges on schema public to kong_rw;
alter schema public owner to kong_rw;
\c postgres
