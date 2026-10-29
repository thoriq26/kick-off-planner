-- Destructive DATA-ONLY reset for KickOff Planner.
-- Use this after a testing round when the schema, functions, RLS, and auth
-- accounts should remain in place. It removes communities, members, players,
-- matches, history, invitations, and payment-proof metadata.
--
-- IMPORTANT:
--   * auth.users is NOT deleted.
--   * public.profiles is NOT deleted, so existing test logins keep their names.
--   * Files inside the private payment-proofs Storage bucket are NOT removed by
--     SQL. Delete/empty that bucket from Supabase Dashboard > Storage if needed.
--   * This script does not change the database schema.
--
-- Review carefully, then run once in Supabase Dashboard > SQL Editor.

begin;

do $$
begin
    if to_regclass('public.community_activity_log') is not null then
        execute 'delete from public.community_activity_log';
    end if;
    if to_regclass('public.community_roster_snapshots') is not null then
        execute 'delete from public.community_roster_snapshots';
    end if;
    if to_regclass('public.community_player_levels') is not null then
        execute 'delete from public.community_player_levels';
    end if;
    if to_regclass('public.community_payment_proofs') is not null then
        execute 'delete from public.community_payment_proofs';
    end if;
    if to_regclass('public.community_event_history') is not null then
        execute 'delete from public.community_event_history';
    end if;
    if to_regclass('public.community_players') is not null then
        execute 'delete from public.community_players';
    end if;
    if to_regclass('public.community_invite_uses') is not null then
        execute 'delete from public.community_invite_uses';
    end if;
    if to_regclass('public.community_invites') is not null then
        execute 'delete from public.community_invites';
    end if;
    if to_regclass('public.community_members') is not null then
        execute 'delete from public.community_members';
    end if;
    if to_regclass('public.community_matches') is not null then
        execute 'delete from public.community_matches';
    end if;
    if to_regclass('public.communities') is not null then
        execute 'delete from public.communities';
    end if;

    -- Legacy tables are not used by the current frontend. Clear them when they
    -- exist so an old installation cannot retain old test rows.
    if to_regclass('public.pemain') is not null then
        execute 'delete from public.pemain';
    end if;
    if to_regclass('public.jadwal_lapangan') is not null then
        execute 'delete from public.jadwal_lapangan';
    end if;
    if to_regclass('public.event_history') is not null then
        execute 'delete from public.event_history';
    end if;
    if to_regclass('public.admin_settings') is not null then
        execute 'delete from public.admin_settings';
    end if;
end
$$;

commit;

-- Expected after a successful run:
--   communities             0
--   community_members       0
--   community_players       0
--   community_matches       0
--   community_event_history 0
--   community_invites       0
--   community_invite_uses   0
--   community_payment_proofs 0
--   community_roster_snapshots 0
--   community_activity_log  0
--   community_player_levels 0
