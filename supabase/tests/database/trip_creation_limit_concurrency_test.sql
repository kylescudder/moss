-- This test intentionally uses two database connections, so it cannot run
-- inside the rollback transaction used by the main quota suite. It cleans up
-- its committed fixture before returning.
create extension if not exists pgtap with schema extensions;
create extension if not exists dblink with schema extensions;
set search_path = public, extensions;

select plan(4);

delete from auth.users
where id = '55555555-5555-5555-5555-555555555555';
insert into auth.users (id, email)
values ('55555555-5555-5555-5555-555555555555', 'concurrent@example.com');

set role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '55555555-5555-5555-5555-555555555555',
  false
);
insert into public.trips (owner_id, title, destination)
values ('55555555-5555-5555-5555-555555555555', 'Existing', 'A');
reset role;

select dblink_connect('quota_a', 'dbname=' || current_database());
select dblink_connect('quota_b', 'dbname=' || current_database());

-- Holding each successful transaction open for one second guarantees overlap:
-- both requests start from a lifetime count of one and contend on the quota PK.
select dblink_send_query('quota_a', $query$
  with auth_context as materialized (
    select set_config(
      'request.jwt.claim.sub',
      '55555555-5555-5555-5555-555555555555',
      false
    )
  ), inserted as (
    insert into public.trips (owner_id, title, destination)
    select
      '55555555-5555-5555-5555-555555555555'::uuid,
      'Concurrent A',
      'B'
    from auth_context
    returning id
  ), paused as (
    select pg_sleep(1) from inserted
  )
  select 'ok'::text as result from paused
$query$);

select dblink_send_query('quota_b', $query$
  with auth_context as materialized (
    select set_config(
      'request.jwt.claim.sub',
      '55555555-5555-5555-5555-555555555555',
      false
    )
  ), inserted as (
    insert into public.trips (owner_id, title, destination)
    select
      '55555555-5555-5555-5555-555555555555'::uuid,
      'Concurrent B',
      'C'
    from auth_context
    returning id
  ), paused as (
    select pg_sleep(1) from inserted
  )
  select 'ok'::text as result from paused
$query$);

create temporary table concurrent_results (
  connection_name text,
  result text
);
insert into concurrent_results
select 'quota_a', result
from dblink_get_result('quota_a', false) as response(result text);
insert into concurrent_results
select 'quota_b', result
from dblink_get_result('quota_b', false) as response(result text);

create temporary table concurrent_errors (
  connection_name text,
  message text
);
insert into concurrent_errors values
  ('quota_a', dblink_error_message('quota_a')),
  ('quota_b', dblink_error_message('quota_b'));

select is(
  (select count(*) from concurrent_results where result = 'ok'),
  1::bigint,
  'exactly one of two concurrent free creations succeeds'
);
select is(
  (select count(*) from public.trips
   where owner_id = '55555555-5555-5555-5555-555555555555'),
  2::bigint,
  'concurrent inserts cannot exceed the free allowance'
);
select is(
  (select lifetime_trip_count from public.trip_creation_quotas
   where user_id = '55555555-5555-5555-5555-555555555555'),
  2::bigint,
  'the rejected concurrent increment is rolled back'
);
select is(
  (select count(*) from concurrent_errors
   where message like '%lifetime free-trip allowance%'),
  1::bigint,
  'the losing concurrent request receives the quota error'
);

select dblink_disconnect('quota_a');
select dblink_disconnect('quota_b');
delete from auth.users
where id = '55555555-5555-5555-5555-555555555555';

select * from finish();
