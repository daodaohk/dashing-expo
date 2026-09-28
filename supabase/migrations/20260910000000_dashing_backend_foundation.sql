-- Dashing backend foundation
--
-- Creates the schema the application and the two later migrations assume:
-- profiles (with private DOB/location), posts, post_photos, post_ratings,
-- comments, bookmarks, the profile_cards and leaderboard views, the
-- is_adult() age gate, RLS across every table, the max_viewer_age
-- visibility rule, and the get_feed / get_post / submit_outfit_rating RPCs.
--
-- Security model:
--   * The client 18+ checkbox is UX only. Adult eligibility is decided here,
--     from date_of_birth, which never leaves the database.
--   * Feed and detail reads go through SECURITY DEFINER RPCs so the
--     max_viewer_age ceiling is enforced in one auditable place.
--   * post-media is a PRIVATE bucket. URLs are signed per request.

begin;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------

create type public.post_visibility as enum ('public', 'adult');
create type public.post_status as enum ('draft', 'in_review', 'published', 'rejected', 'removed');
create type public.photo_status as enum ('pending', 'ready', 'rejected');

-- ---------------------------------------------------------------------------
-- Age gate
-- ---------------------------------------------------------------------------

create or replace function public.is_adult(dob date)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select dob is not null and dob <= (current_date - interval '18 years');
$$;

create or replace function public.age_years(dob date)
returns integer
language sql
stable
set search_path = ''
as $$
  select case
    when dob is null then null
    else extract(year from age(current_date, dob))::integer
  end;
$$;

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username text not null unique,
  display_name text,
  avatar_url text,
  bio text,
  date_of_birth date not null,
  country text,
  city text,
  is_moderator boolean not null default false,
  is_suspended boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint profiles_username_format
    check (username = lower(btrim(username)) and username ~ '^[a-z0-9_]{3,30}$'),
  constraint profiles_display_name_length
    check (display_name is null or char_length(btrim(display_name)) between 1 and 60),
  constraint profiles_bio_length
    check (bio is null or char_length(bio) <= 300),
  constraint profiles_is_adult
    check (public.is_adult(date_of_birth))
);

create index profiles_username_idx on public.profiles (username);

-- ---------------------------------------------------------------------------
-- posts
-- ---------------------------------------------------------------------------

create table public.posts (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references public.profiles (id) on delete cascade,
  caption text,
  tags text[] not null default '{}',
  visibility public.post_visibility not null default 'public',
  status public.post_status not null default 'draft',
  -- Server-calculated ceiling. NULL = no ceiling. A viewer whose age exceeds
  -- this value cannot see the post. Never set from the client.
  max_viewer_age integer,
  published_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint posts_caption_length
    check (caption is null or char_length(caption) <= 2000),
  constraint posts_tags_bounds
    check (cardinality(tags) between 0 and 3),
  constraint posts_max_viewer_age_bounds
    check (max_viewer_age is null or max_viewer_age between 18 and 120)
);

create index posts_feed_idx on public.posts (status, created_at desc);
create index posts_author_idx on public.posts (author_id, created_at desc);

-- ---------------------------------------------------------------------------
-- post_photos
-- ---------------------------------------------------------------------------

create table public.post_photos (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts (id) on delete cascade,
  storage_path text not null unique,
  position smallint not null,
  status public.photo_status not null default 'pending',
  created_at timestamptz not null default now(),

  constraint post_photos_position_bounds check (position between 0 and 4),
  unique (post_id, position)
);

create index post_photos_post_idx on public.post_photos (post_id, position);

-- ---------------------------------------------------------------------------
-- post_ratings — one current rating per (post, viewer)
-- ---------------------------------------------------------------------------

create table public.post_ratings (
  post_id uuid not null references public.posts (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  value smallint not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  primary key (post_id, user_id),
  constraint post_ratings_value_bounds check (value between 1 and 5)
);

create index post_ratings_post_idx on public.post_ratings (post_id);

-- ---------------------------------------------------------------------------
-- comments
-- ---------------------------------------------------------------------------

create table public.comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts (id) on delete cascade,
  author_id uuid not null references public.profiles (id) on delete cascade,
  body text not null,
  created_at timestamptz not null default now(),

  constraint comments_body_length
    check (char_length(btrim(body)) between 1 and 1000)
);

create index comments_post_idx on public.comments (post_id, created_at);

-- ---------------------------------------------------------------------------
-- bookmarks — private to the owner
-- ---------------------------------------------------------------------------

