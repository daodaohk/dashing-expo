# Dashing rebuild handoff

**Rebuilt:** September 14, 2026

## Delivered source

- `App.tsx` is a runnable Expo MVP with an adult acknowledgement entry gate and tabbed Discover, Post, Saved, Ranks, and You views.
- The composer uses `expo-image-picker` and accepts one to five local photos. It requires a styling description and one to three tags before mock submission.
- Post detail supports a photo carousel, an outfit-focused 1–5 spark rating control, comments, a private bookmark control, and a report receipt.
- `src/data/mock.ts` contains isolated display-only data; no deployment environment or database identity is invented.
- `src/theme.ts` applies the approved brand board: Dashing `#FF6B7D`, Blush `#FFC7D7`, Ivory `#F8F5EF`, Charcoal `#111111`, expressive Georgia/Playfair-like display styling, clean system body text, editorial spacing, and rounded panels.

## Security boundary

`src/config/supabase.ts` uses only `EXPO_PUBLIC_SUPABASE_URL` and `EXPO_PUBLIC_SUPABASE_ANON_KEY`. It contains no service-role key and disables persisted sessions until secure native auth storage is deliberately added.

The local 18+ confirmation is never authorization. The approved backend foundation must enforce adult eligibility, suspension status, RLS visibility, and post `max_viewer_age` against the authenticated viewer on the database/server. It must preserve one rating per `(post_id, viewer_id)` and use trusted processing/moderation before publishing content.

## Required backend restoration

The durable backend handoff references the approved initial migration:

`supabase/migrations/20260911180000_dashing_backend_foundation.sql`

That SQL file was not available in this workspace on September 14, 2026, so no migration has been recreated, applied, or claimed as deployed. Restore it from its original artifact before binding the UI to Supabase. Then configure only the two public variables in `.env`; never copy service credentials into Expo.

## Validation and transfer

1. Run `npm install` from the repository root.
2. Run `npx tsc --noEmit`.
3. Test `npm run start` in Expo Go or a simulator.
4. Read `README.md` before upload. `.gitignore` excludes `node_modules/`, `.expo/`, `.env`, and `.env.*`, but allows `.env.example`.
5. Upload or commit the source with a normal authenticated push. Do not force-push. This environment does not claim a successful GitHub push or deployed build.

## Artifact source of truth

- Expo implementation handoff: `a5ddd0ee-f2d9-405e-aeb7-89c3582f604e`
- Backend foundation: `ebd46982-8d2b-465f-8d24-cdc83b20f8e6`
- MVP blueprint: `cc4792a7-170d-43aa-bc7b-45b77d45262b`
- Brand kit: `32d90b63-a70e-4e48-b743-4e6ce92e0c77`
