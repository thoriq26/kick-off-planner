(() => {
    const sb = window.KOP.supabase;
    const params = new URLSearchParams(window.location.search);
    const requestedNext = params.get("next") || "onboarding.html";
    let nextUrl;
    try {
        nextUrl = new URL(requestedNext, window.location.origin);
    } catch {
        nextUrl = new URL("/onboarding.html", window.location.origin);
    }
    if (nextUrl.origin !== window.location.origin) {
        nextUrl = new URL("/onboarding.html", window.location.origin);
    }
    const next = `${nextUrl.pathname}${nextUrl.search}`;

    const title = document.getElementById("authTitle");
    const subtitle = document.getElementById("authSubtitle");
    const form = document.getElementById("authForm");
    const tabs = document.getElementById("authTabs");
    const nameField = document.getElementById("nameField");
    const confirmField = document.getElementById("confirmField");
    const fullName = document.getElementById("fullName");
    const email = document.getElementById("email");
    const passwordLabel = document.getElementById("passwordLabel");
    const password = document.getElementById("password");
    const confirmPassword = document.getElementById("confirmPassword");
    const submitButton = document.getElementById("submitButton");
    const forgotButton = document.getElementById("forgotButton");
    const resendButton = document.getElementById("resendButton");
    const message = document.getElementById("authMessage");
    let mode = "login";
    let resetMode = false;
    let resendEmail = "";

    function showMessage(text, type = "") {
        message.textContent = text;
        message.className = `form-message ${type}`;
    }

    function showResend(value) {
        resendEmail = value.trim();
        resendButton.hidden = !resendEmail;
    }

    function setMode(nextMode) {
        mode = nextMode;
        resetMode = false;
        tabs.querySelectorAll("button").forEach((button) => {
            button.classList.toggle("active", button.dataset.mode === mode);
        });
        const signup = mode === "signup";
        title.textContent = signup ? "Daftar Akun" : "Login";
        subtitle.textContent = signup
            ? "Buat akun untuk membuat atau bergabung dengan komunitas."
            : "Masuk untuk menggunakan komunitas Anda.";
        nameField.hidden = !signup;
        confirmField.hidden = !signup;
        confirmPassword.required = signup;
        password.disabled = false;
        password.required = true;
        password.hidden = false;
        passwordLabel.hidden = false;
        password.setAttribute("autocomplete", signup ? "new-password" : "current-password");
        confirmPassword.setAttribute("autocomplete", "new-password");
        submitButton.textContent = signup ? "DAFTAR SEKARANG" : "MASUK";
        forgotButton.hidden = signup;
        resendButton.hidden = false;
        showMessage("");
    }

    async function redirectAfterAuth() {
        window.location.replace(next);
    }

    form.addEventListener(
        "invalid",
        (event) => {
            if (event.target === email) {
                showMessage("Masukkan email yang valid.", "error");
            } else if (event.target === password) {
                showMessage("Isi password dengan minimal 6 karakter.", "error");
            } else if (event.target === confirmPassword) {
                showMessage("Ulangi password pada kolom konfirmasi.", "error");
            }
        },
        true,
    );

    form.addEventListener("submit", async (event) => {
        event.preventDefault();
        showMessage("");
        submitButton.disabled = true;

        try {
            if (resetMode) {
                const { error } = await sb.auth.resetPasswordForEmail(email.value.trim(), {
                    redirectTo: `${window.location.origin}/reset-password.html?next=${encodeURIComponent(next)}`,
                });
                if (error) throw error;
                showMessage(
                    "Jika email terdaftar, tautan reset password sudah dikirim. Periksa spam/junk Anda.",
                    "success",
                );
                submitButton.disabled = false;
                return;
            }

            if (mode === "signup") {
                if (password.value !== confirmPassword.value) {
                    throw new Error("Konfirmasi password tidak sama.");
                }
                const { data, error } = await sb.auth.signUp({
                    email: email.value.trim(),
                    password: password.value,
                    options: {
                        data: { full_name: fullName.value.trim() },
                        emailRedirectTo: `${window.location.origin}/auth.html?next=${encodeURIComponent(next)}`,
                    },
                });
                if (error) throw error;
                if (!data.session) {
                    showMessage(
                        "Akun berhasil dibuat. Silakan buka email dan konfirmasi akun KickOff Planner Anda sebelum login.",
                        "success",
                    );
                    showResend(email.value);
                    submitButton.disabled = false;
                    return;
                }
                if (!data.user?.email_confirmed_at) {
                    await sb.auth.signOut();
                    showMessage(
                        "Akun berhasil dibuat. Silakan buka email dan konfirmasi akun KickOff Planner Anda sebelum login.",
                        "success",
                    );
                    showResend(email.value);
                    submitButton.disabled = false;
                    return;
                }
            } else {
                const { data, error } = await sb.auth.signInWithPassword({
                    email: email.value.trim(),
                    password: password.value,
                });
                if (error) throw error;
                if (!data.user) throw new Error("Login tidak menghasilkan sesi aktif.");
            }
            await redirectAfterAuth();
        } catch (error) {
            if (/email.*not confirmed|not confirmed/i.test(error.message || "")) {
                showResend(email.value);
            }
            showMessage(error.message || "Terjadi kesalahan. Silakan coba lagi.", "error");
            submitButton.disabled = false;
        }
    });

    tabs.addEventListener("click", (event) => {
        const button = event.target.closest("button[data-mode]");
        if (button) setMode(button.dataset.mode);
    });

    forgotButton.addEventListener("click", () => {
        resetMode = true;
        title.textContent = "Reset Password";
        subtitle.textContent = "Masukkan email akun yang terdaftar.";
        password.disabled = true;
        password.required = false;
        password.hidden = true;
        passwordLabel.hidden = true;
        resendButton.hidden = true;
        submitButton.textContent = "KIRIM TAUTAN RESET";
        showMessage("");
    });

    resendButton.addEventListener("click", async () => {
        if (!resendEmail) return;
        resendButton.disabled = true;
        const { error } = await sb.auth.resend({
            type: "signup",
            email: resendEmail,
            options: {
                emailRedirectTo: `${window.location.origin}/auth.html?next=${encodeURIComponent(next)}`,
            },
        });
        resendButton.disabled = false;
        if (error) {
            showMessage(error.message, "error");
        } else {
            showMessage("Tautan konfirmasi akun baru telah dikirim. Silakan cek inbox dan spam.", "success");
        }
    });

    setMode("login");
    if (params.get("mode") === "reset") forgotButton.click();
})();
