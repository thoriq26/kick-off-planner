(() => {
    const PENDING_INVITE_KEY = "kop_pending_invite";
    const fragmentToken = new URLSearchParams(window.location.hash.slice(1)).get("token");
    const queryToken = new URLSearchParams(window.location.search).get("token");
    const sessionToken = sessionStorage.getItem(PENDING_INVITE_KEY);
    const token = fragmentToken || queryToken || sessionToken;
    if (token) {
        sessionStorage.setItem(PENDING_INVITE_KEY, token);
        // Remember in localStorage as well so the invite survives closing the
        // tab and the onboarding page can auto-join after email verification.
        try {
            localStorage.setItem(
                PENDING_INVITE_KEY,
                JSON.stringify({ token, savedAt: Date.now() }),
            );
        } catch {
            // Private browsing may block localStorage; sessionStorage fallback stays.
        }
    }
    const message = document.getElementById("joinMessage");

    function formatInviteError(value) {
        if (/expired|revoked|already used/i.test(value || "")) {
            return "Undangan tidak valid, sudah kedaluwarsa, dicabut, atau sudah dipakai.";
        }
        if (/must be verified|not verified|email address/i.test(value || "")) {
            return "Email Anda belum terverifikasi. Buka email verifikasi dari Supabase terlebih dahulu, lalu coba lagi.";
        }
        if (/authentication required/i.test(value || "")) {
            return "Sesi login Anda berakhir. Muat ulang halaman ini lalu login kembali.";
        }
        if (/token is invalid/i.test(value || "")) {
            return "Kode undangan tidak dikenal. Cek lagi kodenya — slug komunitas bukan kode undangan.";
        }
        return window.KOP.translateError(value);
    }

    if (!token) {
        message.textContent = "Token undangan tidak ditemukan.";
        return;
    }

    window.KOP.auth.getContext({ requireCommunity: false }).then(async (context) => {
        if (!context) return;
        message.textContent = "Menghubungkan ke komunitas...";
        try {
            const { data, error } = await window.KOP.supabase.rpc("accept_community_invite", {
                p_token: token,
            });
            if (error) {
                message.textContent = formatInviteError(error.message);
                return;
            }
            const membership = Array.isArray(data) ? data[0] : data;
            if (!membership) throw new Error("Undangan tidak mengembalikan komunitas.");
            const communityId = membership.joined_community_id || membership.community_id;
            const role = membership.joined_role || membership.role;
            await window.KOP.auth.setSelectedCommunity(communityId);
            sessionStorage.removeItem("kop_pending_invite");
            try {
                localStorage.removeItem(PENDING_INVITE_KEY);
            } catch {
                // localStorage may be unavailable in private browsing.
            }
            const pending = sessionStorage.getItem("kop_after_onboarding");
            sessionStorage.removeItem("kop_after_onboarding");
            const target = pending && !pending.includes("onboarding.html") ? pending : "";
            window.location.href = target || (role === "member" ? "index.html" : "admin.html");
        } catch (error) {
            if (/fetch|network|failed to fetch|load failed/i.test(String(error && error.message))) {
                message.textContent = "Tidak dapat menghubungi server. Periksa koneksi internet Anda, lalu muat ulang halaman ini.";
            } else {
                message.textContent = window.KOP.translateError(error && error.message);
            }
        }
    }).catch((error) => {
        message.textContent = window.KOP.translateError(error && error.message);
    });
})();
