-- Match results for archived events: score, scorers, assists, cards, and the
-- team split captured at archive time so history stays accurate later.
-- Apply after 20260924040000_member_status.sql.

alter table public.community_event_history
    add column if not exists team_players jsonb not null default '{}'::jsonb,
    add column if not exists score jsonb not null default '{}'::jsonb,
    add column if not exists goals jsonb not null default '[]'::jsonb,
    add column if not exists assists jsonb not null default '[]'::jsonb,
    add column if not exists cards jsonb not null default '[]'::jsonb,
    add column if not exists archived_at timestamptz not null default now();

create index if not exists community_history_archived_idx
    on public.community_event_history (community_id, archived_at desc);

-- Only admins may correct results after the fact. There is no member write path.
drop policy if exists history_update_admin on public.community_event_history;
create policy history_update_admin on public.community_event_history
    for update to authenticated
    using (public.is_community_admin(community_id, auth.uid()))
    with check (public.is_community_admin(community_id, auth.uid()));

-- Safe integer parsing. The browser payload is untrusted, so a non-numeric
-- value must never raise; it falls back to 0 and is then clamped.
create or replace function public.safe_int(p_value text, p_min integer, p_max integer)
returns integer
language plpgsql
immutable
as $$
declare
    parsed integer;
begin
    if p_value is null or btrim(p_value) !~ '^-?[0-9]+$' then
        return 0;
    end if;
    parsed := btrim(p_value)::integer;
    return greatest(p_min, least(parsed, p_max));
exception when others then
    return 0;
end;
$$;

revoke all on function public.safe_int(text, integer, integer) from public, anon, authenticated;

