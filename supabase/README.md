# Supabase setup for the multi-community build

The browser code uses only the public anon key. Never put a service-role key in
`supabase-client.js` or any HTML file.

## Reset application schema (optional)

To start the application schema over while keeping Supabase Auth accounts,
run [`reset_schema_preserve_auth.sql`](reset_schema_preserve_auth.sql) once in
the SQL Editor. This deletes the new and legacy application tables, functions,
policies, and trigger, but intentionally does not delete `auth.users`.
Supabase blocks direct SQL deletion from `storage.objects`; delete the
`payment-proofs` bucket through Dashboard > Storage first if its files should
also be removed.

## Reset test data while keeping accounts (recommended between test rounds)

If the schema is already migrated and you only want to remove the data created
by testers, run [`reset_test_data.sql`](reset_test_data.sql) once in the SQL
Editor. It removes communities, memberships, players, matches, history,
invitations, and payment-proof metadata while preserving:

- `auth.users` login accounts
- `public.profiles`
- tables, functions, policies, and RLS
- the application schema

Uploaded files are stored separately in the private `payment-proofs` bucket.
Delete or empty that bucket from **Dashboard → Storage** if the actual proof
files must also be removed. Do not expect SQL to delete `storage.objects`.

For a completely clean slate including test login accounts, delete the test
users separately from **Authentication → Users** after running the data reset.
That action is intentionally not part of the SQL script.

A schema-level reset is only needed when the tables/functions themselves must
be recreated. Use [`reset_schema_preserve_auth.sql`](reset_schema_preserve_auth.sql)
for that case, then rerun the migrations in order.

## Apply the schema

In the Supabase Dashboard SQL Editor, query/tab names such as `migration pertama`
or `migration keempat` are only labels. The file name and tab name do not
change the database; the SQL content and execution order matter. Run each
query once in the listed order. Do not continuously rerun completed migrations.

1. Open the Supabase project → **SQL Editor**.
2. Review and run [`migrations/20260924000000_multi_tenant_auth.sql`](migrations/20260924000000_multi_tenant_auth.sql).
3. Then run [`migrations/20260924010000_short_invite_codes.sql`](migrations/20260924010000_short_invite_codes.sql) to generate short `KOP-...` invitation codes.
4. Run [`migrations/20260924020000_payment_proofs.sql`](migrations/20260924020000_payment_proofs.sql) to create the private `payment-proofs` bucket, metadata table, and storage RLS.
5. Run [`migrations/20260924025000_fix_invite_ambiguity.sql`](migrations/20260924025000_fix_invite_ambiguity.sql) to fix the invite redemption function used by the onboarding page.
6. Run [`migrations/20260924030000_invite_usage_audit.sql`](migrations/20260924030000_invite_usage_audit.sql) to record which account accepted each invitation. It powers the **LIHAT DAFTAR** button in the Undangan tab. Invitations accepted before this migration have no usage history and will show an empty list.
7. Run [`migrations/20260924040000_member_status.sql`](migrations/20260924040000_member_status.sql) to add `community_members.is_active` plus the admin-only RPCs used by the **Anggota Terdaftar** card: `list_community_members`, `set_community_member_status`, and `remove_community_member`. Inactive members keep their membership row but lose all community access. Owner/admin rows cannot be deactivated or removed when they are the last active owner.
8. Run [`migrations/20260924050000_match_results.sql`](migrations/20260924050000_match_results.sql) to add archived match results: score, scorers, assists, cards, and the team split snapshot. It backs the admin **Arsipkan** tab and the per-team breakdown in `history.html`.
9. Run [`migrations/20260924060000_match_fixtures.sql`](migrations/20260924060000_match_fixtures.sql) to store results per matchup instead of per team. It adds the `fixtures` column plus `generate_round_robin`, `normalize_fixture_result`, `merge_match_fixtures`, and `fixture_team_totals`, and replaces `archive_community_match`/`update_event_history_result` so the schedule is generated server-side from the real team split. The browser cannot invent matchups, and events archived before this migration get a schedule generated on first edit.
10. Run [`migrations/20260924070000_more_teams.sql`](migrations/20260924070000_more_teams.sql) to lift the four-team limit. It widens the `community_players_team_check` constraint to `Orange`, `Pink`, `Teal`, and `Navy`, and refreshes `fixture_team_totals` and `normalize_match_result` so all eight teams are accepted.
11. In **Authentication → URL Configuration**, set the site URL to the production origin.
12. Add the production auth redirect URLs:
   - `https://YOUR-DOMAIN/auth.html`
   - `https://YOUR-DOMAIN/reset-password.html`
   - `https://YOUR-DOMAIN/join.html` (for older direct invite links)
