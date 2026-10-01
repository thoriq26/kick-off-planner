-- KickOff Planner: multi-community authentication and data isolation.
-- Run this file in the Supabase SQL editor after reviewing it. It creates new
-- tables; it does not drop the legacy_public_* tables used by the old pages.

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table if not exists public.profiles (
    id uuid primary key references auth.users(id) on delete cascade,
    full_name text not null default '',
    created_at timestamptz not null default now()
);

create table if not exists public.communities (
    id uuid primary key default gen_random_uuid(),
    name text not null check (char_length(trim(name)) between 2 and 80),
    slug text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,47}$'),
    owner_id uuid not null references auth.users(id) on delete cascade,
    created_at timestamptz not null default now()
);

create table if not exists public.community_members (
    community_id uuid not null references public.communities(id) on delete cascade,
    user_id uuid not null references auth.users(id) on delete cascade,
    role text not null default 'member' check (role in ('owner', 'admin', 'member')),
    joined_at timestamptz not null default now(),
    primary key (community_id, user_id)
);

create table if not exists public.community_invites (
    id uuid primary key default gen_random_uuid(),
    community_id uuid not null references public.communities(id) on delete cascade,
    token_hash text not null unique,
    role text not null default 'member' check (role in ('admin', 'member')),
    expires_at timestamptz not null default now() + interval '7 days',
    max_uses integer not null default 1 check (max_uses > 0),
    uses integer not null default 0 check (uses >= 0),
    created_by uuid not null references auth.users(id) on delete cascade,
    created_at timestamptz not null default now(),
    revoked_at timestamptz,
    check (uses <= max_uses)
);

create table if not exists public.community_players (
    id uuid primary key default gen_random_uuid(),
    community_id uuid not null references public.communities(id) on delete cascade,
    user_id uuid not null references auth.users(id) on delete cascade,
    name text not null check (char_length(trim(name)) between 1 and 100),
    position text not null default 'GK' check (position in ('GK', 'CB', 'LB', 'RB', 'LWB', 'RWB', 'DMF', 'CMF', 'AMF', 'LMF', 'RMF', 'LWF', 'RWF', 'SS', 'CF', 'SPECTATOR (FAN)')),
    team text check (team is null or team in ('Red', 'Blue', 'Green', 'Purple')),
    created_at timestamptz not null default now(),
    unique (community_id, user_id)
);

