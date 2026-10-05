(() => {
    const KOP = window.KOP;
    if (!KOP || !KOP.supabase) {
        throw new Error("supabase-client.js must be loaded before auth-guard.js");
    }

    const sb = KOP.supabase;
    const storageKey = KOP.communityStorageKey;
    const defaultHome = "index.html";

    function escapeHtml(value) {
        return String(value ?? "").replace(/[&<>"']/g, (character) => ({
            "&": "&amp;",
            "<": "&lt;",
            ">": "&gt;",
            '"': "&quot;",
            "'": "&#39;",
        }[character]));
    }

    function isSafeMapUrl(value) {
        try {
            const url = new URL(value);
            return url.protocol === "https:" && [
                "www.google.com",
                "maps.google.com",
                "maps.app.goo.gl",
                "www.googleusercontent.com",
            ].includes(url.hostname);
        } catch {
            return false;
        }
    }

    function currentPath() {
        return `${window.location.pathname}${window.location.search}`;
    }

    function loginRedirect() {
        const pendingInvite = sessionStorage.getItem("kop_pending_invite");
        const next = pendingInvite ? "join.html" : currentPath();
        return `auth.html?next=${encodeURIComponent(next)}`;
    }

    async function getUser() {
        const { data, error } = await sb.auth.getUser();
        if (error) {
            if (error.name === "AuthSessionMissingError" || /auth session missing/i.test(error.message || "")) {
                return null;
            }
            throw error;
        }
        return data.user;
    }

    async function getCommunities(user) {
        const { data: memberships, error: membershipError } = await sb
            .from("community_members")
            .select("community_id, role")
            .eq("user_id", user.id);

        if (membershipError) throw membershipError;
        if (!memberships?.length) return [];

        const ids = memberships.map((membership) => membership.community_id);
        const { data: communities, error: communityError } = await sb
            .from("communities")
            .select("id, name, slug")
            .in("id", ids);

        if (communityError) throw communityError;
        const byId = new Map((communities || []).map((community) => [community.id, community]));

        return memberships
            .map((membership) => ({
                ...byId.get(membership.community_id),
                role: membership.role,
            }))
            .filter((community) => community.id);
    }

    function rememberCommunity(communityId) {
        if (communityId) localStorage.setItem(storageKey, communityId);
    }

    function forgetCommunity() {
        localStorage.removeItem(storageKey);
    }

    async function getContext(options = {}) {
        const user = await getUser();
        if (!user) {
            window.location.replace(loginRedirect());
            return null;
        }

        const communities = await getCommunities(user);
        if (options.requireCommunity !== false && communities.length === 0) {
            sessionStorage.setItem("kop_after_onboarding", currentPath());
            window.location.replace("onboarding.html");
            return null;
        }

        const rememberedId = localStorage.getItem(storageKey);
        const community =
            communities.find((item) => item.id === rememberedId) || communities[0] || null;

        if (options.requireCommunity !== false) {
            if (!community) {
                sessionStorage.setItem("kop_after_onboarding", currentPath());
                window.location.replace("onboarding.html");
                return null;
            }
            rememberCommunity(community.id);
        }

        if (community && options.roles && !options.roles.includes(community.role)) {
            window.location.replace("index.html?error=admin_required");
            return null;
        }

        const context = {
            user,
            community,
            role: community?.role || null,
            communities,
        };
        window.KOP.context = context;
        return context;
    }

    async function setSelectedCommunity(communityId) {
        rememberCommunity(communityId);
    }

    async function signOut() {
        await sb.auth.signOut();
        forgetCommunity();
        window.location.href = defaultHome;
    }

    function addTextElement(parent, tag, text, className) {
        const element = document.createElement(tag);
        element.textContent = text;
        if (className) element.className = className;
        parent.appendChild(element);
        return element;
    }

    async function renderAccountBar(elementId = "accountBar") {
        const bar = document.getElementById(elementId);
        if (!bar) return;

        bar.replaceChildren();
        const user = await getUser();
        if (!user) {
            const login = addTextElement(bar, "a", "MASUK / DAFTAR", "account-link");
            login.href = "auth.html";
            return;
        }

        addTextElement(bar, "span", user.email, "account-email");
        const communities = await getCommunities(user);
        let selectedCommunity = null;
        if (communities.length === 0) {
            const onboarding = addTextElement(bar, "a", "BUAT / GABUNG KOMUNITAS", "account-link");
            onboarding.href = "onboarding.html";
        } else {
            const rememberedId = localStorage.getItem(storageKey);
            selectedCommunity = communities.find((item) => item.id === rememberedId) || communities[0];
            const select = addTextElement(bar, "select", "", "community-select");
            communities.forEach((community) => {
                const option = document.createElement("option");
                option.value = community.id;
                option.textContent = community.name;
                option.selected = community.id === selectedCommunity.id;
                select.appendChild(option);
            });
            select.addEventListener("change", async () => {
                await setSelectedCommunity(select.value);
                window.location.reload();
            });
            bar.dataset.communityId = selectedCommunity.id;
            const joinAnother = addTextElement(bar, "a", "GABUNG / BUAT", "account-link");
            joinAnother.href = "onboarding.html";
        }

        if (selectedCommunity && ["owner", "admin"].includes(selectedCommunity.role)) {
            const admin = addTextElement(bar, "a", "PANEL ADMIN", "account-link");
            admin.href = "admin.html";
        }
        const logout = addTextElement(bar, "button", "KELUAR", "account-link account-button");
        logout.addEventListener("click", signOut);
    }

    window.KOP.escapeHtml = escapeHtml;
    window.KOP.isSafeMapUrl = isSafeMapUrl;
    window.KOP.auth = {
        getUser,
        getCommunities,
        getContext,
        setSelectedCommunity,
        forgetCommunity,
        signOut,
        renderAccountBar,
    };
})();
