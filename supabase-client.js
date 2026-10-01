(() => {
    if (!window.supabase) {
        throw new Error("Supabase JS must be loaded before supabase-client.js");
    }

    // This is the public anon key used by the existing static site. Never replace
    // it with a service-role key in browser code.
    const url = "https://yyngexaagxboclzvhtlt.supabase.co";
    const anonKey =
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inl5bmdleGFhZ3hib2NsenZodGx0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzgwNzI4ODcsImV4cCI6MjA5MzY0ODg4N30.gl1XXutl4va8pty1OO1CIT7jdW62wAWMFO0IyUiWNb4";

    window.KOP = {
        supabase: window.supabase.createClient(url, anonKey),
        communityStorageKey: "kop_selected_community",
    };
})();
