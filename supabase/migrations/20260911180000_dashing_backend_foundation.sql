-- Dashing backend foundation
--
-- Expected prerequisites
-- * Run this in a Supabase project with Supabase Auth enabled (auth.users exists).
-- * This migration owns the public.profiles, posts, ratings, comments,
--   bookmarks, reports, and leaderboard objects below. Review it before running
--   it against a project that already uses those names.
-- * Client applications must use only the project's URL and publishable/anon key.
--   Never expose a database password, service_role key, or secret key in Expo.
-- * Media URLs are application-managed. This migration does not create a Storage
--   bucket; configure one separately and save only its safe public or signed URLs.
--
-- The migration is intentionally safe to re-run where PostgreSQL permits. It
-- applies database-side eligibility, visibility, ownership, and content limits;
-- do not replace these checks with client-only validation.

create extension if not exists pgcrypto;

do $$
begin
  create type public.post_status as enum ('draft', 'published', 'hidden', 'removed');
exception
  when duplicate_object then null;
end $$;

do $$
begin
  create type public.report_reason as enum (
    'underage', 'nudity_or_sexual_content', 'harassment', 'spam', 'copyright', 'other'
  );
exception
  when duplicate_object then null;
end $$;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null,
  display_name text,
  avatar_url text,
  bio text,
  date_of_birth date not null,
  is_moderator boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_username_length check (char_length(username) between 3 and 32),
  constraint profiles_username_format check (username ~ '^[a-z0-9_]+$')
);

alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists avatar_url text;
alter table public.profiles add column if not exists bio text;
alter table public.profiles add column if not exists date_of_birth date;
alter table public.profiles add column if not exists is_moderator boolean not null default false;
alter table public.profiles add column if not exists created_at timestamptz not null default now();
alter table public.profiles add column if not exists updated_at timestamptz not null default now();

create unique index if not exists profiles_username_lower_key on public.profiles (lower(username));

create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references public.profiles(id) on delete cascade,
  caption text,
  media_urls text[] not null,
  viewer_min_age smallint not null default 18,
  status public.post_status not null default 'published',
  moderation_note text,
  moderated_at timestamptz,
  moderated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint posts_caption_length check (caption is null or char_length(caption) <= 2200),
  constraint posts_media_count check (cardinality(media_urls) between 1 and 5),
  constraint posts_media_no_blank_urls check (
    array_position(media_urls, '') is null and array_position(media_urls, null) is null
  ),
  constraint posts_viewer_min_age check (viewer_min_age between 18 and 100)
);

alter table public.posts add column if not exists caption text;
alter table public.posts add column if not exists media_urls text[];
alter table public.posts add column if not exists viewer_min_age smallint not null default 18;
alter table public.posts add column if not exists status public.post_status not null default 'published';
alter table public.posts add column if not exists moderation_note text;
alter table public.posts add column if not exists moderated_at timestamptz;
alter table public.posts add column if not exists moderated_by uuid references public.profiles(id) on delete set null;
alter table public.posts add column if not exists created_at timestamptz not null default now();
alter table public.posts add column if not exists updated_at timestamptz not null default now();

create index if not exists posts_visible_feed_idx
  on public.posts (status, viewer_min_age, created_at desc);
create index if not exists posts_author_idx on public.posts (author_id, created_at desc);

create table if not exists public.ratings (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  score smallint not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ratings_score_range check (score between 1 and 5),
  constraint ratings_one_per_user_per_post unique (post_id, user_id)
);

create index if not exists ratings_post_idx on public.ratings (post_id);

create table if not exists public.comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete cascade,
  body text not null,
  is_hidden boolean not null default false,
  moderation_note text,
  moderated_at timestamptz,
  moderated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint comments_body_length check (char_length(btrim(body)) between 1 and 1000)
);

create index if not exists comments_post_created_idx on public.comments (post_id, created_at);

create table if not exists public.bookmarks (
  user_id uuid not null references public.profiles(id) on delete cascade,
  post_id uuid not null references public.posts(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, post_id)
);

