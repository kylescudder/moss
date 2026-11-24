-- Invites wait for the invitee. Sharing never adds anyone directly: every
-- invite is pending, the API emails the invitee, and they accept or decline it
-- in the app while signed in with a verified account for that email address.

drop trigger if exists auth_user_share_invites on public.auth_user;
drop function if exists public.accept_share_invites();

create or replace function public.share_display_name(p_user_id uuid) returns text
language sql stable security definer set search_path = '' as $$
  select coalesce(
    nullif(btrim(p.display_name), ''),
    nullif(btrim(u.name), ''),
    nullif(split_part(u.email, '@', 1), ''),
    'Someone'
  )
  from public.auth_user u
  left join public.profiles p on p.id = u.id
  where u.id = p_user_id
$$;
revoke all on function public.share_display_name(uuid) from public;

-- The caller's verified email, or null.
create or replace function public.request_verified_email() returns text
language sql stable security definer set search_path = '' as $$
  select lower(email) from public.auth_user
  where id = public.request_user_id() and email_verified
$$;
revoke all on function public.request_verified_email() from public;

-- Returns the details the API needs to email the invitee; the API sends the
-- app only `status`.
create or replace function public.share_invite(p_space text, p_space_id uuid, p_email text, p_role text)
returns json
language plpgsql security definer set search_path = '' as $$
declare
  me uuid := public.request_user_id();
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_target text;
begin
  perform public.require_share_owner(p_space, p_space_id);
  if p_role is null or p_role not in ('editor', 'viewer') then
    raise exception using errcode = 'MX006', message = 'Choose Editor or Viewer.';
  end if;
  if length(v_email) > 320 or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+$' then
    raise exception using errcode = 'MX006', message = 'Enter the email address they use to sign in.';
  end if;
  if exists (select 1 from public.auth_user where id = me and lower(email) = v_email) then
    raise exception using errcode = 'MX006', message = 'That''s your own email address.';
  end if;
  if exists (
    select 1 from public.auth_user u
    where lower(u.email) = v_email and u.email_verified
      and (
        (p_space = 'trip' and exists (
          select 1 from public.trip_members m where m.trip_id = p_space_id and m.user_id = u.id))
        or (p_space = 'library' and exists (
          select 1 from public.library_members m where m.library_id = p_space_id and m.user_id = u.id))
      )
  ) then
    raise exception using errcode = 'MX006', message = 'They already have access.';
  end if;
  -- Each invite sends an email, so one account can send only so many a day.
  if (
    select count(*) from (
      select 1 from public.trip_pending_invites
      where invited_by = me and created_at > statement_timestamp() - interval '1 day'
      union all
      select 1 from public.library_pending_invites
      where invited_by = me and created_at > statement_timestamp() - interval '1 day'
    ) recent
  ) >= 50 then
    raise exception using errcode = 'MX006', message = 'You''ve sent a lot of invites today. Try again tomorrow.';
  end if;

  if p_space = 'trip' then
    insert into public.trip_pending_invites (trip_id, email, role, invited_by)
    values (p_space_id, v_email, p_role, me)
    on conflict (trip_id, email) do update
      set role = excluded.role, invited_by = excluded.invited_by,
          accepted_at = null, created_at = statement_timestamp();
    select 'the trip “' || title || '”' into v_target from public.trips where id = p_space_id;
  else
    insert into public.library_pending_invites (library_id, email, role, invited_by)
    values (p_space_id, v_email, p_role, me)
    on conflict (library_id, email) do update
      set role = excluded.role, invited_by = excluded.invited_by,
          accepted_at = null, created_at = statement_timestamp();
    v_target := 'all their trips';
  end if;
  return json_build_object(
    'status', 'pending',
    'email', v_email,
    'inviter', public.share_display_name(me),
    'target', v_target
  );
end $$;
revoke all on function public.share_invite(text, uuid, text, text) from public;

-- Open invites sent to the caller's verified email.
create or replace function public.share_incoming(p_space text)
returns table (id uuid, space_id uuid, space_name text, inviter_name text, role text, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare v_email text := public.request_verified_email();
begin
  if v_email is null then return; end if;
  if p_space = 'trip' then
    return query
    select i.id, i.trip_id, t.title, public.share_display_name(i.invited_by), i.role, i.created_at
    from public.trip_pending_invites i
    join public.trips t on t.id = i.trip_id and t.deleted_at is null
    where i.email = v_email and i.accepted_at is null
    order by i.created_at desc;
  elsif p_space = 'library' then
    return query
    select i.id, i.library_id,
      'All of ' || public.share_display_name(i.library_id) || '''s trips',
      public.share_display_name(i.invited_by), i.role, i.created_at
    from public.library_pending_invites i
    where i.email = v_email and i.accepted_at is null
    order by i.created_at desc;
  else
    raise exception using errcode = 'MX006', message = 'This can''t be shared.';
  end if;
end $$;
revoke all on function public.share_incoming(text) from public;

create or replace function public.share_accept(p_space text, p_invite_id uuid)
returns json
language plpgsql security definer set search_path = '' as $$
declare
  me uuid := public.request_user_id();
  v_email text := public.request_verified_email();
  v_space uuid;
  v_role text;
  v_inviter uuid;
begin
  if p_space = 'trip' then
    select i.trip_id, i.role, i.invited_by into v_space, v_role, v_inviter
    from public.trip_pending_invites i
    join public.trips t on t.id = i.trip_id and t.deleted_at is null
    where i.id = p_invite_id and i.email = v_email and i.accepted_at is null
    for update of i;
  elsif p_space = 'library' then
    select i.library_id, i.role, i.invited_by into v_space, v_role, v_inviter
    from public.library_pending_invites i
    where i.id = p_invite_id and i.email = v_email and i.accepted_at is null
    for update;
  else
    raise exception using errcode = 'MX006', message = 'This can''t be shared.';
  end if;
  if me is null or v_email is null or v_space is null then
    raise exception using errcode = 'MX006', message = 'This invite is no longer available.';
  end if;

  if p_space = 'trip' then
    insert into public.trip_members (trip_id, user_id, role, invited_by)
    values (v_space, me, v_role, v_inviter)
    on conflict (trip_id, user_id) do update set role = excluded.role
    where public.trip_members.role <> 'owner';
    update public.trip_pending_invites set accepted_at = statement_timestamp() where id = p_invite_id;
  else
    insert into public.library_members (library_id, user_id, role, invited_by)
    values (v_space, me, v_role, v_inviter)
    on conflict (library_id, user_id) do update set role = excluded.role
    where public.library_members.role <> 'owner';
    update public.library_pending_invites set accepted_at = statement_timestamp() where id = p_invite_id;
  end if;
  return json_build_object('status', 'accepted', 'space_id', v_space);
end $$;
revoke all on function public.share_accept(text, uuid) from public;

create or replace function public.share_decline(p_space text, p_invite_id uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_email text := public.request_verified_email();
begin
  if p_space = 'trip' then
    delete from public.trip_pending_invites
    where id = p_invite_id and email = v_email and accepted_at is null;
  elsif p_space = 'library' then
    delete from public.library_pending_invites
    where id = p_invite_id and email = v_email and accepted_at is null;
  else
    raise exception using errcode = 'MX006', message = 'This can''t be shared.';
  end if;
end $$;
revoke all on function public.share_decline(text, uuid) from public;

grant execute on function
  public.share_incoming(text),
  public.share_accept(text, uuid),
  public.share_decline(text, uuid)
to moss_api;
