-- ============================================================
-- Fase 6.2: kuota pemain + daftar tunggu
-- Jalankan setelah 20261028000000_archive_safety.sql.
-- Aman dijalankan sekali.
-- ============================================================

alter table public.community_matches
    add column if not exists player_quota integer
    check (player_quota is null or player_quota between 0 and 500);

alter table public.community_players
    add column if not exists status text not null default 'active'
    check (status in ('active', 'waitlisted'));

create index if not exists community_players_status_idx
    on public.community_players(community_id, status);

-- Menentukan status pendaftaran berdasarkan kuota event saat ini.
-- Penonton tidak pernah masuk daftar tunggu dan tidak dihitung ke kuota.
create or replace function public.community_player_registration_status(
    p_community uuid,
    p_position text
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    quota integer;
    active_count integer;
begin
    if upper(trim(coalesce(p_position, ''))) = 'SPECTATOR (FAN)' then
        return 'active';
    end if;

    select player_quota into quota
    from public.community_matches
    where community_id = p_community;

    if coalesce(quota, 0) <= 0 then
        return 'active';
    end if;

    select count(*)::integer into active_count
    from public.community_players
    where community_id = p_community
      and status = 'active'
      and position <> 'SPECTATOR (FAN)';

    if active_count >= quota then
        return 'waitlisted';
    end if;
    return 'active';
end;
$$;

revoke all on function public.community_player_registration_status(uuid, text) from public, anon, authenticated;

-- Trigger penjaga: member tidak boleh mengubah status pendaftaran sendiri,
-- dan status awal selalu dihitung dari kuota (termasuk saat insert langsung).
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
        new.status := public.community_player_registration_status(
            new.community_id,
            new.position
        );
        return new;
    end if;

    if new.community_id <> old.community_id or new.user_id <> old.user_id then
        raise exception 'Player community and user cannot be changed';
    end if;

    if not public.is_community_admin(old.community_id, auth.uid()) then
        if new.team is distinct from old.team then
            raise exception 'Only community admins can change team assignments';
        end if;
        if new.status is distinct from old.status then
            -- Member hanya boleh naik dari daftar tunggu bila kuota memang tersedia.
            if old.status = 'waitlisted'
               and new.status = 'active'
               and public.community_player_registration_status(
                       old.community_id,
                       new.position
                   ) = 'active' then
                return new;
            end if;
            raise exception 'Only community admins can change registration status';
        end if;
    end if;
    return new;
end;
$$;

drop trigger if exists protect_community_player_write on public.community_players;
create trigger protect_community_player_write
    before insert or update on public.community_players
    for each row execute procedure public.protect_community_player_write();

-- Naikkan pendaftar tertua dari daftar tunggu saat satu slot aktif kosong.
create or replace function public.promote_waitlisted_player()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    quota integer;
    active_count integer;
    next_player uuid;
begin
    if coalesce(current_setting('kop.skip_promotion', true), 'off') = 'on' then
        return null;
    end if;

    -- Hanya relevan untuk pemain (bukan penonton) yang meninggalkan slot aktif.
    if old.position = 'SPECTATOR (FAN)' then
        return null;
    end if;
    if tg_op = 'UPDATE' then
        if not (old.status = 'active' and new.status <> 'active') then
            return null;
        end if;
    end if;

    select player_quota into quota
    from public.community_matches
    where community_id = old.community_id;

    if coalesce(quota, 0) <= 0 then
        return null;
    end if;

    select count(*)::integer into active_count
    from public.community_players
    where community_id = old.community_id
      and status = 'active'
      and position <> 'SPECTATOR (FAN)';

    if active_count >= quota then
        return null;
    end if;

    select id into next_player
    from public.community_players
    where community_id = old.community_id
      and status = 'waitlisted'
    order by created_at, id
    limit 1;

    if next_player is not null then
        update public.community_players
        set status = 'active'
        where id = next_player;
    end if;
    return null;
end;
$$;

revoke all on function public.promote_waitlisted_player() from public, anon, authenticated;
drop trigger if exists promote_waitlisted_player on public.community_players;
create trigger promote_waitlisted_player
    after update or delete on public.community_players
    for each row execute procedure public.promote_waitlisted_player();

-- Daftar tunggu bisa dipromosikan manual oleh admin.
create or replace function public.promote_community_player(p_player uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    player_row public.community_players%rowtype;
begin
    select * into player_row from public.community_players where id = p_player;
    if not found then
        raise exception 'Player not found';
    end if;
    if not public.is_community_admin(player_row.community_id, auth.uid()) then
        raise exception 'Only community admins can promote players';
    end if;
    update public.community_players set status = 'active' where id = p_player;
    perform public.log_community_activity(
        player_row.community_id,
        'player.promote',
        player_row.name,
        jsonb_build_object('user_id', player_row.user_id)
    );
end;
$$;

revoke all on function public.promote_community_player(uuid) from public, anon;
grant execute on function public.promote_community_player(uuid) to authenticated;

-- Daftarkan pemain dengan pengecekan kuota di server.
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
    next_status text;
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

    next_status := case
        when exists (
            select 1
            from public.community_players
            where community_id = p_community
              and user_id = auth.uid()
              and status = 'active'
        ) then 'active'
        else public.community_player_registration_status(
            p_community,
            clean_position
        )
    end;

    insert into public.community_players (
        community_id, user_id, name, position, status
    ) values (
        p_community, auth.uid(), clean_name, clean_position, next_status
    )
    on conflict (community_id, user_id) do update
        set name = excluded.name,
            position = excluded.position,
            status = excluded.status
    returning id into player_id;

    return player_id;
end;
$$;

revoke all on function public.register_community_player(uuid, text, text) from public, anon;
grant execute on function public.register_community_player(uuid, text, text) to authenticated;

-- Reset event juga mengosongkan kuota supaya event berikutnya netral.
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
        player_quota = null,
        match_version = match_version + 1,
        updated_at = now()
    where community_id = p_community;

    perform public.log_community_activity(p_community, 'match.reset', null, '{}'::jsonb);
end;
$$;

revoke all on function public.reset_community_match(uuid) from public, anon;
grant execute on function public.reset_community_match(uuid) to authenticated;
