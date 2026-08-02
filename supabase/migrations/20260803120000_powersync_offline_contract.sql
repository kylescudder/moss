begin;
lock table public.trips in share row exclusive mode;

alter table public.profiles add column if not exists deleted_at timestamptz;
alter table public.trip_creation_quotas add column if not exists updated_at timestamptz not null default now();

create table if not exists public.trip_creation_events (
  trip_id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists trip_creation_events_user_id_idx on public.trip_creation_events(user_id);
revoke all on table public.trip_creation_events from public, anon, authenticated;

insert into public.trip_creation_events (trip_id, user_id, created_at)
select id, owner_id, coalesce(created_at, now()) from public.trips
on conflict (trip_id) do nothing;

create or replace function public.initialize_trip_creation_quota()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.trip_creation_quotas(user_id,lifetime_trip_count,updated_at)
  values(new.id,0,statement_timestamp()) on conflict(user_id) do nothing;
  return new;
end $$;
revoke all on function public.initialize_trip_creation_quota() from public;
drop trigger if exists profiles_initialize_trip_creation_quota on public.profiles;
create trigger profiles_initialize_trip_creation_quota after insert on public.profiles
for each row execute function public.initialize_trip_creation_quota();

insert into public.trip_creation_quotas(user_id,lifetime_trip_count,updated_at)
select p.id,count(e.trip_id),statement_timestamp() from public.profiles p
left join public.trip_creation_events e on e.user_id=p.id group by p.id
on conflict(user_id) do update set lifetime_trip_count=greatest(trip_creation_quotas.lifetime_trip_count,excluded.lifetime_trip_count);

-- Record the UUID before incrementing. A replay of the same UUID is therefore
-- idempotent and cannot consume quota twice, even though this is a BEFORE trigger.
create or replace function public.enforce_trip_creation_limit()
returns trigger language plpgsql security definer set search_path = '' as $$
declare actor_id uuid := auth.uid(); next_count bigint; entitled boolean;
begin
  if actor_id is null then raise exception using errcode='28000',detail='MOSS_AUTHENTICATION_REQUIRED'; end if;
  if new.owner_id is distinct from actor_id then raise exception using errcode='42501',detail='MOSS_TRIP_OWNER_MISMATCH'; end if;
  insert into public.trip_creation_events(trip_id,user_id) values(new.id,actor_id)
  on conflict(trip_id) do nothing;
  if not found then return new; end if;
  insert into public.trip_creation_quotas as q(user_id,lifetime_trip_count,updated_at)
  values(actor_id,1,statement_timestamp()) on conflict(user_id) do update
  set lifetime_trip_count=q.lifetime_trip_count+1,updated_at=statement_timestamp()
  returning lifetime_trip_count into next_count;
  entitled := public.has_active_trip_entitlement(actor_id);
  if not entitled and next_count > 2 then raise exception using errcode='MS001',detail='MOSS_TRIP_LIMIT_REACHED'; end if;
  return new;
end $$;

-- Add publication membership in place so an environment configured from the
-- dashboard keeps its replication slots. Dynamic DDL makes this migration
-- safe both for new and already-configured Moss projects.
do $$
declare table_name text;
begin
  if not exists (select 1 from pg_publication where pubname = 'powersync') then
    execute 'create publication powersync';
  end if;
  foreach table_name in array array[
    'profiles','trips','trip_members','itinerary_items',
    'trip_creation_quotas','iap_entitlements'
  ] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname='powersync' and schemaname='public' and tablename=table_name
    ) then
      execute format('alter publication powersync add table public.%I', table_name);
    end if;
  end loop;
end $$;
commit;