13. Keep email confirmation enabled for production. Configure SMTP before relying
    on password reset for real users.

The migration creates new `community_*` tables and does not drop the old public
`pemain`, `jadwal_lapangan`, `event_history`, or `admin_settings` tables. It
revokes browser access to those legacy tables when they exist. The new frontend
starts with an empty dataset. The old admin password is not migrated; the first
verified user creates a community and becomes its owner through `create_community`.

Payment proofs are stored in the private `payment-proofs` Storage bucket. The
browser uploads a JPG/PNG/WEBP/PDF (maximum 5 MB); owners/admins open it through
short-lived signed URLs from the Admin Panel. Direct email delivery is not
used because it would expose owner email/API credentials; email notifications
would require a server-side Edge Function/provider later.

## Verification email template

Set this under Supabase Dashboard → Authentication → Email/Templates → Confirm signup:

**Subject**

```text
Konfirmasi akun KickOff Planner Anda
```

**Body**

```html
<p>Halo,</p>
<p>Terima kasih sudah membuat akun KickOff Planner.</p>
<p>Silakan konfirmasi akun Anda melalui tombol di bawah ini:</p>
<p><a href="{{ .ConfirmationURL }}">Konfirmasi Akun KickOff Planner</a></p>
<p>Jika Anda tidak membuat akun ini, abaikan email ini.</p>
<p>Terima kasih,<br />Tim KickOff Planner</p>
```

The `{{ .ConfirmationURL }}` variable is generated by Supabase and automatically uses the configured Site/Redirect URL. Do not hardcode `localhost` in the template. For production, configure the Vercel origin under Authentication → URL Configuration first.

## Reset password email template

If the reset email shows the words "Reset Password" as plain text instead of a clickable
link, the Supabase template is still the unmodified default. Set this under
Supabase Dashboard → **Authentication → Email/Templates → Reset Password**:

**Subject**

```text
Reset password KickOff Planner
```

**Body**

```html
<p>Halo,</p>
<p>Kami menerima permintaan reset password untuk akun KickOff Planner Anda.</p>
<p>Silakan pilih password baru melalui tombol di bawah ini:</p>
<p><a href="{{ .ConfirmationURL }}">Buat Password Baru</a></p>
<p>Jika Anda tidak meminta reset password, abaikan email ini. Password lama Anda
tetap berlaku.</p>
<p>Terima kasih,<br />Tim KickOff Planner</p>
```

`{{ .ConfirmationURL }}` points to `reset-password.html?next=...`, which is handled
by `reset-password.html` and `reset-password-page.js`. Keep these production URLs in
**Authentication → URL Configuration → Redirect URLs**, otherwise Supabase redirects
to the Site URL instead of the reset page.
## Brevo custom SMTP (recommended for Auth email)

No application code or database migration is required to switch to Brevo. In
Supabase Dashboard → Authentication → Email → SMTP Settings, enable custom SMTP
and use:

```text
Host: smtp-relay.brevo.com
Port: 587
Username: the SMTP Login shown in Brevo
Password: the SMTP Key from Brevo (not the API key)
Sender: a verified Brevo sender/domain
```

Keep SMTP credentials only in Supabase Dashboard; never put the SMTP key in
`supabase-client.js` or HTML. The current Auth flow already supplies the
`emailRedirectTo` URL, and the template should use `{{ .ConfirmationURL }}`.

Brevo's current Free plan is listed at 300 email sends/day (subject to Brevo's
current terms); Supabase may also impose a separate Auth email rate limit after
custom SMTP is enabled. Check both dashboards before a large signup campaign.

### Gmail as Brevo sender

`kickoffplanner.noreply@gmail.com` can be used as the verified sender, but it
must first be verified in Brevo under **Senders & Domains**. In Supabase SMTP
Settings set only the sender/admin email to that address; the SMTP username
must remain the separate SMTP Login generated by Brevo (often an
`...@smtp-brevo.com` address). Never put the Brevo SMTP key in browser code.
For production, a custom-domain sender such as `no-reply@yourdomain.com` is
usually more reliable and easier to authenticate with SPF/DKIM.


If Supabase CLI is installed and authenticated:

```sh
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase db push
```

The local environment used for this repository does not have the Supabase CLI,
`psql`, or project credentials configured, so the remote migration must be
applied through the dashboard or from a machine with authenticated access. The
SQL in this repository has not been applied to the remote project by this
session. Apply it before deploying the new frontend; otherwise the new pages
will redirect but their community queries will fail.
