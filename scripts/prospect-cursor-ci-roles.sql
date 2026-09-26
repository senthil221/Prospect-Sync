-- Synthetic equivalents of the cluster roles created by the production
-- bootstrap. This fixture is used only in the disposable CI database; the
-- application migrations remain the source of every tested schema/function.
create role anon nologin noinherit;
create role authenticated nologin noinherit;
create role service_role nologin noinherit bypassrls;
create role authenticator login noinherit connection limit 30;
grant anon, authenticated, service_role to authenticator;

create role prospect_importer nologin noinherit;
create role prospect_import_worker login inherit connection limit 4;
grant prospect_importer to prospect_import_worker;

create role prospect_operator nologin noinherit;
create role prospect_ops_worker login inherit connection limit 2;
grant prospect_operator to prospect_ops_worker;

create role prospect_integrator nologin noinherit;
create role prospect_integration_worker login inherit connection limit 2;
grant prospect_integrator to prospect_integration_worker;
