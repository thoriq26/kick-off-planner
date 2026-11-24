-- ============================================================
-- FULL DESTRUCTIVE RESET untuk KickOff Planner
-- ============================================================
-- Jalankan HANYA di Supabase Dashboard > SQL Editor.
--
-- Script ini menghapus:
--   * seluruh data aplikasi (komunitas, anggota, pemain, match, arsip,
--     undangan, bukti transfer, snapshot, log aktivitas, level pemain)
--   * tabel legacy jika masih ada
--   * SEMUA akun login di auth.users (otomatis menghapus sesi/identity
--     dan public.profiles lewat ON DELETE CASCADE)
--
-- Script ini TIDAK menghapus:
--   * struktur tabel/fungsi/RLS/migration
--   * file fisik di Storage. Kosongkan bucket "payment-proofs" lewat
--     Supabase Dashboard > Storage, bukan SQL.
--
-- PERINGATAN:
--   * Semua pengguna akan logout dan akun login akan hilang permanen.
--   * Akun owner/admin yang sedang dipakai ikut terhapus. Setelah reset,
--     daftar ulang akun baru untuk komunitas production.
--   * Ambil backup dulu jika data masih mungkin dibutuhkan.
--
-- Kalau hanya ingin menghapus data komunitas tetapi TETAP mempertahankan
-- akun login, gunakan reset_test_data.sql, bukan file ini.
--
-- Review, lalu run sekali.
-- ============================================================

begin;

do $$
begin
    -- Data aplikasi dihapus lebih dulu supaya tidak bergantung pada cascade
    -- dari auth.users. Tabel yang belum ada (migration belum lengkap) dilewati.
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

    -- Legacy tables dari versi lama aplikasi.
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

-- Profil tidak lagi punya arti tanpa akun login. Hapus dulu agar tidak ada
-- baris yatim kalau ada profil lama yang tidak terhubung ke auth.users.
do $$
begin
    if to_regclass('public.profiles') is not null then
        execute 'delete from public.profiles';
    end if;
end
$$;

-- Menghapus auth.users ikut menghapus auth.identities, auth.sessions,
-- auth.refresh_tokens, dan profil melalui foreign key cascade.
delete from auth.users;

commit;

-- Verifikasi setelah run:
-- select
--     (select count(*) from public.communities) as communities,
--     (select count(*) from public.community_members) as members,
--     (select count(*) from public.community_players) as players,
--     (select count(*) from public.community_matches) as matches,
--     (select count(*) from public.community_event_history) as history,
--     (select count(*) from public.community_invites) as invites,
--     (select count(*) from public.community_payment_proofs) as proofs,
--     (select count(*) from public.profiles) as profiles,
--     (select count(*) from auth.users) as auth_users;
--
-- Semua nilai harus 0.
-- Jangan lupa: Supabase Dashboard > Storage > payment-proofs > Empty/Delete.
