-- Only Apple-verifying server code may populate these fields. In particular,
-- verified_at is intentionally not backfilled: pre-existing rows remain
-- unverified until Apple transaction data is verified again.
alter table public.iap_entitlements
  add column if not exists bundle_id text,
  add column if not exists signed_at timestamptz,
  add column if not exists verified_at timestamptz,
  add column if not exists verification_source text;

create unique index if not exists iap_entitlements_verified_original_transaction_idx
on public.iap_entitlements(original_transaction_id)
where verified_at is not null;

create or replace function public.record_verified_iap_entitlement(
  target_user_id uuid,
  target_bundle_id text,
  target_product_id text,
  target_original_transaction_id text,
  target_transaction_id text,
  target_status text,
  target_environment text,
  target_expires_at timestamptz,
  target_revoked_at timestamptz,
  target_signed_at timestamptz,
  target_verification_source text,
  target_last_signed_transaction text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  entitlement_user_id uuid := target_user_id;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception using
      errcode = '42501',
      message = 'Only the entitlement verification service may record Apple entitlements.',
      detail = 'MOSS_IAP_SERVICE_ROLE_REQUIRED';
  end if;

  if target_bundle_id is distinct from 'app.getmoss.moss' then
    raise exception using
      errcode = '22023',
      message = 'The verified transaction has an invalid bundle identifier.',
      detail = 'MOSS_IAP_INVALID_BUNDLE_ID';
  end if;

  if target_product_id is distinct from 'app.moss.supporter.monthly' then
    raise exception using
      errcode = '22023',
      message = 'The verified transaction has an unsupported product identifier.',
      detail = 'MOSS_IAP_INVALID_PRODUCT_ID';
  end if;

  if target_environment is null
     or target_environment not in ('Production', 'Sandbox') then
    raise exception using
      errcode = '22023',
      message = 'The verified transaction has an unsupported environment.',
      detail = 'MOSS_IAP_INVALID_ENVIRONMENT';
  end if;

  if nullif(pg_catalog.btrim(target_original_transaction_id), '') is null
     or nullif(pg_catalog.btrim(target_transaction_id), '') is null then
    raise exception using
      errcode = '22023',
      message = 'The verified transaction is missing required transaction identifiers.',
      detail = 'MOSS_IAP_MISSING_TRANSACTION_ID';
  end if;

  if target_signed_at is null
     or target_signed_at > pg_catalog.now() + interval '5 minutes' then
    raise exception using
      errcode = '22023',
      message = 'The verified transaction has an invalid signing timestamp.',
      detail = 'MOSS_IAP_INVALID_SIGNED_AT';
  end if;

  if target_verification_source is null
     or target_verification_source not in (
       'app_store_transaction_jws',
       'app_store_server_notification_v2'
     ) then
    raise exception using
      errcode = '22023',
      message = 'The entitlement verification source is invalid.',
      detail = 'MOSS_IAP_INVALID_VERIFICATION_SOURCE';
  end if;

  if nullif(pg_catalog.btrim(target_last_signed_transaction), '') is null then
    raise exception using
      errcode = '22023',
      message = 'The verified transaction payload is required.',
      detail = 'MOSS_IAP_MISSING_SIGNED_TRANSACTION';
  end if;

  if target_status is null
     or target_status not in ('active', 'expired', 'revoked', 'unknown') then
    raise exception using
      errcode = '22023',
      message = 'The entitlement status is invalid.',
      detail = 'MOSS_IAP_INVALID_STATUS';
  end if;

  if target_status = 'active' and (
    target_expires_at is null
    or target_expires_at <= pg_catalog.now()
    or target_revoked_at is not null
  ) then
    raise exception using
      errcode = '22023',
      message = 'An active entitlement must be unrevoked and unexpired.',
      detail = 'MOSS_IAP_INVALID_ACTIVE_STATE';
  end if;

  if target_status = 'expired' and (
    target_expires_at is null or target_expires_at > pg_catalog.now()
  ) then
    raise exception using
      errcode = '22023',
      message = 'An expired entitlement must have an elapsed expiration timestamp.',
      detail = 'MOSS_IAP_INVALID_EXPIRED_STATE';
  end if;

  if target_status = 'revoked' and target_revoked_at is null then
    raise exception using
      errcode = '22023',
      message = 'A revoked entitlement must have a revocation timestamp.',
      detail = 'MOSS_IAP_INVALID_REVOKED_STATE';
  end if;

  -- Server notifications may omit appAccountToken. They may update only a
  -- previously verified subscription with the same original transaction ID;
  -- an unverified legacy row is never promoted by identifier alone.
  if entitlement_user_id is null then
    select entitlement.user_id
    into entitlement_user_id
    from public.iap_entitlements as entitlement
    where entitlement.original_transaction_id = target_original_transaction_id
      and entitlement.bundle_id = 'app.getmoss.moss'
      and entitlement.product_id = 'app.moss.supporter.monthly'
      and entitlement.environment = target_environment
      and entitlement.verified_at is not null
      and entitlement.verification_source in (
        'app_store_transaction_jws',
        'app_store_server_notification_v2'
      )
    order by entitlement.verified_at desc
    limit 1;

    if entitlement_user_id is null then
      raise exception using
        errcode = '22023',
        message = 'The notification cannot be matched to a verified Moss account.',
        detail = 'MOSS_IAP_ACCOUNT_NOT_VERIFIED';
    end if;
  end if;

  insert into public.iap_entitlements as entitlement (
    user_id,
    bundle_id,
    product_id,
    original_transaction_id,
    transaction_id,
    status,
    environment,
    expires_at,
    revoked_at,
    signed_at,
    verified_at,
    verification_source,
    last_signed_transaction
  ) values (
    entitlement_user_id,
    target_bundle_id,
    target_product_id,
    target_original_transaction_id,
    target_transaction_id,
    target_status,
    target_environment,
    target_expires_at,
    target_revoked_at,
    target_signed_at,
    pg_catalog.now(),
    target_verification_source,
    target_last_signed_transaction
  )
  on conflict (user_id, product_id) do update set
    bundle_id = excluded.bundle_id,
    original_transaction_id = excluded.original_transaction_id,
    transaction_id = excluded.transaction_id,
    status = excluded.status,
    environment = excluded.environment,
    expires_at = excluded.expires_at,
    revoked_at = excluded.revoked_at,
    signed_at = excluded.signed_at,
    verified_at = excluded.verified_at,
    verification_source = excluded.verification_source,
    last_signed_transaction = excluded.last_signed_transaction;
end;
$$;

revoke all on function public.record_verified_iap_entitlement(
  uuid, text, text, text, text, text, text, timestamptz, timestamptz,
  timestamptz, text, text
) from public, anon, authenticated;
grant execute on function public.record_verified_iap_entitlement(
  uuid, text, text, text, text, text, text, timestamptz, timestamptz,
  timestamptz, text, text
) to service_role;

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
      and bundle_id = 'app.getmoss.moss'
      and product_id = 'app.moss.supporter.monthly'
      and environment in ('Production', 'Sandbox')
      and nullif(pg_catalog.btrim(original_transaction_id), '') is not null
      and nullif(pg_catalog.btrim(transaction_id), '') is not null
      and signed_at is not null
      and verified_at is not null
      and verification_source in (
        'app_store_transaction_jws',
        'app_store_server_notification_v2'
      )
      and nullif(pg_catalog.btrim(last_signed_transaction), '') is not null
      and status = 'active'
      and revoked_at is null
      and expires_at > pg_catalog.now()
  );
