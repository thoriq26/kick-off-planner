-- Membership hardening: close direct-write bypasses on community_members.
-- Apply after 20260924090000_multicycle_rounds.sql. Safe to run once.
--
-- Problem (verified on a local Postgres replica of this schema):
--   * members_delete_self_or_admin let any admin DELETE any membership row,
--     including the owner, straight through the REST API. That bypassed the
--     "keep at least one owner" guard in remove_community_member().
--   * members_update_admin let an admin UPDATE role / is_active directly, so an
--     admin could promote a member to admin (contradicting
--     create_community_invite(), which says only the owner may create admins)
--     or deactivate another admin. (Editing the owner's row was already
--     stopped by protect_community_member_role, only with a misleading error.)
--   * Any member could DELETE their own membership row, including the last owner.
--   * remove_community_member() / set_community_member_status() let an admin
--     act on other admins.
--
-- The browser never writes to community_members directly: admin.html only
-- SELECTs it and calls the RPCs below. So direct UPDATE/DELETE access is
-- removed, and the RPCs enforce who may act on whom.

-- 1) No direct writes to memberships from the browser.
drop policy if exists members_update_admin on public.community_members;
drop policy if exists members_delete_self_or_admin on public.community_members;
revoke update, delete on public.community_members from authenticated;

-- 2) Defense in depth: even if a grant is re-added later, only the owner may
--    change the role or active flag of an admin/owner row, and the last active
--    owner can never be deactivated.
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

    if auth.uid() is not null
       and (new.role is distinct from old.role or new.is_active is distinct from old.is_active)
       and (old.role in ('admin', 'owner') or new.role in ('admin', 'owner'))
       and not public.is_community_owner(old.community_id, auth.uid()) then
        raise exception 'Only the owner can change an admin or owner';
    end if;

    if old.role = 'owner' and old.is_active and not new.is_active
       and (select count(*) from public.community_members
             where community_id = old.community_id and role = 'owner' and is_active) <= 1 then
        raise exception 'A community must keep at least one active owner';
    end if;

    new.updated_at := now();
    return new;
end;
$$;

revoke all on function public.protect_community_member_role() from public, anon, authenticated;

-- 3) Status changes: an admin may only (de)activate plain members; only the
--    owner may touch admins or other owners.
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

    if target_role in ('admin', 'owner')
       and not public.is_community_owner(p_community, auth.uid()) then
        raise exception 'Only the owner can change an admin or owner';
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

-- 4) Removal: same rule. The auth account itself is still left untouched.
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

    if target_role in ('admin', 'owner')
       and not public.is_community_owner(p_community, auth.uid()) then
        raise exception 'Only the owner can change an admin or owner';
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

revoke all on function public.set_community_member_status(uuid, uuid, boolean) from public, anon;
revoke all on function public.remove_community_member(uuid, uuid) from public, anon;
grant execute on function public.set_community_member_status(uuid, uuid, boolean) to authenticated;
grant execute on function public.remove_community_member(uuid, uuid) to authenticated;