create table if not exists public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  post_id uuid references public.posts(id) on delete cascade,
  comment_id uuid references public.comments(id) on delete cascade,
  reason public.report_reason not null,
  details text,
  resolved_at timestamptz,
  resolved_by uuid references public.profiles(id) on delete set null,
  resolution_note text,
  created_at timestamptz not null default now(),
  constraint reports_target_check check (
    (post_id is not null and comment_id is null) or (post_id is null and comment_id is not null)
  ),
  constraint reports_details_length check (details is null or char_length(details) <= 1000)
);

create index if not exists reports_open_idx on public.reports (resolved_at, created_at desc);

create or replace function public.is_adult(birth_date date)
returns boolean
language sql
stable
set search_path = public
as $$
  select birth_date is not null and birth_date <= (current_date - interval '18 years')::date;
$$;

create or replace function public.current_user_is_adult()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and public.is_adult(date_of_birth)
  );
$$;

create or replace function public.current_user_is_moderator()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and is_moderator
  );
$$;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.enforce_profile_gate()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if not public.is_adult(new.date_of_birth) then
    raise exception 'Dashing accounts require a verified age of 18 or older'
      using errcode = 'check_violation';
  end if;

  -- Clients cannot grant themselves moderator privileges. A database owner or
  -- service-role administrative process may assign the role outside client RLS.
  if tg_op = 'UPDATE' and new.is_moderator is distinct from old.is_moderator
     and current_user not in ('postgres', 'supabase_admin', 'service_role') then
    raise exception 'Moderator role may only be changed by an administrator'
      using errcode = 'insufficient_privilege';
  end if;

  return new;
end;
$$;

create or replace function public.enforce_post_author_gate()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.profiles
    where id = new.author_id and public.is_adult(date_of_birth)
  ) then
    raise exception 'Only profiles age 18 or older may create posts'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create or replace function public.enforce_interaction_target()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  required_age smallint;
  target_status public.post_status;
begin
  select viewer_min_age, status into required_age, target_status
  from public.posts where id = new.post_id;

  if not found or target_status <> 'published' then
    raise exception 'Interactions require a published post' using errcode = 'check_violation';
  end if;

  if not exists (
    select 1 from public.profiles
    where id = auth.uid()
      and public.is_adult(date_of_birth)
      and date_of_birth <= (current_date - make_interval(years => required_age))::date
  ) then
    raise exception 'You do not meet this post''s viewer-age requirement' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at before update on public.profiles
for each row execute function public.set_updated_at();

drop trigger if exists profiles_enforce_age_gate on public.profiles;
create trigger profiles_enforce_age_gate before insert or update on public.profiles
for each row execute function public.enforce_profile_gate();

drop trigger if exists posts_set_updated_at on public.posts;
create trigger posts_set_updated_at before update on public.posts
for each row execute function public.set_updated_at();

drop trigger if exists posts_enforce_author_gate on public.posts;
create trigger posts_enforce_author_gate before insert or update of author_id on public.posts
for each row execute function public.enforce_post_author_gate();

drop trigger if exists ratings_set_updated_at on public.ratings;
create trigger ratings_set_updated_at before update on public.ratings
for each row execute function public.set_updated_at();

drop trigger if exists ratings_enforce_target on public.ratings;
create trigger ratings_enforce_target before insert or update of post_id on public.ratings
for each row execute function public.enforce_interaction_target();

drop trigger if exists comments_set_updated_at on public.comments;
create trigger comments_set_updated_at before update on public.comments
for each row execute function public.set_updated_at();

drop trigger if exists comments_enforce_target on public.comments;
create trigger comments_enforce_target before insert or update of post_id on public.comments
for each row execute function public.enforce_interaction_target();

drop trigger if exists bookmarks_enforce_target on public.bookmarks;
create trigger bookmarks_enforce_target before insert or update of post_id on public.bookmarks
for each row execute function public.enforce_interaction_target();

alter table public.profiles enable row level security;
alter table public.posts enable row level security;
alter table public.ratings enable row level security;
alter table public.comments enable row level security;
alter table public.bookmarks enable row level security;
alter table public.reports enable row level security;

