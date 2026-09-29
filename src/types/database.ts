/**
 * Generated from the live Dashing schema (project ozeixaolbickpauayjcu)
 * on 2026-09-29. Replaces the earlier hand-written version.
 *
 * Differences from that version:
 *   - The ratings table is `ratings`, with a `score` column (not `value`).
 *   - There is no `post_photos` table; photos live in `posts.media_urls`.
 *   - `posts.max_viewer_age` is a CEILING: the viewer must be no older than
 *     this. NULL means no restriction. (It replaced `viewer_min_age`, a floor.)
 *   - `profiles` has no `is_suspended` column.
 *   - `profiles` carries `default_max_viewer_age`, the saved preference applied
 *     to new posts.
 *   - The leaderboard is a materialized view reached via get_post_leaderboard().
 */

export type PostStatus = 'draft' | 'in_review' | 'published' | 'rejected' | 'removed';

export type ReportReason = 'sexual_content' | 'harassment' | 'spam' | 'minor' | 'other';

export interface ProfileRow {
  id: string;
  username: string;
  display_name: string | null;
  avatar_url: string | null;
  bio: string | null;
  date_of_birth: string;
  is_moderator: boolean;
  country: string | null;
  city: string | null;
  default_max_viewer_age: number | null;
  created_at: string;
  updated_at: string;
}

/** Public projection. No date_of_birth, country or city. */
export interface ProfileCardRow {
  id: string;
  username: string;
  display_name: string | null;
  avatar_url: string | null;
  bio: string | null;
  created_at: string;
}

export interface PostRow {
  id: string;
  author_id: string;
  caption: string | null;
  media_urls: string[];
  max_viewer_age: number | null;
  status: PostStatus;
  moderation_note: string | null;
  moderated_at: string | null;
  moderated_by: string | null;
  created_at: string;
  updated_at: string;
}

export interface RatingRow {
  id: string;
  post_id: string;
  user_id: string;
  score: number;
  created_at: string;
  updated_at: string;
}

export interface CommentRow {
  id: string;
  post_id: string;
  author_id: string;
  body: string;
  is_hidden: boolean;
  moderation_note: string | null;
  moderated_at: string | null;
  moderated_by: string | null;
  created_at: string;
  updated_at: string;
}

export interface BookmarkRow {
  user_id: string;
  post_id: string;
  created_at: string;
}

export interface ReportRow {
  id: string;
  reporter_id: string;
  post_id: string | null;
  comment_id: string | null;
  reason: ReportReason;
  details: string | null;
  resolved_at: string | null;
  resolved_by: string | null;
  resolution_note: string | null;
  created_at: string;
}

export interface LeaderboardEntry {
  post_id: string;
  author_id: string;
  max_viewer_age: number | null;
  created_at: string;
  rating_count: number;
  average_rating: number;
  rating_total: number;
}
