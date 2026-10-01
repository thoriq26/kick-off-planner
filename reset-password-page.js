(() => {
    const sb = window.KOP.supabase;
    const requestedNext = new URLSearchParams(window.location.search).get("next") || "auth.html";
    let nextUrl;
    try {
        nextUrl = new URL(requestedNext, window.location.origin);
    } catch {
        nextUrl = new URL("/auth.html", window.location.origin);
    }
    const next = nextUrl.origin === window.location.origin
        ? `${nextUrl.pathname}${nextUrl.search}${nextUrl.hash}`
        : "auth.html";
    const form = document.getElementById("resetForm");
    const message = document.getElementById("resetMessage");
    const password = document.getElementById("newPassword");
    const confirmation = document.getElementById("confirmNewPassword");
    let recoveryReady = false;

    function showMessage(text, type = "") {
        message.textContent = text;
        message.className = `form-message ${type}`;
    }

    async function checkSession() {
        const { data, error } = await sb.auth.getSession();
        if (error) {
            showMessage(error.message, "error");
            return;
        }
        recoveryReady = Boolean(data.session);
        if (!recoveryReady) {
            showMessage("Tautan reset tidak valid atau sudah kedaluwarsa. Minta tautan baru dari halaman login.");
        }
    }

    sb.auth.onAuthStateChange((event, session) => {
        if (event === "PASSWORD_RECOVERY" || session) {
            recoveryReady = true;
            showMessage("Tautan valid. Silakan buat password baru.");
        }
    });

    form.addEventListener("submit", async (event) => {
        event.preventDefault();
        if (!recoveryReady) {
            showMessage("Sesi reset password belum siap.", "error");
            return;
        }
        if (password.value !== confirmation.value) {
            showMessage("Konfirmasi password tidak sama.", "error");
            return;
        }
        const { error } = await sb.auth.updateUser({ password: password.value });
        if (error) {
            showMessage(error.message, "error");
            return;
        }
        showMessage("Password berhasil diperbarui. Anda akan diarahkan ke login.", "success");
        setTimeout(() => {
            window.location.replace(next);
        }, 1200);
    });

    checkSession();
})();
