# Dashing Expo MVP

Dashing is an adult-only, style-first outfit-sharing app: onboarding, discovery, one-to-five-photo posts, outfit-focused ratings and comments, private bookmarks, profile, and leaderboards. Expo + TypeScript on the client, Supabase (Postgres, Auth, Storage) on the server.

> Status: the database and data layer (`src/data/dashing-data.ts`) are live. Most screens in `App.tsx` still render mock data and are being wired to the data layer next.

## Local setup

1. Install Node.js 22 LTS.
2. `npm install`
3. Copy `.env.example` to `.env` and fill in the two public values from Supabase → Project Settings → API.
4. `npm run start`, then open the app in Expo Go, an Android emulator or an iOS simulator. After changing `.env`, restart with `npx expo start -c`.
5. `npm run typecheck` before pushing. CI runs it on every pull request.

The app needs a Supabase project to start; it fails fast with a clear message if `.env` is missing.

## Database

Migrations live in `supabase/migrations/`:

| File | What it is |
| --- | --- |
| `20260929170000_remote_baseline.sql` | The live schema as it stood on 2026-10-15, reconstructed from the production catalog. Replaces the original migrations (kept for reference in `supabase/migrations_archive/`). |
| `20261015081023_post_status_in_review.sql` | Adds the `in_review` post status. |
| `20261015090000_security_hardening.sql` | Security fixes and the age-ceiling redesign. |

Never edit an applied migration; add a new one.

### Tests

`supabase/tests/run_local.sh` builds a scratch database on any plain Postgres (with `supabase_stub.sql` standing in for Supabase's `auth` and `storage` schemas), applies every migration, and runs `security_tests.sql`, which signs in as several users and tries to break each rule. CI runs it on every pull request.

```bash
PGHOST=localhost PGUSER=postgres supabase/tests/run_local.sh
```

### Types

`src/types/supabase.ts` is generated from the live schema; don't edit it by hand. After a schema change:

```bash
npx supabase gen types typescript --project-id ozeixaolbickpauayjcu > src/types/supabase.ts
```

`src/types/database.ts` gives the generated types friendly names.

## Security model

All rules are enforced in the database (row-level security, triggers and `SECURITY DEFINER` functions in the `private` schema). Client-side checks are only for friendlier messages.

- **Keys.** The app holds only `EXPO_PUBLIC_SUPABASE_URL` and the publishable key. Never put a service-role/secret key or database password in the app, `.env.example`, source control or an Expo build.
- **Adults only.** Every read and write requires a profile whose date of birth makes the user 18+. Date of birth can't be changed from the app; an administrator corrects it if needed.
- **Moderation.** New posts are submitted as `in_review` and only moderators can publish, hide or remove them. Editing a live post's caption, photos or visibility sends it back to review. Authors can't undo a moderator's decision. The switch `private.app_settings.require_post_review` turns review off (posts then publish on submit).
- **Viewer-age ceiling.** `posts.max_viewer_age` is the oldest viewer age (inclusive) that may see a post — "Under 25" is stored as 24 — and can never be below the author's own age. If the author later grows older than the ceiling, their current age applies instead.
- **Ratings.** One per user per post (1–5). Rows are private to the rater; totals live on `posts.rating_count` / `rating_sum` and are maintained by the database.
- **Leaderboard.** `get_post_leaderboard(result_limit, since)` ranks visible posts by a Bayesian average, filtered for each viewer.
- **Author cards.** `get_profile_cards(ids)` returns only public profile fields; date of birth, country and city are never exposed.
- **Media.** The `post-media` bucket is private. Uploads go to `<user id>/…`. Viewers can read media of posts they can see; authors and moderators can always read their own / all media.
- **Signed-out access.** None.

### Making someone a moderator

Supabase dashboard → Table editor → `profiles` → set `is_moderator` to `true`. This can't be done from the app.

## Scope boundaries

Dashing does not include direct messages, follows/follower counts, under-18 access, payments, or third-party email SDKs. Ratings always refer to outfit styling — not a person's body, attractiveness, age, ethnicity or identity.
