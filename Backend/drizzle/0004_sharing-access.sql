-- Sharing access. A person can read a trip they own, a trip they are a member
-- of, or any trip of an account whose library they are a member of. Owners
-- and editors change the trip and its itinerary; only the owner deletes it
-- or changes who it is shared with. Membership tables are written only by the
-- definer functions below; the API role cannot touch them directly.

create or replace function public.request_user_id() returns uuid
language sql stable set search_path = '' as $$
  select nullif(current_setting('moss.user_id', true), '')::uuid
$$;

-- The caller's strongest role on a trip, or null when they cannot see it.
create or replace function public.trip_role(p_trip_id uuid) returns text
language sql stable security definer set search_path = '' as $$
  select case
    when t.owner_id = me.id then 'owner'
    else (
      select r.role from (
        select m.role from public.trip_members m
        where m.trip_id = t.id and m.user_id = me.id
        union all
        select l.role from public.library_members l
        where l.library_id = t.owner_id and l.user_id = me.id
      ) r
      order by case r.role when 'owner' then 3 when 'editor' then 2 else 1 end desc
      limit 1
    )
  end
  from public.trips t, (select public.request_user_id() as id) me
  where t.id = p_trip_id and me.id is not null
$$;

create or replace function public.can_read_trip(p_trip_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.trip_role(p_trip_id) is not null
$$;

create or replace function public.can_edit_trip(p_trip_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(public.trip_role(p_trip_id) in ('owner', 'editor'), false)
$$;

-- Trips: members read, editors change, the owner inserts and deletes.
drop policy if exists own_rows on public.trips;
create policy trips_select on public.trips for select to moss_api
  using (public.can_read_trip(id));
create policy trips_insert on public.trips for insert to moss_api
  with check (owner_id = public.request_user_id());
create policy trips_update on public.trips for update to moss_api
  using (public.can_edit_trip(id)) with check (public.can_edit_trip(id));
create policy trips_delete on public.trips for delete to moss_api
  using (owner_id = public.request_user_id());

create or replace function public.guard_shared_trip_update() returns trigger
language plpgsql set search_path = '' as $$ begin
  if new.owner_id is distinct from old.owner_id then
    raise exception using errcode = 'MX003', message = 'trip owner cannot change';
  end if;
  if new.deleted_at is distinct from old.deleted_at
     and public.request_user_id() is not null
     and old.owner_id is distinct from public.request_user_id() then
    raise exception using errcode = 'MX003', message = 'only the owner can delete a trip';
  end if;
  return new;
end $$;
revoke all on function public.guard_shared_trip_update() from public;
create trigger trips_guard_shared_update before update on public.trips
for each row execute function public.guard_shared_trip_update();

-- Itinerary items belong to the trip's owner whoever adds them, so they sync
-- to everyone the trip is shared with.
drop policy if exists own_rows on public.itinerary_items;
create policy itinerary_items_select on public.itinerary_items for select to moss_api
  using (public.can_read_trip(trip_id));
create policy itinerary_items_insert on public.itinerary_items for insert to moss_api
  with check (public.can_edit_trip(trip_id));
create policy itinerary_items_update on public.itinerary_items for update to moss_api
  using (public.can_edit_trip(trip_id)) with check (public.can_edit_trip(trip_id));
create policy itinerary_items_delete on public.itinerary_items for delete to moss_api
  using (public.can_edit_trip(trip_id));

-- Runs as the request role, so RLS limits the lookup to trips the caller can see.
create or replace function public.check_itinerary_trip_owner() returns trigger
language plpgsql set search_path = '' as $$ begin
  if not exists (
    select 1 from public.trips where id = new.trip_id and owner_id = new.owner_id
  ) or (public.request_user_id() is not null and not public.can_edit_trip(new.trip_id))
  then raise exception using errcode='MX003', message='trip is unavailable'; end if;
  return new;
end $$;

-- Every trip and every library has an owner row.
create or replace function public.initialize_trip_owner() returns trigger
language plpgsql security definer set search_path = '' as $$ begin
  insert into public.trip_members (trip_id, user_id, role, invited_by)
  values (new.id, new.owner_id, 'owner', new.owner_id)
  on conflict do nothing;
  return new;
end $$;
revoke all on function public.initialize_trip_owner() from public;
create trigger trips_initialize_owner after insert on public.trips
for each row execute function public.initialize_trip_owner();

create or replace function public.initialize_library_owner() returns trigger
language plpgsql security definer set search_path = '' as $$ begin
  insert into public.library_members (library_id, user_id, role, invited_by)
  values (new.id, new.id, 'owner', new.id)
  on conflict do nothing;
  return new;
end $$;
revoke all on function public.initialize_library_owner() from public;
create trigger profiles_initialize_library after insert on public.profiles
for each row execute function public.initialize_library_owner();

insert into public.trip_members (trip_id, user_id, role, invited_by)
select id, owner_id, 'owner', owner_id from public.trips
on conflict do nothing;
insert into public.library_members (library_id, user_id, role, invited_by)
select id, id, 'owner', id from public.profiles
on conflict do nothing;

-- Sharing actions. Errors use MX006 (invalid request) and MX007 (not the
-- owner) with messages the app shows as they are.
create or replace function public.require_share_owner(p_space text, p_space_id uuid) returns void
language plpgsql stable security definer set search_path = '' as $$
declare me uuid := public.request_user_id();
begin
  if me is null then
    raise exception using errcode = 'MX002', message = 'authentication required';
  end if;
  if p_space = 'trip' then
    if not exists (
      select 1 from public.trips
      where id = p_space_id and owner_id = me and deleted_at is null
    ) then
      raise exception using errcode = 'MX007', message = 'Only the trip''s owner can change who it''s shared with.';
    end if;
  elsif p_space = 'library' then
    if p_space_id is distinct from me then
      raise exception using errcode = 'MX007', message = 'Only you can change who sees all your trips.';
    end if;
  else
    raise exception using errcode = 'MX006', message = 'This can''t be shared.';
  end if;
end $$;
revoke all on function public.require_share_owner(text, uuid) from public;

create or replace function public.share_invite(p_space text, p_space_id uuid, p_email text, p_role text)
returns json
language plpgsql security definer set search_path = '' as $$
declare
  me uuid := public.request_user_id();
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_user uuid;
begin
  perform public.require_share_owner(p_space, p_space_id);
  if p_role is null or p_role not in ('editor', 'viewer') then
    raise exception using errcode = 'MX006', message = 'Choose Editor or Viewer.';
  end if;
  if length(v_email) > 320 or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+$' then
    raise exception using errcode = 'MX006', message = 'Enter the email address they use to sign in.';
  end if;

  select u.id into v_user
  from public.auth_user u
  join public.profiles p on p.id = u.id
  where lower(u.email) = v_email and u.email_verified
  limit 1;

  if v_user = me then
    raise exception using errcode = 'MX006', message = 'That''s your own email address.';
  end if;

  if v_user is not null then
    if p_space = 'trip' then
      insert into public.trip_members (trip_id, user_id, role, invited_by)
      values (p_space_id, v_user, p_role, me)
      on conflict (trip_id, user_id) do update set role = excluded.role
      where public.trip_members.role <> 'owner';
    else
      insert into public.library_members (library_id, user_id, role, invited_by)
      values (p_space_id, v_user, p_role, me)
      on conflict (library_id, user_id) do update set role = excluded.role
      where public.library_members.role <> 'owner';
    end if;
    return json_build_object('status', 'added');
  end if;

  if p_space = 'trip' then
    insert into public.trip_pending_invites (trip_id, email, role, invited_by)
    values (p_space_id, v_email, p_role, me)
    on conflict (trip_id, email) do update
      set role = excluded.role, invited_by = excluded.invited_by,
          accepted_at = null, created_at = statement_timestamp();
  else
    insert into public.library_pending_invites (library_id, email, role, invited_by)
    values (p_space_id, v_email, p_role, me)
    on conflict (library_id, email) do update
      set role = excluded.role, invited_by = excluded.invited_by,
          accepted_at = null, created_at = statement_timestamp();
  end if;
  return json_build_object('status', 'pending');
end $$;
revoke all on function public.share_invite(text, uuid, text, text) from public;

-- Owners remove anyone else; members remove themselves. Owner rows stay.
create or replace function public.share_remove_member(p_space text, p_space_id uuid, p_user_id uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare me uuid := public.request_user_id();
begin
  if me is null then
    raise exception using errcode = 'MX002', message = 'authentication required';
  end if;
  if p_space not in ('trip', 'library') then
    raise exception using errcode = 'MX006', message = 'This can''t be shared.';
  end if;
  if p_user_id is distinct from me then
    perform public.require_share_owner(p_space, p_space_id);
  end if;
  if p_space = 'trip' then
    delete from public.trip_members
    where trip_id = p_space_id and user_id = p_user_id and role <> 'owner';
  else
    delete from public.library_members
    where library_id = p_space_id and user_id = p_user_id and role <> 'owner';
  end if;
end $$;
revoke all on function public.share_remove_member(text, uuid, uuid) from public;

create or replace function public.share_revoke_invite(p_space text, p_invite_id uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare me uuid := public.request_user_id();
begin
  if me is null then
    raise exception using errcode = 'MX002', message = 'authentication required';
  end if;
  if p_space = 'trip' then
    delete from public.trip_pending_invites i
    using public.trips t
    where i.id = p_invite_id and t.id = i.trip_id and t.owner_id = me;
  elsif p_space = 'library' then
    delete from public.library_pending_invites
    where id = p_invite_id and library_id = me;
  else
    raise exception using errcode = 'MX006', message = 'This can''t be shared.';
  end if;
end $$;
revoke all on function public.share_revoke_invite(text, uuid) from public;

-- Names of a space's members, for its members only.
create or replace function public.share_member_profiles(p_space text, p_space_id uuid)
returns table (id uuid, display_name text)
language plpgsql stable security definer set search_path = '' as $$
declare me uuid := public.request_user_id();
begin
  if p_space = 'trip' then
    return query
    select p.id, coalesce(
      nullif(btrim(p.display_name), ''),
      nullif(btrim(u.name), ''),
      nullif(split_part(u.email, '@', 1), '')
    )
    from public.trip_members m
    join public.profiles p on p.id = m.user_id
    join public.auth_user u on u.id = m.user_id
    where m.trip_id = p_space_id
      and exists (
        select 1 from public.trip_members s
        where s.trip_id = p_space_id and s.user_id = me
      )
    order by m.joined_at;
  elsif p_space = 'library' then
    return query
    select p.id, coalesce(
      nullif(btrim(p.display_name), ''),
      nullif(btrim(u.name), ''),
      nullif(split_part(u.email, '@', 1), '')
    )
    from public.library_members m
    join public.profiles p on p.id = m.user_id
    join public.auth_user u on u.id = m.user_id
    where m.library_id = p_space_id
      and exists (
        select 1 from public.library_members s
        where s.library_id = p_space_id and s.user_id = me
      )
    order by m.joined_at;
  else
    raise exception using errcode = 'MX006', message = 'This can''t be shared.';
  end if;
end $$;
revoke all on function public.share_member_profiles(text, uuid) from public;

-- An invite is accepted once its email belongs to a verified account, so an
-- unverified sign-up with someone else's address never joins anything.
create or replace function public.accept_share_invites() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_email text := lower(new.email);
begin
  if not new.email_verified
     or not exists (select 1 from public.profiles where id = new.id) then
    return new;
  end if;
  insert into public.trip_members (trip_id, user_id, role, invited_by)
  select i.trip_id, new.id, i.role, i.invited_by
  from public.trip_pending_invites i
  where i.email = v_email and i.accepted_at is null
  on conflict do nothing;
  update public.trip_pending_invites set accepted_at = statement_timestamp()
  where email = v_email and accepted_at is null;
  insert into public.library_members (library_id, user_id, role, invited_by)
  select i.library_id, new.id, i.role, i.invited_by
  from public.library_pending_invites i
  where i.email = v_email and i.accepted_at is null
  on conflict do nothing;
  update public.library_pending_invites set accepted_at = statement_timestamp()
  where email = v_email and accepted_at is null;
  return new;
end $$;
revoke all on function public.accept_share_invites() from public;
-- Fires after auth_user_profile, which creates the profile.
create trigger auth_user_share_invites
after insert or update of email_verified, email on public.auth_user
for each row execute function public.accept_share_invites();

alter table public.trip_members enable row level security;
alter table public.trip_pending_invites enable row level security;
alter table public.library_members enable row level security;
alter table public.library_pending_invites enable row level security;
revoke all on public.trip_members, public.trip_pending_invites,
  public.library_members, public.library_pending_invites from public, moss_api;

revoke all on function
  public.request_user_id(),
  public.trip_role(uuid),
  public.can_read_trip(uuid),
  public.can_edit_trip(uuid)
from public;
grant execute on function
  public.request_user_id(),
  public.trip_role(uuid),
  public.can_read_trip(uuid),
  public.can_edit_trip(uuid),
  public.share_invite(text, uuid, text, text),
  public.share_remove_member(text, uuid, uuid),
  public.share_revoke_invite(text, uuid),
  public.share_member_profiles(text, uuid)
to moss_api;

do $$ declare t text; begin
  foreach t in array array['trip_members','trip_pending_invites','library_members','library_pending_invites'] loop
    execute format('create trigger recovery_before before insert or update or delete on public.%I for each statement execute function public.guard_recoverable_mutation()', t);
    execute format('create constraint trigger recovery_commit after insert or update or delete on public.%I deferrable initially deferred for each row execute function public.guard_recoverable_mutation()', t);
  end loop;
end $$;
