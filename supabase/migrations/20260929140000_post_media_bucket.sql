-- Dashing: private post-media bucket
--
-- Creates the bucket the composer uploads into. It is PRIVATE: nothing is
-- served from a public URL, and reads go through short-lived signed URLs
-- generated after the posts RLS policy has already decided the viewer is
-- allowed to see the post.
--
-- Object layout: <author_id>/<post_id>/<position>.<ext>
-- The first path segment is the author's id, which is what the upload policy
-- checks — a user can only write inside their own folder.

begin;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'post-media',
  'post-media',
  false,
  8388608,                                                            -- 8 MB per file
  array['image/jpeg', 'image/png', 'image/webp', 'image/heic']
)
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- ---------------------------------------------------------------------------
-- Upload: only into your own folder
-- ---------------------------------------------------------------------------

drop policy if exists "Authors upload to their own folder" on storage.objects;
create policy "Authors upload to their own folder" on storage.objects
for insert to authenticated
with check (
  bucket_id = 'post-media'
  and (storage.foldername(name))[1] = auth.uid()::text
);

-- ---------------------------------------------------------------------------
-- Manage and delete: your own folder only
-- ---------------------------------------------------------------------------

drop policy if exists "Authors manage their own media" on storage.objects;
create policy "Authors manage their own media" on storage.objects
for update to authenticated
using (
  bucket_id = 'post-media'
  and (storage.foldername(name))[1] = auth.uid()::text
)
with check (
  bucket_id = 'post-media'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists "Authors delete their own media" on storage.objects;
create policy "Authors delete their own media" on storage.objects
for delete to authenticated
using (
  bucket_id = 'post-media'
  and (storage.foldername(name))[1] = auth.uid()::text
);

-- ---------------------------------------------------------------------------
-- Read: any eligible adult may request a signed URL for media on a post they
-- can already see. The EXISTS clause mirrors the posts SELECT policy, so the
-- storage layer inherits the same max_viewer_age ceiling.
-- ---------------------------------------------------------------------------

drop policy if exists "Adults read media of visible posts" on storage.objects;
create policy "Adults read media of visible posts" on storage.objects
for select to authenticated
using (
  bucket_id = 'post-media'
  and exists (
    select 1
    from public.posts p
    join public.profiles viewer on viewer.id = auth.uid()
    where p.status = 'published'
      and p.media_urls @> array[storage.objects.name]
      and public.is_adult(viewer.date_of_birth)
      and (
        p.max_viewer_age is null
        or viewer.date_of_birth >= (current_date - make_interval(years => p.max_viewer_age::integer))::date
      )
  )
);

commit;
