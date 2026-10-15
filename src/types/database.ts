/**
 * Friendly names for the generated Supabase types in ./supabase.ts.
 *
 * Do not hand-write row shapes here — regenerate supabase.ts instead, so the
 * app can never drift from the live schema again.
 *
 * Semantics worth knowing:
 *   - posts.max_viewer_age is the OLDEST viewer age (inclusive) that may see a
 *     post. "Under 25" is stored as 24. NULL = everyone. It can never be set
 *     below the author's own age.
 *   - posts.rating_count / rating_sum are maintained by the database. Clients
 *     can read them but not write them.
 *   - Ratings rows are private: a user can only read their own.
 *   - New posts are submitted as 'in_review'; a moderator publishes them.
 */

import type { Database, Enums, Tables } from './supabase';

export type { Database };

export type PostStatus = Enums<'post_status'>;
export type ReportReason = Enums<'report_reason'>;

export type ProfileRow = Tables<'profiles'>;
export type PostRow = Tables<'posts'>;
export type RatingRow = Tables<'ratings'>;
export type CommentRow = Tables<'comments'>;
export type BookmarkRow = Tables<'bookmarks'>;
export type ReportRow = Tables<'reports'>;

/** Public author card. Never includes date of birth, country or city. */
export type ProfileCardRow = Database['public']['Functions']['get_profile_cards']['Returns'][number];

export type LeaderboardEntry = Database['public']['Functions']['get_post_leaderboard']['Returns'][number];
