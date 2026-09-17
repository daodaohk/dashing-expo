/**
 * Contract for the existing Dashing migration. Keep this file as the one
 * schema adapter if generated Supabase types use different column names.
 */
export type Visibility = 'public' | 'adult';

export interface ProfileRow {
  id: string;
  username: string;
  display_name: string | null;
  avatar_url: string | null;
  bio: string | null;
  date_of_birth?: string;
  country?: string | null;
  city?: string | null;
  created_at: string;
}

export interface PostRow {
  id: string;
  author_id: string;
  caption: string | null;
  visibility: Visibility;
  created_at: string;
}

export interface PostPhotoRow {
  id: string;
  post_id: string;
  storage_path: string;
  position: number;
}

export interface RatingRow {
  post_id: string;
  user_id: string;
  value: number;
}

export interface CommentRow {
  id: string;
  post_id: string;
  author_id: string;
  body: string;
  created_at: string;
}

export interface BookmarkRow {
  post_id: string;
  user_id: string;
}

export interface LeaderboardRow {
  user_id: string;
  username: string;
  display_name: string | null;
  avatar_url: string | null;
  score: number;
  rank: number;
}

type Table<Row, Insert = Partial<Row>, Update = Partial<Insert>> = {
  Row: Row;
  Insert: Insert;
  Update: Update;
  Relationships: [];
};

export interface Database {
  public: {
    Tables: {
      profiles: Table<ProfileRow, Omit<ProfileRow, 'created_at'>>;
      posts: Table<PostRow, Omit<PostRow, 'id' | 'created_at'>>;
      post_photos: Table<PostPhotoRow, Omit<PostPhotoRow, 'id'>>;
      post_ratings: Table<RatingRow, RatingRow>;
      comments: Table<CommentRow, Omit<CommentRow, 'id' | 'created_at'>>;
      bookmarks: Table<BookmarkRow, BookmarkRow>;
    };
    Views: {
      leaderboard: { Row: LeaderboardRow; Relationships: [] };
    };
    Functions: Record<string, never>;
    Enums: Record<string, Visibility>;
    CompositeTypes: Record<string, never>;
  };
}