create table public.bookmarks (
  post_id uuid not null references public.posts (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

create index bookmarks_user_idx on public.bookmarks (user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Visibility helper — the single definition of "can this viewer see this post"
-- ---------------------------------------------------------------------------

create or replace function public.can_view_post(p_post public.posts, p_viewer uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select
    p_post.status = 'published'
    and exists (
      select 1
      from public.profiles viewer
      where viewer.id = p_viewer
        and not viewer.is_suspended
        and public.is_adult(viewer.date_of_birth)
        and (
          p_post.max_viewer_age is null
          or public.age_years(viewer.date_of_birth) <= p_post.max_viewer_age
        )
    );
$$;

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

alter table public.profiles enable row level security;
alter table public.posts enable row level security;
alter table public.post_photos enable row level security;
alter table public.post_ratings enable row level security;
alter table public.comments enable row level security;
alter table public.bookmarks enable row level security;

-- profiles: a user reads and writes only their own row.
-- Public-facing fields are exposed through profile_cards.
create policy "Users can read their own profile" on public.profiles
for select to authenticated
using (id = (select auth.uid()));

create policy "Users can create their own adult profile" on public.profiles
for insert to authenticated
with check (
  id = (select auth.uid())
  and public.is_adult(date_of_birth)
  and not is_moderator
);

create policy "Users can update their own profile" on public.profiles
for update to authenticated
using (id = (select auth.uid()))
with check (
  id = (select auth.uid())
  and public.is_adult(date_of_birth)
  and not is_moderator
);

-- posts
create policy "Authors manage their own posts" on public.posts
for all to authenticated
using (author_id = (select auth.uid()))
with check (author_id = (select auth.uid()));

create policy "Adults read visible published posts" on public.posts
for select to authenticated
using (public.can_view_post(posts, (select auth.uid())));

-- post_photos: readable when the parent post is
create policy "Authors manage their own photos" on public.post_photos
for all to authenticated
using (exists (select 1 from public.posts p where p.id = post_id and p.author_id = (select auth.uid())))
with check (exists (select 1 from public.posts p where p.id = post_id and p.author_id = (select auth.uid())));

create policy "Photos follow post visibility" on public.post_photos
for select to authenticated
using (exists (
  select 1 from public.posts p
  where p.id = post_id and public.can_view_post(p, (select auth.uid()))
));

-- post_ratings: a viewer sees and writes only their own row.
-- Aggregates reach the client through the RPCs, never raw rows.
create policy "Viewers manage their own rating" on public.post_ratings
for all to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

-- comments
create policy "Comments follow post visibility" on public.comments
for select to authenticated
using (exists (
  select 1 from public.posts p
  where p.id = post_id and public.can_view_post(p, (select auth.uid()))
));

create policy "Adults comment on visible posts" on public.comments
for insert to authenticated
with check (
  author_id = (select auth.uid())
  and exists (
    select 1 from public.posts p
    where p.id = post_id and public.can_view_post(p, (select auth.uid()))
  )
);

create policy "Authors delete their own comments" on public.comments
for delete to authenticated
using (author_id = (select auth.uid()));

-- bookmarks
create policy "Bookmarks are private to their owner" on public.bookmarks
for all to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- profile_cards — public projection. No DOB, no country, no city.
-- ---------------------------------------------------------------------------

create view public.profile_cards
with (security_invoker = true)
as
select
  p.id,
  p.username,
  p.display_name,
  p.avatar_url,
  p.bio,
  p.created_at
from public.profiles p
where not p.is_suspended;

-- ---------------------------------------------------------------------------
-- leaderboard — aggregate only, no individual votes
-- ---------------------------------------------------------------------------

create view public.leaderboard
with (security_invoker = true)
as
select
  p.author_id as user_id,
  pr.username,
  pr.display_name,
  pr.avatar_url,
  round(avg(r.value)::numeric, 2) as score,
  count(r.*) as rating_count,
  rank() over (order by avg(r.value) desc nulls last, count(r.*) desc) as rank
from public.posts p
join public.profiles pr on pr.id = p.author_id
join public.post_ratings r on r.post_id = p.id
where p.status = 'published'
  and not pr.is_suspended
group by p.author_id, pr.username, pr.display_name, pr.avatar_url
having count(r.*) >= 3;

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------

create or replace function public.get_feed(p_cursor timestamptz default null, p_limit integer default 20)
returns table (
  id uuid,
  author_id uuid,
  username text,
  display_name text,
  avatar_url text,
  caption text,
  tags text[],
  photo_paths text[],
  rating_average numeric,
  rating_count bigint,
  viewer_rating smallint,
  is_bookmarked boolean,
  created_at timestamptz
)
language sql
security definer
stable
set search_path = ''
as $$
  select
    p.id,
    p.author_id,
    pr.username,
    pr.display_name,
    pr.avatar_url,
    p.caption,
    p.tags,
    coalesce(
      (select array_agg(ph.storage_path order by ph.position)
       from public.post_photos ph
       where ph.post_id = p.id and ph.status = 'ready'),
      '{}'
    ),
    (select round(avg(r.value)::numeric, 2) from public.post_ratings r where r.post_id = p.id),
    (select count(*) from public.post_ratings r where r.post_id = p.id),
    (select r.value from public.post_ratings r
      where r.post_id = p.id and r.user_id = (select auth.uid())),
    exists (select 1 from public.bookmarks b
      where b.post_id = p.id and b.user_id = (select auth.uid())),
    p.created_at
  from public.posts p
  join public.profiles pr on pr.id = p.author_id
  where public.can_view_post(p, (select auth.uid()))
    and (p_cursor is null or p.created_at < p_cursor)
  order by p.created_at desc
  limit least(greatest(p_limit, 1), 50);
$$;

create or replace function public.get_post(p_post_id uuid)
returns table (
  id uuid,
  author_id uuid,
  username text,
  display_name text,
  avatar_url text,
  caption text,
  tags text[],
  photo_paths text[],
  rating_average numeric,
  rating_count bigint,
  viewer_rating smallint,
  is_bookmarked boolean,
  created_at timestamptz
)
language sql
security definer
stable
set search_path = ''
as $$
  select
    p.id, p.author_id, pr.username, pr.display_name, pr.avatar_url,
    p.caption, p.tags,
    coalesce(
      (select array_agg(ph.storage_path order by ph.position)
       from public.post_photos ph
       where ph.post_id = p.id and ph.status = 'ready'),
      '{}'
    ),
    (select round(avg(r.value)::numeric, 2) from public.post_ratings r where r.post_id = p.id),
    (select count(*) from public.post_ratings r where r.post_id = p.id),
    (select r.value from public.post_ratings r
      where r.post_id = p.id and r.user_id = (select auth.uid())),
    exists (select 1 from public.bookmarks b
      where b.post_id = p.id and b.user_id = (select auth.uid())),
    p.created_at
  from public.posts p
  join public.profiles pr on pr.id = p.author_id
  where p.id = p_post_id
    and public.can_view_post(p, (select auth.uid()));
$$;

create or replace function public.submit_outfit_rating(p_post_id uuid, p_value smallint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_viewer uuid := (select auth.uid());
  v_post public.posts;
begin
  if v_viewer is null then
    raise exception 'Sign in to rate a look.' using errcode = '42501';
  end if;

  if p_value is null or p_value < 1 or p_value > 5 then
    raise exception 'Ratings must be whole numbers from 1 to 5.' using errcode = '22023';
  end if;

  select * into v_post from public.posts where id = p_post_id;

  if not found or not public.can_view_post(v_post, v_viewer) then
    raise exception 'That look is not available.' using errcode = '42501';
  end if;

  if v_post.author_id = v_viewer then
    raise exception 'You cannot rate your own look.' using errcode = '42501';
  end if;

  insert into public.post_ratings (post_id, user_id, value)
  values (p_post_id, v_viewer, p_value)
  on conflict (post_id, user_id)
  do update set value = excluded.value, updated_at = now();
end;
$$;

revoke all on function public.get_feed(timestamptz, integer) from public;
revoke all on function public.get_post(uuid) from public;
revoke all on function public.submit_outfit_rating(uuid, smallint) from public;
grant execute on function public.get_feed(timestamptz, integer) to authenticated;
grant execute on function public.get_post(uuid) to authenticated;
grant execute on function public.submit_outfit_rating(uuid, smallint) to authenticated;

-- ---------------------------------------------------------------------------
-- Storage — PRIVATE bucket, signed URLs only
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'post-media',
  'post-media',
  false,
  8388608,
  array['image/jpeg', 'image/png', 'image/webp', 'image/heic']
)
on conflict (id) do nothing;

create policy "Authors upload to their own folder" on storage.objects
for insert to authenticated
with check (
  bucket_id = 'post-media'
  and (storage.foldername(name))[1] = (select auth.uid())::text
);

create policy "Authors manage their own media" on storage.objects
for all to authenticated
using (
  bucket_id = 'post-media'
  and (storage.foldername(name))[1] = (select auth.uid())::text
);

create policy "Adults read media of visible posts" on storage.objects
for select to authenticated
using (
  bucket_id = 'post-media'
  and exists (
    select 1
    from public.post_photos ph
    join public.posts p on p.id = ph.post_id
    where ph.storage_path = storage.objects.name
      and ph.status = 'ready'
      and public.can_view_post(p, (select auth.uid()))
  )
);

-- ---------------------------------------------------------------------------
-- updated_at triggers
-- ---------------------------------------------------------------------------

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger profiles_touch before update on public.profiles
  for each row execute function public.touch_updated_at();
create trigger posts_touch before update on public.posts
  for each row execute function public.touch_updated_at();

commit;
