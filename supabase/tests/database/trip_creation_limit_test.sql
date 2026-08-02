begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(45);

select has_table('public', 'trip_creation_quotas', 'quota table exists');
select has_index('public', 'trips', 'trips_owner_id_idx', 'trip owner queries are indexed');
select has_trigger(
  'public',
  'trips',
  'trips_enforce_creation_limit',
  'trip creation trigger is installed'
);
select has_column('public', 'iap_entitlements', 'bundle_id', 'entitlements record the verified bundle');
select has_column('public', 'iap_entitlements', 'signed_at', 'entitlements record the Apple signing time');
select has_column('public', 'iap_entitlements', 'verified_at', 'entitlements record server verification time');
select has_column('public', 'iap_entitlements', 'verification_source', 'entitlements record the verification source');
select has_function(
  'public',
  'record_verified_iap_entitlement',
  array[
    'uuid', 'text', 'text', 'text', 'text', 'text', 'text',
    'timestamp with time zone', 'timestamp with time zone',
    'timestamp with time zone', 'text', 'text'
  ],
  'verified entitlements are written through the server function'
);

insert into auth.users (id, email)
values
  ('11111111-1111-1111-1111-111111111111', 'free@example.com'),
  ('22222222-2222-2222-2222-222222222222', 'other@example.com'),
  ('33333333-3333-3333-3333-333333333333', 'paid@example.com'),
  ('44444444-4444-4444-4444-444444444444', 'legacy@example.com');

select set_config('request.jwt.claim.sub', '', true);
select throws_ok(
  $$insert into public.trips (owner_id, title, destination)
    values ('11111111-1111-1111-1111-111111111111', 'Anonymous', 'Nowhere')$$,
  '28000',
  'Authentication is required to create a trip.',
  'the security-definer trigger requires auth.uid()'
);

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-1111-1111-111111111111',
  true
);

select lives_ok(
  $$insert into public.trips (owner_id, title, destination)
    values ('11111111-1111-1111-1111-111111111111', 'Free one', 'Berlin')$$,
  'first free creation succeeds'
);
select lives_ok(
  $$insert into public.trips (owner_id, title, destination)
    values ('11111111-1111-1111-1111-111111111111', 'Free two', 'Lisbon')$$,
  'second free creation succeeds'
);
select throws_ok(
  $$insert into public.trips (owner_id, title, destination)
    values ('11111111-1111-1111-1111-111111111111', 'Free three', 'Oslo')$$,
  'MS001',
  'The lifetime free-trip allowance has been used.',
  'third free creation is rejected'
);

reset role;
select is(
  (select lifetime_trip_count from public.trip_creation_quotas
   where user_id = '11111111-1111-1111-1111-111111111111'),
  2::bigint,
  'a rejected insert rolls its quota increment back'
);
select is(
  (select count(*) from public.trips
   where owner_id = '11111111-1111-1111-1111-111111111111'),
  2::bigint,
  'only two free trips were created'
);

update public.trips
set deleted_at = now()
where owner_id = '11111111-1111-1111-1111-111111111111'
  and title = 'Free one';

set local role authenticated;
select throws_ok(
  $$insert into public.trips (owner_id, title, destination)
    values ('11111111-1111-1111-1111-111111111111', 'After soft delete', 'Rome')$$,
  'MS001',
  'The lifetime free-trip allowance has been used.',
  'soft deletion does not restore quota'
);
reset role;
select is(
  (select lifetime_trip_count from public.trip_creation_quotas
   where user_id = '11111111-1111-1111-1111-111111111111'),
  2::bigint,
  'soft-delete rejection also rolls its increment back'
);

delete from public.trips
where owner_id = '11111111-1111-1111-1111-111111111111'
  and title = 'Free one';

set local role authenticated;
select throws_ok(
  $$insert into public.trips (owner_id, title, destination)
    values ('11111111-1111-1111-1111-111111111111', 'After hard delete', 'Tokyo')$$,
  'MS001',
  'The lifetime free-trip allowance has been used.',
  'hard deletion does not restore quota'
);
reset role;
select is(
  (select lifetime_trip_count from public.trip_creation_quotas
   where user_id = '11111111-1111-1111-1111-111111111111'),
  2::bigint,
  'hard deletion does not decrement the lifetime counter'
);

set local role authenticated;
select throws_ok(
  $$insert into public.trips (owner_id, title, destination)
    values ('22222222-2222-2222-2222-222222222222', 'Spoofed', 'Paris')$$,
  '42501',
  'A trip cannot be created for another user.',
  'owner spoofing is rejected inside the trigger'
);
reset role;
select is(
  (select count(*) from public.trip_creation_quotas
   where user_id = '22222222-2222-2222-2222-222222222222'),
  0::bigint,
  'owner spoofing cannot create or increment another account quota'
);

