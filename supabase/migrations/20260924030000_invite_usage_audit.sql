-- Track which authenticated accounts accepted each community invitation.
-- Apply after 20260924025000_fix_invite_ambiguity.sql.
--
-- Existing accepted invitations cannot be backfilled reliably because the
-- original schema only stored a counter. Records begin with this migration.

create table if not exists public.community_invite_uses (
    invite_id uuid not null references public.community_invites(id) on delete cascade,
    community_id uuid not null references public.communities(id) on delete cascade,
    user_id uuid not null references auth.users(id) on delete cascade,
    role text not null check (role in ('admin', 'member')),
    used_at timestamptz not null default now(),
    primary key (invite_id, user_id)
);

create index if not exists community_invite_uses_community_idx
    on public.community_invite_uses (community_id, used_at desc);
create index if not exists community_invite_uses_user_idx
    on public.community_invite_uses (user_id, used_at desc);

alter table public.community_invite_uses enable row level security;

drop policy if exists invite_uses_select_admin on public.community_invite_uses;
create policy invite_uses_select_admin on public.community_invite_uses
    for select to authenticated
    using (public.is_community_admin(community_id, auth.uid()));

revoke all on public.community_invite_uses from anon;
revoke insert, update, delete on public.community_invite_uses from authenticated;
grant select on public.community_invite_uses to authenticated;

-- Record the accepting account when a new membership is created. The insert is
-- intentionally inside the function so members cannot forge usage rows.
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
    on conflict on constraint community_members_pkey do nothing;

    get diagnostics inserted_rows = row_count;
    if inserted_rows > 0 then
        insert into public.community_invite_uses (
            invite_id,
            community_id,
            user_id,
            role
        )
        values (
            invite_row.id,
            invite_row.community_id,
            auth.uid(),
            invite_row.role
        )
        on conflict (invite_id, user_id) do nothing;

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

revoke all on function public.accept_community_invite(text) from public, anon;
grant execute on function public.accept_community_invite(text) to authenticated;

-- Admin-only list of accounts that used a specific invitation.
-- jsonb is used instead of RETURNS TABLE so PostgREST never has to match column
-- types, and the browser receives the exact field names it reads.
drop function if exists public.list_community_invite_users(uuid);

create function public.list_community_invite_users(
    p_invite uuid
)
returns setof jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    invite_community uuid;
begin
    select i.community_id into invite_community
    from public.community_invites i
    where i.id = p_invite;

    if invite_community is null
       or not public.is_community_admin(invite_community, auth.uid()) then
        raise exception 'Only community admins can view invitation users';
    end if;

    return query
        select jsonb_build_object(
            'user_id', u.user_id,
            'full_name', coalesce(pr.full_name, ''),
            'email', coalesce(a.email, ''),
            'role', u.role,
            'used_at', u.used_at
        )
        from public.community_invite_uses u
        join auth.users a on a.id = u.user_id
        left join public.profiles pr on pr.id = u.user_id
        where u.invite_id = p_invite
        order by u.used_at asc;
end;
$$;

revoke all on function public.list_community_invite_users(uuid) from public, anon;
grant execute on function public.list_community_invite_users(uuid) to authenticated;