-- Private payment-proof uploads for the current community match.
-- Apply after 20260924000000_multi_tenant_auth.sql and
-- 20260924010000_short_invite_codes.sql.

-- A community currently reuses one match row. Versioning keeps proofs from a
-- previous event separate when the owner resets or archives the match.
alter table public.community_matches
    add column if not exists match_version integer not null default 1;

create table if not exists public.community_payment_proofs (
    id uuid primary key default gen_random_uuid(),
    community_id uuid not null references public.communities(id) on delete cascade,
    match_id uuid not null references public.community_matches(id) on delete cascade,
    match_version integer not null default 1 check (match_version > 0),
    user_id uuid not null references auth.users(id) on delete cascade,
    storage_path text not null unique,
    original_name text not null,
    mime_type text not null,
    size_bytes bigint not null check (size_bytes > 0 and size_bytes <= 5242880),
    status text not null default 'submitted' check (status in ('submitted', 'verified', 'rejected')),
    review_note text,
    reviewed_at timestamptz,
    reviewed_by uuid references auth.users(id) on delete set null,
    created_at timestamptz not null default now()
);

create index if not exists payment_proofs_match_idx
    on public.community_payment_proofs(match_id, match_version, created_at desc);
create index if not exists payment_proofs_community_idx
    on public.community_payment_proofs(community_id, created_at desc);
create index if not exists payment_proofs_user_idx
    on public.community_payment_proofs(user_id, created_at desc);

-- The browser object path is:
-- <community_uuid>/<match_uuid>/<user_uuid>/<random-file-name>
create or replace function public.payment_proof_community_id(object_name text)
returns uuid
language plpgsql
immutable
security definer
set search_path = public, storage
as $$
declare
    folder text;
begin
    folder := (storage.foldername(object_name))[1];
    return folder::uuid;
exception
    when others then return null;
end;
$$;

create or replace function public.payment_proof_match_id(object_name text)
returns uuid
language plpgsql
immutable
security definer
set search_path = public, storage
as $$
declare
    folder text;
begin
    folder := (storage.foldername(object_name))[2];
    return folder::uuid;
exception
    when others then return null;
end;
$$;

create or replace function public.payment_proof_user_id(object_name text)
returns uuid
language plpgsql
immutable
security definer
set search_path = public, storage
as $$
declare
    folder text;
begin
    folder := (storage.foldername(object_name))[3];
    return folder::uuid;
exception
    when others then return null;
end;
$$;

revoke all on function public.payment_proof_community_id(text) from public, anon;
revoke all on function public.payment_proof_match_id(text) from public, anon;
revoke all on function public.payment_proof_user_id(text) from public, anon;
grant execute on function public.payment_proof_community_id(text) to authenticated;
grant execute on function public.payment_proof_match_id(text) to authenticated;
grant execute on function public.payment_proof_user_id(text) to authenticated;

create or replace function public.validate_payment_proof()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
    if not exists (
        select 1
        from public.community_matches
        where id = new.match_id
          and community_id = new.community_id
          and match_version = new.match_version
    ) then
        raise exception 'Payment proof does not belong to the current match';
    end if;

    if new.storage_path not like
        new.community_id::text || '/' || new.match_id::text || '/' || new.user_id::text || '/%' then
        raise exception 'Invalid payment proof storage path';
    end if;

    if tg_op = 'INSERT' and auth.uid() is not null and (
        new.user_id <> auth.uid()
        or new.status <> 'submitted'
        or new.reviewed_at is not null
        or new.reviewed_by is not null
        or new.review_note is not null
    ) then
        raise exception 'A member can only submit an unreviewed payment proof';
    end if;

    if tg_op = 'UPDATE' and (
        new.community_id <> old.community_id
        or new.match_id <> old.match_id
        or new.match_version <> old.match_version
        or new.user_id <> old.user_id
        or new.storage_path <> old.storage_path
    ) then
        raise exception 'Payment proof identity fields cannot be changed';
    end if;

    return new;
end;
$$;

drop trigger if exists validate_payment_proof on public.community_payment_proofs;
create trigger validate_payment_proof
    before insert or update on public.community_payment_proofs
    for each row execute procedure public.validate_payment_proof();

revoke all on function public.validate_payment_proof() from public, anon, authenticated;