$$;

revoke all on function public.has_active_trip_entitlement(uuid) from public;

create or replace function public.has_pending_trip_entitlement_verification(
  target_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not public.has_active_trip_entitlement(target_user_id)
    and exists (
      select 1
      from public.iap_entitlements
      where user_id = target_user_id
        and product_id = 'app.moss.supporter.monthly'
        and status = 'active'
        and revoked_at is null
        and expires_at > pg_catalog.now()
    );
$$;

revoke all on function public.has_pending_trip_entitlement_verification(uuid)
from public;

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
      message = 'Authentication is required to create a trip.',
      detail = 'MOSS_AUTHENTICATION_REQUIRED';
  end if;

  if new.owner_id is not null and new.owner_id <> actor_id then
    raise exception using
      errcode = '42501',
      message = 'A trip cannot be created for another user.',
      detail = 'MOSS_TRIP_OWNER_MISMATCH';
  end if;

  new.owner_id := actor_id;

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
    if public.has_pending_trip_entitlement_verification(actor_id) then
      raise exception using
        errcode = 'MS002',
        message = 'The subscription must be verified before creating another trip.',
        detail = 'MOSS_SUBSCRIPTION_VERIFICATION_PENDING',
        hint = 'Retry subscription verification, then save this draft again.';
    end if;

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

drop function if exists public.get_trip_creation_status();
create function public.get_trip_creation_status()
returns table (
  lifetime_trip_count bigint,
  free_trip_allowance bigint,
  has_active_entitlement boolean,
  subscription_verification_pending boolean,
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
  pending_verification boolean;
begin
  if actor_id is null then
    raise exception using
      errcode = '28000',
      message = 'Authentication is required to read trip creation status.',
      detail = 'MOSS_AUTHENTICATION_REQUIRED';
  end if;

  select coalesce(quota.lifetime_trip_count, 0)
  into usage_count
  from (select actor_id as user_id) as authenticated_actor
  left join public.trip_creation_quotas as quota using (user_id);

  active_entitlement := public.has_active_trip_entitlement(actor_id);
  pending_verification :=
    public.has_pending_trip_entitlement_verification(actor_id);

  return query select
    usage_count,
    2::bigint,
    active_entitlement,
    pending_verification,
    active_entitlement or usage_count < 2;
end;
$$;

revoke all on function public.get_trip_creation_status() from public;
grant execute on function public.get_trip_creation_status() to authenticated;