insert into public.iap_entitlements (
  user_id,
  product_id,
  original_transaction_id,
  transaction_id,
  status,
  environment,
  last_signed_transaction,
  expires_at
) values (
  '33333333-3333-3333-3333-333333333333',
  'app.moss.supporter.monthly',
  'original-paid',
  'transaction-paid-1',
  'active',
  'Sandbox',
  'legacy-unverified-jws',
  now() + interval '1 month'
);

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '33333333-3333-3333-3333-333333333333',
  true
);
select lives_ok(
  $$insert into public.trips (owner_id, title, destination)
    values
      ('33333333-3333-3333-3333-333333333333', 'Paid one', 'A'),
      ('33333333-3333-3333-3333-333333333333', 'Paid two', 'B')$$,
  'a legacy entitlement does not affect the two free creations'
);
select throws_ok(
  $$insert into public.trips (owner_id, title, destination)
    values ('33333333-3333-3333-3333-333333333333', 'Unverified paid three', 'C')$$,
  'MS002',
  'The subscription must be verified before creating another trip.',
  'a legacy active row without verification metadata cannot bypass the limit'
);
reset role;
select is(
  (select lifetime_trip_count from public.trip_creation_quotas
   where user_id = '33333333-3333-3333-3333-333333333333'),
  2::bigint,
  'the unverified-entitlement rejection rolls its increment back'
);

set local role authenticated;
select is(
  (select subscription_verification_pending from public.get_trip_creation_status()),
  true,
  'the safe RPC exposes pending verification without granting paid creation'
);
select is(
  (select can_create_trip from public.get_trip_creation_status()),
  false,
  'the safe RPC does not authorize an unverified active row'
);
reset role;

select set_config('request.jwt.claim.role', 'service_role', true);
set local role service_role;
select throws_ok(
  $$select public.record_verified_iap_entitlement(
    '33333333-3333-3333-3333-333333333333',
    'com.example.spoof',
    'app.moss.supporter.monthly',
    'original-paid',
    'transaction-paid-1',
    'active',
    'Sandbox',
    now() + interval '1 month',
    null,
    now() - interval '1 minute',
    'app_store_transaction_jws',
    'verified-jws'
  )$$,
  '22023',
  'The verified transaction has an invalid bundle identifier.',
  'the server function rejects a non-Moss bundle'
);
select throws_ok(
  $$select public.record_verified_iap_entitlement(
    '33333333-3333-3333-3333-333333333333',
    'app.getmoss.moss',
    'com.example.unsupported',
    'original-paid',
    'transaction-paid-1',
    'active',
    'Sandbox',
    now() + interval '1 month',
    null,
    now() - interval '1 minute',
    'app_store_transaction_jws',
    'verified-jws'
  )$$,
  '22023',
  'The verified transaction has an unsupported product identifier.',
  'the server function rejects a non-Moss product'
);
select throws_ok(
  $$select public.record_verified_iap_entitlement(
    '33333333-3333-3333-3333-333333333333',
    'app.getmoss.moss',
    'app.moss.supporter.monthly',
    'original-paid',
    'transaction-paid-1',
    'active',
    'Staging',
    now() + interval '1 month',
    null,
    now() - interval '1 minute',
    'app_store_transaction_jws',
    'verified-jws'
  )$$,
  '22023',
  'The verified transaction has an unsupported environment.',
  'the server function rejects an unsupported environment'
);
select throws_ok(
  $$select public.record_verified_iap_entitlement(
    '33333333-3333-3333-3333-333333333333',
    'app.getmoss.moss',
    'app.moss.supporter.monthly',
    '',
    'transaction-paid-1',
    'active',
    'Sandbox',
    now() + interval '1 month',
    null,
    now() - interval '1 minute',
    'app_store_transaction_jws',
    'verified-jws'
  )$$,
  '22023',
  'The verified transaction is missing required transaction identifiers.',
  'the server function requires transaction identifiers'
);
select throws_ok(
  $$select public.record_verified_iap_entitlement(
    '33333333-3333-3333-3333-333333333333',
    'app.getmoss.moss',
    'app.moss.supporter.monthly',
    'original-paid',
    'transaction-paid-1',
    'active',
    'Sandbox',
    now() + interval '1 month',
    null,
    now() + interval '10 minutes',
    'app_store_transaction_jws',
    'verified-jws'
  )$$,
  '22023',
  'The verified transaction has an invalid signing timestamp.',
  'the server function validates the Apple signing timestamp'
);
select throws_ok(
  $$select public.record_verified_iap_entitlement(
    '33333333-3333-3333-3333-333333333333',
    'app.getmoss.moss',
    'app.moss.supporter.monthly',
    'original-paid',
    'transaction-paid-1',
    'active',
    'Sandbox',
    now() + interval '1 month',
    null,
    now() - interval '1 minute',
    'client_claimed',
    'verified-jws'
  )$$,
  '22023',
  'The entitlement verification source is invalid.',
  'the server function accepts only Apple verification sources'
);
reset role;
select is(
  (select verified_at from public.iap_entitlements
   where user_id = '33333333-3333-3333-3333-333333333333'),
  null::timestamptz,
  'failed validation does not promote a legacy entitlement'
);

