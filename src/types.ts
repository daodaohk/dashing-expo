export type Tab = 'feed' | 'compose' | 'saved' | 'profile' | 'rankings';

export type Post = {
  id: string;
  author: string;
  city: string;
  caption: string;
  tags: string[];
  imageUrls: string[];
  ratingAverage: number;
  ratingCount: number;
  isBookmarked?: boolean;
  maxViewerAge?: number | null;
};

export type Comment = {
  id: string;
  author: string;
  body: string;
  time: string;
};
