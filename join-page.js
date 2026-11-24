(() => {
    const PENDING_INVITE_KEY = "kop_pending_invite";
    const fragmentToken = new URLSearchParams(window.location.hash.slice(1)).get("token");
    const queryToken = new URLSearchParams(window.location.search).get("token");

    function readSessionInvite() {
        try {
            return sessionStorage.getItem(PENDING_INVITE_KEY);
        } catch {
            return null;
        }
    }

    const sessionToken = readSessionInvite();

    function readStoredInvite() {
        try {
            const raw = JSON.parse(localStorage.getItem(PENDING_INVITE_KEY) || "null");
            if (!raw || !raw.token) return null;
            if (Date.now() - (raw.savedAt || 0) > 30 * 24 * 60 * 60 * 1000) {
                try {
                    localStorage.removeItem(PENDING_INVITE_KEY);
                } catch {
                    // Ignore storage access errors.
                }
                return null;
            }
            return raw.token;
        } catch {
            try {
                localStorage.removeItem(PENDING_INVITE_KEY);
            } catch {
                // Ignore storage access errors.
            }
            return null;
        }
    }

    function clearPendingInvite() {
        try {
            sessionStorage.removeItem(PENDING_INVITE_KEY);
        } catch {
            // Ignore storage access errors.
        }
        try {
            localStorage.removeItem(PENDING_INVITE_KEY);
        } catch {
            // Ignore storage access errors; the server-side invite is already used.
        }
    }

    function rememberInvite(value) {
        if (!value) return;
        try {
            sessionStorage.setItem(PENDING_INVITE_KEY, value);
        } catch {
            // Ignore storage access errors.
        }
        // Remember in localStorage as well so the invite survives closing the
        // tab and the onboarding page can auto-join after email verification.
        try {
            localStorage.setItem(
                PENDING_INVITE_KEY,
                JSON.stringify({ token: value, savedAt: Date.now() }),
            );
        } catch {
            // Private browsing may block localStorage; sessionStorage fallback stays.
        }
    }

    // An email verification link can open in a new tab, so sessionStorage may
    // be empty by the time this page loads. Fall back to the durable copy.
    const storedToken = readStoredInvite();
    const token = fragmentToken || queryToken || storedToken || sessionToken;
    rememberInvite(token);
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

    window.KOP.auth.getContext({ requireCommunity: false }).then(async (context) => {
        if (!context) return;
        const metadataSavedAt = Number(context.user?.user_metadata?.pending_invite_saved_at || 0);
        const metadataIsFresh =
            !metadataSavedAt || Date.now() - metadataSavedAt <= 30 * 24 * 60 * 60 * 1000;
        const metadataToken =
            metadataIsFresh && typeof context.user?.user_metadata?.pending_invite === "string"
                ? context.user.user_metadata.pending_invite.trim()
                : "";
        const inviteToken = token || metadataToken;
        if (!inviteToken) {
            message.textContent = "Token undangan tidak ditemukan.";
            return;
        }
        rememberInvite(inviteToken);
        message.textContent = "Menghubungkan ke komunitas...";
        try {
            const { data, error } = await window.KOP.supabase.rpc("accept_community_invite", {
                p_token: inviteToken,
            });
            if (error) {
                if (/expired|revoked|already used/i.test(error.message || "")) {
                    clearPendingInvite();
                }
                message.textContent = formatInviteError(error.message);
                return;
            }
            const membership = Array.isArray(data) ? data[0] : data;
            if (!membership) throw new Error("Undangan tidak mengembalikan komunitas.");
            const communityId = membership.joined_community_id || membership.community_id;
            const role = membership.joined_role || membership.role;
            await window.KOP.auth.setSelectedCommunity(communityId);
            clearPendingInvite();
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
