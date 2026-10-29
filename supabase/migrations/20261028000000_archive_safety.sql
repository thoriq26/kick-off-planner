-- ============================================================
-- Fase 3: arsip aman, snapshot pemain, dan log aktivitas admin
-- Jalankan setelah 20260924090000_multicycle_rounds.sql.
-- Aman dijalankan sekali; seluruh objek dibuat ulang secara idempoten.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Snapshot daftar pemain sebelum reset/arsip (undo 7 hari)
-- ------------------------------------------------------------
create table if not exists public.community_roster_snapshots (
    id uuid primary key default gen_random_uuid(),
    community_id uuid not null references public.communities(id) on delete cascade,
    reason text not null default 'reset'
        check (reason in ('reset', 'archive', 'restore')),
    players jsonb not null default '[]'::jsonb,
    created_by uuid references auth.users(id) on delete set null,
    created_at timestamptz not null default now(),
    expires_at timestamptz not null default (now() + interval '7 days')
);

create index if not exists roster_snapshots_community_idx
    on public.community_roster_snapshots(community_id, created_at desc);

alter table public.community_roster_snapshots enable row level security;

drop policy if exists roster_snapshots_select_admin on public.community_roster_snapshots;
create policy roster_snapshots_select_admin on public.community_roster_snapshots
    for select to authenticated
    using (public.is_community_admin(community_id, auth.uid()));

revoke all on public.community_roster_snapshots from anon;
revoke insert, update, delete on public.community_roster_snapshots from authenticated;
grant select on public.community_roster_snapshots to authenticated;

-- ------------------------------------------------------------
-- 2. Log aktivitas admin (hanya bisa ditulis dari fungsi/trigger)
-- ------------------------------------------------------------
create table if not exists public.community_activity_log (
    id bigint generated always as identity primary key,
    community_id uuid not null references public.communities(id) on delete cascade,
    actor_id uuid references auth.users(id) on delete set null,
    action text not null,
    target text,
    detail jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now()
);

create index if not exists community_activity_log_community_idx
    on public.community_activity_log(community_id, created_at desc);

alter table public.community_activity_log enable row level security;

drop policy if exists activity_log_select_admin on public.community_activity_log;
create policy activity_log_select_admin on public.community_activity_log
    for select to authenticated
    using (public.is_community_admin(community_id, auth.uid()));

revoke all on public.community_activity_log from anon;
revoke insert, update, delete on public.community_activity_log from authenticated;
grant select on public.community_activity_log to authenticated;

-- Helper internal. Tidak diberikan ke anon/authenticated supaya browser
-- tidak bisa memalsukan entri log; dipanggil dari fungsi security definer.
create or replace function public.log_community_activity(
    p_community uuid,
    p_action text,
    p_target text default null,
    p_detail jsonb default '{}'::jsonb
)
returns void
language sql
security definer
set search_path = public, extensions
as $$
    insert into public.community_activity_log (community_id, actor_id, action, target, detail)
    values (p_community, auth.uid(), p_action, p_target, coalesce(p_detail, '{}'::jsonb));
$$;

revoke all on function public.log_community_activity(uuid, text, text, jsonb) from public, anon, authenticated;

-- ------------------------------------------------------------
-- 3. Trigger log untuk anggota, undangan, bukti transfer, riwayat
-- ------------------------------------------------------------
create or replace function public.log_member_activity()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
    if tg_op = 'DELETE' then
        perform public.log_community_activity(
            old.community_id,
            'member.remove',
            old.user_id::text,
            jsonb_build_object('user_id', old.user_id, 'role', old.role)
        );
        return null;
    end if;

    if tg_op = 'UPDATE' and new.is_active is distinct from old.is_active then
        perform public.log_community_activity(
            new.community_id,
            case when new.is_active then 'member.activate' else 'member.deactivate' end,
            new.user_id::text,
            jsonb_build_object('user_id', new.user_id, 'role', new.role)
        );
        return null;
    end if;

    if tg_op = 'UPDATE' and new.role is distinct from old.role then
        perform public.log_community_activity(
            new.community_id,
            'member.role',
            new.user_id::text,
            jsonb_build_object('user_id', new.user_id, 'from', old.role, 'to', new.role)
        );
    end if;
    return null;
end;
$$;

revoke all on function public.log_member_activity() from public, anon, authenticated;
drop trigger if exists log_member_activity on public.community_members;
create trigger log_member_activity
    after update or delete on public.community_members
    for each row execute procedure public.log_member_activity();