-- Full profiles contain date_of_birth and moderation state. Keep them private;
-- expose only the safe public fields through profile_cards below.
drop policy if exists "Users and moderators can view profiles" on public.profiles;
drop policy if exists "Adult users can view profiles" on public.profiles;
create policy "Users and moderators can view profiles" on public.profiles for select to authenticated
using (id = auth.uid() or public.current_user_is_moderator());

drop policy if exists "Users can create their own adult profile" on public.profiles;
create policy "Users can create their own adult profile" on public.profiles for insert to authenticated
with check (id = auth.uid() and public.is_adult(date_of_birth) and not is_moderator);

drop policy if exists "Users can update their own profile" on public.profiles;
create policy "Users can update their own profile" on public.profiles for update to authenticated
using (id = auth.uid())
with check (id = auth.uid() and public.is_adult(date_of_birth) and not is_moderator);

drop policy if exists "Authors and moderators can view posts" on public.posts;
create policy "Authors and moderators can view posts" on public.posts for select to authenticated
using (
  author_id = auth.uid()
  or public.current_user_is_moderator()
  or (
    status = 'published'
    and public.current_user_is_adult()
    and exists (
      select 1 from public.profiles viewer
      where viewer.id = auth.uid()
        and viewer.date_of_birth <= (current_date - make_interval(years => viewer_min_age))::date
    )
  )
);

drop policy if exists "Adult users can create their own posts" on public.posts;
create policy "Adult users can create their own posts" on public.posts for insert to authenticated
with check (
  author_id = auth.uid()
  and public.current_user_is_adult()
  and viewer_min_age between 18 and 100
  and cardinality(media_urls) between 1 and 5
  and status in ('draft', 'published')
  and moderated_by is null and moderated_at is null and moderation_note is null
);

drop policy if exists "Authors can update their unmoderated posts" on public.posts;
create policy "Authors can update their unmoderated posts" on public.posts for update to authenticated
using (author_id = auth.uid())
with check (
  author_id = auth.uid()
  and public.current_user_is_adult()
  and viewer_min_age between 18 and 100
  and cardinality(media_urls) between 1 and 5
  and status in ('draft', 'published')
  and moderated_by is null and moderated_at is null and moderation_note is null
);

drop policy if exists "Authors can delete their posts" on public.posts;
create policy "Authors can delete their posts" on public.posts for delete to authenticated
using (author_id = auth.uid());

drop policy if exists "Moderators can manage posts" on public.posts;
create policy "Moderators can manage posts" on public.posts for all to authenticated
using (public.current_user_is_moderator())
with check (public.current_user_is_moderator());

drop policy if exists "Eligible adult users can view ratings" on public.ratings;
create policy "Eligible adult users can view ratings" on public.ratings for select to authenticated
using (exists (select 1 from public.posts where id = post_id));

drop policy if exists "Users can create their own ratings" on public.ratings;
create policy "Users can create their own ratings" on public.ratings for insert to authenticated
with check (user_id = auth.uid() and public.current_user_is_adult());

drop policy if exists "Users can update their own ratings" on public.ratings;
create policy "Users can update their own ratings" on public.ratings for update to authenticated
using (user_id = auth.uid()) with check (user_id = auth.uid() and public.current_user_is_adult());

drop policy if exists "Users can delete their own ratings" on public.ratings;
create policy "Users can delete their own ratings" on public.ratings for delete to authenticated
using (user_id = auth.uid());

drop policy if exists "Eligible adult users can view comments" on public.comments;
create policy "Eligible adult users can view comments" on public.comments for select to authenticated
using ((not is_hidden and exists (select 1 from public.posts where id = post_id)) or author_id = auth.uid() or public.current_user_is_moderator());

drop policy if exists "Users can write their own comments" on public.comments;
create policy "Users can write their own comments" on public.comments for insert to authenticated
with check (author_id = auth.uid() and public.current_user_is_adult() and not is_hidden and moderated_by is null and moderated_at is null);

