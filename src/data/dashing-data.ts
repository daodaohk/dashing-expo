import { supabase } from '../config/supabase.js';
import type { CommentRow, LeaderboardRow, PostPhotoRow, PostRow, ProfileRow } from '../types/database.js';
import type { CommentWithAuthor, FeedPage, FeedPost, PostDraft } from '../types/live-data.js';

const PAGE_SIZE = 20;
const POST_MEDIA_BUCKET = 'post-media';

function storageUrl(path: string): string {
  return supabase.storage.from(POST_MEDIA_BUCKET).getPublicUrl(path).data.publicUrl;
}

function unique<T>(items: T[]): T[] {
  return [...new Set(items)];
}

async function requireUserId(): Promise<string> {
  const { data, error } = await supabase.auth.getUser();
  if (error) throw error;
  if (!data.user) throw new Error('You must sign in to do that.');
  return data.user.id;
}

async function hydratePosts(pageRows: PostRow[]): Promise<FeedPost[]> {
  if (!pageRows.length) return [];
  const postIds = pageRows.map((post) => post.id);
  const authorIds = unique(pageRows.map((post) => post.author_id));
  const [{ data: authors, error: authorsError }, { data: photos, error: photosError }, { data: ratings, error: ratingsError }] =
    await Promise.all([
      supabase.from('profiles').select('*').in('id', authorIds),
      supabase.from('post_photos').select('*').in('post_id', postIds).order('position'),
      supabase.from('post_ratings').select('post_id, value').in('post_id', postIds),
    ]);
  if (authorsError) throw authorsError;
  if (photosError) throw photosError;
  if (ratingsError) throw ratingsError;

  const { data: userData } = await supabase.auth.getUser();
  const viewerId = userData.user?.id;
  const { data: myRatings, error: myRatingsError } = viewerId
    ? await supabase.from('post_ratings').select('post_id, value').in('post_id', postIds).eq('user_id', viewerId)
    : { data: [], error: null };
  if (myRatingsError) throw myRatingsError;
  const { data: bookmarks, error: bookmarksError } = viewerId
    ? await supabase.from('bookmarks').select('post_id').in('post_id', postIds).eq('user_id', viewerId)
    : { data: [], error: null };
  if (bookmarksError) throw bookmarksError;

  const authorById = new Map((authors as ProfileRow[]).map((author) => [author.id, author]));
  const photosByPost = new Map<string, PostPhotoRow[]>();
  for (const photo of (photos as PostPhotoRow[])) {
    photosByPost.set(photo.post_id, [...(photosByPost.get(photo.post_id) ?? []), photo]);
  }
  const ratingsByPost = new Map<string, number[]>();
  for (const rating of (ratings ?? []) as Array<{ post_id: string; value: number }>) {
    ratingsByPost.set(rating.post_id, [...(ratingsByPost.get(rating.post_id) ?? []), rating.value]);
  }
  const viewerRatingByPost = new Map((myRatings ?? []).map((rating) => [rating.post_id, rating.value]));
  const bookmarkedPostIds = new Set((bookmarks ?? []).map((bookmark) => bookmark.post_id));

  return pageRows.flatMap((post) => {
    const author = authorById.get(post.author_id);
    if (!author) return [];
    const postRatings = ratingsByPost.get(post.id) ?? [];
    return [{
      ...post,
      author,
      photoUrls: (photosByPost.get(post.id) ?? []).map((photo) => storageUrl(photo.storage_path)),
      ratingCount: postRatings.length,
      ratingAverage: postRatings.length ? postRatings.reduce((total, rating) => total + rating, 0) / postRatings.length : null,
      viewerRating: viewerRatingByPost.get(post.id) ?? null,
      isBookmarked: bookmarkedPostIds.has(post.id),
    }];
  });
}

export async function loadFeed(cursor?: string): Promise<FeedPage> {
  const query = supabase
    .from('posts')
    .select('*')
    .order('created_at', { ascending: false })
    .limit(PAGE_SIZE + 1);
  const { data: rawPosts, error: postsError } = cursor
    ? await query.lt('created_at', cursor)
    : await query;
  if (postsError) throw postsError;

  const rows = rawPosts as PostRow[];
  const pageRows = rows.slice(0, PAGE_SIZE);
  if (!pageRows.length) return { posts: [], nextCursor: null };
  const posts = await hydratePosts(pageRows);

  const finalPost = pageRows[pageRows.length - 1];
  return { posts, nextCursor: rows.length > PAGE_SIZE ? finalPost?.created_at ?? null : null };
}

