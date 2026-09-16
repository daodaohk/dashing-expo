import { Comment, Post } from '../types';

export const posts: Post[] = [
  {
    id: 'sunset-tailoring', author: 'Mara L.', city: 'Lisbon, Portugal',
    caption: 'Soft structure for a late golden-hour walk.', tags: ['Tailored', 'Warm tones'],
    imageUrls: ['https://images.unsplash.com/photo-1483985988355-763728e1935b?auto=format&fit=crop&w=1200&q=85'],
    ratingAverage: 4.8, ratingCount: 128, isBookmarked: true,
  },
  {
    id: 'street-bright', author: 'June K.', city: 'Seoul, South Korea',
    caption: 'A bright layer to make a grey day feel louder.', tags: ['Streetwear', 'Color pop'],
    imageUrls: ['https://images.unsplash.com/photo-1496747611176-843222e1e57c?auto=format&fit=crop&w=1200&q=85'],
    ratingAverage: 4.6, ratingCount: 93,
  },
  {
    id: 'weekend-linen', author: 'Sofia A.', city: 'Mexico City, Mexico',
    caption: 'Linen, leather, and nowhere to rush to.', tags: ['Minimal', 'Weekend'],
    imageUrls: ['https://images.unsplash.com/photo-1509631179647-0177331693ae?auto=format&fit=crop&w=1200&q=85'],
    ratingAverage: 4.9, ratingCount: 176,
  },
];

export const comments: Comment[] = [
  { id: 'c1', author: 'Amira', body: 'The texture mix is so good.', time: '18m' },
  { id: 'c2', author: 'Noah', body: 'That palette is a whole mood.', time: '42m' },
];
