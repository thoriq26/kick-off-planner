-- Admin member management: activate/deactivate and remove community members.
-- Apply after 20260924030000_invite_usage_audit.sql.

alter table public.community_members
    add column if not exists is_active boolean not null default true;
alter table public.community_members
    add column if not exists updated_at timestamptz not null default now();

create index if not exists community_members_community_idx
    on public.community_members (community_id, is_active);

-- An inactive member keeps the membership row but loses all community access.
-- The community itself must remain visible so the owner can still manage it.
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
          and is_active
    );
$$;

revoke all on function public.is_community_member(uuid, uuid) from public, anon;
grant execute on function public.is_community_member(uuid, uuid) to authenticated;

-- Owners and admins stay reachable even when deactivated, otherwise a
-- community could end up with no one able to restore access.
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
          and is_active
    );
$$;

revoke all on function public.is_community_admin(uuid, uuid) from public, anon;
grant execute on function public.is_community_admin(uuid, uuid) to authenticated;

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
          and is_active
    );
$$;

revoke all on function public.is_community_owner(uuid, uuid) from public, anon;
grant execute on function public.is_community_owner(uuid, uuid) to authenticated;

-- The trigger must also carry is_active so status changes are audited the same
-- way role changes are.
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
    new.updated_at := now();
    return new;
end;
$$;

-- Never deactivate the last active owner of a community.
create or replace function public.set_community_member_status(
    p_community uuid,
    p_user uuid,
    p_active boolean
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    target_role text;
begin
    if not public.is_community_admin(p_community, auth.uid()) then
        raise exception 'Only community admins can change member status';
    end if;
    if p_user = auth.uid() then
        raise exception 'You cannot change your own status';
    end if;

    select role into target_role
    from public.community_members
    where community_id = p_community and user_id = p_user;

    if target_role is null then
        raise exception 'Member is not part of this community';
    end if;

    if not p_active and target_role = 'owner' then
        if (select count(*) from public.community_members
             where community_id = p_community and role = 'owner' and is_active) <= 1 then
            raise exception 'A community must keep at least one active owner';
        end if;
    end if;

    update public.community_members
    set is_active = p_active
    where community_id = p_community and user_id = p_user;
end;
$$;

-- Removes the membership and its player rows. The auth account itself is left
-- untouched so the person can still sign in and rejoin with a new invite.
create or replace function public.remove_community_member(
    p_community uuid,
    p_user uuid
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    target_role text;
begin
    if not public.is_community_admin(p_community, auth.uid()) then
        raise exception 'Only community admins can remove members';
    end if;
    if p_user = auth.uid() then
        raise exception 'You cannot remove yourself';
    end if;

    select role into target_role
    from public.community_members
    where community_id = p_community and user_id = p_user;

    if target_role is null then
        raise exception 'Member is not part of this community';
    end if;

    if target_role = 'owner'
       and (select count(*) from public.community_members
             where community_id = p_community and role = 'owner') <= 1 then
        raise exception 'A community must keep at least one owner';
    end if;

    delete from public.community_players
    where community_id = p_community and user_id = p_user;

    delete from public.community_members
    where community_id = p_community and user_id = p_user;
end;
$$;

-- Admin-only member list including email, used by the Undangan tab.
create or replace function public.list_community_members(p_community uuid)
returns setof jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
    if not public.is_community_admin(p_community, auth.uid()) then
        raise exception 'Only community admins can view the member list';
    end if;

    return query
        select jsonb_build_object(
            'user_id', m.user_id,
            'full_name', coalesce(pr.full_name, ''),
            'email', coalesce(a.email, ''),
            'role', m.role,
            'is_active', m.is_active,
            'joined_at', m.joined_at
        )
        from public.community_members m
        join auth.users a on a.id = m.user_id
        left join public.profiles pr on pr.id = m.user_id
        where m.community_id = p_community
        order by m.role = 'owner' desc,
                 m.role = 'admin' desc,
                 m.joined_at asc;
end;
$$;

revoke all on function public.set_community_member_status(uuid, uuid, boolean) from public, anon;
revoke all on function public.remove_community_member(uuid, uuid) from public, anon;
revoke all on function public.list_community_members(uuid) from public, anon;

grant execute on function public.set_community_member_status(uuid, uuid, boolean) to authenticated;
grant execute on function public.remove_community_member(uuid, uuid) to authenticated;
grant execute on function public.list_community_members(uuid) to authenticated;