-- Keep reset and archive operations versioned. The frontend uses the reset RPC
-- so old proofs do not appear on the next event.
create or replace function public.reset_community_match(
    p_community uuid
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
    if not public.is_community_admin(p_community, auth.uid()) then
        raise exception 'Only community admins can reset matches';
    end if;

    update public.community_matches
    set event_name = 'TBA',
        nama_lp = 'TBA',
        waktu = null,
        jersey = '-',
        htm = '0',
        rekening = '-',
        maps_url = '',
        match_version = match_version + 1,
        updated_at = now()
    where community_id = p_community;
end;
$$;

revoke all on function public.reset_community_match(uuid) from public, anon;
grant execute on function public.reset_community_match(uuid) to authenticated;

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
        match_version = match_version + 1,
        updated_at = now()
    where community_id = p_community;

    delete from public.community_players where community_id = p_community;
    return history_id;
end;
$$;

revoke all on function public.archive_community_match(uuid) from public, anon;
grant execute on function public.archive_community_match(uuid) to authenticated;

-- Private bucket. The browser never receives a public URL; admins and owners
-- use short-lived signed URLs generated after an authenticated RLS check.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
    'payment-proofs',
    'payment-proofs',
    false,
    5242880,
    array['image/jpeg', 'image/png', 'image/webp', 'application/pdf']
)
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

-- Payment-proof metadata RLS.
alter table public.community_payment_proofs enable row level security;

drop policy if exists payment_proofs_select on public.community_payment_proofs;
create policy payment_proofs_select on public.community_payment_proofs
    for select to authenticated
    using (user_id = auth.uid() or public.is_community_admin(community_id, auth.uid()));

drop policy if exists payment_proofs_insert on public.community_payment_proofs;
create policy payment_proofs_insert on public.community_payment_proofs
    for insert to authenticated
    with check (
        user_id = auth.uid()
        and public.is_community_member(community_id, auth.uid())
    );

drop policy if exists payment_proofs_update_admin on public.community_payment_proofs;
create policy payment_proofs_update_admin on public.community_payment_proofs
    for update to authenticated
    using (public.is_community_admin(community_id, auth.uid()))
    with check (public.is_community_admin(community_id, auth.uid()));

drop policy if exists payment_proofs_delete_owner_or_admin on public.community_payment_proofs;
create policy payment_proofs_delete_owner_or_admin on public.community_payment_proofs
    for delete to authenticated
    using (user_id = auth.uid() or public.is_community_admin(community_id, auth.uid()));

revoke all on public.community_payment_proofs from anon;
grant select, insert, update, delete on public.community_payment_proofs to authenticated;

-- Storage object RLS. The folder helpers safely return NULL for malformed
-- names, so a crafted object name cannot bypass the tenant checks.
drop policy if exists payment_proof_storage_insert on storage.objects;
create policy payment_proof_storage_insert on storage.objects
    for insert to authenticated
    with check (
        bucket_id = 'payment-proofs'
        and public.payment_proof_user_id(name) = auth.uid()
        and public.is_community_member(
            public.payment_proof_community_id(name),
            auth.uid()
        )
    );

drop policy if exists payment_proof_storage_select on storage.objects;
create policy payment_proof_storage_select on storage.objects
    for select to authenticated
    using (
        bucket_id = 'payment-proofs'
        and (
            public.payment_proof_user_id(name) = auth.uid()
            or public.is_community_admin(
                public.payment_proof_community_id(name),
                auth.uid()
            )
        )
    );

drop policy if exists payment_proof_storage_update on storage.objects;
create policy payment_proof_storage_update on storage.objects
    for update to authenticated
    using (
        bucket_id = 'payment-proofs'
        and (
            public.payment_proof_user_id(name) = auth.uid()
            or public.is_community_admin(
                public.payment_proof_community_id(name),
                auth.uid()
            )
        )
    )
    with check (
        bucket_id = 'payment-proofs'
        and public.payment_proof_user_id(name) = auth.uid()
    );

drop policy if exists payment_proof_storage_delete on storage.objects;
create policy payment_proof_storage_delete on storage.objects
    for delete to authenticated
    using (
        bucket_id = 'payment-proofs'
        and (
            public.payment_proof_user_id(name) = auth.uid()
            or public.is_community_admin(
                public.payment_proof_community_id(name),
                auth.uid()
            )
        )
    );
