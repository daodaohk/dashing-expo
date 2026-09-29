/**
 * Dashing data layer — written against the live schema.
 *
 * Tables this talks to (project ozeixaolbickpauayjcu):
 *   profiles(id, username, display_name, avatar_url, bio, date_of_birth,
 *            is_moderator, country, city, default_max_viewer_age, ...)
 *   posts(id, author_id, caption, media_urls, max_viewer_age, status,
 *         moderation_note, moderated_at, moderated_by, ...)
 *   ratings(id, post_id, user_id, score, ...)      -- score, not value
 *   comments(id, post_id, author_id, body, is_hidden, ...)
 *   bookmarks(user_id, post_id, created_at)
 *   reports(id, reporter_id, post_id, comment_id, reason, details, ...)
 *   profile_cards(id, username, display_name, avatar_url, bio, created_at)
 *
 * Visibility is enforced by RLS, not here. `max_viewer_age` is a ceiling:
 * a viewer older than it cannot see the post, and the SELECT policy filters
 * those rows out before this code ever receives them.
 */

import { supabase } from '../config/supabase';
import type {
  CommentRow,
  LeaderboardEntry,
  PostRow,
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
  status: PostRow['status'];
  created_at: string;
  author: FeedAuthor;
  ratingAverage: number | null;
  ratingCount: number;
  viewerRating: number | null;
  isBookmarked: boolean;
}

export interface FeedPage {
  posts: FeedPost[];
  nextCursor: string | null;
}

export interface CommentWithAuthor extends CommentRow {
  author: FeedAuthor;
}

export interface PostDraft {
  caption: string;
  mediaUrls: string[];
  maxViewerAge: number | null;
  status?: PostRow['status'];
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

function unique<T>(items: T[]): T[] {
  return [...new Set(items)];
}

async function requireUserId(): Promise<string> {
  const { data, error } = await supabase.auth.getUser();
  if (error) throw error;
  if (!data.user) throw new Error('You must sign in to do that.');
  return data.user.id;
}

function toAuthor(card: ProfileCardRow): FeedAuthor {
  return {
    id: card.id,
    username: card.username,
    display_name: card.display_name,
    avatar_url: card.avatar_url,
  };
}

/** Fetch the public profile cards for a set of ids. */
async function loadAuthors(authorIds: string[]): Promise<Map<string, FeedAuthor>> {
  const ids = unique(authorIds);
  if (!ids.length) return new Map();

  const { data, error } = await supabase
    .from('profile_cards')
    .select('id, username, display_name, avatar_url, bio, created_at')
    .in('id', ids);
  if (error) throw error;

  return new Map((data as ProfileCardRow[]).map((card) => [card.id, toAuthor(card)]));
}

/**
 * Attach author, rating and bookmark state to raw post rows.
 *
 * Ratings are aggregated over the page's posts in one round trip. The SELECT
 * policy on `ratings` scopes what comes back, so this only ever sees rows the
 * viewer is entitled to.
 */
async function hydratePosts(rows: PostRow[]): Promise<FeedPost[]> {
  if (!rows.length) return [];

  const postIds = rows.map((row) => row.id);
  const viewerId = (await supabase.auth.getUser()).data.user?.id ?? null;

  const [authors, ratingsResult, myRatingsResult, bookmarksResult] = await Promise.all([
    loadAuthors(rows.map((row) => row.author_id)),
    supabase.from('ratings').select('post_id, score').in('post_id', postIds),
    viewerId
      ? supabase.from('ratings').select('post_id, score').in('post_id', postIds).eq('user_id', viewerId)
      : Promise.resolve({ data: [], error: null }),
    viewerId
      ? supabase.from('bookmarks').select('post_id').in('post_id', postIds).eq('user_id', viewerId)
      : Promise.resolve({ data: [], error: null }),
  ]);

  if (ratingsResult.error) throw ratingsResult.error;
  if (myRatingsResult.error) throw myRatingsResult.error;
  if (bookmarksResult.error) throw bookmarksResult.error;

  const totals = new Map<string, { sum: number; count: number }>();
  for (const row of (ratingsResult.data ?? []) as Array<{ post_id: string; score: number }>) {
    const current = totals.get(row.post_id) ?? { sum: 0, count: 0 };
    totals.set(row.post_id, { sum: current.sum + row.score, count: current.count + 1 });
  }

  const myRatings = new Map(
    ((myRatingsResult.data ?? []) as Array<{ post_id: string; score: number }>).map((row) => [
      row.post_id,
      row.score,
    ]),
  );
  const bookmarked = new Set(
    ((bookmarksResult.data ?? []) as Array<{ post_id: string }>).map((row) => row.post_id),
  );

  return rows.flatMap((row) => {
    const author = authors.get(row.author_id);
    if (!author) return [];
    const rating = totals.get(row.id);
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
        ratingAverage: rating ? rating.sum / rating.count : null,
        ratingCount: rating?.count ?? 0,
        viewerRating: myRatings.get(row.id) ?? null,
        isBookmarked: bookmarked.has(row.id),
      },
    ];
  });
}

// ---------------------------------------------------------------------------
// Feed
// ---------------------------------------------------------------------------

