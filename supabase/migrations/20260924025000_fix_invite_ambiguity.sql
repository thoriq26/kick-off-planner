-- Fix PL/pgSQL output-name ambiguity in accept_community_invite.
-- The original function's OUT names are preserved so CREATE OR REPLACE can
-- update an already-installed function safely.

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
