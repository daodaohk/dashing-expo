-- Dashing: per-post viewer age ceiling + profile default
--
-- Replaces posts.viewer_min_age (a floor) with posts.max_viewer_age (a ceiling:
-- the viewer must be no older than this). NULL means no restriction.
-- Adds profiles.default_max_viewer_age, the saved preference applied to new posts.
--
-- Applied after 20260917140000.

begin;

-- ---------------------------------------------------------------------------
-- posts: the new column
-- ---------------------------------------------------------------------------

alter table public.posts
  add column if not exists max_viewer_age smallint;

-- Existing posts carry viewer_min_age = 18 by default, which under the old
-- semantics meant "adults only" — already enforced platform-wide by
-- enforce_profile_gate. Copying 18 across would mean "nobody over 18" and hide
-- every existing post, so any value at or below the platform floor becomes NULL.
update public.posts
  set max_viewer_age = null
  where viewer_min_age is null or viewer_min_age <= 18;

alter table public.posts
  add constraint posts_max_viewer_age_bounds
  check (max_viewer_age is null or max_viewer_age between 18 and 100);

comment on column public.posts.max_viewer_age is
  'Maximum viewer age allowed to see this post. NULL = no ceiling.';

create index if not exists posts_max_viewer_age_idx on public.posts (max_viewer_age);

-- ---------------------------------------------------------------------------
-- profiles: the saved default
-- ---------------------------------------------------------------------------

alter table public.profiles
  add column if not exists default_max_viewer_age smallint;

alter table public.profiles
  add constraint profiles_default_max_viewer_age_bounds
  check (
    default_max_viewer_age is null
    or default_max_viewer_age between 18 and 100
  );

comment on column public.profiles.default_max_viewer_age is
  'Preferred viewer age ceiling for new posts. NULL = no restriction.';

-- ---------------------------------------------------------------------------
-- RLS: invert the comparison
-- ---------------------------------------------------------------------------

drop policy if exists "Authors and moderators can view posts" on public.posts;
create policy "Authors and moderators can view posts" on public.posts
for select to authenticated
using (
  author_id = auth.uid()
  or private.current_user_is_moderator()
  or (
    status = 'published'
    and private.current_user_is_adult()
    and (
      max_viewer_age is null
      or exists (
        select 1 from public.profiles viewer
        where viewer.id = auth.uid()
          and viewer.date_of_birth >= (current_date - make_interval(years => posts.max_viewer_age::integer))::date
      )
    )
  )
);

drop policy if exists "Adult users can create their own posts" on public.posts;
create policy "Adult users can create their own posts" on public.posts
for insert to authenticated
with check (
  author_id = auth.uid()
  and private.current_user_is_adult()
  and (max_viewer_age is null or max_viewer_age between 18 and 100)
  and cardinality(media_urls) >= 1 and cardinality(media_urls) <= 5
  and status = any (array['draft'::post_status, 'published'::post_status])
  and moderated_by is null and moderated_at is null and moderation_note is null
);

drop policy if exists "Authors can update their unmoderated posts" on public.posts;
create policy "Authors can update their unmoderated posts" on public.posts
for update to authenticated
using (author_id = auth.uid())
with check (
  author_id = auth.uid()
  and private.current_user_is_adult()
  and (max_viewer_age is null or max_viewer_age between 18 and 100)
  and cardinality(media_urls) >= 1 and cardinality(media_urls) <= 5
  and status = any (array['draft'::post_status, 'published'::post_status])
  and moderated_by is null and moderated_at is null and moderation_note is null
);

-- The profile default is a normal profile field; the existing
-- "Users can update their own profile" policy already governs writes to it.

-- ---------------------------------------------------------------------------
-- Leaderboard: same inversion
-- ---------------------------------------------------------------------------

drop materialized view if exists public.post_leaderboard;
create materialized view public.post_leaderboard as
select
  p.id as post_id,
  p.author_id,
  p.max_viewer_age,
  p.created_at,
  count(r.*)::integer as rating_count,
  round(avg(r.score)::numeric, 2) as average_rating,
  coalesce(sum(r.score), 0)::integer as rating_total
from public.posts p
join public.ratings r on r.post_id = p.id
where p.status = 'published'
group by p.id, p.author_id, p.max_viewer_age, p.created_at
having count(r.*) > 0;

create unique index if not exists post_leaderboard_post_id_idx
  on public.post_leaderboard (post_id);
create index if not exists post_leaderboard_rating_idx
  on public.post_leaderboard (average_rating desc, rating_count desc);

drop function if exists public.get_post_leaderboard(integer);
create or replace function public.get_post_leaderboard(result_limit integer default 50)
returns table (
  post_id uuid,
  author_id uuid,
  max_viewer_age smallint,
  created_at timestamptz,
  rating_count integer,
  average_rating numeric,
  rating_total integer
)
language sql
stable
security definer
set search_path to 'pg_catalog', 'private'
as $$
  select l.post_id, l.author_id, l.max_viewer_age, l.created_at,
         l.rating_count, l.average_rating, l.rating_total
  from public.post_leaderboard l
  join public.profiles viewer on viewer.id = auth.uid()
  where public.is_adult(viewer.date_of_birth)
    and (
      l.max_viewer_age is null
      or viewer.date_of_birth >= (current_date - make_interval(years => l.max_viewer_age::integer))::date
    )
  order by l.average_rating desc, l.rating_count desc, l.created_at desc
  limit greatest(1, least(coalesce(result_limit, 50), 100));
$$;

revoke all on function public.get_post_leaderboard(integer) from public;
grant execute on function public.get_post_leaderboard(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- Retire the old column
-- ---------------------------------------------------------------------------

alter table public.posts drop column if exists viewer_min_age;

commit;
