begin;
select plan(4);

select ok(exists(select 1 from pg_publication_tables where pubname='powersync' and tablename='trip_creation_quotas'), 'quota snapshot is published');
select ok(exists(select 1 from pg_publication_tables where pubname='powersync' and tablename='iap_entitlements'), 'verified entitlement snapshot is published');
select ok(exists(select 1 from pg_trigger where tgname='profiles_initialize_trip_creation_quota' and not tgisinternal), 'new profiles initialize zero quota');
select ok(exists(select 1 from pg_class where relname='trip_creation_events'), 'durable trip creation ledger exists');

select * from finish();
rollback;
