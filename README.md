# Dashing Expo MVP

Dashing is an adult-only, style-first outfit-sharing MVP. This repository contains a runnable Expo + TypeScript interface for the approved initial journeys: onboarding, discovery, one-to-five-photo composing, outfit-focused ratings and comments, private bookmarks, profile, and leaderboards.

## Local setup

1. Install Node.js 20 LTS or newer.
2. From this project directory, run `npm install`.
3. Copy `.env.example` to `.env`.
4. Set only these public variables if a Supabase project has already been provisioned:

   ```bash
   EXPO_PUBLIC_SUPABASE_URL=https://your-project.supabase.co
   EXPO_PUBLIC_SUPABASE_ANON_KEY=your-public-anon-key
   ```

5. Run `npm run start`, then open the app using Expo Go, an Android emulator, or an iOS simulator.
6. Run `npx tsc --noEmit` before sharing changes.

The UI intentionally uses local mock data until the database migration is applied. A missing `.env` is safe for UI-only development; the app does not invent a Supabase project.

## Supabase security contract

- The Expo client reads only `EXPO_PUBLIC_SUPABASE_URL` and `EXPO_PUBLIC_SUPABASE_ANON_KEY` in `src/config/supabase.ts`.
- Never put a Supabase service-role key, database password, admin token, or other privileged secret in this app, `.env.example`, source control, or an Expo build configuration.
- The client 18+ checkbox is an experience gate only. Supabase must enforce adult eligibility from private date-of-birth data on every protected path.
- Published-post visibility must enforce each post’s server-calculated `max_viewer_age`; client filtering is not a security boundary.
- Feed and detail reads should use RLS-protected `get_feed` / `get_post` RPCs. Ratings should use `submit_outfit_rating`; the database must enforce one current rating per `(post_id, viewer_id)`.
- Post submission must remain moderated: 1–5 trusted/ready media rows are required before a post can be submitted or published. Media processing and leaderboard refreshes require trusted server-side operations.

The original backend foundation describes the migration as `supabase/migrations/20260911180000_dashing_backend_foundation.sql`. It was not included in the available workspace, so this rebuild deliberately does not fabricate or deploy it. Restore the approved migration before replacing the mock flows with live calls.

## Safe GitHub upload

1. Confirm `.gitignore` is present before staging files.
2. Verify no `.env`, `.env.*`, `node_modules`, or `.expo` entries are staged: `git status --ignored`.
3. Initialize and review locally:

   ```bash
   git init
   git add App.tsx app.json package.json tsconfig.json README.md .gitignore .env.example src .agent
   git diff --cached --check
   git commit -m "Initial Dashing Expo MVP"
   ```

4. Add the intended remote and make a normal, non-force push only after confirming the repository URL and authenticated write access:

   ```bash
   git remote add origin https://github.com/daodaohk/dashing-expo.git
   git branch -M main
   git push -u origin main
   ```

Do not run `git push --force`. If authentication or remote history is uncertain, stop and preserve this folder for review. GitHub visibility does not make secrets safe: public Expo variables are suitable only for the public Supabase URL and anonymous key.

## Scope boundaries

Dashing does not include direct messages, follows/follower counts, under-18 access, Stripe/payment flows, or third-party email SDKs. Ratings always refer to outfit styling—not a person’s body, attractiveness, age, ethnicity, or identity.
