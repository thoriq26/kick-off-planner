-- ============================================================
-- Perbaikan lanjutan: isolasi bukti transfer antar-event, kuota saat
-- pemain berubah posisi, dan visibilitas anggota yang dinonaktifkan.
-- Jalankan setelah 20261031000000_player_stats.sql.
-- Aman dijalankan sekali; seluruh fungsi dibuat ulang secara idempoten.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Arsip harus menaikkan match_version dan mengosongkan kuota.
--
-- Versi 20261028000000 menggantikan archive_community_match() dari
-- 20260924060000 tanpa membawa dua perubahan penting:
--   * match_version tidak dinaikkan, sehingga bukti transfer event lama
--     masih dianggap milik event baru (match_id sama).
--   * player_quota tidak dikosongkan, sehingga event baru mewarisi kuota
--     event yang sudah diarsipkan.
-- ------------------------------------------------------------
create or replace function public.archive_community_match(
    p_community uuid,
    p_result jsonb default null
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
    team_split jsonb;
    clean_result jsonb;
    schedule jsonb;
    merged_fixtures jsonb;
    submitted_fixtures jsonb;
    snapshot_id uuid;
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

    -- Snapshot the team split now, before the player rows are deleted.
    select coalesce(jsonb_object_agg(grouped.team_name, grouped.players), '{}'::jsonb)
    into team_split
    from (
        select
            coalesce(nullif(p.team, ''), 'Tanpa Tim') as team_name,
            jsonb_agg(p.name order by p.created_at) as players
        from public.community_players p
        where p.community_id = p_community
          and p.status = 'active'
          and p.position <> 'SPECTATOR (FAN)'
        group by coalesce(nullif(p.team, ''), 'Tanpa Tim')
    ) as grouped;

    -- Full roster snapshot so the admin can restore it within 7 days.
    insert into public.community_roster_snapshots (community_id, reason, players, created_by)
    select
        p_community,
        'archive',
        coalesce(jsonb_agg(to_jsonb(p) order by p.created_at), '[]'::jsonb),
        auth.uid()
    from public.community_players p
    where p.community_id = p_community
    having count(*) > 0
    returning id into snapshot_id;

    clean_result := public.normalize_match_result(coalesce(p_result, '{}'::jsonb));

    -- The schedule is generated server-side from the real team split, so the
    -- browser cannot add or remove matchups.
    schedule := public.generate_round_robin(
        array(
            select keys.team_name
            from jsonb_object_keys(team_split) as keys(team_name)
            where keys.team_name is distinct from 'Tanpa Tim'
        ),
        public.safe_int(p_result ->> 'rounds', 0, 99)
    );

    submitted_fixtures := coalesce(p_result -> 'fixtures', '[]'::jsonb);
    merged_fixtures := public.merge_match_fixtures(schedule, submitted_fixtures);

    insert into public.community_event_history (
        community_id,
        event_name,
        location_name,
        match_date,
        player_list,
        player_count,
        team_players,
        score,
        goals,
        assists,
        cards,
        fixtures,
        archived_at
    ) values (
        p_community,
        match_row.event_name,
        match_row.nama_lp,
        match_row.waktu,
        archived_players,
        archived_count,
        team_split,
        coalesce((
            select jsonb_object_agg(teams.team_name, counts.goals)
            from (
                values
                    ('Red'), ('Blue'), ('Green'), ('Purple'),
                    ('Orange'), ('Pink'), ('Teal'), ('Navy')
            ) as teams(team_name)
            left join lateral (
                select count(*)::integer as goals
                from jsonb_array_elements(
                    case when jsonb_typeof(merged_fixtures) = 'array'
                         then merged_fixtures else '[]'::jsonb end
                ) as fixture(fixture_doc)
                cross join lateral jsonb_array_elements(
                    case when jsonb_typeof(fixture.fixture_doc -> 'goals') = 'array'
                         then fixture.fixture_doc -> 'goals' else '[]'::jsonb end
                ) as entry(entry_doc)
                where entry.entry_doc ->> 'team' = teams.team_name
            ) as counts on true
        ), '{}'::jsonb),
        '[]'::jsonb,
        '[]'::jsonb,
        '[]'::jsonb,
        merged_fixtures,
        now()
    ) returning id into history_id;

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

    perform set_config('kop.skip_promotion', 'on', true);
    delete from public.community_players where community_id = p_community;
    perform set_config('kop.skip_promotion', 'off', true);

    perform public.log_community_activity(
        p_community,
        'match.archive',
        match_row.event_name,
        jsonb_build_object(
            'history_id', history_id,
            'players', archived_count,
            'fixtures', jsonb_array_length(merged_fixtures),
            'snapshot_id', snapshot_id
        )
    );

    return history_id;
end;
$$;

revoke all on function public.archive_community_match(uuid, jsonb) from public, anon;
grant execute on function public.archive_community_match(uuid, jsonb) to authenticated;

-- ------------------------------------------------------------
-- 2. Perubahan posisi penonton <-> pemain harus menghormati kuota.
--
-- Sebelumnya status hanya dihitung saat INSERT. Penonton yang mengubah
-- posisinya menjadi pemain bisa melewati kuota, dan pemain aktif yang
-- menjadi penonton tidak memicu promosi daftar tunggu.
-- ------------------------------------------------------------
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
        -- Upsert pendaftaran ulang: pemain yang sudah memegang slot aktif
        -- tidak boleh turun ke daftar tunggu hanya karena kuota sedang penuh.
        if new.status = 'waitlisted' and exists (
            select 1
            from public.community_players p
            where p.community_id = new.community_id
              and p.user_id = new.user_id
              and p.status = 'active'
        ) then
            new.status := 'active';
        end if;
        return new;
    end if;

    if new.community_id <> old.community_id or new.user_id <> old.user_id then
        raise exception 'Player community and user cannot be changed';
    end if;

    if not public.is_community_admin(old.community_id, auth.uid()) then
        if new.team is distinct from old.team then
            raise exception 'Only community admins can change team assignments. SQL Editor/service role writes must set request.jwt.claim.sub or use the admin UI';
        end if;

        -- Penonton tidak memakai slot kuota. Saat beralih ke posisi pemain,
        -- hitung ulang statusnya supaya kuota tidak bisa dilewati.
        if old.position = 'SPECTATOR (FAN)'
           and new.position is distinct from 'SPECTATOR (FAN)' then
            new.status := public.community_player_registration_status(
                old.community_id,
                new.position
            );
        end if;

        if new.status is distinct from old.status then
            -- Member boleh naik dari daftar tunggu bila kuota memang tersedia.
            if old.status = 'waitlisted'
               and new.status = 'active'
               and public.community_player_registration_status(
                       old.community_id,
                       new.position
                   ) = 'active' then
                return new;
            end if;
            -- Penonton yang pindah ke posisi pemain saat kuota penuh masuk
            -- daftar tunggu, bukan ditolak.
            if old.status = 'active'
               and old.position = 'SPECTATOR (FAN)'
               and new.status = 'waitlisted' then
                return new;
            end if;
            raise exception 'Only community admins can change registration status';
        end if;
    end if;
    return new;
end;
$$;

revoke all on function public.protect_community_player_write() from public, anon, authenticated;
drop trigger if exists protect_community_player_write on public.community_players;
create trigger protect_community_player_write
    before insert or update on public.community_players
    for each row execute procedure public.protect_community_player_write();

-- ------------------------------------------------------------
-- 3. Promosi daftar tunggu saat slot aktif benar-benar kosong.
--
-- Selain status active -> non-active dan DELETE, slot juga kosong ketika
-- pemain aktif berubah menjadi SPECTATOR (FAN).
-- ------------------------------------------------------------
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

    -- Penonton tidak pernah memegang slot aktif, jadi tidak ada slot yang
    -- ditinggalkan saat barisnya dihapus/diubah.
    if old.position = 'SPECTATOR (FAN)' then
        return null;
    end if;

    if tg_op = 'UPDATE' then
        if not (
            (old.status = 'active' and new.status <> 'active')
            or (
                old.status = 'active'
                and old.position is distinct from 'SPECTATOR (FAN)'
                and new.position = 'SPECTATOR (FAN)'
            )
        ) then
            return null;
        end if;
    end if;

    -- Same key as community_player_registration_status(): promotions and new
    -- registrations for one community are serialized.
    perform pg_advisory_xact_lock(
        hashtext('kop_player_quota'),
        hashtext(old.community_id::text)
    );

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

-- ------------------------------------------------------------
-- 4. Anggota nonaktif harus bisa melihat statusnya sendiri.
--
-- RLS community_members hanya mengizinkan anggota aktif membaca baris
-- membership. Akibatnya auth-guard tidak bisa membedakan "belum punya
-- komunitas" dari "dinonaktifkan", dan pengguna terjebak di onboarding.
-- RPC ini hanya mengembalikan membership milik auth.uid().
-- ------------------------------------------------------------
create or replace function public.list_my_communities()
returns table (
    community_id uuid,
    name text,
    slug text,
    role text,
    is_active boolean
)
language sql
stable
security definer
set search_path = public, extensions
as $$
    select m.community_id, c.name, c.slug, m.role, m.is_active
    from public.community_members m
    join public.communities c on c.id = m.community_id
    where m.user_id = auth.uid()
    order by c.name;
$$;

revoke all on function public.list_my_communities() from public, anon;
grant execute on function public.list_my_communities() to authenticated;

-- ------------------------------------------------------------
-- 5. Izinkan penukaran kandang/tandang pada hasil arsip.
--
-- Jadwal lawan tetap dibuat server-side dari pembagian tim, tetapi admin
-- boleh menukar posisi kandang/tandang. Sebelumnya merge hanya mencocokkan
-- (home, away) persis, sehingga hasil pertandingan yang ditukar dibuang
-- diam-diam dan skornya kembali 0-0.
-- ------------------------------------------------------------
create or replace function public.merge_match_fixtures(
    p_existing jsonb,
    p_incoming jsonb
)
returns jsonb
language plpgsql
immutable
set search_path = public, extensions
as $$
declare
    fixture jsonb;
    submitted jsonb;
    merged jsonb := '[]'::jsonb;
begin
    if jsonb_typeof(p_existing) <> 'array' then
        return merged;
    end if;

    for fixture in select value from jsonb_array_elements(p_existing)
    loop
        submitted := null;

        if jsonb_typeof(p_incoming) = 'array' then
            -- Round-aware match; the pairing may be submitted in either
            -- home/away order so admins can swap sides.
            select value into submitted
            from jsonb_array_elements(p_incoming)
            where (
                    (
                        (value ->> 'home') = (fixture ->> 'home')
                        and (value ->> 'away') = (fixture ->> 'away')
                    )
                    or (
                        (value ->> 'home') = (fixture ->> 'away')
                        and (value ->> 'away') = (fixture ->> 'home')
                    )
                  )
              and coalesce(value ->> 'round', '') = coalesce(fixture ->> 'round', '')
            limit 1;

            if submitted is null then
                -- Legacy fallback: a cached older browser submits fixtures
                -- without a round key.
                select value into submitted
                from jsonb_array_elements(p_incoming)
                where (
                        (
                            (value ->> 'home') = (fixture ->> 'home')
                            and (value ->> 'away') = (fixture ->> 'away')
                        )
                        or (
                            (value ->> 'home') = (fixture ->> 'away')
                            and (value ->> 'away') = (fixture ->> 'home')
                        )
                      )
                  and (value -> 'round') is null
                limit 1;
            end if;
        end if;

        if submitted is null then
            merged := merged || jsonb_build_array(
                fixture || public.normalize_fixture_result('{}'::jsonb)
            );
        else
            -- Keep the admin's chosen home/away orientation, but keep the
            -- round from the server schedule when the submission omits it.
            merged := merged || jsonb_build_array(
                (
                    fixture
                    || jsonb_build_object(
                        'home', submitted ->> 'home',
                        'away', submitted ->> 'away'
                    )
                )
                || public.normalize_fixture_result(submitted)
            );
        end if;
    end loop;

    return merged;
end;
$$;

revoke all on function public.merge_match_fixtures(jsonb, jsonb) from public, anon, authenticated;