create or replace function public.log_invite_activity()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
    if tg_op = 'INSERT' then
        perform public.log_community_activity(
            new.community_id,
            'invite.create',
            new.id::text,
            jsonb_build_object('role', new.role, 'max_uses', new.max_uses, 'expires_at', new.expires_at)
        );
        return null;
    end if;

    if tg_op = 'UPDATE' then
        if new.revoked_at is not null and old.revoked_at is null then
            perform public.log_community_activity(
                new.community_id,
                'invite.revoke',
                new.id::text,
                jsonb_build_object('role', new.role, 'uses', new.uses)
            );
        end if;
        return null;
    end if;

    perform public.log_community_activity(
        old.community_id,
        'invite.revoke',
        old.id::text,
        jsonb_build_object('role', old.role, 'uses', old.uses)
    );
    return null;
end;
$$;

revoke all on function public.log_invite_activity() from public, anon, authenticated;
drop trigger if exists log_invite_activity on public.community_invites;
create trigger log_invite_activity
    after insert or update or delete on public.community_invites
    for each row execute procedure public.log_invite_activity();

create or replace function public.log_payment_proof_activity()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
    if tg_op = 'INSERT' then
        perform public.log_community_activity(
            new.community_id,
            'payment.submit',
            new.user_id::text,
            jsonb_build_object('proof_id', new.id, 'match_version', new.match_version)
        );
        return null;
    end if;

    if tg_op = 'UPDATE' and new.status is distinct from old.status then
        perform public.log_community_activity(
            new.community_id,
            case new.status
                when 'verified' then 'payment.verify'
                when 'rejected' then 'payment.reject'
                else 'payment.status'
            end,
            new.user_id::text,
            jsonb_build_object(
                'proof_id', new.id,
                'from', old.status,
                'to', new.status,
                'note', new.review_note
            )
        );
        return null;
    end if;

    if tg_op = 'DELETE' then
        perform public.log_community_activity(
            old.community_id,
            'payment.delete',
            old.user_id::text,
            jsonb_build_object('proof_id', old.id)
        );
    end if;
    return null;
end;
$$;

revoke all on function public.log_payment_proof_activity() from public, anon, authenticated;
drop trigger if exists log_payment_proof_activity on public.community_payment_proofs;
create trigger log_payment_proof_activity
    after insert or update or delete on public.community_payment_proofs
    for each row execute procedure public.log_payment_proof_activity();

create or replace function public.log_history_activity()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
    if tg_op = 'DELETE' then
        perform public.log_community_activity(
            old.community_id,
            'history.delete',
            old.id::text,
            jsonb_build_object('event_name', old.event_name)
        );
    else
        perform public.log_community_activity(
            new.community_id,
            'history.update',
            new.id::text,
            jsonb_build_object('event_name', new.event_name)
        );
    end if;
    return null;
end;
$$;

revoke all on function public.log_history_activity() from public, anon, authenticated;
drop trigger if exists log_history_activity on public.community_event_history;
create trigger log_history_activity
    after update or delete on public.community_event_history
    for each row execute procedure public.log_history_activity();

-- Pembatalan pendaftaran oleh member sendiri (bukan aksi admin) dicatat
-- sebagai aktivitas komunitas. Reset/arsip oleh admin sudah punya log sendiri.
create or replace function public.log_player_activity()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
    if old.user_id = auth.uid() then
        perform public.log_community_activity(
            old.community_id,
            'player.cancel',
            old.name,
            jsonb_build_object('user_id', old.user_id, 'position', old.position)
        );
    end if;
    return null;
end;
$$;

revoke all on function public.log_player_activity() from public, anon, authenticated;
drop trigger if exists log_player_activity on public.community_players;
create trigger log_player_activity
    after delete on public.community_players
    for each row execute procedure public.log_player_activity();

-- ------------------------------------------------------------
-- 4. RPC publish + reset dengan log aktivitas
-- ------------------------------------------------------------
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

    perform public.log_community_activity(
        p_community,
        'match.publish',
        clean_event,
        jsonb_build_object('location', clean_location, 'date', p_waktu)
    );

    return match_id;
end;
$$;

revoke all on function public.publish_community_match(uuid, text, text, text, text, text, text, text) from public, anon;
grant execute on function public.publish_community_match(uuid, text, text, text, text, text, text, text) to authenticated;

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

    perform public.log_community_activity(p_community, 'match.reset', null, '{}'::jsonb);
end;
$$;