export async function loadFeed(cursor?: string): Promise<FeedPage> {
  const base = supabase
    .from('posts')
    .select('*')
    .eq('status', 'published')
    .order('created_at', { ascending: false })
    .limit(PAGE_SIZE + 1);

  const { data, error } = cursor ? await base.lt('created_at', cursor) : await base;
  if (error) throw error;

  const rows = (data ?? []) as PostRow[];
  const pageRows = rows.slice(0, PAGE_SIZE);
  if (!pageRows.length) return { posts: [], nextCursor: null };

  const posts = await hydratePosts(pageRows);
  const last = pageRows[pageRows.length - 1];
  return {
    posts,
    nextCursor: rows.length > PAGE_SIZE ? last.created_at : null,
  };
}

export async function loadPost(postId: string): Promise<FeedPost | null> {
  const { data, error } = await supabase.from('posts').select('*').eq('id', postId).maybeSingle();
  if (error) throw error;
  if (!data) return null;
  const [post] = await hydratePosts([data as PostRow]);
  return post ?? null;
}

export async function loadMyPosts(): Promise<FeedPost[]> {
  const userId = await requireUserId();
  const { data, error } = await supabase
    .from('posts')
    .select('*')
    .eq('author_id', userId)
    .order('created_at', { ascending: false });
  if (error) throw error;
  return hydratePosts((data ?? []) as PostRow[]);
}

// ---------------------------------------------------------------------------
// Composing
// ---------------------------------------------------------------------------

export async function createPost(draft: PostDraft): Promise<PostRow> {
  const mediaUrls = draft.mediaUrls.filter((url) => url.trim().length > 0);
  if (mediaUrls.length < 1 || mediaUrls.length > 5) {
    throw new Error('A post needs between one and five photos.');
  }

  const authorId = await requireUserId();
  const maxAge = draft.maxViewerAge;
  if (maxAge !== null && (maxAge < 18 || maxAge > 100)) {
    throw new Error('The viewer age limit must be between 18 and 100.');
  }

  const { data, error } = await supabase
    .from('posts')
    .insert({
      author_id: authorId,
      caption: draft.caption.trim() || null,
      media_urls: mediaUrls,
      max_viewer_age: maxAge,
      status: draft.status ?? 'published',
    })
    .select('*')
    .single();
  if (error) throw error;
  return data as PostRow;
}

export async function deleteMyPost(postId: string): Promise<void> {
  const { error } = await supabase.from('posts').delete().eq('id', postId);
  if (error) throw error;
}

// ---------------------------------------------------------------------------
// Ratings — one per viewer, enforced by the table's unique (post_id, user_id)
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
  const { error } = await supabase
    .from('ratings')
    .delete()
    .eq('post_id', postId)
    .eq('user_id', userId);
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

  const rows = (data ?? []) as CommentRow[];
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

  const authorId = await requireUserId();
  const { error } = await supabase
    .from('comments')
    .insert({ post_id: postId, author_id: authorId, body: trimmed });
  if (error) throw error;
}

// ---------------------------------------------------------------------------
// Bookmarks — private to the owner
// ---------------------------------------------------------------------------

export async function setBookmark(postId: string, shouldBookmark: boolean): Promise<void> {
  const userId = await requireUserId();
  const query = supabase.from('bookmarks');
  const { error } = shouldBookmark
    ? await query.upsert({ post_id: postId, user_id: userId }, { onConflict: 'post_id,user_id' })
    : await query.delete().eq('post_id', postId).eq('user_id', userId);
  if (error) throw error;
}

export async function loadMyBookmarks(): Promise<FeedPost[]> {
  const userId = await requireUserId();
  const { data: rows, error } = await supabase
    .from('bookmarks')
    .select('post_id')
    .eq('user_id', userId)
    .order('created_at', { ascending: false });
  if (error) throw error;

  const ids = ((rows ?? []) as Array<{ post_id: string }>).map((row) => row.post_id);
  if (!ids.length) return [];

  const { data: posts, error: postsError } = await supabase
    .from('posts')
    .select('*')
    .in('id', ids)
    .eq('status', 'published');
  if (postsError) throw postsError;

  return hydratePosts((posts ?? []) as PostRow[]);
}

// ---------------------------------------------------------------------------
// Leaderboard — ages filtered in the function, not here
// ---------------------------------------------------------------------------

export async function loadLeaderboard(limit = 50): Promise<LeaderboardEntry[]> {
  const { data, error } = await supabase.rpc('get_post_leaderboard', { result_limit: limit });
  if (error) throw error;
  return (data ?? []) as LeaderboardEntry[];
}

// ---------------------------------------------------------------------------
// Reports — the destination for the report button
// ---------------------------------------------------------------------------

export async function fileReport(input: {
  postId?: string;
  commentId?: string;
  reason: ReportReason;
  details?: string;
}): Promise<void> {
  if (!input.postId && !input.commentId) {
    throw new Error('A report needs a post or a comment.');
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

export async function updateMyVisibilityDefault(maxAge: number | null): Promise<void> {
  if (maxAge !== null && (maxAge < 18 || maxAge > 100)) {
    throw new Error('The viewer age limit must be between 18 and 100.');
  }

  const userId = await requireUserId();
  const { error } = await supabase
    .from('profiles')
    .update({ default_max_viewer_age: maxAge })
    .eq('id', userId);
  if (error) throw error;
}
