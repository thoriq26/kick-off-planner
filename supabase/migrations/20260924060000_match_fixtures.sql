-- Per-fixture results for round-robin events.
-- With 3 teams an admin cannot sensibly fill one flat score per team: the event
-- is really A vs B, B vs C, and A vs C. This migration stores the generated
-- schedule plus the result of each matchup separately.
-- Apply after 20260924050000_match_results.sql.

alter table public.community_event_history
    add column if not exists fixtures jsonb not null default '[]'::jsonb;

-- Build a round-robin schedule. With 3 teams a full cycle yields exactly
-- A vs B, B vs C, A vs C — never six games. p_rounds caps how many rounds are
-- generated so an admin can play a single round instead of a full cycle.
create or replace function public.generate_round_robin(
    p_teams text[],
    p_rounds integer default null
)
returns jsonb
language plpgsql
immutable
set search_path = public, extensions
as $$
declare
    teams text[];
    full_rounds integer;
    rounds_to_run integer;
    rotating text[];
    rest text[];
    field_size integer;
    i integer;
    pair_index integer;
    output jsonb := '[]'::jsonb;
    home_team text;
    away_team text;
begin
    if p_teams is null then
        return output;
    end if;

    -- Drop blanks and duplicates, keeping the caller's order.
    select coalesce(array_agg(distinct t order by t), '{}'::text[])
    into teams
    from unnest(p_teams) as t
    where btrim(coalesce(t, '')) <> '';

    if coalesce(array_length(teams, 1), 0) < 2 then
        return output;
    end if;

    -- The circle method needs an even field, so an odd team count gets a hidden
    -- BYE slot. It rotates like any other entry, which is what keeps every
    -- pairing unique across the rounds.
    if array_length(teams, 1) % 2 = 1 then
        teams := array_append(teams, '__BYE__');
    end if;

    field_size := array_length(teams, 1);
    full_rounds := field_size - 1;
    rounds_to_run := full_rounds;

    if p_rounds is not null then
        rounds_to_run := greatest(1, least(p_rounds, full_rounds));
    end if;

    rotating := teams;

    for i in 1..rounds_to_run loop
        -- Pair the outside entries and work inwards.
        for pair_index in 0..(field_size / 2 - 1) loop
            home_team := rotating[pair_index + 1];
            away_team := rotating[field_size - pair_index];

            if home_team <> '__BYE__' and away_team <> '__BYE__' then
                -- Alternate home/away between rounds so nobody plays two home
                -- matches in a row where that can be avoided.
                if (i % 2) = 0 then
                    output := output || jsonb_build_array(
                        jsonb_build_object(
                            'round', i,
                            'home', away_team,
                            'away', home_team
                        )
                    );
                else
                    output := output || jsonb_build_array(
                        jsonb_build_object(
                            'round', i,
                            'home', home_team,
                            'away', away_team
                        )
                    );
                end if;
            end if;
        end loop;

        -- Circle rotation: keep position 1 fixed, move the last entry into
        -- position 2, and shift everything else right by one. Reversing the inner
        -- block instead would repeat the same pairings in later rounds.
        rest := rotating;
        rotating := array[rest[1], rest[field_size]];
        for pair_index in 2..(field_size - 1) loop
            rotating := rotating || (rest[pair_index]);
        end loop;
    end loop;

    return output;
end;
$$;

revoke all on function public.generate_round_robin(text[], integer) from public, anon, authenticated;

