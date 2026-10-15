-- Dashing — add the 'in_review' post status (2026-10-15)
--
-- Kept in its own migration: a new enum value cannot be used in the same
-- transaction that adds it, and the next migration's policies use it.

alter type public.post_status add value if not exists 'in_review' after 'draft';