drop policy if exists "Authors can update their own comments" on public.comments;
create policy "Authors can update their own comments" on public.comments for update to authenticated
using (author_id = auth.uid())
with check (author_id = auth.uid() and not is_hidden and moderated_by is null and moderated_at is null);

drop policy if exists "Authors can delete their own comments" on public.comments;
create policy "Authors can delete their own comments" on public.comments for delete to authenticated
using (author_id = auth.uid());

drop policy if exists "Moderators can manage comments" on public.comments;
create policy "Moderators can manage comments" on public.comments for all to authenticated
using (public.current_user_is_moderator()) with check (public.current_user_is_moderator());

drop policy if exists "Users can manage only their own bookmarks" on public.bookmarks;
create policy "Users can manage only their own bookmarks" on public.bookmarks for all to authenticated
using (user_id = auth.uid()) with check (user_id = auth.uid() and public.current_user_is_adult());

drop policy if exists "Users can file their own reports" on public.reports;
create policy "Users can file their own reports" on public.reports for insert to authenticated
with check (reporter_id = auth.uid() and public.current_user_is_adult() and resolved_at is null and resolved_by is null);

drop policy if exists "Reporters and moderators can view reports" on public.reports;
create policy "Reporters and moderators can view reports" on public.reports for select to authenticated
using (reporter_id = auth.uid() or public.current_user_is_moderator());

drop policy if exists "Moderators can resolve reports" on public.reports;
create policy "Moderators can resolve reports" on public.reports for update to authenticated
using (public.current_user_is_moderator()) with check (public.current_user_is_moderator());

create or replace view public.profile_cards
with (security_barrier = true)
as
select id, username, display_name, avatar_url, bio, created_at
from public.profiles
where public.current_user_is_adult();

revoke all on public.profile_cards from public, anon;
grant select on public.profile_cards to authenticated;

create materialized view if not exists public.post_leaderboard as
select
  p.id as post_id,
  p.author_id,
  p.viewer_min_age,
  p.created_at,
  count(r.id)::integer as rating_count,
  coalesce(avg(r.score), 0)::numeric(4, 2) as average_rating,
  coalesce(sum(r.score), 0)::integer as rating_total
from public.posts p
left join public.ratings r on r.post_id = p.id
where p.status = 'published'
group by p.id, p.author_id, p.viewer_min_age, p.created_at;

create unique index if not exists post_leaderboard_post_id_key on public.post_leaderboard (post_id);
create index if not exists post_leaderboard_rank_idx
  on public.post_leaderboard (average_rating desc, rating_count desc, created_at desc);

create or replace function public.refresh_post_leaderboard()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.current_user_is_moderator() then
    raise exception 'Only moderators may refresh the leaderboard' using errcode = 'insufficient_privilege';
  end if;
  refresh materialized view public.post_leaderboard;
end;
$$;

create or replace function public.get_post_leaderboard(result_limit integer default 50)
returns table (
  post_id uuid,
  author_id uuid,
  viewer_min_age smallint,
  created_at timestamptz,
  rating_count integer,
  average_rating numeric,
  rating_total integer
)
language sql
stable
security definer
set search_path = public
as $$
  select l.post_id, l.author_id, l.viewer_min_age, l.created_at,
         l.rating_count, l.average_rating, l.rating_total
  from public.post_leaderboard l
  join public.profiles viewer on viewer.id = auth.uid()
  where public.is_adult(viewer.date_of_birth)
    and viewer.date_of_birth <= (current_date - make_interval(years => l.viewer_min_age))::date
  order by l.average_rating desc, l.rating_count desc, l.created_at desc
  limit greatest(1, least(coalesce(result_limit, 50), 100));
$$;

revoke all on public.post_leaderboard from public, anon, authenticated;
revoke all on function public.refresh_post_leaderboard() from public, anon, authenticated;
revoke all on function public.get_post_leaderboard(integer) from public, anon;
grant execute on function public.get_post_leaderboard(integer) to authenticated;

-- Use a trusted server-side scheduler or a moderator-only dashboard action to
-- call select public.refresh_post_leaderboard(); after rating changes. The
-- materialized view deliberately has no client write access.
