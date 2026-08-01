begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(24);

select has_table('public', 'trip_creation_quotas', 'quota table exists');
select has_index('public', 'trips', 'trips_owner_id_idx', 'trip owner queries are indexed');
select has_trigger(
  'public',
  'trips',
  'trips_enforce_creation_limit',
  'trip creation trigger is installed'
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
  'P0001',
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
  'P0001',
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
  'P0001',
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
  status,
  expires_at
) values (
  '33333333-3333-3333-3333-333333333333',
  'app.moss.supporter.monthly',
  'active',
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
      ('33333333-3333-3333-3333-333333333333', 'Paid two', 'B'),
      ('33333333-3333-3333-3333-333333333333', 'Paid three', 'C')$$,
  'server-confirmed paid creation works beyond the allowance'
);
reset role;
select is(
  (select lifetime_trip_count from public.trip_creation_quotas
   where user_id = '33333333-3333-3333-3333-333333333333'),
  3::bigint,
  'creations while subscribed count toward lifetime usage'
);

update public.iap_entitlements
set status = 'expired', expires_at = now() - interval '1 second'
where user_id = '33333333-3333-3333-3333-333333333333';
set local role authenticated;
select throws_ok(
  $$insert into public.trips (owner_id, title, destination)
    values ('33333333-3333-3333-3333-333333333333', 'After expiry', 'D')$$,
  'P0001',
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

select * from finish();
rollback;
