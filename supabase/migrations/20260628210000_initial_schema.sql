create extension if not exists "pgcrypto";

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.trips (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  title text not null,
  destination text not null,
  starts_at timestamptz,
  ends_at timestamptz,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table public.trip_members (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'viewer' check (role in ('owner', 'editor', 'viewer')),
  created_at timestamptz not null default now(),
  unique (trip_id, user_id)
);

create table public.itinerary_items (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete cascade,
  kind text not null default 'activity' check (kind in ('flight', 'lodging', 'food', 'activity', 'transport', 'note')),
  title text not null,
  location_name text,
  starts_at timestamptz,
  ends_at timestamptz,
  notes text,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table public.device_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  token text not null,
  platform text not null default 'ios',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, token)
);

create table public.iap_entitlements (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  product_id text not null,
  original_transaction_id text,
  transaction_id text,
  status text not null default 'unknown' check (status in ('active', 'expired', 'revoked', 'unknown')),
  environment text,
  expires_at timestamptz,
  revoked_at timestamptz,
  last_signed_transaction text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, product_id)
);

create index trips_owner_id_idx on public.trips(owner_id);
create index itinerary_items_trip_id_idx on public.itinerary_items(trip_id);
create index trip_members_user_id_idx on public.trip_members(user_id);
create index device_tokens_user_id_idx on public.device_tokens(user_id);
create index iap_entitlements_user_id_idx on public.iap_entitlements(user_id);
create index iap_entitlements_status_idx on public.iap_entitlements(status, expires_at);

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function public.set_updated_at();

create trigger trips_set_updated_at
before update on public.trips
for each row execute function public.set_updated_at();

create trigger itinerary_items_set_updated_at
before update on public.itinerary_items
for each row execute function public.set_updated_at();

create trigger device_tokens_set_updated_at
before update on public.device_tokens
for each row execute function public.set_updated_at();

create trigger iap_entitlements_set_updated_at
before update on public.iap_entitlements
for each row execute function public.set_updated_at();

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email, '@', 1)))
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

create or replace function public.is_trip_member(target_trip_id uuid)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.trip_members
    where trip_id = target_trip_id
      and user_id = auth.uid()
  );
$$;

alter table public.profiles enable row level security;
alter table public.trips enable row level security;
alter table public.trip_members enable row level security;
alter table public.itinerary_items enable row level security;
alter table public.device_tokens enable row level security;
alter table public.iap_entitlements enable row level security;

create policy "profiles read own" on public.profiles
for select using (id = auth.uid());

create policy "profiles update own" on public.profiles
for update using (id = auth.uid()) with check (id = auth.uid());

create policy "trips read own or member" on public.trips
for select using (owner_id = auth.uid() or public.is_trip_member(id));

create policy "trips insert own" on public.trips
for insert with check (owner_id = auth.uid());

create policy "trips update own" on public.trips
for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());

create policy "trip members read related" on public.trip_members
for select using (
  user_id = auth.uid()
  or exists (
    select 1 from public.trips
    where trips.id = trip_members.trip_id
      and trips.owner_id = auth.uid()
  )
);

create policy "trip members manage owner" on public.trip_members
for all using (
  exists (
    select 1 from public.trips
    where trips.id = trip_members.trip_id
      and trips.owner_id = auth.uid()
  )
) with check (
  exists (
    select 1 from public.trips
    where trips.id = trip_members.trip_id
      and trips.owner_id = auth.uid()
  )
);

create policy "items read related" on public.itinerary_items
for select using (
  owner_id = auth.uid()
  or exists (
    select 1 from public.trips
    where trips.id = itinerary_items.trip_id
      and (trips.owner_id = auth.uid() or public.is_trip_member(trips.id))
  )
);

create policy "items insert related" on public.itinerary_items
for insert with check (
  owner_id = auth.uid()
  and exists (
    select 1 from public.trips
    where trips.id = itinerary_items.trip_id
      and trips.owner_id = auth.uid()
  )
);

create policy "items update owner" on public.itinerary_items
for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());

create policy "device tokens manage own" on public.device_tokens
for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "entitlements read own" on public.iap_entitlements
for select using (user_id = auth.uid());

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from auth.users where id = auth.uid();
end;
$$;
