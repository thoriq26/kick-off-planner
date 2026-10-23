(() => {
    if (!window.supabase) {
        throw new Error("Supabase JS must be loaded before supabase-client.js");
    }

    // This is the public anon key used by the static site. Never replace it with
    // a service-role key in browser code.
    const url = "https://yyngexaagxboclzvhtlt.supabase.co";
    const anonKey =
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inl5bmdleGFhZ3hib2NsenZodGx0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzgwNzI4ODcsImV4cCI6MjA5MzY0ODg4N30.gl1XXutl4va8pty1OO1CIT7jdW62wAWMFO0IyUiWNb4";

    // Map raw Supabase/auth error messages to friendly Indonesian text so no
    // English error ever reaches the UI.
    function translateError(value) {
        const text = String(value ?? "");
        const map = [
            [/not confirmed|email.*confirm/i, "Email Anda belum dikonfirmasi. Buka email verifikasi dari KickOff Planner lalu klik tautannya, baru login kembali."],
            [/invalid login credentials/i, "Email atau password salah. Coba lagi, atau pakai lupa password."],
            [/already.*registered/i, "Email ini sudah terdaftar. Silakan login, atau pakai lupa password jika lupa."],
            [/rate limit/i, "Terlalu banyak permintaan dalam waktu singkat. Tunggu satu menit lagi, lalu coba lagi."],
            [/for security purposes, you can only request this after (\d+)/i, (m) => `Email baru bisa dikirim lagi setelah ${m[1]} detik. Tunggu sebentar, lalu klik kirim ulang.`],
            [/password should be at least/i, "Password terlalu pendek — gunakan minimal 6 karakter."],
            [/should be different from the old/i, "Password baru harus berbeda dari password lama."],
            [/invalid format|validate email address/i, "Format email tidak valid. Cek lagi penulisan alamat emailnya."],
            [/email address.*invalid|invalid email/i, "Format email tidak valid. Cek lagi penulisan alamat emailnya."],
            [/user not found|user from sub claim/i, "Akun tidak ditemukan. Daftar dulu jika belum punya akun."],
            [/session missing|session_not_found/i, "Sesi login sudah berakhir. Silakan login lagi."],
            [/token.*expired|refresh_token.*not found|invalid claim/i, "Tautan atau sesi sudah kedaluwarsa. Minta tautan baru, atau login lagi."],
            [/signups not allowed/i, "Pendaftaran akun baru sedang dimatikan. Hubungi admin aplikasi."],
            [/fetch|network|failed to fetch|load failed/i, "Tidak dapat menghubungi server. Periksa koneksi internet Anda, lalu coba lagi."],
            [/database|server error|internal error|5[0-9]{2}/i, "Server sedang bermasalah. Coba lagi beberapa saat, atau hubungi admin aplikasi."],
        ];
        for (const [pattern, message] of map) {
            if (pattern.test(text)) {
                const match = text.match(pattern);
                return typeof message === "function" ? message(match) : message;
            }
        }
        return text || "Terjadi kesalahan. Silakan coba lagi.";
    }

    window.KOP = {
        supabase: window.supabase.createClient(url, anonKey),
        communityStorageKey: "kop_selected_community",
        translateError,
    };
})();
