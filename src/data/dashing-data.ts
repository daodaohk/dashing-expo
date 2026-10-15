/**
 * Dashing data layer — written against the live schema (see
 * supabase/migrations and src/types/supabase.ts).
 *
 * Security lives in the database, not here:
 *   - Which posts a viewer can see (status, age ceiling) is decided by RLS.
 *   - New posts go to 'in_review'; only moderators publish.
 *   - Rating totals are maintained server-side on posts.rating_count/sum.
 *   - Ratings rows are private; we only ever read the viewer's own.
 * Client-side checks below exist only to give friendlier error messages.
 */

import { supabase } from '../config/supabase';
import type {
  CommentRow,
  LeaderboardEntry,
  PostRow,
  PostStatus,
  ProfileCardRow,
  ReportReason,
} from '../types/database';

const PAGE_SIZE = 20;

// ---------------------------------------------------------------------------
// Shapes the UI consumes
// ---------------------------------------------------------------------------

export interface FeedAuthor {
  id: string;
  username: string;
  display_name: string | null;
  avatar_url: string | null;
}

export interface FeedPost {
  id: string;
  author_id: string;
  caption: string | null;
  media_urls: string[];
  max_viewer_age: number | null;
  status: PostStatus;
  created_at: string;
  author: FeedAuthor;
  ratingAverage: number | null;
  ratingCount: number;
  viewerRating: number | null;
  isBookmarked: boolean;
}

export interface FeedPage {
  posts: FeedPost[];
  /** Opaque cursor for the next page, or null when there are no more posts. */
  nextCursor: string | null;
}

export interface CommentWithAuthor extends CommentRow {
  author: FeedAuthor;
}

export interface PostDraft {
  caption: string;
  mediaUrls: string[];
  /** Oldest viewer age allowed (inclusive), or null for everyone. */
  maxViewerAge: number | null;
  /** 'draft' to save without submitting. Defaults to 'in_review'. */
  status?: Extract<PostStatus, 'draft' | 'in_review'>;
}

/** Visibility choices shown in the UI. Values are inclusive maximum ages. */
export const VIEWER_AGE_OPTIONS: ReadonlyArray<{ label: string; hint: string; value: number | null }> = [
  { label: 'Everyone', hint: 'Any adult on Dashing', value: null },
  { label: 'Under 30', hint: 'Adults aged 18 to 29', value: 29 },
  { label: 'Under 25', hint: 'Adults aged 18 to 24', value: 24 },
  { label: 'Under 21', hint: 'Adults aged 18 to 20', value: 20 },
];

/** The options a user of this age may choose: never younger than themselves. */
export function viewerAgeOptionsFor(ownAge: number) {
  return VIEWER_AGE_OPTIONS.filter((option) => option.value === null || option.value >= ownAge);
}