set local role service_role;
select lives_ok(
  $$select public.record_verified_iap_entitlement(
    '33333333-3333-3333-3333-333333333333',
    'app.getmoss.moss',
    'app.moss.supporter.monthly',
    'original-paid',
    'transaction-paid-1',
    'active',
    'Sandbox',
    now() + interval '1 month',
    null,
    now() - interval '1 minute',
    'app_store_transaction_jws',
    'verified-jws'
  )$$,
  'the service-role function records a newly verified entitlement'
);
reset role;
select is(
  public.has_active_trip_entitlement('33333333-3333-3333-3333-333333333333'),
  true,
  'a complete newly verified row is an active trip entitlement'
);

set local role authenticated;
select lives_ok(
  $$insert into public.trips (owner_id, title, destination)
    values ('33333333-3333-3333-3333-333333333333', 'Verified paid three', 'C')$$,
  'newly server-verified paid creation works beyond the allowance'
);
reset role;
select is(
  (select lifetime_trip_count from public.trip_creation_quotas
   where user_id = '33333333-3333-3333-3333-333333333333'),
  3::bigint,
  'creations while subscribed count toward lifetime usage'
);

set local role service_role;
select lives_ok(
  $$select public.record_verified_iap_entitlement(
    '33333333-3333-3333-3333-333333333333',
    'app.getmoss.moss',
    'app.moss.supporter.monthly',
    'original-paid',
    'transaction-paid-expired',
    'expired',
    'Sandbox',
    now() - interval '1 second',
    null,
    now() - interval '1 minute',
    'app_store_server_notification_v2',
    'verified-expiration-jws'
  )$$,
  'the service-role function records verified expiration state'
);
reset role;

set local role authenticated;
select throws_ok(
  $$insert into public.trips (owner_id, title, destination)
    values ('33333333-3333-3333-3333-333333333333', 'After expiry', 'D')$$,
  'MS001',
  'The lifetime free-trip allowance has been used.',
  'creation is gated again after server-confirmed entitlement expiry'
);
reset role;
select is(
  (select lifetime_trip_count from public.trip_creation_quotas
   where user_id = '33333333-3333-3333-3333-333333333333'),
  3::bigint,
  'post-expiry rejection rolls the increment back'
);

alter table public.trips disable trigger trips_enforce_creation_limit;
insert into public.trips (owner_id, title, destination)
values
  ('44444444-4444-4444-4444-444444444444', 'Legacy one', 'A'),
  ('44444444-4444-4444-4444-444444444444', 'Legacy two', 'B'),
  ('44444444-4444-4444-4444-444444444444', 'Legacy deleted', 'C');
update public.trips
set deleted_at = now()
where owner_id = '44444444-4444-4444-4444-444444444444'
  and title = 'Legacy deleted';
alter table public.trips enable trigger trips_enforce_creation_limit;

insert into public.trip_creation_quotas as quota (user_id, lifetime_trip_count)
select owner_id, count(*)
from public.trips
where owner_id = '44444444-4444-4444-4444-444444444444'
group by owner_id
on conflict (user_id) do update
set lifetime_trip_count = greatest(
  quota.lifetime_trip_count,
  excluded.lifetime_trip_count
);

select is(
  (select lifetime_trip_count from public.trip_creation_quotas
   where user_id = '44444444-4444-4444-4444-444444444444'),
  3::bigint,
  'backfill includes existing active and soft-deleted trips'
);

insert into public.trip_creation_quotas as quota (user_id, lifetime_trip_count)
select owner_id, count(*)
from public.trips
where owner_id = '44444444-4444-4444-4444-444444444444'
group by owner_id
on conflict (user_id) do update
set lifetime_trip_count = greatest(
  quota.lifetime_trip_count,
  excluded.lifetime_trip_count
);

select is(
  (select lifetime_trip_count from public.trip_creation_quotas
   where user_id = '44444444-4444-4444-4444-444444444444'),
  3::bigint,
  'backfill is idempotent and does not double-count'
);

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-1111-1111-111111111111',
  true
);
select is(
  (select lifetime_trip_count from public.get_trip_creation_status()),
  2::bigint,
  'safe RPC reports authoritative lifetime usage'
);
select is(
  (select can_create_trip from public.get_trip_creation_status()),
  false,
  'safe RPC applies the database creation gate'
);
reset role;

select is(
  (select count(*) from information_schema.role_table_grants
   where table_schema = 'public'
     and table_name = 'trip_creation_quotas'
     and grantee in ('anon', 'authenticated')),
  0::bigint,
  'client roles have no quota-table privileges'
);

select is(
  (select count(*) from information_schema.routine_privileges
   where routine_schema = 'public'
     and routine_name = 'record_verified_iap_entitlement'
     and grantee in ('PUBLIC', 'anon', 'authenticated')),
  0::bigint,
  'client roles cannot execute the verified-entitlement writer'
);

select * from finish();
rollback;
