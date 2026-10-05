# KickOff Planner Agent Notes

## Project shape

- This is a static, multi-page vanilla HTML/CSS/JS app. There is no package manifest, lockfile, build, lint, typecheck, test runner, or CI config; do not invent `npm` commands or expect a compiled entrypoint.
- `index.html` is the public landing page. `admin.html` is a role-protected route; it is intentionally not linked as a public button, but authorized owners/admins can reach it from the account bar.
- `KickOff Planner` is a plain-text product/learning note, not a source file or runtime directory.
- `supabase-client.js` and `auth-guard.js` are shared browser helpers; `auth.html`, `onboarding.html`, `join.html`, and `reset-password.html` are the auth/onboarding entrypoints. Most page-specific CSS/JS remains inline; keep the shared context contract consistent when changing page guards.
- Supabase, Font Awesome, and Flatpickr are loaded from external CDNs; functional previews need network access.

## Local run and verification

- From the repository root, serve the files with `python3 -m http.server 8000`, then open `http://localhost:8000/index.html` or the target page directly.
- There is no automated test/lint/typecheck command. Use focused browser smoke checks; do not claim automated verification when none is configured.
- Apply the Supabase migrations in order (`20260924000000`, `20260924010000`, `20260924020000`, `20260924025000`, `20260924030000`) before testing auth, invite codes, payment proofs, invite redemption, or the admin invite-usage list. In the Supabase Dashboard SQL Editor, renamed query/tab labels do not matter; run each completed migration once. For a clean app-schema reset that preserves `auth.users`, run `supabase/reset_schema_preserve_auth.sql` once first; delete the `payment-proofs` Storage bucket through the Supabase Storage UI/API, not direct SQL. See `supabase/README.md`; this repository does not contain remote Supabase credentials or a configured CLI.

## Data and auth contract

- The public anon key is centralized in `supabase-client.js`; never add a service-role key to browser code.
- New tenant data lives in `communities`, `community_members`, `community_invites`, `community_players`, `community_matches`, `community_event_history`, and `community_payment_proofs`. Every app query must filter by `context.community.id`; RLS in the migrations is the actual isolation boundary.
- `communities` is self-service: `create_community` makes the authenticated creator an `owner`; invite codes use `create_community_invite` and are accepted with `accept_community_invite`. Share the normal site URL plus the one-time `KOP-...` code; raw invite tokens are shown once and should not be logged.
- Public registration binds `community_players.user_id` to the authenticated Supabase user and requires a community membership. Team fields use `team`; player fields use `name`/`position`. The current MVP has one active roster/match per community; concurrent events are not modeled yet.
- `admin.html` requires an authenticated `owner` or `admin` role. The old `admin_settings` password and `sessionStorage` login flow are obsolete.
- Password reset uses Supabase Auth email; production requires configured redirect URLs and SMTP.

## High-risk flows

- `archiveMatch()` inserts `community_event_history`, resets the current community match, and deletes that community's player rows. Treat Archive as destructive and never use it as a harmless smoke test.
- The admin match form accepts a full Google Maps iframe; `updateInfo()` extracts its `src`. The public match page embeds recognized Google embed URLs and otherwise renders a directions link.
- Payment proofs live in the private `payment-proofs` bucket and `community_payment_proofs` table; owners/admins use short-lived signed URLs, never public or durable URLs. `match_version` separates proofs after reset/archive.
- Current pages reference the case-sensitive assets `geminix.jpg` and `aaa.png`; `gemini.jpg` is currently unreferenced. Preserve/update these paths when changing assets.

## Deployment

- No deploy script or hosting workflow is defined. The repository is a set of root-level static files; deployment must serve the repository root and permit requests to the configured CDNs and Supabase project.
