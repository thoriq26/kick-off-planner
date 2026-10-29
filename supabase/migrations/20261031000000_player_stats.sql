-- ============================================================
-- Fase 6.4: statistik pemain lintas event
-- Jalankan setelah 20261030000000_player_levels.sql.
-- Agregasi dilakukan di database (bukan menarik semua baris ke browser).
-- ============================================================

create or replace function public.community_player_stats(
    p_community uuid,
    p_from timestamptz default null,
    p_to timestamptz default null
)
returns setof jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
    if not public.is_community_member(p_community, auth.uid()) then
        raise exception 'Join the community before reading stats';
    end if;

    return query
    with events as (
        select *
        from public.community_event_history
        where community_id = p_community
          and (p_from is null or archived_at >= p_from)
          and (p_to is null or archived_at <= p_to)
    ),
    entries as (
        select 'goal'::text as kind, entry ->> 'player' as player, null::text as card_type
        from events e
        cross join lateral jsonb_array_elements(
            case when jsonb_typeof(e.fixtures) = 'array' then e.fixtures else '[]'::jsonb end
        ) as f(fixture)
        cross join lateral jsonb_array_elements(
            case when jsonb_typeof(f.fixture -> 'goals') = 'array'
                 then f.fixture -> 'goals' else '[]'::jsonb end
        ) as x(entry)
        union all
        select 'assist', entry ->> 'player', null
        from events e
        cross join lateral jsonb_array_elements(
            case when jsonb_typeof(e.fixtures) = 'array' then e.fixtures else '[]'::jsonb end
        ) as f(fixture)
        cross join lateral jsonb_array_elements(
            case when jsonb_typeof(f.fixture -> 'assists') = 'array'
                 then f.fixture -> 'assists' else '[]'::jsonb end
        ) as x(entry)
        union all
        select 'card', entry ->> 'player', entry ->> 'type'
        from events e
        cross join lateral jsonb_array_elements(
            case when jsonb_typeof(e.fixtures) = 'array' then e.fixtures else '[]'::jsonb end
        ) as f(fixture)
        cross join lateral jsonb_array_elements(
            case when jsonb_typeof(f.fixture -> 'cards') = 'array'
                 then f.fixture -> 'cards' else '[]'::jsonb end
        ) as x(entry)
    ),
    aggregates as (
        select
            player,
            count(*) filter (where kind = 'goal')::integer as goals,
            count(*) filter (where kind = 'assist')::integer as assists,
            count(*) filter (where kind = 'card')::integer as cards,
            count(*) filter (where kind = 'card' and card_type = 'yellow')::integer as yellow,
            count(*) filter (where kind = 'card' and card_type = 'red')::integer as red
        from entries
        where player is not null and btrim(player) <> ''
        group by player
    ),
    attendance as (
        select name as player, count(*)::integer as appearances
        from events e
        cross join lateral jsonb_each(
            case when jsonb_typeof(e.team_players) = 'object'
                 then e.team_players else '{}'::jsonb end
        ) as t(team, names)
        cross join lateral jsonb_array_elements_text(
            case when jsonb_typeof(t.names) = 'array'
                 then t.names else '[]'::jsonb end
        ) as n(name)
        where btrim(name) <> ''
        group by name
    ),
    combined as (
        select
            coalesce(a.player, att.player) as player,
            coalesce(a.goals, 0) as goals,
            coalesce(a.assists, 0) as assists,
            coalesce(a.cards, 0) as cards,
            coalesce(a.yellow, 0) as yellow,
            coalesce(a.red, 0) as red,
            coalesce(att.appearances, 0) as appearances
        from aggregates a
        full join attendance att on lower(att.player) = lower(a.player)
    )
    select jsonb_build_object(
        'player', player,
        'goals', goals,
        'assists', assists,
        'cards', cards,
        'yellow', yellow,
        'red', red,
        'appearances', appearances
    )
    from combined
    order by goals desc, assists desc, appearances desc, player asc;
end;
$$;

revoke all on function public.community_player_stats(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function public.community_player_stats(uuid, timestamptz, timestamptz) to authenticated;
