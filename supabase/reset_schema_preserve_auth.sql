-- Destructive reset for the KickOff Planner application schema.
-- This removes community/application data and recreates an empty schema on the
-- next migration run, but intentionally DOES NOT delete auth.users accounts.
-- Review before running. Run once in Supabase SQL Editor, then run migrations
-- 20260924000000, 20260924010000, 20260924020000, 20260924025000,
-- 20260924030000, and 20260924040000 in order.
--
-- Supabase intentionally blocks direct DELETE from storage.objects. Delete the
-- payment-proof bucket through Dashboard > Storage (or the Storage API) before
-- running this file if you also want to remove uploaded proof files.

begin;

-- Remove the auth trigger; the first migration recreates it and backfills
-- profiles for the preserved auth.users.
drop trigger if exists on_auth_user_created on auth.users;

-- Remove application functions. CASCADE is limited to the application objects
-- listed here; it does not delete rows from auth.users.
drop function if exists public.payment_proof_community_id(text) cascade;
drop function if exists public.payment_proof_match_id(text) cascade;
drop function if exists public.payment_proof_user_id(text) cascade;
drop function if exists public.validate_payment_proof() cascade;
drop function if exists public.reset_community_match(uuid) cascade;
drop function if exists public.create_community(text, text) cascade;
drop function if exists public.create_community_invite(uuid, text, integer, integer) cascade;
drop function if exists public.list_community_invites(uuid) cascade;
drop function if exists public.revoke_community_invite(uuid) cascade;
drop function if exists public.list_community_members(uuid) cascade;
drop function if exists public.set_community_member_status(uuid, uuid, boolean) cascade;
drop function if exists public.remove_community_member(uuid, uuid) cascade;
drop function if exists public.list_community_invite_users(uuid) cascade;
drop function if exists public.accept_community_invite(text) cascade;
drop function if exists public.publish_community_match(uuid, text, text, text, text, text, text, text) cascade;
drop function if exists public.archive_community_match(uuid) cascade;
drop function if exists public.register_community_player(uuid, text, text) cascade;
drop function if exists public.protect_community_player_write() cascade;
drop function if exists public.protect_community_member_role() cascade;
drop function if exists public.is_verified_user(uuid) cascade;
drop function if exists public.is_community_owner(uuid, uuid) cascade;
drop function if exists public.is_community_admin(uuid, uuid) cascade;
drop function if exists public.is_community_member(uuid, uuid) cascade;
drop function if exists public.handle_new_user() cascade;

-- Remove the new application tables.
drop table if exists public.community_payment_proofs cascade;
drop table if exists public.community_event_history cascade;
drop table if exists public.community_matches cascade;
drop table if exists public.community_players cascade;
drop table if exists public.community_invite_uses cascade;
drop table if exists public.community_invites cascade;
drop table if exists public.community_members cascade;
drop table if exists public.communities cascade;
drop table if exists public.profiles cascade;

-- The old password table is no longer used by Supabase Auth. This reset also
-- removes the legacy application tables; auth.users is not touched.
drop table if exists public.pemain cascade;
drop table if exists public.jadwal_lapangan cascade;
drop table if exists public.event_history cascade;
drop table if exists public.admin_settings cascade;

commit;