create table if not exists public.community_matches (
    id uuid primary key default gen_random_uuid(),
    community_id uuid not null unique references public.communities(id) on delete cascade,
    event_name text not null default 'TBA',
    nama_lp text not null default 'TBA',
    waktu text,
    jersey text not null default '-',
    htm text not null default '0',
    rekening text not null default '-',
    maps_url text not null default '',
    check (maps_url = '' or maps_url ~ '^https://(www\.google\.com|maps\.google\.com|maps\.app\.goo\.gl|www\.googleusercontent\.com)/'),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.community_event_history (
    id uuid primary key default gen_random_uuid(),
    community_id uuid not null references public.communities(id) on delete cascade,
    event_name text not null,
    location_name text not null,
    match_date text,
    player_list text not null default '-',
    player_count integer not null default 0,
    created_at timestamptz not null default now()
);

create index if not exists community_members_user_idx
    on public.community_members(user_id);
create index if not exists community_invites_community_idx
    on public.community_invites(community_id);
create index if not exists community_players_community_idx
    on public.community_players(community_id);
create index if not exists community_history_community_idx
    on public.community_event_history(community_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Small security-definer helpers used by RLS and invite RPCs
-- ---------------------------------------------------------------------------

create or replace function public.is_community_member(
    target_community uuid,
    target_user uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
    select exists (
        select 1
        from public.community_members
        where community_id = target_community
          and user_id = target_user
    );
$$;

create or replace function public.is_community_admin(
    target_community uuid,
    target_user uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
    select exists (
        select 1
        from public.community_members
        where community_id = target_community
          and user_id = target_user
          and role in ('owner', 'admin')
    );
$$;

create or replace function public.is_community_owner(
    target_community uuid,
    target_user uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
    select exists (
        select 1
        from public.community_members
        where community_id = target_community
          and user_id = target_user
          and role = 'owner'
    );
$$;

revoke all on function public.is_community_member(uuid, uuid) from public, anon;
revoke all on function public.is_community_admin(uuid, uuid) from public, anon;
grant execute on function public.is_community_member(uuid, uuid) to authenticated;
grant execute on function public.is_community_admin(uuid, uuid) to authenticated;
revoke all on function public.is_community_owner(uuid, uuid) from public, anon;
grant execute on function public.is_community_owner(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Auth profile bootstrap
-- ---------------------------------------------------------------------------

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    resolved_name text;
begin
    resolved_name := coalesce(
        nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''),
        nullif(split_part(coalesce(new.email, ''), '@', 1), '')
    );
    insert into public.profiles (id, full_name)
    values (new.id, coalesce(resolved_name, ''))
    on conflict (id) do update set full_name = excluded.full_name;
    return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
    after insert on auth.users
    for each row execute procedure public.handle_new_user();

revoke all on function public.handle_new_user() from public, anon, authenticated;

insert into public.profiles (id, full_name)
select
    id,
    coalesce(
        nullif(trim(raw_user_meta_data ->> 'full_name'), ''),
        nullif(split_part(coalesce(email, ''), '@', 1), ''),
        ''
    )
from auth.users
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- Community and invite RPCs
-- ---------------------------------------------------------------------------

create or replace function public.is_verified_user(target_user uuid)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
    select exists (
        select 1
        from auth.users
        where id = target_user
          and email_confirmed_at is not null
    );
$$;

revoke all on function public.is_verified_user(uuid) from public, anon;
grant execute on function public.is_verified_user(uuid) to authenticated;

create or replace function public.create_community(
    p_name text,
    p_slug text
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    new_community_id uuid;
    clean_name text;
    clean_slug text;
begin
    if auth.uid() is null then
        raise exception 'Authentication required';
    end if;
    if not public.is_verified_user(auth.uid()) then
        raise exception 'Email must be verified before creating a community';
    end if;

    clean_name := trim(coalesce(p_name, ''));
    clean_slug := lower(trim(coalesce(p_slug, '')));

    if char_length(clean_name) < 2 or char_length(clean_name) > 80 then
        raise exception 'Community name must be between 2 and 80 characters';
    end if;
    if clean_slug !~ '^[a-z0-9][a-z0-9-]{1,47}$' then
        raise exception 'Slug must contain lowercase letters, numbers, and hyphens';
    end if;

    insert into public.communities (name, slug, owner_id)
    values (clean_name, clean_slug, auth.uid())
    returning id into new_community_id;

    insert into public.community_members (community_id, user_id, role)
    values (new_community_id, auth.uid(), 'owner');

    insert into public.community_matches (community_id)
    values (new_community_id)
    on conflict (community_id) do nothing;

    return new_community_id;
end;
$$;

create or replace function public.create_community_invite(
    p_community uuid,
    p_role text default 'member',
    p_expires_days integer default 7,
    p_max_uses integer default 1
)
returns table (token text, expires_at timestamptz)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    raw_token text;
    token_expiry timestamptz;
    safe_role text;
    safe_expiry_days integer;
    safe_max_uses integer;
begin
    if not public.is_community_admin(p_community, auth.uid()) then
        raise exception 'Only community admins can create invitations';
    end if;

    safe_role := case when p_role = 'admin' then 'admin' else 'member' end;
    if safe_role = 'admin' and not exists (
        select 1
        from public.community_members
        where community_id = p_community
          and user_id = auth.uid()
          and role = 'owner'
    ) then
        raise exception 'Only the community owner can invite an admin';
    end if;
    safe_expiry_days := greatest(1, least(coalesce(p_expires_days, 7), 30));
    safe_max_uses := greatest(1, least(coalesce(p_max_uses, 1), 100));
    raw_token := encode(extensions.gen_random_bytes(24), 'hex');
    token_expiry := now() + make_interval(days => safe_expiry_days);

    insert into public.community_invites (
        community_id,
        token_hash,
        role,
        expires_at,
        max_uses,
        created_by
    ) values (
        p_community,
        encode(extensions.digest(raw_token, 'sha256'), 'hex'),
        safe_role,
        token_expiry,
        safe_max_uses,
        auth.uid()
    );

    return query select raw_token, token_expiry;
end;
$$;

create or replace function public.list_community_invites(
    p_community uuid
)
returns table (
    id uuid,
    role text,
    expires_at timestamptz,
    uses integer,
    max_uses integer,
    created_at timestamptz
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
    if not public.is_community_admin(p_community, auth.uid()) then
        raise exception 'Only community admins can view invitations';
    end if;

    return query
        select i.id, i.role, i.expires_at, i.uses, i.max_uses, i.created_at
        from public.community_invites i
        where i.community_id = p_community
          and i.revoked_at is null
          and i.expires_at > now()
          and i.uses < i.max_uses
        order by i.created_at desc;
end;
$$;

create or replace function public.revoke_community_invite(
    p_invite uuid
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    invite_community uuid;
begin
    select community_id into invite_community
    from public.community_invites
    where id = p_invite;

    if invite_community is null or not public.is_community_admin(invite_community, auth.uid()) then
        raise exception 'Only community admins can revoke invitations';
    end if;

    update public.community_invites
    set revoked_at = now()
    where id = p_invite;
end;
$$;

revoke all on function public.list_community_invites(uuid) from public, anon;
revoke all on function public.revoke_community_invite(uuid) from public, anon;
grant execute on function public.list_community_invites(uuid) to authenticated;
grant execute on function public.revoke_community_invite(uuid) to authenticated;

create or replace function public.accept_community_invite(
    p_token text
)
returns table (community_id uuid, community_name text, role text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    token_digest text;
    invite_row public.community_invites%rowtype;
    inserted_rows integer;
begin
    if auth.uid() is null then
        raise exception 'Authentication required';
    end if;
    if not public.is_verified_user(auth.uid()) then
        raise exception 'Email must be verified before accepting an invitation';
    end if;
    if p_token is null or char_length(trim(p_token)) < 16 then
        raise exception 'Invitation token is invalid';
    end if;

    token_digest := encode(extensions.digest(trim(p_token), 'sha256'), 'hex');
    select * into invite_row
    from public.community_invites
    where token_hash = token_digest
      and revoked_at is null
      and expires_at > now()
      and uses < max_uses
    for update;

    if not found then
        raise exception 'Invitation is expired, revoked, or already used';
    end if;

    insert into public.community_members (community_id, user_id, role)
    values (invite_row.community_id, auth.uid(), invite_row.role)
    on conflict (community_id, user_id) do nothing;

    get diagnostics inserted_rows = row_count;
    if inserted_rows > 0 then
        update public.community_invites
        set uses = uses + 1
        where id = invite_row.id;
    end if;

    return query
        select c.id, c.name, coalesce(m.role, invite_row.role)
        from public.communities c
        join public.community_members m
          on m.community_id = c.id
         and m.user_id = auth.uid()
        where c.id = invite_row.community_id;
end;
$$;

revoke all on function public.create_community(text, text) from public, anon;
revoke all on function public.create_community_invite(uuid, text, integer, integer) from public, anon;
revoke all on function public.accept_community_invite(text) from public, anon;
grant execute on function public.create_community(text, text) to authenticated;
grant execute on function public.create_community_invite(uuid, text, integer, integer) to authenticated;
grant execute on function public.accept_community_invite(text) to authenticated;

create or replace function public.publish_community_match(
    p_community uuid,
    p_event_name text,
    p_nama_lp text,
    p_waktu text,
    p_jersey text,
    p_htm text,
    p_rekening text,
    p_maps_url text
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    match_id uuid;
    clean_event text;
    clean_location text;
    clean_maps text;
begin
    if not public.is_community_admin(p_community, auth.uid()) then
        raise exception 'Only community admins can publish matches';
    end if;

    clean_event := trim(coalesce(p_event_name, 'TBA'));
    clean_location := trim(coalesce(p_nama_lp, 'TBA'));
    clean_maps := trim(coalesce(p_maps_url, ''));
    if char_length(clean_event) > 120 or char_length(clean_location) > 160 then
        raise exception 'Match details are too long';
    end if;
    if clean_maps <> '' and clean_maps !~ '^https://(www\.google\.com|maps\.google\.com|maps\.app\.goo\.gl|www\.googleusercontent\.com)/' then
        raise exception 'Map URL is not an allowed Google Maps HTTPS URL';
    end if;

    insert into public.community_matches (
        community_id,
        event_name,
        nama_lp,
        waktu,
        jersey,
        htm,
        rekening,
        maps_url,
        updated_at
    ) values (
        p_community,
        clean_event,
        clean_location,
        nullif(trim(coalesce(p_waktu, '')), ''),
        coalesce(nullif(trim(coalesce(p_jersey, '')), ''), '-'),
        coalesce(nullif(trim(coalesce(p_htm, '')), ''), '0'),
        coalesce(nullif(trim(coalesce(p_rekening, '')), ''), '-'),
        clean_maps,
        now()
    )
    on conflict (community_id) do update set
        event_name = excluded.event_name,
        nama_lp = excluded.nama_lp,
        waktu = excluded.waktu,
        jersey = excluded.jersey,
        htm = excluded.htm,
        rekening = excluded.rekening,
        maps_url = excluded.maps_url,
        updated_at = now()
    returning id into match_id;

    return match_id;
end;
$$;

revoke all on function public.publish_community_match(uuid, text, text, text, text, text, text, text) from public, anon;
grant execute on function public.publish_community_match(uuid, text, text, text, text, text, text, text) to authenticated;

create or replace function public.archive_community_match(
    p_community uuid
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    match_row public.community_matches%rowtype;
    archived_players text;
    archived_count integer;
    history_id uuid;
begin
    if not public.is_community_admin(p_community, auth.uid()) then
        raise exception 'Only community admins can archive matches';
    end if;

    select * into match_row
    from public.community_matches
    where community_id = p_community
    for update;

    if not found then
        raise exception 'Current match not found';
    end if;

    select coalesce(string_agg(name, ', ' order by created_at), '-'), count(*)::integer
    into archived_players, archived_count
    from public.community_players
    where community_id = p_community;

    insert into public.community_event_history (
        community_id,
        event_name,
        location_name,
        match_date,
        player_list,
        player_count
    ) values (
        p_community,
        match_row.event_name,
        match_row.nama_lp,
        match_row.waktu,
        archived_players,
        archived_count
    ) returning id into history_id;

    update public.community_matches
    set event_name = 'TBA',
        nama_lp = 'TBA',
        waktu = null,
        jersey = '-',
        htm = '0',
        rekening = '-',
        maps_url = '',
        updated_at = now()
    where community_id = p_community;

    delete from public.community_players where community_id = p_community;
    return history_id;
end;
$$;

revoke all on function public.archive_community_match(uuid) from public, anon;
grant execute on function public.archive_community_match(uuid) to authenticated;

create or replace function public.register_community_player(
    p_community uuid,
    p_name text,
    p_position text
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    player_id uuid;
    clean_name text;
    clean_position text;
begin
    if auth.uid() is null then
        raise exception 'Authentication required';
    end if;
    if not public.is_verified_user(auth.uid()) then
        raise exception 'Email must be verified before registering';
    end if;
    if not public.is_community_member(p_community, auth.uid()) then
        raise exception 'Join the community before registering';
    end if;

    clean_name := trim(coalesce(p_name, ''));
    clean_position := upper(trim(coalesce(p_position, 'GK')));
    if char_length(clean_name) < 1 or char_length(clean_name) > 100 then
        raise exception 'Player name must be between 1 and 100 characters';
    end if;
    if clean_position not in (
        'GK', 'CB', 'LB', 'RB', 'LWB', 'RWB', 'DMF', 'CMF', 'AMF',
        'LMF', 'RMF', 'LWF', 'RWF', 'SS', 'CF', 'SPECTATOR (FAN)'
    ) then
        raise exception 'Invalid player position';
    end if;

    update public.profiles
    set full_name = clean_name
    where id = auth.uid();

    insert into public.community_players (
        community_id, user_id, name, position
    ) values (
        p_community, auth.uid(), clean_name, clean_position
    )
    on conflict (community_id, user_id) do update
        set name = excluded.name,
            position = excluded.position
    returning id into player_id;

    return player_id;
end;
$$;

revoke all on function public.register_community_player(uuid, text, text) from public, anon;
grant execute on function public.register_community_player(uuid, text, text) to authenticated;

create or replace function public.protect_community_player_write()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
    if tg_op = 'INSERT' then
        if not public.is_community_admin(new.community_id, auth.uid()) then
            new.team := null;
        end if;
        return new;
    end if;

    if new.community_id <> old.community_id or new.user_id <> old.user_id then
        raise exception 'Player community and user cannot be changed';
    end if;
    if not public.is_community_admin(old.community_id, auth.uid())
       and new.team is distinct from old.team then
        raise exception 'Only community admins can change team assignments';
    end if;
    return new;
end;
$$;

drop trigger if exists protect_community_player_write on public.community_players;
create trigger protect_community_player_write
    before insert or update on public.community_players
    for each row execute procedure public.protect_community_player_write();

revoke all on function public.protect_community_player_write() from public, anon, authenticated;

create or replace function public.protect_community_member_role()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
    if new.community_id <> old.community_id or new.user_id <> old.user_id then
        raise exception 'Membership identity cannot be changed';
    end if;
    if new.role = 'owner' and not public.is_community_owner(old.community_id, auth.uid()) then
        raise exception 'Only the owner can grant ownership';
    end if;
    if old.role = 'owner' and new.role <> 'owner' and not public.is_community_owner(old.community_id, auth.uid()) then
        raise exception 'Only the owner can change an owner role';
    end if;
    if old.role = 'owner' and new.role <> 'owner'
       and (select count(*) from public.community_members where community_id = old.community_id and role = 'owner') = 1 then
        raise exception 'A community must keep at least one owner';
    end if;
    return new;
end;
$$;

drop trigger if exists protect_community_member_role on public.community_members;
create trigger protect_community_member_role
    before update on public.community_members
    for each row execute procedure public.protect_community_member_role();

revoke all on function public.protect_community_member_role() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------

alter table public.profiles enable row level security;
alter table public.communities enable row level security;
alter table public.community_members enable row level security;
alter table public.community_invites enable row level security;
alter table public.community_players enable row level security;
alter table public.community_matches enable row level security;
alter table public.community_event_history enable row level security;

-- Profiles: a user can maintain their own profile and see names of people in
-- their communities (the table intentionally contains no email or auth data).
drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own on public.profiles
    for select to authenticated
    using (id = auth.uid());
drop policy if exists profiles_select_community on public.profiles;
create policy profiles_select_community on public.profiles
    for select to authenticated
    using (
        exists (
            select 1
            from public.community_members mine
            join public.community_members theirs on theirs.user_id = profiles.id
            where mine.user_id = auth.uid()
              and mine.community_id = theirs.community_id
        )
    );
drop policy if exists profiles_insert_own on public.profiles;
create policy profiles_insert_own on public.profiles
    for insert to authenticated
    with check (id = auth.uid());
drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles
    for update to authenticated
    using (id = auth.uid())
    with check (id = auth.uid());

-- Communities are visible only to their members; creation is self-service.
drop policy if exists communities_select_members on public.communities;
create policy communities_select_members on public.communities
    for select to authenticated
    using (public.is_community_member(id, auth.uid()));
-- Community creation is atomic through create_community; no direct insert policy.
drop policy if exists communities_update_admin on public.communities;
create policy communities_update_admin on public.communities
    for update to authenticated
    using (public.is_community_owner(id, auth.uid()))
    with check (public.is_community_owner(id, auth.uid()));
drop policy if exists communities_delete_owner on public.communities;
create policy communities_delete_owner on public.communities
    for delete to authenticated
    using (public.is_community_owner(id, auth.uid()));

-- Membership rows are readable by members. Changes go through the RPCs or
-- explicit admin actions; direct privilege escalation is not allowed.
drop policy if exists members_select_members on public.community_members;
create policy members_select_members on public.community_members
    for select to authenticated
    using (public.is_community_member(community_id, auth.uid()));
-- New memberships are inserted only by create_community/accept_community_invite;
-- there is no direct member insert policy.
drop policy if exists members_update_admin on public.community_members;
create policy members_update_admin on public.community_members
    for update to authenticated
    using (public.is_community_admin(community_id, auth.uid()))
    with check (
        public.is_community_admin(community_id, auth.uid())
        and (role <> 'owner' or public.is_community_owner(community_id, auth.uid()))
    );
drop policy if exists members_delete_self_or_admin on public.community_members;
create policy members_delete_self_or_admin on public.community_members
    for delete to authenticated
    using (user_id = auth.uid() or public.is_community_admin(community_id, auth.uid()));

-- Invites are visible/manageable by community admins only. The raw token is
-- returned once by create_community_invite; only its digest is stored.
drop policy if exists invites_select_admin on public.community_invites;
create policy invites_select_admin on public.community_invites
    for select to authenticated
    using (public.is_community_admin(community_id, auth.uid()));
drop policy if exists invites_insert_admin on public.community_invites;
create policy invites_insert_admin on public.community_invites
    for insert to authenticated
    with check (public.is_community_admin(community_id, auth.uid()));
drop policy if exists invites_update_admin on public.community_invites;
create policy invites_update_admin on public.community_invites
    for update to authenticated
    using (public.is_community_admin(community_id, auth.uid()))
    with check (public.is_community_admin(community_id, auth.uid()));
drop policy if exists invites_delete_admin on public.community_invites;
create policy invites_delete_admin on public.community_invites
    for delete to authenticated
    using (public.is_community_admin(community_id, auth.uid()));

-- A member can register themselves; an admin can manage any registered member
-- of the same community.
drop policy if exists players_select_members on public.community_players;
create policy players_select_members on public.community_players
    for select to authenticated
    using (public.is_community_member(community_id, auth.uid()));
drop policy if exists players_insert_member_or_admin on public.community_players;
create policy players_insert_member_or_admin on public.community_players
    for insert to authenticated
    with check (
        public.is_community_member(community_id, auth.uid())
        and exists (
            select 1
            from public.community_members target_member
            where target_member.community_id = community_players.community_id
              and target_member.user_id = community_players.user_id
        )
        and (user_id = auth.uid() or public.is_community_admin(community_id, auth.uid()))
    );
drop policy if exists players_update_owner_or_admin on public.community_players;
create policy players_update_owner_or_admin on public.community_players
    for update to authenticated
    using (user_id = auth.uid() or public.is_community_admin(community_id, auth.uid()))
    with check (user_id = auth.uid() or public.is_community_admin(community_id, auth.uid()));
drop policy if exists players_delete_owner_or_admin on public.community_players;
create policy players_delete_owner_or_admin on public.community_players
    for delete to authenticated
    using (user_id = auth.uid() or public.is_community_admin(community_id, auth.uid()));

-- Match details and archives are read-only for members and writable by admins.
drop policy if exists matches_select_members on public.community_matches;
create policy matches_select_members on public.community_matches
    for select to authenticated
    using (public.is_community_member(community_id, auth.uid()));
drop policy if exists matches_insert_admin on public.community_matches;
create policy matches_insert_admin on public.community_matches
    for insert to authenticated
    with check (public.is_community_admin(community_id, auth.uid()));
drop policy if exists matches_update_admin on public.community_matches;
create policy matches_update_admin on public.community_matches
    for update to authenticated
    using (public.is_community_admin(community_id, auth.uid()))
    with check (public.is_community_admin(community_id, auth.uid()));
drop policy if exists matches_delete_admin on public.community_matches;
create policy matches_delete_admin on public.community_matches
    for delete to authenticated
    using (public.is_community_admin(community_id, auth.uid()));

drop policy if exists history_select_members on public.community_event_history;
create policy history_select_members on public.community_event_history
    for select to authenticated
    using (public.is_community_member(community_id, auth.uid()));
drop policy if exists history_insert_admin on public.community_event_history;
create policy history_insert_admin on public.community_event_history
    for insert to authenticated
    with check (public.is_community_admin(community_id, auth.uid()));
drop policy if exists history_delete_admin on public.community_event_history;
create policy history_delete_admin on public.community_event_history
    for delete to authenticated
    using (public.is_community_admin(community_id, auth.uid()));

-- ---------------------------------------------------------------------------
-- Grants. The browser receives the anon key only and is restricted by RLS.
-- ---------------------------------------------------------------------------

revoke all on public.profiles, public.communities, public.community_members,
    public.community_invites, public.community_players, public.community_matches,
    public.community_event_history from anon;
grant select, insert, update, delete on public.profiles, public.communities,
    public.community_members, public.community_players,
    public.community_matches, public.community_event_history to authenticated;
revoke insert on public.communities, public.community_members from authenticated;
revoke all on public.community_invites from public, anon, authenticated;

-- Legacy tables are no longer used by the application. Revoke browser access if
-- they already exist; this migration intentionally does not drop their data.
do $$
declare
    table_name text;
begin
    foreach table_name in array array['pemain', 'jadwal_lapangan', 'event_history', 'admin_settings']
    loop
        if to_regclass('public.' || table_name) is not null then
            execute format('revoke all on public.%I from anon, authenticated', table_name);
            execute format('alter table public.%I enable row level security', table_name);
        end if;
    end loop;
end;
$$;
