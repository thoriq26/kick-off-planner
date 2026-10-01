-- Use human-copyable invite codes while keeping the existing hashed-token model.
-- Existing join.html#token= links remain valid; newly created invitations use
-- a short KOP-... code that users can enter after logging in.

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
    raw_token := 'KOP-' || upper(encode(extensions.gen_random_bytes(10), 'hex'));
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

revoke all on function public.create_community_invite(uuid, text, integer, integer) from public, anon;
grant execute on function public.create_community_invite(uuid, text, integer, integer) to authenticated;
