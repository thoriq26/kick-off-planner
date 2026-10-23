-- Multi-cycle schedules: rounds beyond one full round-robin cycle repeat the
-- pairings (double round robin / playoff-style runs decided by the admin).
-- Two fixes make repeated pairings safe:
--   1. generate_round_robin may run up to 99 rounds instead of being clamped
--      to a single cycle.
--   2. merge_match_fixtures keys a scored submission by (round, home, away)
--      so a rematch in a later cycle can carry its own result instead of
--      swallowing the first meeting's score. Submissions without a round key
--      (an older cached browser) still fall back to pairing-only matching.
-- Apply after 20260924080000_team_aliases.sql.

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

    -- Rounds past the first full cycle deliberately repeat the pairings, so
    -- clamp to the hard request ceiling instead of the cycle length. The
    -- parity flip below of alternating home/away keeps a rematch oriented
    -- opposite to its earlier meeting.
    rounds_to_run := field_size - 1;
    if p_rounds is not null then
        rounds_to_run := greatest(1, least(p_rounds, 99));
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
            -- Round-aware match: repeated pairings across cycles are distinct
            -- fixtures, so the round must agree with the pairing.
            select value into submitted
            from jsonb_array_elements(p_incoming)
            where (value ->> 'home') = (fixture ->> 'home')
              and (value ->> 'away') = (fixture ->> 'away')
              and coalesce(value ->> 'round', '') = coalesce(fixture ->> 'round', '')
            limit 1;

            if submitted is null then
                -- Legacy fallback: a cached older browser submits fixtures
                -- without a round key. Only allow a pairing-only match from
                -- roundless submissions so cycle-aware data is never double
                -- scored.
                select value into submitted
                from jsonb_array_elements(p_incoming)
                where (value ->> 'home') = (fixture ->> 'home')
                  and (value ->> 'away') = (fixture ->> 'away')
                  and (value -> 'round') is null
                limit 1;
            end if;
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