revoke all on function public.reset_community_match(uuid) from public, anon;
grant execute on function public.reset_community_match(uuid) to authenticated;

-- ------------------------------------------------------------
-- 5. Reset pemain dengan snapshot + log
-- ------------------------------------------------------------
create or replace function public.reset_community_players(p_community uuid)
returns integer
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_count integer := 0;
begin
    if not public.is_community_admin(p_community, auth.uid()) then
        raise exception 'Only community admins can reset players';
    end if;

    insert into public.community_roster_snapshots (community_id, reason, players, created_by)
    select
        p_community,
        'reset',
        coalesce(jsonb_agg(to_jsonb(p) order by p.created_at), '[]'::jsonb),
        auth.uid()
    from public.community_players p
    where p.community_id = p_community
    having count(*) > 0;

    perform set_config('kop.skip_promotion', 'on', true);
    delete from public.community_players where community_id = p_community;
    get diagnostics v_count = row_count;
    perform set_config('kop.skip_promotion', 'off', true);

    perform public.log_community_activity(
        p_community,
        'players.reset',
        null,
        jsonb_build_object('players', v_count)
    );

    return v_count;
end;
$$;

revoke all on function public.reset_community_players(uuid) from public, anon;
grant execute on function public.reset_community_players(uuid) to authenticated;

-- ------------------------------------------------------------
-- 6. Arsip dengan snapshot + log (menggantikan versi 20260924060000)
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
-- 7. Pulihkan snapshot (khusus admin, maksimal 7 hari)
-- ------------------------------------------------------------
create or replace function public.restore_community_roster(p_snapshot uuid)
returns integer
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    snapshot_row public.community_roster_snapshots%rowtype;
    restored integer := 0;
begin
    if auth.uid() is null then
        raise exception 'Authentication required';
    end if;

    select * into snapshot_row
    from public.community_roster_snapshots
    where id = p_snapshot;

    if not found then
        raise exception 'Snapshot not found';
    end if;

    if not public.is_community_admin(snapshot_row.community_id, auth.uid()) then
        raise exception 'Only community admins can restore a roster';
    end if;

    if snapshot_row.expires_at < now() then
        raise exception 'Snapshot has expired';
    end if;

    insert into public.community_players (community_id, user_id, name, position, team, created_at)
    select
        snapshot_row.community_id,
        (entry ->> 'user_id')::uuid,
        entry ->> 'name',
        coalesce(nullif(entry ->> 'position', ''), 'GK'),
        null,
        coalesce((entry ->> 'created_at')::timestamptz, now())
    from jsonb_array_elements(snapshot_row.players) as item(entry)
    where entry ? 'user_id'
      and entry ->> 'user_id' is not null
      and exists (
          select 1
          from public.community_members m
          where m.community_id = snapshot_row.community_id
            and m.user_id = (entry ->> 'user_id')::uuid
            and m.is_active
      )
      and not exists (
          select 1
          from public.community_players p
          where p.community_id = snapshot_row.community_id
            and p.user_id = (entry ->> 'user_id')::uuid
      );

    get diagnostics restored = row_count;

    perform public.log_community_activity(
        snapshot_row.community_id,
        'roster.restore',
        p_snapshot::text,
        jsonb_build_object('restored', restored, 'reason', snapshot_row.reason)
    );

    return restored;
end;
$$;

revoke all on function public.restore_community_roster(uuid) from public, anon;
grant execute on function public.restore_community_roster(uuid) to authenticated;

-- ------------------------------------------------------------
-- 8. Daftar log aktivitas (50 terbaru) untuk tab admin
-- ------------------------------------------------------------
create or replace function public.list_community_activity(
    p_community uuid,
    p_limit integer default 50
)
returns setof jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
    if not public.is_community_admin(p_community, auth.uid()) then
        raise exception 'Only community admins can read the activity log';
    end if;

    return query
    select jsonb_build_object(
        'id', log.id,
        'action', log.action,
        'target', log.target,
        'detail', log.detail,
        'created_at', log.created_at,
        'actor_id', log.actor_id,
        'actor_name', coalesce(profile.full_name, 'Sistem')
    )
    from public.community_activity_log log
    left join public.profiles profile on profile.id = log.actor_id
    where log.community_id = p_community
    order by log.created_at desc
    limit greatest(1, least(coalesce(p_limit, 50), 200));
end;
$$;

revoke all on function public.list_community_activity(uuid, integer) from public, anon;
grant execute on function public.list_community_activity(uuid, integer) to authenticated;
