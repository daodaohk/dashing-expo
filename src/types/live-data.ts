import type { CommentRow, LeaderboardRow, PostRow, ProfileRow, Visibility } from './database.js';

export interface FeedPost extends PostRow {
  author: ProfileRow;
  photoUrls: string[];
  ratingCount: number;
  ratingAverage: number | null;
  viewerRating: number | null;
  isBookmarked: boolean;
}

export interface FeedPage {
  posts: FeedPost[];
  nextCursor: string | null;
}

export interface PostDraft {
  caption: string;
  visibility: Visibility;
  photoUris: string[];
}

export interface CommentWithAuthor extends CommentRow {
  author: Pick<ProfileRow, 'id' | 'username' | 'display_name' | 'avatar_url'>;
}

export type { LeaderboardRow };
