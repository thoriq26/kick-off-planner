(() => {
    const sb = window.KOP.supabase;
    const message = document.getElementById("onboardingMessage");
    const membershipList = document.getElementById("membershipList");
    const createForm = document.getElementById("createCommunityForm");
    const joinForm = document.getElementById("joinCommunityForm");
    const nameInput = document.getElementById("communityName");
    const slugInput = document.getElementById("communitySlug");
    const inviteInput = document.getElementById("inviteCode");
    const inviteCodeFromUrl = new URLSearchParams(window.location.search).get("code");
    if (inviteCodeFromUrl) inviteInput.value = inviteCodeFromUrl;
    let context;

    function showMessage(text, type = "") {
        message.textContent = text;
        message.className = `form-message ${type}`;
    }

    function redirectAfterOnboarding(fallback) {
        const pending = sessionStorage.getItem("kop_after_onboarding");
        sessionStorage.removeItem("kop_after_onboarding");
        window.location.href = pending || fallback;
    }

    function formatInviteError(message) {
        if (/expired|revoked|already used/i.test(message || "")) {
            return "Undangan tidak valid, sudah kedaluwarsa, dicabut, atau sudah dipakai.";
        }
        return message;
    }

    function extractInviteToken(value) {
        const raw = value.trim();
        try {
            const url = new URL(raw);
            return url.hash.startsWith("#token=")
                ? decodeURIComponent(url.hash.slice("#token=".length))
                : url.searchParams.get("token") || raw;
        } catch {
            const match = raw.match(/[#?&]token=([^&]+)/);
            return match ? decodeURIComponent(match[1]) : raw;
        }
    }

    function slugify(value) {
        return value
            .toLowerCase()
            .trim()
            .replace(/[^a-z0-9]+/g, "-")
            .replace(/^-+|-+$/g, "")
            .slice(0, 48);
    }

    function renderMemberships() {
        membershipList.replaceChildren();
        if (!context.communities.length) {
            const empty = document.createElement("p");
            empty.className = "subtitle";
            empty.textContent = "Belum ada komunitas.";
            membershipList.appendChild(empty);
            return;
        }
        context.communities.forEach((community) => {
            const row = document.createElement("div");
            row.className = "membership-item";
            const label = document.createElement("span");
            label.textContent = `${community.name} (${community.role})`;
            const button = document.createElement("a");
            button.href = community.role === "member" ? "index.html" : "admin.html";
            button.textContent = "Buka";
            button.addEventListener("click", async () => {
                await window.KOP.auth.setSelectedCommunity(community.id);
            });
            row.append(label, button);
            membershipList.appendChild(row);
        });
    }

    createForm.addEventListener("submit", async (event) => {
        event.preventDefault();
        showMessage("");
        const name = nameInput.value.trim();
        let slug = slugInput.value.trim() || slugify(name);
        if (slug !== slugify(slug)) slug = slugify(slug);
        if (slug.length < 2) {
            showMessage("Slug harus memiliki minimal 2 karakter.", "error");
            return;
        }
        const { data, error } = await sb.rpc("create_community", {
            p_name: name,
            p_slug: slug,
        });
        if (error) {
            showMessage(error.message, "error");
            return;
        }
        await window.KOP.auth.setSelectedCommunity(data);
        redirectAfterOnboarding("admin.html");
    });

    joinForm.addEventListener("submit", async (event) => {
        event.preventDefault();
        showMessage("");
        const { data, error } = await sb.rpc("accept_community_invite", {
            p_token: extractInviteToken(inviteInput.value),
        });
        if (error) {
            showMessage(formatInviteError(error.message), "error");
            return;
        }
        const membership = Array.isArray(data) ? data[0] : data;
        if (!membership) throw new Error("Undangan tidak mengembalikan komunitas.");
        const communityId = membership.joined_community_id || membership.community_id;
        const role = membership.joined_role || membership.role;
        await window.KOP.auth.setSelectedCommunity(communityId);
        redirectAfterOnboarding(role === "member" ? "index.html" : "admin.html");
    });

    nameInput.addEventListener("input", () => {
        if (!slugInput.dataset.touched) slugInput.value = slugify(nameInput.value);
    });
    slugInput.addEventListener("input", () => {
        slugInput.dataset.touched = "true";
    });

    window.KOP.auth.getContext({ requireCommunity: false }).then((result) => {
        if (!result) return;
        context = result;
        renderMemberships();
    }).catch((error) => showMessage(error.message, "error"));
})();
