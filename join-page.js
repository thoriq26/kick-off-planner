(() => {
    const fragmentToken = new URLSearchParams(window.location.hash.slice(1)).get("token");
    const queryToken = new URLSearchParams(window.location.search).get("token");
    const token = fragmentToken || queryToken || sessionStorage.getItem("kop_pending_invite");
    if (token) sessionStorage.setItem("kop_pending_invite", token);
    const message = document.getElementById("joinMessage");

    function formatInviteError(value) {
        if (/expired|revoked|already used/i.test(value || "")) {
            return "Undangan tidak valid, sudah kedaluwarsa, dicabut, atau sudah dipakai.";
        }
        return value;
    }

    if (!token) {
        message.textContent = "Token undangan tidak ditemukan.";
        return;
    }

    window.KOP.auth.getContext({ requireCommunity: false }).then(async (context) => {
        if (!context) return;
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
        const pending = sessionStorage.getItem("kop_after_onboarding");
        sessionStorage.removeItem("kop_after_onboarding");
        window.location.href = pending || (role === "member" ? "index.html" : "admin.html");
    }).catch((error) => {
        message.textContent = error.message;
    });
})();
