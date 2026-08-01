-- Keep the free trip allowance authoritative in Postgres. This counter is
-- intentionally lifetime-based: deleting a trip does not restore a free slot.
create table public.trip_creation_quotas (
  user_id uuid primary key references auth.users(id) on delete cascade,
  lifetime_trip_count bigint not null default 0 check (lifetime_trip_count >= 0)
);

alter table public.trip_creation_quotas enable row level security;

-- The table is maintained only by the trigger below. In particular, clients
-- must not be able to lower their own count.
revoke all on table public.trip_creation_quotas from public, anon, authenticated;

create or replace function public.enforce_trip_creation_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  quota_incremented boolean := false;
  has_active_entitlement boolean;
begin
  select exists (
    select 1
    from public.iap_entitlements
    where user_id = new.owner_id
      and status = 'active'
      and revoked_at is null
      and (expires_at is null or expires_at > pg_catalog.now())
  )
  into has_active_entitlement;

  insert into public.trip_creation_quotas as quota (
    user_id,
    lifetime_trip_count
  )
  values (new.owner_id, 1)
  on conflict (user_id) do update
    set lifetime_trip_count = quota.lifetime_trip_count + 1
    where quota.lifetime_trip_count < 2
       or has_active_entitlement
  returning true into quota_incremented;

  if quota_incremented is not true then
    raise exception using
      errcode = 'P0001',
      message = 'Free accounts can create up to 2 trips. An active subscription is required to create another trip.';
  end if;

  return new;
end;
$$;

revoke all on function public.enforce_trip_creation_limit() from public;

create trigger trips_enforce_creation_limit
before insert on public.trips
for each row execute function public.enforce_trip_creation_limit();

-- Seed accounts that created trips before this trigger was installed. The
-- trigger lock prevents writes from slipping between this snapshot and commit.
insert into public.trip_creation_quotas as quota (user_id, lifetime_trip_count)
select owner_id, count(*)
from public.trips
group by owner_id
on conflict (user_id) do update
set lifetime_trip_count = pg_catalog.greatest(
  quota.lifetime_trip_count,
  excluded.lifetime_trip_count
);
