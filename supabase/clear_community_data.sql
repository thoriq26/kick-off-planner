-- ============================================================
-- Hapus ISI satu komunitas, tetapi komunitasnya tetap ada
-- ============================================================
-- Jalankan di Supabase Dashboard > SQL Editor.
--
-- Gunakan script ini kalau ingin "mengosongkan" komunitas:
-- anggota dan komunitas tetap ada, tetapi data operasionalnya dihapus.
--
-- target_key boleh berupa:
--   * slug komunitas, misalnya 'liga-kampung'
--   * UUID komunitas
--   * nama komunitas persis, misalnya 'tes'
--
-- Script ini sudah diisi contoh 'tes' sesuai komunitas di screenshot.
-- Untuk komunitas lain, ganti nilai target_key di bawah.
--
-- Yang dihapus:
--   * pemain dan daftar tunggu
--   * match dan info pertandingan
--   * arsip/history
--   * bukti transfer (metadata)
--   * undangan dan riwayat pemakaian undangan
--   * snapshot roster
--   * activity log
--   * level pemain
--
-- Yang tetap ada:
--   * baris komunitas (nama, slug, owner)
--   * anggota komunitas dan role-nya
--   * akun login auth.users
--   * public.profiles
--   * nama tim kustom
--   * file fisik di bucket payment-proofs (hapus manual lewat Storage)
--
-- Untuk menghapus komunitas sekaligus anggotanya, gunakan
-- delete_community.sql, bukan script ini.
-- ============================================================

begin;

do $$
declare
    target_key text := 'tes';
    target_id uuid;
    target_name text;
    target_slug text;
    name_matches integer;
begin
    if target_key is null or btrim(target_key) = '' then
        raise exception 'target_key wajib diisi.';
    end if;

    -- Prioritas 1: slug atau UUID (paling spesifik).
    select id, name, slug
      into target_id, target_name, target_slug
      from public.communities
     where slug = lower(btrim(target_key))
        or id::text = lower(btrim(target_key))
     limit 1;

    -- Prioritas 2: nama persis, hanya jika hasilnya tunggal.
    if target_id is null then
        select count(*)
          into name_matches
          from public.communities
         where lower(btrim(name)) = lower(btrim(target_key));

        if name_matches = 0 then
            raise exception 'Komunitas "%" tidak ditemukan. Cek daftar komunitas terlebih dahulu.',
                target_key;
        end if;

        if name_matches > 1 then
            raise exception 'Ada % komunitas bernama "%". Gunakan slug atau UUID dari query daftar komunitas.',
                name_matches, target_key;
        end if;

        select id, name, slug
          into target_id, target_name, target_slug
          from public.communities
         where lower(btrim(name)) = lower(btrim(target_key))
         limit 1;
    end if;

    raise notice 'Mengosongkan isi komunitas "%" (slug: %, id: %).',
        target_name, target_slug, target_id;

    -- Cegah trigger waitlist mempromosikan pemain saat semua pemain dihapus.
    perform set_config('kop.skip_promotion', 'on', true);

    -- Hapus data operasional. Activity log dihapus paling akhir karena
    -- trigger pada tabel lain dapat menulis log baru saat proses delete.
    delete from public.community_payment_proofs where community_id = target_id;
    delete from public.community_event_history where community_id = target_id;
    delete from public.community_invite_uses where community_id = target_id;
    delete from public.community_invites where community_id = target_id;
    delete from public.community_players where community_id = target_id;
    delete from public.community_matches where community_id = target_id;
    delete from public.community_roster_snapshots where community_id = target_id;
    delete from public.community_player_levels where community_id = target_id;

    -- Opsional: hapus nama tim kustom agar kembali ke label default.
    -- delete from public.community_team_names where community_id = target_id;

    delete from public.community_activity_log where community_id = target_id;

    raise notice 'Selesai. Komunitas "%" tetap ada; isinya sudah dikosongkan.',
        target_name;
    raise notice 'File bukti transfer lama ada di payment-proofs/%/ dan harus dihapus manual dari Storage.',
        target_id;
end
$$;

commit;

-- Verifikasi setelah run:
--   * komunitas target masih ada
--   * pemain, match, arsip, undangan, dan log target sudah kosong
--
-- select c.id, c.name, c.slug,
--        (select count(*) from public.community_players p where p.community_id = c.id) as players,
--        (select count(*) from public.community_matches m where m.community_id = c.id) as matches,
--        (select count(*) from public.community_event_history h where h.community_id = c.id) as history,
--        (select count(*) from public.community_invites i where i.community_id = c.id) as invites
--   from public.communities c
--  where lower(btrim(c.name)) = lower(btrim('tes'))
--     or c.slug = 'tes';