-- Normalises the jsonb payload sent by the admin panel. Anything the browser
-- sends is treated as untrusted: unknown fields are dropped, counts are
-- clamped, and card type is limited to yellow/red.
create or replace function public.normalize_match_result(p_result jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public, extensions
as $$
declare
    entry jsonb;
    out_goals jsonb := '[]'::jsonb;
    out_assists jsonb := '[]'::jsonb;
    out_cards jsonb := '[]'::jsonb;
    raw_score jsonb;
    team text;
begin
    if p_result is null or jsonb_typeof(p_result) <> 'object' then
        p_result := '{}'::jsonb;
    end if;

    raw_score := p_result -> 'score';
    if jsonb_typeof(raw_score) <> 'object' then
        raw_score := '{}'::jsonb;
    end if;

    if jsonb_typeof(p_result -> 'goals') = 'array' then
        for entry in select value from jsonb_array_elements(p_result -> 'goals')
        loop
            if jsonb_typeof(entry) <> 'object' then
                continue;
            end if;
            team := btrim(coalesce(entry ->> 'team', ''));
            if team not in ('Red', 'Blue', 'Green', 'Purple') then
                continue;
            end if;
            if char_length(btrim(coalesce(entry ->> 'player', ''))) = 0 then
                continue;
            end if;
            out_goals := out_goals || jsonb_build_array(
                jsonb_build_object(
                    'team', team,
                    'player', btrim(entry ->> 'player'),
                    'minute', public.safe_int(entry ->> 'minute', 0, 150)
                )
            );
        end loop;
    end if;

    if jsonb_typeof(p_result -> 'assists') = 'array' then
        for entry in select value from jsonb_array_elements(p_result -> 'assists')
        loop
            if jsonb_typeof(entry) <> 'object' then
                continue;
            end if;
            team := btrim(coalesce(entry ->> 'team', ''));
            if team not in ('Red', 'Blue', 'Green', 'Purple') then
                continue;
            end if;
            if char_length(btrim(coalesce(entry ->> 'player', ''))) = 0 then
                continue;
            end if;
            out_assists := out_assists || jsonb_build_array(
                jsonb_build_object(
                    'team', team,
                    'player', btrim(entry ->> 'player'),
                    'minute', public.safe_int(entry ->> 'minute', 0, 150)
                )
            );
        end loop;
    end if;

    if jsonb_typeof(p_result -> 'cards') = 'array' then
        for entry in select value from jsonb_array_elements(p_result -> 'cards')
        loop
            if jsonb_typeof(entry) <> 'object' then
                continue;
            end if;
            team := btrim(coalesce(entry ->> 'team', ''));
            if team not in ('Red', 'Blue', 'Green', 'Purple') then
                continue;
            end if;
            if char_length(btrim(coalesce(entry ->> 'player', ''))) = 0 then
                continue;
            end if;
            if coalesce(entry ->> 'type', '') not in ('yellow', 'red') then
                continue;
            end if;
            out_cards := out_cards || jsonb_build_array(
                jsonb_build_object(
                    'team', team,
                    'player', btrim(entry ->> 'player'),
                    'type', entry ->> 'type',
                    'minute', public.safe_int(entry ->> 'minute', 0, 150)
                )
            );
        end loop;
    end if;

    -- Per-team score is clamped to a sane football range.
    return jsonb_build_object(
        'score', jsonb_build_object(
            'Red', public.safe_int(raw_score ->> 'Red', 0, 99),
            'Blue', public.safe_int(raw_score ->> 'Blue', 0, 99),
            'Green', public.safe_int(raw_score ->> 'Green', 0, 99),
            'Purple', public.safe_int(raw_score ->> 'Purple', 0, 99)
        ),
        'goals', out_goals,
        'assists', out_assists,
        'cards', out_cards
    );
end;
$$;

revoke all on function public.normalize_match_result(jsonb) from public, anon, authenticated;

-- Archive the current match together with its result. The old single-argument
-- overload is dropped first so only one implementation exists; a second copy
-- would silently archive rows with empty results and duplicate the reset logic.
drop function if exists public.archive_community_match(uuid);

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
    result_score jsonb;
    result_goals jsonb;
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

    clean_result := public.normalize_match_result(coalesce(p_result, '{}'::jsonb));
    result_score := clean_result -> 'score';
    result_goals := clean_result -> 'goals';

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
        archived_at
    ) values (
        p_community,
        match_row.event_name,
        match_row.nama_lp,
        match_row.waktu,
        archived_players,
        archived_count,
        team_split,
        result_score,
        result_goals,
        clean_result -> 'assists',
        clean_result -> 'cards',
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

    delete from public.community_players where community_id = p_community;
    return history_id;
end;
$$;

revoke all on function public.archive_community_match(uuid, jsonb) from public, anon;
grant execute on function public.archive_community_match(uuid, jsonb) to authenticated;

-- Backfill or correct the result of an already-archived event.
create or replace function public.update_event_history_result(
    p_history uuid,
    p_result jsonb
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    history_community uuid;
    clean_result jsonb;
begin
    select community_id into history_community
    from public.community_event_history
    where id = p_history;

    if history_community is null then
        raise exception 'Archived event not found';
    end if;

    if not public.is_community_admin(history_community, auth.uid()) then
        raise exception 'Only community admins can edit match results';
    end if;

    clean_result := public.normalize_match_result(coalesce(p_result, '{}'::jsonb));

    update public.community_event_history
    set score = clean_result -> 'score',
        goals = clean_result -> 'goals',
        assists = clean_result -> 'assists',
        cards = clean_result -> 'cards'
    where id = p_history;
end;
$$;

revoke all on function public.update_event_history_result(uuid, jsonb) from public, anon;
grant execute on function public.update_event_history_result(uuid, jsonb) to authenticated;

-- Admin-only list of archived events, newest first, used by the Arsip tab.
create or replace function public.list_event_history_admin(p_community uuid)
returns setof jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
    if not public.is_community_admin(p_community, auth.uid()) then
        raise exception 'Only community admins can view the archive list';
    end if;

    return query
        select jsonb_build_object(
            'id', h.id,
            'event_name', h.event_name,
            'location_name', h.location_name,
            'match_date', h.match_date,
            'player_count', h.player_count,
            'team_players', h.team_players,
            'score', h.score,
            'goals', h.goals,
            'assists', h.assists,
            'cards', h.cards,
            'archived_at', h.archived_at,
            'has_result', h.score <> '{}'::jsonb
        )
        from public.community_event_history h
        where h.community_id = p_community
        order by h.archived_at desc;
end;
$$;

revoke all on function public.list_event_history_admin(uuid) from public, anon;
grant execute on function public.list_event_history_admin(uuid) to authenticated;