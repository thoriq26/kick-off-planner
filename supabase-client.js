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
            [/not confirmed|email.*confirm/i, "Email Anda belum dikonfirmasi. Buka email verifikasi dari KickOff Planner dan klik tautannya sebelum login."],
            [/invalid login credentials/i, "Email atau password salah."],
            [/already.*registered/i, "Email sudah terdaftar. Silakan login dengan akun tersebut."],
            [/rate limit/i, "Terlalu banyak permintaan berturut-turut. Tunggu sekitar satu menit lalu coba lagi."],
            [/for security purposes|request this after/i, "Demi keamanan, tunggu sekejap (kurang dari satu menit) sebelum meminta email lagi."],
            [/password should be at least/i, "Password terlalu pendek. Gunakan minimal 6 karakter."],
            [/should be different from the old/i, "Password baru harus berbeda dari password lama."],
            [/invalid format|validate email address/i, "Format email tidak valid. Periksa kembali alamat email Anda."],
            [/email address.*invalid|invalid email/i, "Format email tidak valid. Periksa kembali alamat email Anda."],
            [/user not found|user from sub claim/i, "Akun tidak ditemukan. Silakan daftar terlebih dahulu."],
            [/session missing|session_not_found/i, "Sesi login berakhir. Silakan login kembali."],
            [/token.*expired|refresh_token.*not found|invalid claim/i, "Sesi atau tautan sudah kedaluwarsa. Minta tautan baru atau login kembali."],
            [/signups not allowed/i, "Pendaftaran akun baru sedang dinonaktifkan. Hubungi admin aplikasi."],
            [/fetch|network|failed to fetch|load failed/i, "Tidak bisa menghubungi server. Periksa koneksi internet Anda lalu coba lagi."],
            [/database|server error|internal error|5[0-9]{2}/i, "Server sedang bermasalah atau sedang dijeda. Coba lagi beberapa saat, atau hubungi admin aplikasi."],
        ];
        for (const [pattern, message] of map) {
            if (pattern.test(text)) return message;
        }
        return text || "Terjadi kesalahan. Silakan coba lagi.";
    }

    window.KOP = {
        supabase: window.supabase.createClient(url, anonKey),
        communityStorageKey: "kop_selected_community",
        translateError,
    };
})();
