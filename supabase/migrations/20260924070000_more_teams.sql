-- Allow more than four teams.
-- community_players.team originally accepted only Red/Blue/Green/Purple, which
-- capped a draft at four teams. The round-robin schedule already supports any
-- team count; only this check constraint and the hardcoded lists were limiting it.
-- Apply after 20260924060000_match_fixtures.sql.

alter table public.community_players
    drop constraint if exists community_players_team_check;

alter table public.community_players
    add constraint community_players_team_check
    check (
        team is null or team in (
            'Red', 'Blue', 'Green', 'Purple',
            'Orange', 'Pink', 'Teal', 'Navy'
        )
    );

-- The per-team goal tally must cover every supported team, otherwise totals for
-- the new colours would silently be missing.
--
-- Deliberately written as language sql with no plpgsql variables: a plpgsql body
-- that mixes a query with a RETURN can be flagged by PostgreSQL as a set-returning
-- function, which then fails with "set-returning functions are not allowed in
-- WHERE" wherever the archive RPC touches an RLS-checked row.
--
-- The drop is required because CREATE OR REPLACE cannot switch a plpgsql body
-- over to language sql on an already-installed function.
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

-- Only rows that still hold a supported team name are accepted from the browser.
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
            if team not in (
                'Red', 'Blue', 'Green', 'Purple',
                'Orange', 'Pink', 'Teal', 'Navy'
            ) then
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
            if team not in (
                'Red', 'Blue', 'Green', 'Purple',
                'Orange', 'Pink', 'Teal', 'Navy'
            ) then
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
            if team not in (
                'Red', 'Blue', 'Green', 'Purple',
                'Orange', 'Pink', 'Teal', 'Navy'
            ) then
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

    return jsonb_build_object(
        'score', jsonb_build_object(
            'Red', public.safe_int(raw_score ->> 'Red', 0, 99),
            'Blue', public.safe_int(raw_score ->> 'Blue', 0, 99),
            'Green', public.safe_int(raw_score ->> 'Green', 0, 99),
            'Purple', public.safe_int(raw_score ->> 'Purple', 0, 99),
            'Orange', public.safe_int(raw_score ->> 'Orange', 0, 99),
            'Pink', public.safe_int(raw_score ->> 'Pink', 0, 99),
            'Teal', public.safe_int(raw_score ->> 'Teal', 0, 99),
            'Navy', public.safe_int(raw_score ->> 'Navy', 0, 99)
        ),
        'goals', out_goals,
        'assists', out_assists,
        'cards', out_cards
    );
end;
$$;

revoke all on function public.normalize_match_result(jsonb) from public, anon, authenticated;