/** Whole years between a YYYY-MM-DD birth date and today. */
export function ageFromDateOfBirth(dateOfBirth: string, today = new Date()): number {
  const [year, month, day] = dateOfBirth.split('-').map(Number);
  let age = today.getFullYear() - year;
  const beforeBirthday =
    today.getMonth() + 1 < month || (today.getMonth() + 1 === month && today.getDate() < day);
  if (beforeBirthday) age -= 1;
  return age;
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

function unique<T>(items: T[]): T[] {
  return [...new Set(items)];
}

/** The signed-in user's id, from the locally stored session (no network call). */
async function currentUserId(): Promise<string | null> {
  const { data, error } = await supabase.auth.getSession();
  if (error) throw error;
  return data.session?.user.id ?? null;
}

async function requireUserId(): Promise<string> {
  const id = await currentUserId();
  if (!id) throw new Error('You must sign in to do that.');
  return id;
}

function toAuthor(card: ProfileCardRow): FeedAuthor {
  return {
    id: card.id,
    username: card.username,
    display_name: card.display_name,
    avatar_url: card.avatar_url,
  };
}

/** Public author cards for a set of ids (one round trip). */
async function loadAuthors(authorIds: string[]): Promise<Map<string, FeedAuthor>> {
  const ids = unique(authorIds);
  if (!ids.length) return new Map();

  const { data, error } = await supabase.rpc('get_profile_cards', { profile_ids: ids });
  if (error) throw error;

  return new Map((data ?? []).map((card) => [card.id, toAuthor(card)]));
}

/** Attach author, the viewer's own rating and bookmark state to post rows. */
async function hydratePosts(rows: PostRow[]): Promise<FeedPost[]> {
  if (!rows.length) return [];

  const postIds = rows.map((row) => row.id);
  const viewerId = await currentUserId();

  const [authors, myRatings, myBookmarks] = await Promise.all([
    loadAuthors(rows.map((row) => row.author_id)),
    viewerId
      ? supabase.from('ratings').select('post_id, score').in('post_id', postIds).eq('user_id', viewerId)
      : Promise.resolve({ data: [] as Array<{ post_id: string; score: number }>, error: null }),
    viewerId
      ? supabase.from('bookmarks').select('post_id').in('post_id', postIds).eq('user_id', viewerId)
      : Promise.resolve({ data: [] as Array<{ post_id: string }>, error: null }),
  ]);

  if (myRatings.error) throw myRatings.error;
  if (myBookmarks.error) throw myBookmarks.error;

  const ratingByPost = new Map((myRatings.data ?? []).map((row) => [row.post_id, row.score]));
  const bookmarked = new Set((myBookmarks.data ?? []).map((row) => row.post_id));

  return rows.flatMap((row) => {
    const author = authors.get(row.author_id);
    if (!author) return [];
    return [
      {
        id: row.id,
        author_id: row.author_id,
        caption: row.caption,
        media_urls: row.media_urls,
        max_viewer_age: row.max_viewer_age,
        status: row.status,
        created_at: row.created_at,
        author,
        ratingAverage: row.rating_count > 0 ? row.rating_sum / row.rating_count : null,
        ratingCount: row.rating_count,
        viewerRating: ratingByPost.get(row.id) ?? null,
        isBookmarked: bookmarked.has(row.id),
      },
    ];
  });
}

function encodeCursor(row: PostRow): string {
  return `${row.created_at}|${row.id}`;
}

function decodeCursor(cursor: string): { createdAt: string; id: string } {
  const [createdAt, id] = cursor.split('|');
  return { createdAt, id };
}

// ---------------------------------------------------------------------------
// Feed
// ---------------------------------------------------------------------------

export async function loadFeed(cursor?: string): Promise<FeedPage> {
  let query = supabase
    .from('posts')
    .select('*')
    .eq('status', 'published')
    .order('created_at', { ascending: false })
    .order('id', { ascending: false })
    .limit(PAGE_SIZE + 1);

  if (cursor) {
    // Keyset pagination on (created_at, id) so posts sharing a timestamp are
    // never skipped or repeated.
    const { createdAt, id } = decodeCursor(cursor);
    query = query.or(`created_at.lt.${createdAt},and(created_at.eq.${createdAt},id.lt.${id})`);
  }

  const { data, error } = await query;
  if (error) throw error;

  const rows = data ?? [];
  const pageRows = rows.slice(0, PAGE_SIZE);
  const posts = await hydratePosts(pageRows);
  const last = pageRows[pageRows.length - 1];
  return {
    posts,
    nextCursor: rows.length > PAGE_SIZE && last ? encodeCursor(last) : null,
  };
}

export async function loadPost(postId: string): Promise<FeedPost | null> {
  const { data, error } = await supabase.from('posts').select('*').eq('id', postId).maybeSingle();
  if (error) throw error;
  if (!data) return null;
  const [post] = await hydratePosts([data]);
  return post ?? null;
}

/** All of the signed-in user's posts, including drafts and ones in review. */
export async function loadMyPosts(): Promise<FeedPost[]> {
  const userId = await requireUserId();
  const { data, error } = await supabase
    .from('posts')
    .select('*')
    .eq('author_id', userId)
    .order('created_at', { ascending: false });
  if (error) throw error;
  return hydratePosts(data ?? []);
}

// ---------------------------------------------------------------------------
// Composing
// ---------------------------------------------------------------------------

/**
 * Save a post. By default it is submitted for review ('in_review'); a
 * moderator publishes it. Media must already be uploaded to the private
 * `post-media` bucket under `<user id>/...`; pass the object paths.
 */
export async function createPost(draft: PostDraft): Promise<PostRow> {
  const mediaUrls = draft.mediaUrls.filter((url) => url.trim().length > 0);
  if (mediaUrls.length < 1 || mediaUrls.length > 5) {
    throw new Error('A post needs between one and five photos.');
  }

  const authorId = await requireUserId();
  const { data, error } = await supabase
    .from('posts')
    .insert({
      author_id: authorId,
      caption: draft.caption.trim() || null,
      media_urls: mediaUrls,
      max_viewer_age: draft.maxViewerAge,
      status: draft.status ?? 'in_review',
    })
    .select('*')
    .single();
  if (error) throw error;
  return data;
}

/** Delete one of your own posts. Posts removed by a moderator can't be deleted. */
export async function deleteMyPost(postId: string): Promise<void> {
  const { error } = await supabase.from('posts').delete().eq('id', postId);
  if (error) throw error;
}

// ---------------------------------------------------------------------------
// Ratings — one per viewer per post; totals maintained by the database
// ---------------------------------------------------------------------------

export async function setRating(postId: string, score: number): Promise<void> {
  if (!Number.isInteger(score) || score < 1 || score > 5) {
    throw new Error('Ratings must be whole numbers from 1 to 5.');
  }
  const userId = await requireUserId();
  const { error } = await supabase
    .from('ratings')
    .upsert({ post_id: postId, user_id: userId, score }, { onConflict: 'post_id,user_id' });
  if (error) throw error;
}

export async function clearMyRating(postId: string): Promise<void> {
  const userId = await requireUserId();
  const { error } = await supabase.from('ratings').delete().eq('post_id', postId).eq('user_id', userId);
  if (error) throw error;
}

// ---------------------------------------------------------------------------
// Comments
// ---------------------------------------------------------------------------

export async function loadComments(postId: string): Promise<CommentWithAuthor[]> {
  const { data, error } = await supabase
    .from('comments')
    .select('*')
    .eq('post_id', postId)
    .eq('is_hidden', false)
    .order('created_at');
  if (error) throw error;

  const rows = data ?? [];
  if (!rows.length) return [];

  const authors = await loadAuthors(rows.map((row) => row.author_id));
  return rows.flatMap((row) => {
    const author = authors.get(row.author_id);
    return author ? [{ ...row, author }] : [];
  });
}

export async function addComment(postId: string, body: string): Promise<void> {
  const trimmed = body.trim();
  if (!trimmed) throw new Error('Write a comment first.');
  if (trimmed.length > 1000) throw new Error('Comments can be up to 1,000 characters.');

  const authorId = await requireUserId();
  const { error } = await supabase.from('comments').insert({ post_id: postId, author_id: authorId, body: trimmed });
  if (error) throw error;
}

// ---------------------------------------------------------------------------
// Bookmarks — private to the owner
// ---------------------------------------------------------------------------

export async function setBookmark(postId: string, shouldBookmark: boolean): Promise<void> {
  const userId = await requireUserId();
  const { error } = shouldBookmark
    ? await supabase.from('bookmarks').upsert({ post_id: postId, user_id: userId }, { onConflict: 'user_id,post_id' })
    : await supabase.from('bookmarks').delete().eq('post_id', postId).eq('user_id', userId);
  if (error) throw error;
}

/** Bookmarked posts, most recently saved first. */
export async function loadMyBookmarks(): Promise<FeedPost[]> {
  const userId = await requireUserId();
  const { data: rows, error } = await supabase
    .from('bookmarks')
    .select('post_id')
    .eq('user_id', userId)
    .order('created_at', { ascending: false });
  if (error) throw error;

  const ids = (rows ?? []).map((row) => row.post_id);
  if (!ids.length) return [];

  const { data: posts, error: postsError } = await supabase
    .from('posts')
    .select('*')
    .in('id', ids)
    .eq('status', 'published');
  if (postsError) throw postsError;

  const order = new Map(ids.map((id, index) => [id, index]));
  const sorted = [...(posts ?? [])].sort((a, b) => (order.get(a.id) ?? 0) - (order.get(b.id) ?? 0));
  return hydratePosts(sorted);
}

// ---------------------------------------------------------------------------
// Leaderboard — ranked and age-filtered in the database
// ---------------------------------------------------------------------------

/**
 * Top posts the viewer is allowed to see, ranked with a Bayesian average so a
 * single high rating can't top the board. Pass `since` for e.g. a weekly board.
 */
export async function loadLeaderboard(options: { limit?: number; since?: Date } = {}): Promise<LeaderboardEntry[]> {
  const { data, error } = await supabase.rpc('get_post_leaderboard', {
    result_limit: options.limit ?? 50,
    ...(options.since ? { since: options.since.toISOString() } : {}),
  });
  if (error) throw error;
  return data ?? [];
}

// ---------------------------------------------------------------------------
// Reports
// ---------------------------------------------------------------------------

export const REPORT_REASONS: ReadonlyArray<{ value: ReportReason; label: string }> = [
  { value: 'underage', label: 'May show someone under 18' },
  { value: 'nudity_or_sexual_content', label: 'Nudity or sexual content' },
  { value: 'harassment', label: 'Harassment or hate' },
  { value: 'spam', label: 'Spam or scam' },
  { value: 'copyright', label: 'Uses my photo without permission' },
  { value: 'other', label: 'Something else' },
];

export async function fileReport(input: {
  postId?: string;
  commentId?: string;
  reason: ReportReason;
  details?: string;
}): Promise<void> {
  if (Boolean(input.postId) === Boolean(input.commentId)) {
    throw new Error('A report needs exactly one post or comment.');
  }

  const reporterId = await requireUserId();
  const { error } = await supabase.from('reports').insert({
    reporter_id: reporterId,
    post_id: input.postId ?? null,
    comment_id: input.commentId ?? null,
    reason: input.reason,
    details: input.details?.trim() || null,
  });
  if (error) throw error;
}

// ---------------------------------------------------------------------------
// Profile visibility preference
// ---------------------------------------------------------------------------

export async function loadMyVisibilityDefault(): Promise<number | null> {
  const userId = await requireUserId();
  const { data, error } = await supabase
    .from('profiles')
    .select('default_max_viewer_age')
    .eq('id', userId)
    .maybeSingle();
  if (error) throw error;
  return data?.default_max_viewer_age ?? null;
}

/** The database rejects a value younger than the user's own age. */
export async function updateMyVisibilityDefault(maxAge: number | null): Promise<void> {
  if (maxAge !== null && (maxAge < 18 || maxAge > 100)) {
    throw new Error('The viewer age limit must be between 18 and 100.');
  }

  const userId = await requireUserId();
  const { error } = await supabase.from('profiles').update({ default_max_viewer_age: maxAge }).eq('id', userId);
  if (error) throw error;
}