export async function createPost(draft: PostDraft): Promise<PostRow> {
  if (draft.photoUris.length < 1 || draft.photoUris.length > 5) {
    throw new Error('A post needs between one and five photos.');
  }
  const authorId = await requireUserId();
  const { data: post, error: postError } = await supabase
    .from('posts')
    .insert({ author_id: authorId, caption: draft.caption.trim() || null, visibility: draft.visibility })
    .select('*')
    .single();
  if (postError) throw postError;

  const uploadedPaths: string[] = [];
  try {
    for (const [position, uri] of draft.photoUris.entries()) {
      const response = await fetch(uri);
      const file = await response.arrayBuffer();
      const extension = uri.split('?')[0].split('.').pop()?.toLowerCase() || 'jpg';
      const storagePath = `${authorId}/${post.id}/${position}.${extension}`;
      const { error: uploadError } = await supabase.storage
        .from(POST_MEDIA_BUCKET)
        .upload(storagePath, file, { contentType: `image/${extension === 'jpg' ? 'jpeg' : extension}`, upsert: false });
      if (uploadError) throw uploadError;
      uploadedPaths.push(storagePath);
    }
    const { error: photosError } = await supabase.from('post_photos').insert(
      uploadedPaths.map((storage_path, position) => ({ post_id: post.id, storage_path, position })),
    );
    if (photosError) throw photosError;
    return post as PostRow;
  } catch (error) {
    await Promise.all(uploadedPaths.map((path) => supabase.storage.from(POST_MEDIA_BUCKET).remove([path])));
    await supabase.from('posts').delete().eq('id', post.id);
    throw error;
  }
}

export async function setRating(postId: string, value: number): Promise<void> {
  if (!Number.isInteger(value) || value < 1 || value > 5) throw new Error('Ratings must be whole numbers from 1 to 5.');
  const userId = await requireUserId();
  const { error } = await supabase.from('post_ratings').upsert({ post_id: postId, user_id: userId, value }, { onConflict: 'post_id,user_id' });
  if (error) throw error;
}

export async function loadComments(postId: string): Promise<CommentWithAuthor[]> {
  const { data: comments, error } = await supabase.from('comments').select('*').eq('post_id', postId).order('created_at');
  if (error) throw error;
  const rows = comments as CommentRow[];
  if (!rows.length) return [];
  const { data: authors, error: authorsError } = await supabase.from('profiles').select('id, username, display_name, avatar_url').in('id', unique(rows.map((row) => row.author_id)));
  if (authorsError) throw authorsError;
  const authorById = new Map((authors ?? []).map((author) => [author.id, author]));
  return rows.flatMap((comment) => {
    const author = authorById.get(comment.author_id);
    return author ? [{ ...comment, author }] : [];
  });
}

export async function addComment(postId: string, body: string): Promise<void> {
  const normalizedBody = body.trim();
  if (!normalizedBody) throw new Error('Write a comment first.');
  const authorId = await requireUserId();
  const { error } = await supabase.from('comments').insert({ post_id: postId, author_id: authorId, body: normalizedBody });
  if (error) throw error;
}

export async function setBookmark(postId: string, shouldBookmark: boolean): Promise<void> {
  const userId = await requireUserId();
  const query = supabase.from('bookmarks');
  const { error } = shouldBookmark
    ? await query.upsert({ post_id: postId, user_id: userId }, { onConflict: 'post_id,user_id' })
    : await query.delete().eq('post_id', postId).eq('user_id', userId);
  if (error) throw error;
}

export async function loadMyBookmarks(): Promise<FeedPage> {
  const userId = await requireUserId();
  const { data: rows, error } = await supabase.from('bookmarks').select('post_id').eq('user_id', userId);
  if (error) throw error;
  const ids = (rows ?? []).map((row) => row.post_id);
  if (!ids.length) return { posts: [], nextCursor: null };
  const { data: posts, error: postsError } = await supabase.from('posts').select('*').in('id', ids).order('created_at', { ascending: false });
  if (postsError) throw postsError;
  return { posts: await hydratePosts(posts as PostRow[]), nextCursor: null };
}

export async function loadLeaderboard(): Promise<LeaderboardRow[]> {
  const { data, error } = await supabase.from('leaderboard').select('*').order('rank').limit(100);
  if (error) throw error;
  return data as LeaderboardRow[];
}
