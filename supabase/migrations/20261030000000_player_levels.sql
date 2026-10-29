-- ============================================================
-- Fase 6.5: level pemain untuk undian berbobot
-- Jalankan setelah 20261029000000_quota_waitlist.sql.
-- Level disimpan terpisah supaya tidak terbaca member biasa.
-- ============================================================

create table if not exists public.community_player_levels (
    community_id uuid not null references public.communities(id) on delete cascade,
    user_id uuid not null references auth.users(id) on delete cascade,
    level smallint not null check (level between 1 and 5),
    updated_by uuid references auth.users(id) on delete set null,
    updated_at timestamptz not null default now(),
    primary key (community_id, user_id)
);

create index if not exists community_player_levels_community_idx
    on public.community_player_levels(community_id);

alter table public.community_player_levels enable row level security;

drop policy if exists player_levels_select_admin on public.community_player_levels;
create policy player_levels_select_admin on public.community_player_levels
    for select to authenticated
    using (public.is_community_admin(community_id, auth.uid()));

drop policy if exists player_levels_insert_admin on public.community_player_levels;
create policy player_levels_insert_admin on public.community_player_levels
    for insert to authenticated
    with check (public.is_community_admin(community_id, auth.uid()));

drop policy if exists player_levels_update_admin on public.community_player_levels;
create policy player_levels_update_admin on public.community_player_levels
    for update to authenticated
    using (public.is_community_admin(community_id, auth.uid()))
    with check (public.is_community_admin(community_id, auth.uid()));

drop policy if exists player_levels_delete_admin on public.community_player_levels;
create policy player_levels_delete_admin on public.community_player_levels
    for delete to authenticated
    using (public.is_community_admin(community_id, auth.uid()));

revoke all on public.community_player_levels from anon;
grant select, insert, update, delete on public.community_player_levels to authenticated;
