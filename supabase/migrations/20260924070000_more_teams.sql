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
create or replace function public.fixture_team_totals(p_fixtures jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public, extensions
as $$
declare
    team text;
    goals int;
    total jsonb := '{}'::jsonb;
begin
    if jsonb_typeof(p_fixtures) <> 'array' then
        return total;
    end if;

    foreach team in array array[
        'Red', 'Blue', 'Green', 'Purple',
        'Orange', 'Pink', 'Teal', 'Navy'
    ]
    loop
        select
            coalesce(sum(
                (select coalesce(sum(public.safe_int(entry ->> 'goals', 0, 99)), 0)
                 from jsonb_array_elements(coalesce(fixture -> 'goals', '[]'::jsonb)) as entry
                 where entry ->> 'team' = team)
            ), 0)::integer
        into goals
        from jsonb_array_elements(p_fixtures) as fixture;

        total := total || jsonb_build_object(team, goals);
    end loop;

    return total;
end;
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