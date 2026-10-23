-- Custom display names for the fixed team keys (Red, Blue, ...).
-- The admin Undi Tim tab gets a rename button per team card; draft.html
-- shows the same custom names to members.
--
-- Team keys stay English in community_players.team; only the presentation
-- label is customizable here. Apply after 20260924070000_more_teams.sql.

create table if not exists public.community_team_names (
    community_id uuid not null references public.communities(id) on delete cascade,
    team text not null check (team in (
        'Red', 'Blue', 'Green', 'Purple', 'Orange', 'Pink', 'Teal', 'Navy'
    )),
    label text not null check (length(btrim(label)) between 1 and 24)
        check (label = btrim(label)),
    updated_at timestamptz not null default now(),
    primary key (community_id, team)
);

create index if not exists community_team_names_community_idx
    on public.community_team_names (community_id);

alter table public.community_team_names enable row level security;

drop policy if exists team_names_select_member on public.community_team_names;
create policy team_names_select_member on public.community_team_names
    for select to authenticated
    using (
        exists (
            select 1
            from public.community_members m
            where m.community_id = community_team_names.community_id
              and m.user_id = auth.uid()
        )
    );

drop policy if exists team_names_write_admin on public.community_team_names;
create policy team_names_write_admin on public.community_team_names
    for insert with check (
        public.is_community_admin(community_team_names.community_id, auth.uid())
    );

drop policy if exists team_names_update_admin on public.community_team_names;
create policy team_names_update_admin on public.community_team_names
    for update to authenticated
    using (
        public.is_community_admin(community_team_names.community_id, auth.uid())
    )
    with check (
        public.is_community_admin(community_team_names.community_id, auth.uid())
    );

drop policy if exists team_names_delete_admin on public.community_team_names;
create policy team_names_delete_admin on public.community_team_names
    for delete to authenticated
    using (
        public.is_community_admin(community_team_names.community_id, auth.uid())
    );

grant select on public.community_team_names to authenticated;

-- Auto-keep updated_at fresh.
create or replace function public.touch_team_names_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

drop trigger if exists team_names_touch on public.community_team_names;
create trigger team_names_touch
    before update on public.community_team_names
    for each row execute function public.touch_team_names_updated_at();
