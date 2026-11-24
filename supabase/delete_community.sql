-- ============================================================
-- Hapus SATU komunitas saja
-- ============================================================
-- Jalankan di Supabase Dashboard > SQL Editor.
--
-- target_key boleh berupa:
--   * slug komunitas, misalnya 'liga-kampung'
--   * UUID komunitas
--   * nama komunitas persis, misalnya 'tes'
--
-- Script ini sudah diisi contoh 'tes' sesuai komunitas di screenshot.
-- Untuk komunitas lain, ganti nilai target_key di bawah.
--
-- Sebelum menghapus, cek kandidat komunitas:
--   select c.id, c.name, c.slug, c.created_at, u.email as owner_email
--     from public.communities c
--     left join auth.users u on u.id = c.owner_id
--    where lower(btrim(c.name)) = lower(btrim('tes'))
--       or c.slug = 'tes'
--    order by c.created_at;
--
-- Kalau ada lebih dari satu komunitas dengan nama yang sama, script akan
-- berhenti dan meminta slug/UUID. Jadi tidak akan menghapus komunitas lain
-- secara tidak sengaja.
--
-- Yang ikut terhapus:
--   * anggota komunitas
--   * pemain
--   * match dan bukti transfer (metadata)
--   * arsip/history
--   * undangan dan riwayat pemakaian undangan
--   * snapshot roster
--   * activity log
--   * level pemain
--   * nama tim kustom
--
-- Data anak dihapus lebih dulu, baru baris komunitas. Ini penting karena
-- trigger activity log menulis ke community_activity_log dan akan gagal jika
-- baris komunitas sudah terhapus lebih dulu.
--
-- Yang TIDAK terhapus:
--   * akun login auth.users
--   * public.profiles
--   * komunitas lain
--   * file fisik di bucket payment-proofs (hapus manual lewat Storage)
-- ============================================================

begin;

do $$
declare
    target_key text := 'tes';
    target_id uuid;
    target_name text;
    target_slug text;
    name_matches integer;
    deleted_rows integer;
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

    raise notice 'Menghapus komunitas "%" (slug: %, id: %).',
        target_name, target_slug, target_id;
    raise notice 'Folder Storage bukti transfer: payment-proofs/%/', target_id;

    -- Jangan langsung DELETE communities. Trigger log pada child table akan
    -- mencoba insert ke community_activity_log dengan community_id yang sudah
    -- tidak ada (FK violation). Hapus child rows dulu saat parent masih ada.
    perform set_config('kop.skip_promotion', 'on', true);

    delete from public.community_payment_proofs where community_id = target_id;
    delete from public.community_event_history where community_id = target_id;
    delete from public.community_invite_uses where community_id = target_id;
    delete from public.community_invites where community_id = target_id;
    delete from public.community_players where community_id = target_id;
    delete from public.community_matches where community_id = target_id;
    delete from public.community_roster_snapshots where community_id = target_id;
    delete from public.community_player_levels where community_id = target_id;
    delete from public.community_team_names where community_id = target_id;
    delete from public.community_members where community_id = target_id;

    -- Trigger di atas menghasilkan log baru; bersihkan setelah semua child
    -- rows selesai dihapus, lalu hapus baris komunitas.
    delete from public.community_activity_log where community_id = target_id;

    delete from public.communities
     where id = target_id;

    get diagnostics deleted_rows = row_count;
    raise notice 'Selesai. % baris komunitas dihapus; data turunannya ikut terhapus.',
        deleted_rows;
end
$$;

commit;

-- Verifikasi setelah run: komunitas target harus sudah tidak ada.
-- select id, name, slug from public.communities order by name;
--
-- File bukti transfer TIDAK terhapus oleh SQL. Setelah komunitas dihapus,
-- buka Supabase Dashboard > Storage > payment-proofs dan hapus folder
-- yang namanya sama dengan ID komunitas yang tadi (lihat NOTICE di atas).
