-- Transactional quota, ownership and verified-entitlement behaviour. Only the
-- request transaction sets moss.user_id.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'moss_api') then
    create role moss_api nologin;
  end if;
end $$;
grant usage on schema public to moss_api;
create or replace function public.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$ begin new.updated_at = now(); return new; end $$;
create or replace function public.has_verified_supporter_entitlement(target_user_id uuid)
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
      and product_id = 'app.moss.supporter.monthly'
      and bundle_id = 'app.getmoss.moss'
      and environment in ('Production', 'Sandbox')
      and verification_source in ('device', 'notification')
      and verified_at is not null
      and signed_at is not null
      and status = 'active'
      and revoked_at is null
      and expires_at > statement_timestamp()
  );
$$;

revoke all on function public.has_verified_supporter_entitlement(uuid) from public;

create or replace function public.record_verified_iap_entitlement(
  p_user_id uuid,
  p_product_id text,
  p_bundle_id text,
  p_original_transaction_id text,
  p_transaction_id text,
  p_status text,
  p_expires_at timestamptz,
  p_revoked_at timestamptz,
  p_environment text,
  p_signed_at timestamptz,
  p_verification_source text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin

  if p_product_id <> 'app.moss.supporter.monthly'
     or p_bundle_id <> 'app.getmoss.moss'
     or p_environment not in ('Production', 'Sandbox')
     or p_verification_source not in ('device', 'notification')
     or p_original_transaction_id is null
     or p_transaction_id is null
     or p_expires_at is null
     or p_signed_at is null
     or p_status not in ('active', 'expired', 'revoked') then
    raise exception using
      errcode = 'MX005',
      message = 'verified entitlement fields are invalid';
  end if;

  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception using
      errcode = 'MX004',
      message = 'profile does not exist';
  end if;

  insert into public.iap_entitlements (
    user_id,
    product_id,
    bundle_id,
    original_transaction_id,
    transaction_id,
    status,
    expires_at,
    revoked_at,
    environment,
    signed_at,
    verified_at,
    verification_source,
    updated_at
  ) values (
    p_user_id,
    p_product_id,
    p_bundle_id,
    p_original_transaction_id,
    p_transaction_id,
    p_status,
    p_expires_at,
    p_revoked_at,
    p_environment,
    p_signed_at,
    statement_timestamp(),
    p_verification_source,
    statement_timestamp()
  )
  on conflict (user_id) do update
    set product_id = excluded.product_id,
        bundle_id = excluded.bundle_id,
        original_transaction_id = excluded.original_transaction_id,
        transaction_id = excluded.transaction_id,
        status = excluded.status,
        expires_at = excluded.expires_at,
        revoked_at = excluded.revoked_at,
        environment = excluded.environment,
        signed_at = excluded.signed_at,
        verified_at = excluded.verified_at,
        verification_source = excluded.verification_source,
        updated_at = excluded.updated_at
    where public.iap_entitlements.signed_at is null
       or excluded.signed_at > public.iap_entitlements.signed_at
       or (excluded.signed_at = public.iap_entitlements.signed_at and
         case excluded.status when 'revoked' then 3 when 'expired' then 2 else 1 end >=
         case public.iap_entitlements.status when 'revoked' then 3 when 'expired' then 2 else 1 end);
end;
$$;

revoke all on function public.record_verified_iap_entitlement(
  uuid, text, text, text, text, text, timestamptz, timestamptz, text, timestamptz, text
) from public;


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
    public.has_verified_supporter_entitlement(authenticated_user_id)
  from (values (1)) as singleton(value)
  left join public.trip_creation_quotas as quota
    on quota.user_id = authenticated_user_id;
end;
$$;

revoke all on function public.get_trip_creation_status() from public;


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
     and not public.has_verified_supporter_entitlement(authenticated_user_id) then
    raise exception using
      errcode = 'MX001',
      message = 'free trip limit reached';
  end if;

  return new;
end;
$$;

revoke all on function public.enforce_free_trip_limit() from public;

drop trigger if exists trips_enforce_free_trip_limit on public.trips;
create trigger trips_enforce_free_trip_limit
  before insert on public.trips
  for each row execute function public.enforce_free_trip_limit();

-- The runtime role cannot mint or edit subscription verification or lifetime use.
grant select, insert, update on public.profiles to moss_api;
grant select, insert, update, delete on public.trips, public.itinerary_items, public.device_tokens to moss_api;
grant execute on function public.get_trip_creation_status() to moss_api;
create or replace function public.initialize_trip_quota() returns trigger
language plpgsql security definer set search_path = '' as $$ begin
  insert into public.trip_creation_quotas (user_id) values (new.id) on conflict do nothing;
  return new;
end $$;
revoke all on function public.initialize_trip_quota() from public;
create trigger profiles_initialize_quota after insert on public.profiles
for each row execute function public.initialize_trip_quota();
-- Runs as the request role, so RLS limits the lookup to the caller's own trips.
create or replace function public.check_itinerary_trip_owner() returns trigger
language plpgsql set search_path = '' as $$ begin
  if not exists (
    select 1 from public.trips where id = new.trip_id and owner_id = new.owner_id
  ) then raise exception using errcode='MX003', message='trip is unavailable'; end if;
  return new;
end $$;
create trigger itinerary_items_check_trip_owner before insert or update on public.itinerary_items
for each row execute function public.check_itinerary_trip_owner();

alter table public.profiles enable row level security;
create policy own_rows on public.profiles to moss_api using (id = nullif(current_setting('moss.user_id', true), '')::uuid) with check (id = nullif(current_setting('moss.user_id', true), '')::uuid);

alter table public.trips enable row level security;
create policy own_rows on public.trips to moss_api using (owner_id = nullif(current_setting('moss.user_id', true), '')::uuid) with check (owner_id = nullif(current_setting('moss.user_id', true), '')::uuid);

alter table public.itinerary_items enable row level security;
create policy own_rows on public.itinerary_items to moss_api using (owner_id = nullif(current_setting('moss.user_id', true), '')::uuid) with check (owner_id = nullif(current_setting('moss.user_id', true), '')::uuid);

alter table public.device_tokens enable row level security;
create policy own_rows on public.device_tokens to moss_api using (user_id = nullif(current_setting('moss.user_id', true), '')::uuid) with check (user_id = nullif(current_setting('moss.user_id', true), '')::uuid);
create trigger profiles_touch_updated_at before update on public.profiles for each row execute function public.touch_updated_at();
create trigger trips_touch_updated_at before update on public.trips for each row execute function public.touch_updated_at();
create trigger itinerary_items_touch_updated_at before update on public.itinerary_items for each row execute function public.touch_updated_at();
create trigger device_tokens_touch_updated_at before update on public.device_tokens for each row execute function public.touch_updated_at();
create trigger iap_entitlements_touch_updated_at before update on public.iap_entitlements for each row execute function public.touch_updated_at();
alter table public.trip_creation_quotas enable row level security;
revoke all on public.trip_creation_quotas from public, moss_api;
alter table public.trip_creation_events enable row level security;
revoke all on public.trip_creation_events from public, moss_api;
alter table public.iap_entitlements enable row level security;
revoke all on public.iap_entitlements from public, moss_api;

-- Recovery fencing. Releases reinstall the shared deploy/recovery-guard.sql and
-- the per-table triggers from app.json after every migration run as well.
create or replace function public.require_recovery_lease() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if clock_timestamp() - transaction_timestamp() >= interval '60 seconds'
     or not exists (
       select 1 from public.recovery_lease
       where id = 1
         and snapshot_started_at > clock_timestamp() - interval '600 seconds'
         and snapshot_started_at <= clock_timestamp()
         and verified_at >= snapshot_started_at
         and verified_at <= clock_timestamp()
         and length(snapshot_id) > 0
     ) then
    raise exception using errcode = 'DX006', message = 'Recovery proof unavailable; retry later';
  end if;
end $$;
revoke all on function public.require_recovery_lease() from public;
grant execute on function public.require_recovery_lease() to moss_api;
create or replace function public.guard_recoverable_mutation() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_recovery_lease();
  return null;
end $$;
revoke all on function public.guard_recoverable_mutation() from public;
do $$ declare t text; begin
  foreach t in array array['auth_user','auth_account','auth_session','auth_verification','auth_rate_limit','auth_email_limit','auth_jwks','profiles','trips','itinerary_items','device_tokens','trip_creation_quotas','trip_creation_events','iap_entitlements','native_codes','notification_inbox'] loop
    execute format('create trigger recovery_before before insert or update or delete on public.%I for each statement execute function public.guard_recoverable_mutation()', t);
    execute format('create constraint trigger recovery_commit after insert or update or delete on public.%I deferrable initially deferred for each row execute function public.guard_recoverable_mutation()', t);
  end loop;
end $$;
revoke all on public.recovery_lease from public, moss_api;
grant select, insert, update, delete on public.auth_user, public.auth_account, public.auth_session, public.auth_verification, public.auth_rate_limit, public.auth_email_limit, public.auth_jwks, public.native_codes, public.notification_inbox to moss_api;
-- The API verifies Apple signatures before invoking this narrow definer function.
grant execute on function public.record_verified_iap_entitlement(uuid,text,text,text,text,text,timestamptz,timestamptz,text,timestamptz,text) to moss_api;
grant execute on function public.has_verified_supporter_entitlement(uuid) to moss_api;
create function public.initialize_profile() returns trigger language plpgsql security definer set search_path = '' as $$ begin
  insert into public.profiles(id, display_name) values(new.id, nullif(new.name,'')) on conflict do nothing;
  return new;
end $$;
revoke all on function public.initialize_profile() from public;
create trigger auth_user_profile after insert on public.auth_user for each row execute function public.initialize_profile();
