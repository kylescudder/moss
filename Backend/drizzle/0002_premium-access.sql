ALTER TABLE "profiles" ADD COLUMN "is_premium_account" boolean DEFAULT false NOT NULL;
--> statement-breakpoint
-- Administrators alone grant complimentary access. Normal profile edits retain
-- column privileges; the request role cannot grant itself premium access.
revoke insert, update on public.profiles from moss_api;
grant insert (id, username, display_name, created_at, updated_at, deleted_at),
      update (username, display_name, updated_at, deleted_at)
  on public.profiles to moss_api;
--> statement-breakpoint
create or replace function public.has_unlimited_creation_access(target_user_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.profiles
    where id = target_user_id and is_premium_account and deleted_at is null
  ) or public.has_verified_supporter_entitlement(target_user_id);
$$;
revoke all on function public.has_unlimited_creation_access(uuid) from public;

--> statement-breakpoint
create or replace function public.get_trip_creation_status()
returns table (
  lifetime_count bigint,
  free_limit integer,
  has_verified_entitlement boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  authenticated_user_id uuid := nullif(current_setting('moss.user_id', true), '')::uuid;
begin
  if authenticated_user_id is null then
    raise exception using
      errcode = 'MX002',
      message = 'authentication required';
  end if;

  if not exists (select 1 from public.profiles where id = authenticated_user_id) then
    raise exception using
      errcode = 'MX004',
      message = 'profile does not exist';
  end if;

  return query
  select
    coalesce(quota.lifetime_count, 0),
    2,
    public.has_unlimited_creation_access(authenticated_user_id)
  from (values (1)) as singleton(value)
  left join public.trip_creation_quotas as quota
    on quota.user_id = authenticated_user_id;
end;
$$;

--> statement-breakpoint
create or replace function public.enforce_free_trip_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  authenticated_user_id uuid := nullif(current_setting('moss.user_id', true), '')::uuid;
  updated_lifetime_count bigint;
begin
  if authenticated_user_id is null then
    raise exception using
      errcode = 'MX002',
      message = 'authentication required';
  end if;

  if new.owner_id is null then
    new.owner_id := authenticated_user_id;
  elsif new.owner_id <> authenticated_user_id then
    raise exception using
      errcode = 'MX003',
      message = 'trip owner does not match authenticated user';
  end if;

  perform 1
  from public.profiles
  where id = authenticated_user_id
  for update;

  if not found then
    raise exception using
      errcode = 'MX004',
      message = 'profile does not exist';
  end if;

  -- A previously unseen trip ID is a genuine lifetime creation. The durable
  -- unique ledger also prevents hard-delete/reinsert cycles and concurrent
  -- duplicate IDs from bypassing or double-consuming the quota. All writes
  -- roll back together if the trip insert later fails.
  insert into public.trip_creation_events (trip_id, user_id)
  values (new.id, authenticated_user_id);

  insert into public.trip_creation_quotas (user_id, lifetime_count, updated_at)
  values (authenticated_user_id, 1, statement_timestamp())
  on conflict (user_id) do update
    set lifetime_count = public.trip_creation_quotas.lifetime_count + 1,
        updated_at = statement_timestamp()
  returning lifetime_count into updated_lifetime_count;

  if updated_lifetime_count > 2
     and not public.has_unlimited_creation_access(authenticated_user_id) then
    raise exception using
      errcode = 'MX001',
      message = 'free trip limit reached';
  end if;

  return new;
end;
$$;
