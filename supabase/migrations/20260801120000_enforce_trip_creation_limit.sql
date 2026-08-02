-- Install the counter and trigger while blocking writes to trips. Keep the
-- transaction explicit because all Supabase migration paths do not add one.
-- The lock is held through backfill and trigger installation; inserts that
-- arrive during deployment resume after commit and use the installed trigger.
begin;

lock table public.trips in share row exclusive mode;

-- lifetime_trip_count means every successfully committed trip creation over
-- the account lifetime, including trips created while subscribed. Neither a
-- soft delete nor a hard delete decrements it.
create table if not exists public.trip_creation_quotas (
  user_id uuid primary key references auth.users(id) on delete cascade,
  lifetime_trip_count bigint not null default 0 check (lifetime_trip_count >= 0)
);

alter table public.trip_creation_quotas enable row level security;

-- The primary key indexes quota ownership. The existing initial-schema index
-- has this shape; keep this migration safe if it is applied to an older schema.
create index if not exists trips_owner_id_idx on public.trips(owner_id);

-- Clients may read only the safe status RPC below and must never be able to
-- lower or otherwise manipulate the authoritative counter.
revoke all on table public.trip_creation_quotas from public, anon, authenticated;

create or replace function public.has_active_trip_entitlement(target_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.iap_entitlements
    where user_id = target_user_id
      and status = 'active'
      and revoked_at is null
      and (expires_at is null or expires_at > pg_catalog.now())
  );
$$;

revoke all on function public.has_active_trip_entitlement(uuid) from public;

create or replace function public.enforce_trip_creation_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := auth.uid();
  pre_increment_count bigint;
  has_active_entitlement boolean;
begin
  if actor_id is null then
    raise exception using
      errcode = '28000',
      message = 'Authentication is required to create a trip.';
  end if;

  if new.owner_id is not null and new.owner_id <> actor_id then
    raise exception using
      errcode = '42501',
      message = 'A trip cannot be created for another user.';
  end if;

  -- Keep ownership authoritative even if a compatible future schema allows a
  -- null/default owner_id or a client omits the value.
  new.owner_id := actor_id;

  -- The upsert serializes concurrent creations on this user's primary-key row.
  -- Increment every attempt first; a later exception rolls the statement (and
  -- therefore this increment) back atomically.
  insert into public.trip_creation_quotas as quota (
    user_id,
    lifetime_trip_count
  )
  values (actor_id, 1)
  on conflict (user_id) do update
    set lifetime_trip_count = quota.lifetime_trip_count + 1
  returning lifetime_trip_count - 1 into pre_increment_count;

  has_active_entitlement := public.has_active_trip_entitlement(actor_id);

  if not has_active_entitlement and pre_increment_count >= 2 then
    raise exception using
      errcode = 'MS001',
      message = 'The lifetime free-trip allowance has been used.',
      detail = 'MOSS_TRIP_LIMIT_REACHED',
      hint = 'An active server-confirmed subscription is required to create another trip.';
  end if;

  return new;
end;
$$;

revoke all on function public.enforce_trip_creation_limit() from public;

-- Backfill while trips remains locked. greatest() makes a rerun safe without
-- double-counting rows already maintained by an earlier trigger installation.
insert into public.trip_creation_quotas as quota (user_id, lifetime_trip_count)
select owner_id, count(*)
from public.trips
group by owner_id
on conflict (user_id) do update
set lifetime_trip_count = greatest(
  quota.lifetime_trip_count,
  excluded.lifetime_trip_count
);

drop trigger if exists trips_enforce_creation_limit on public.trips;
create trigger trips_enforce_creation_limit
before insert on public.trips
for each row execute function public.enforce_trip_creation_limit();

create or replace function public.get_trip_creation_status()
returns table (
  lifetime_trip_count bigint,
  free_trip_allowance bigint,
  has_active_entitlement boolean,
  can_create_trip boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor_id uuid := auth.uid();
  usage_count bigint;
  active_entitlement boolean;
begin
  if actor_id is null then
    raise exception using
      errcode = '28000',
      message = 'Authentication is required to read trip creation status.';
  end if;

  select coalesce(quota.lifetime_trip_count, 0)
  into usage_count
  from (select actor_id as user_id) as authenticated_actor
  left join public.trip_creation_quotas as quota using (user_id);

  active_entitlement := public.has_active_trip_entitlement(actor_id);

  return query select
    usage_count,
    2::bigint,
    active_entitlement,
    active_entitlement or usage_count < 2;
end;
$$;

revoke all on function public.get_trip_creation_status() from public;
grant execute on function public.get_trip_creation_status() to authenticated;

commit;
