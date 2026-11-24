(() => {
    const sb = window.KOP.supabase;
    const message = document.getElementById("onboardingMessage");
    const membershipList = document.getElementById("membershipList");
    const createForm = document.getElementById("createCommunityForm");
    const joinForm = document.getElementById("joinCommunityForm");
    const nameInput = document.getElementById("communityName");
    const slugInput = document.getElementById("communitySlug");
    const inviteInput = document.getElementById("inviteCode");
    const inviteCodeFromUrl = inviteCodeFromUrlValue();
    if (inviteCodeFromUrl) inviteInput.value = inviteCodeFromUrl;
    let context;
    let autoJoining = false;

    // A pending invite code is remembered across sessions so a brand-new user
    // who verifies their email later still ends up inside the community
    // without having to re-enter the code.
    const PENDING_INVITE_KEY = "kop_pending_invite";

    function inviteCodeFromUrlValue() {
        return new URLSearchParams(window.location.search).get("code");
    }

    // Save the code BEFORE the auth redirect. Sebelumnya kode hanya disimpan
    // setelah login, sehingga tautan verifikasi email yang membuka halaman
    // onboarding tanpa query ?code= membuat undangan hilang.
    if (inviteCodeFromUrl) {
        savePendingInvite(inviteCodeFromUrl);
    } else {
        const storedInviteCode = loadPendingInvite();
        if (storedInviteCode) inviteInput.value = storedInviteCode;
    }

    function savePendingInvite(code) {
        if (!code) return;
        try {
            localStorage.setItem(
                PENDING_INVITE_KEY,
                JSON.stringify({ token: code, savedAt: Date.now() }),
            );
        } catch {
            // Private browsing may block localStorage; the URL still carries
            // the code until the auth redirect.
        }
        try {
            sessionStorage.setItem(PENDING_INVITE_KEY, code);
        } catch {
            // Ignore storage access errors; the URL still carries the code.
        }
    }

    function clearPendingInvite() {
        try {
            localStorage.removeItem(PENDING_INVITE_KEY);
        } catch {
            // Ignore storage access errors.
        }
        try {
            sessionStorage.removeItem(PENDING_INVITE_KEY);
        } catch {
            // Ignore storage access errors.
        }
    }

    function loadPendingInvite() {
        try {
            const raw = JSON.parse(localStorage.getItem(PENDING_INVITE_KEY) || "null");
            if (!raw || !raw.token) return null;
            // Ignore stale invites older than 30 days.
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

    function showMessage(text, type = "") {
        message.textContent = text;
        message.className = `form-message ${type}`;
        if (text) message.scrollIntoView({ behavior: "smooth", block: "nearest" });
    }

    // Give every submit immediate visual feedback so slow or hanging requests
    // never look like "the button did nothing".
    function setBusy(form, busy, label) {
        const button = form.querySelector('button[type="submit"]');
        if (!button) return;
        button.disabled = busy;
        if (busy) {
            button.dataset.originalText = button.textContent;
            button.textContent = label || "MEMPROSES...";
        } else if (button.dataset.originalText) {
            button.textContent = button.dataset.originalText;
            delete button.dataset.originalText;
        }
    }

    function describeFailure(error) {
        const detail = error && (error.message || error.detail) ? error.message || error.detail : "";
        if (typeof detail === "string" && /fetch|network|failed to fetch|load failed/i.test(detail)) {
            return "Tidak dapat menghubungi server. Periksa koneksi internet Anda, lalu coba lagi.";
        }
        return window.KOP.translateError(detail || "Terjadi kesalahan tak terduga. Muat ulang halaman lalu coba lagi.");
    }

    function redirectAfterOnboarding(fallback) {
        const pending = sessionStorage.getItem("kop_after_onboarding");
        sessionStorage.removeItem("kop_after_onboarding");
        const target = pending && !pending.includes("onboarding.html") ? pending : fallback;
        window.location.href = target || fallback;
    }

    async function acceptInvite(token) {
        const { data, error } = await sb.rpc("accept_community_invite", {
            p_token: token,
        });
        if (error) throw error;
        const membership = Array.isArray(data) ? data[0] : data;
        if (!membership) throw new Error("Undangan tidak mengembalikan komunitas.");
        return {
            communityId: membership.joined_community_id || membership.community_id,
            role: membership.joined_role || membership.role,
        };
    }

    // New-user flow: an invitation link (?code=...) is remembered in
    // localStorage, and after the account is verified this page joins the
    // user automatically. Auto-join only runs when the visitor explicitly
    // came with a code, or has no community yet (fresh verification return).
    async function autoJoinPendingInvite() {
        if (autoJoining) return;
        const urlCode = inviteCodeFromUrl ? extractInviteToken(inviteCodeFromUrl) : null;
        const storedCode = loadPendingInvite();
        const metadataSavedAt = Number(context.user?.user_metadata?.pending_invite_saved_at || 0);
        const metadataIsFresh =
            !metadataSavedAt || Date.now() - metadataSavedAt <= 30 * 24 * 60 * 60 * 1000;
        const metadataCode =
            metadataIsFresh && typeof context.user?.user_metadata?.pending_invite === "string"
                ? context.user.user_metadata.pending_invite.trim()
                : "";
        const pendingCode = storedCode || metadataCode;
        if (urlCode) savePendingInvite(urlCode);
        if (metadataCode && !storedCode) savePendingInvite(metadataCode);
        if (!inviteInput.value && pendingCode) inviteInput.value = pendingCode;

        const alreadyMember = (context.communities || []).length > 0;
        if (!urlCode && (alreadyMember || !pendingCode)) return;

        const token = urlCode || pendingCode;
        if (!token) return;
        autoJoining = true;
        showMessage("Menghubungkan ke komunitas, mohon tunggu...", "");
        joinForm.querySelector('button[type="submit"]').disabled = true;
        try {
            const { communityId, role } = await acceptInvite(token);
            clearPendingInvite();
            await window.KOP.auth.setSelectedCommunity(communityId);
            showMessage("Berhasil bergabung dengan komunitas! Mengalihkan...", "success");
            setTimeout(() => redirectAfterOnboarding(role === "member" ? "index.html" : "admin.html"), 600);
        } catch (error) {
            autoJoining = false;
            joinForm.querySelector('button[type="submit"]').disabled = false;
            const detail = error && error.message ? error.message : "";
            if (/expired|revoked|already used/i.test(detail)) {
                // A stale remembered code should not nag forever.
                clearPendingInvite();
            }
            showMessage(formatInviteError(detail), "error");
        }
    }

    function formatInviteError(message) {
        if (/expired|revoked|already used/i.test(message || "")) {
            return "Undangan tidak valid, sudah kedaluwarsa, dicabut, atau sudah dipakai.";
        }
        if (/must be verified|not verified|email address/i.test(message || "")) {
            return "Email Anda belum terverifikasi. Buka email verifikasi dari Supabase terlebih dahulu, lalu coba lagi.";
        }
        if (/authentication required/i.test(message || "")) {
            return "Sesi login Anda berakhir. Muat ulang halaman ini lalu login kembali.";
        }
        if (/token is invalid/i.test(message || "")) {
            return "Kode undangan tidak dikenal. Cek lagi kodenya — slug komunitas bukan kode undangan.";
        }
        return window.KOP.translateError(message);
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
        setBusy(createForm, true, "MEMBUAT KOMUNITAS...");
        try {
            const { data, error } = await sb.rpc("create_community", {
                p_name: name,
                p_slug: slug,
            });
            if (error) {
                showMessage(window.KOP.translateError(error.message), "error");
                return;
            }
            await window.KOP.auth.setSelectedCommunity(data);
            redirectAfterOnboarding("admin.html");
        } catch (error) {
            showMessage(describeFailure(error), "error");
        } finally {
            setBusy(createForm, false);
        }
    });

    joinForm.addEventListener("submit", async (event) => {
        event.preventDefault();
        showMessage("");
        setBusy(joinForm, true, "MENGHUBUNGKAN...");
        try {
            const { data, error } = await sb.rpc("accept_community_invite", {
                p_token: extractInviteToken(inviteInput.value),
            });
            if (error) {
                showMessage(formatInviteError(error.message), "error");
                return;
            }
            const membership = Array.isArray(data) ? data[0] : data;
            if (!membership) {
                showMessage("Undangan tidak mengembalikan komunitas.", "error");
                return;
            }
            const communityId = membership.joined_community_id || membership.community_id;
            const role = membership.joined_role || membership.role;
            clearPendingInvite();
            await window.KOP.auth.setSelectedCommunity(communityId);
            redirectAfterOnboarding(role === "member" ? "index.html" : "admin.html");
        } catch (error) {
            showMessage(describeFailure(error), "error");
        } finally {
            setBusy(joinForm, false);
        }
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
        autoJoinPendingInvite();
    }).catch((error) => showMessage(window.KOP.translateError(error && error.message), "error"));
})();