-- Reuse the existing per-entry sanitizer for the nested goal/assist/card lists.
create or replace function public.normalize_fixture_result(p_incoming jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public, extensions
as $$
declare
    cleaned jsonb;
begin
    cleaned := public.normalize_match_result(
        jsonb_build_object(
            'score', coalesce(p_incoming -> 'score', '{}'::jsonb),
            'goals', coalesce(p_incoming -> 'goals', '[]'::jsonb),
            'assists', coalesce(p_incoming -> 'assists', '[]'::jsonb),
            'cards', coalesce(p_incoming -> 'cards', '[]'::jsonb)
        )
    );

    return jsonb_build_object(
        'score_home', public.safe_int(p_incoming ->> 'score_home', 0, 99),
        'score_away', public.safe_int(p_incoming ->> 'score_away', 0, 99),
        'goals', cleaned -> 'goals',
        'assists', cleaned -> 'assists',
        'cards', cleaned -> 'cards'
    );
end;
$$;

revoke all on function public.normalize_fixture_result(jsonb) from public, anon, authenticated;

-- Merge a browser-supplied fixture list into the generated schedule. Only
-- matchups that already exist in the schedule can be written, so the browser
-- cannot invent new pairings.
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
            select value into submitted
            from jsonb_array_elements(p_incoming)
            where (value ->> 'home') = (fixture ->> 'home')
              and (value ->> 'away') = (fixture ->> 'away')
            limit 1;
        end if;

        if submitted is null then
            -- Untouched fixture: keep an empty result set so the UI can show a
            -- consistent shape for every matchup.
            merged := merged || jsonb_build_array(
                fixture || public.normalize_fixture_result('{}'::jsonb)
            );
        else
            merged := merged || jsonb_build_array(
                fixture || public.normalize_fixture_result(submitted)
            );
        end if;
    end loop;

    return merged;
end;
$$;

revoke all on function public.merge_match_fixtures(jsonb, jsonb) from public, anon, authenticated;

-- Total goals per team, summed across every fixture. Written as language sql with
-- no plpgsql variables: a plpgsql body that mixes a query with a RETURN can be
-- classified by PostgreSQL as a set-returning function, which then fails with
-- "set-returning functions are not allowed in WHERE" when the archive RPC writes an
-- RLS-checked row. migration 20260924070000 replaces this with the wider version.
drop function if exists public.fixture_team_totals(jsonb);

create function public.fixture_team_totals(p_fixtures jsonb)
returns jsonb
language sql
immutable
as $$
    select coalesce(jsonb_object_agg(teams.team_name, counts.goals), '{}'::jsonb)
    from (
        values
            ('Red'), ('Blue'), ('Green'), ('Purple'),
            ('Orange'), ('Pink'), ('Teal'), ('Navy')
    ) as teams(team_name)
    left join lateral (
        select count(*)::integer as goals
        from jsonb_array_elements(
            case
                when jsonb_typeof(p_fixtures) = 'array' then p_fixtures
                else '[]'::jsonb
            end
        ) as fixture(fixture_doc)
        cross join lateral jsonb_array_elements(
            case
                when jsonb_typeof(fixture.fixture_doc -> 'goals') = 'array'
                    then fixture.fixture_doc -> 'goals'
                else '[]'::jsonb
            end
        ) as entry(entry_doc)
        where entry.entry_doc ->> 'team' = teams.team_name
    ) as counts on true;
$$;

revoke all on function public.fixture_team_totals(jsonb) from public, anon, authenticated;

-- Archive the current match together with its per-fixture results.
drop function if exists public.archive_community_match(uuid, jsonb);

create function public.archive_community_match(
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

    -- The schedule is generated server-side from the real team split, so the
    -- browser cannot add or remove matchups.
    -- jsonb_object_keys is a set-returning function, so it may only appear in
    -- FROM. Putting it directly in a WHERE clause makes PostgreSQL raise
    -- "set-returning functions are not allowed in WHERE" and archiving fails.
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
        -- Per-team goal totals are computed inline instead of through a helper.
        -- A helper called from this RLS-checked INSERT can trip PostgreSQL's
        -- "set-returning functions are not allowed in WHERE" if its proretset flag
        -- was ever inferred incorrectly, which would break archiving entirely.
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

    delete from public.community_players where community_id = p_community;
    return history_id;
end;
$$;

revoke all on function public.archive_community_match(uuid, jsonb) from public, anon;
grant execute on function public.archive_community_match(uuid, jsonb) to authenticated;

-- Backfill or correct the results of an already-archived event.
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
    existing_fixtures jsonb;
    submitted_fixtures jsonb;
    merged_fixtures jsonb;
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
    existing_fixtures := coalesce(
        (select fixtures from public.community_event_history where id = p_history),
        '[]'::jsonb
    );

    -- An event archived before this migration has no schedule yet, so build one
    -- from its stored team split before merging the submitted results.
    if jsonb_typeof(existing_fixtures) <> 'array' or jsonb_array_length(existing_fixtures) = 0 then
        existing_fixtures := public.generate_round_robin(
            array(
                select keys.team_name
                from jsonb_object_keys(
                    coalesce(
                        (select team_players from public.community_event_history where id = p_history),
                        '{}'::jsonb
                    )
                ) as keys(team_name)
                where keys.team_name is distinct from 'Tanpa Tim'
            ),
            public.safe_int(p_result ->> 'rounds', 0, 99)
        );
    end if;

    submitted_fixtures := coalesce(p_result -> 'fixtures', '[]'::jsonb);
    merged_fixtures := public.merge_match_fixtures(existing_fixtures, submitted_fixtures);

    update public.community_event_history
    set fixtures = merged_fixtures,
        score = -- Per-team goal totals are computed inline instead of through a helper.
        -- A helper called from this RLS-checked INSERT can trip PostgreSQL's
        -- "set-returning functions are not allowed in WHERE" if its proretset flag
        -- was ever inferred incorrectly, which would break archiving entirely.
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
        goals = '[]'::jsonb,
        assists = '[]'::jsonb,
        cards = '[]'::jsonb
    where id = p_history;
end;
$$;

revoke all on function public.update_event_history_result(uuid, jsonb) from public, anon;
grant execute on function public.update_event_history_result(uuid, jsonb) to authenticated;

-- Admin-only archive list, now including the fixture schedule.
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
            'fixtures', h.fixtures,
            'goals', h.goals,
            'assists', h.assists,
            'cards', h.cards,
            'archived_at', h.archived_at,
            'has_result', jsonb_array_length(h.fixtures) > 0
        )
        from public.community_event_history h
        where h.community_id = p_community
        order by h.archived_at desc;
end;
$$;

revoke all on function public.list_event_history_admin(uuid) from public, anon;
grant execute on function public.list_event_history_admin(uuid) to authenticated;