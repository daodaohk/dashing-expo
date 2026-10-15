-- Dashing — security hardening and age-ceiling redesign (2026-10-15)
--
-- Fixes, in order:
--   1. Signed-in users could not read posts at all: the RLS helper
--      private.current_user_is_adult() was never granted to `authenticated`.
--   2. Clients could publish posts directly, skipping moderation.
--   3. Authors could undo a moderator's removal by editing their post.
--   4. Every rating/comment/bookmark insert failed: the interaction trigger
--      still read the dropped posts.viewer_min_age column.
--   5. profile_cards returned only the caller's own card (security_invoker over
--      an own-row-only policy), so other authors were invisible.
--   6. Users could change their own date of birth, defeating age rules.
--   7. Any rater's identity was readable, and averages were computed on the
--      client from raw rows. Ratings are now private; counts live on posts.
--   8. The leaderboard was a materialised view nobody could refresh (its
--      refresh function called a function that no longer exists).
--   9. Authors and moderators could not read media of unpublished posts.
--  10. `anon` held full table privileges (RLS still blocked it; removed as
--      defence in depth — Dashing has no signed-out reads).
--
-- Age-ceiling redesign (product decision, 2026-10-15):
--   * posts.max_viewer_age / profiles.default_max_viewer_age now mean the
--     OLDEST age, inclusive, that may see the post. "Under 25" is stored as 24.
--   * A ceiling may not be below the author's own age. A post whose author has
--     since grown older than its ceiling is treated as having ceiling = the
--     author's current age.
--   * Date of birth is locked after onboarding; only an administrator (SQL /
--     dashboard / service role) can correct it.
--   * The leaderboard includes restricted posts, filtered per viewer.

-- ===========================================================================
-- Moderation workflow: posts are submitted for review ('in_review' is added
-- by the previous migration)
-- ===========================================================================

create table if not exists private.app_settings (
  id boolean primary key default true check (id),
  require_post_review boolean not null default true
);
insert into private.app_settings (id) values (true) on conflict (id) do nothing;
comment on table private.app_settings is
  'Single-row app configuration. require_post_review=false auto-publishes posts submitted for review.';
revoke all on private.app_settings from public, anon, authenticated;

create or replace function private.post_review_required()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select s.require_post_review from private.app_settings s where s.id), true);
$$;

alter table public.posts alter column status set default 'draft';

-- ===========================================================================
-- Helpers (private schema; not exposed through the API)
-- ===========================================================================

create or replace function private.age_on(birth_date date, on_date date default current_date)
returns integer
language sql
immutable
set search_path = ''
as $$
  select date_part('year', age(on_date, birth_date))::integer;
$$;

create or replace function private.profile_age(profile_id uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select private.age_on(p.date_of_birth) from public.profiles p where p.id = profile_id;
$$;

-- The single visibility rule for a post. Used by RLS on posts, the
-- interaction trigger, storage reads and the leaderboard.
create or replace function private.can_view_post(
  p_author_id uuid,
  p_status public.post_status,
  p_max_viewer_age smallint
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    p_author_id = auth.uid()
    or private.current_user_is_moderator()
    or (
      p_status = 'published'
      and exists (
        select 1
        from public.profiles viewer
        where viewer.id = auth.uid()
          and public.is_adult(viewer.date_of_birth)
          and (
            p_max_viewer_age is null
            or private.age_on(viewer.date_of_birth)
               <= greatest(p_max_viewer_age, coalesce(private.profile_age(p_author_id), p_max_viewer_age))
          )
      )
    );
$$;

revoke all on function private.age_on(date, date) from public, anon;
revoke all on function private.profile_age(uuid) from public, anon;
revoke all on function private.can_view_post(uuid, public.post_status, smallint) from public, anon;
grant execute on function private.age_on(date, date) to authenticated, service_role;
grant execute on function private.profile_age(uuid) to authenticated, service_role;
grant execute on function private.can_view_post(uuid, public.post_status, smallint) to authenticated, service_role;

-- Fix 1: policies call this as the signed-in user.
grant execute on function private.current_user_is_adult() to authenticated;

-- ===========================================================================
-- Profiles: DOB lock, ceiling >= own age, public cards
-- ===========================================================================

create or replace function public.enforce_profile_gate()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  is_client boolean := current_user in ('authenticated', 'anon');
begin
  if not public.is_adult(new.date_of_birth) then
    raise exception 'Dashing accounts require a verified age of 18 or older'
      using errcode = 'check_violation';
  end if;

  if tg_op = 'UPDATE' and is_client then
    if new.is_moderator is distinct from old.is_moderator then
      raise exception 'Moderator role may only be changed by an administrator'
        using errcode = 'insufficient_privilege';
    end if;
    if new.date_of_birth is distinct from old.date_of_birth then
      raise exception 'Date of birth cannot be changed in the app. Contact support to correct it.'
        using errcode = 'insufficient_privilege';
    end if;
  end if;

  if new.default_max_viewer_age is not null
     and new.default_max_viewer_age < private.age_on(new.date_of_birth) then
    raise exception 'Your visibility limit cannot be younger than your own age'
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

comment on column public.profiles.default_max_viewer_age is
  'Default oldest viewer age (inclusive) for new posts; must be >= the user''s own age. NULL = everyone.';

-- Fix 5: public author cards via a definer function exposing only public
-- columns, instead of a view over an own-row-only table.
drop view if exists public.profile_cards;

create or replace function public.get_profile_cards(profile_ids uuid[])
returns table (
  id uuid,
  username text,
  display_name text,
  avatar_url text,
  bio text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id, p.username, p.display_name, p.avatar_url, p.bio, p.created_at
  from public.profiles p
  where p.id = any (profile_ids)
    and private.current_user_is_adult()
  limit 200;
$$;

revoke all on function public.get_profile_cards(uuid[]) from public, anon;
grant execute on function public.get_profile_cards(uuid[]) to authenticated;

-- ===========================================================================
-- Posts: rating counters, write guard, policies
-- ===========================================================================

alter table public.posts
  add column if not exists rating_count integer not null default 0,
  add column if not exists rating_sum integer not null default 0;

alter table public.posts
  add constraint posts_rating_counters_valid
  check (rating_count >= 0 and rating_sum >= rating_count and rating_sum <= rating_count * 5);

comment on column public.posts.max_viewer_age is
  'Oldest viewer age (inclusive) allowed to see this post; must be >= the author''s age when set. NULL = everyone.';
comment on column public.posts.rating_count is 'Maintained by trigger from public.ratings. Read-only to clients.';
comment on column public.posts.rating_sum is 'Maintained by trigger from public.ratings. Read-only to clients.';

create index if not exists posts_feed_idx on public.posts (status, created_at desc, id desc);

-- Fixes 2 and 3, plus the ceiling rule. Runs as the caller so current_user
-- tells client requests apart from trusted (definer/admin) writes.
create or replace function private.guard_post_write()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  is_client boolean := current_user in ('authenticated', 'anon');
  is_mod boolean := is_client and private.current_user_is_moderator();
  author_age integer;
begin
  if not is_client then
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.rating_count := 0;
    new.rating_sum := 0;
  elsif new.rating_count is distinct from old.rating_count
     or new.rating_sum is distinct from old.rating_sum then
    raise exception 'Rating totals are maintained by the server' using errcode = 'insufficient_privilege';
  end if;

  if is_mod then
    if tg_op = 'UPDATE' and new.status is distinct from old.status then
      new.moderated_by := auth.uid();
      new.moderated_at := now();
    end if;
  else
    if tg_op = 'UPDATE' and (
         new.moderated_by is distinct from old.moderated_by
      or new.moderated_at is distinct from old.moderated_at
      or new.moderation_note is distinct from old.moderation_note) then
      raise exception 'Moderation fields are set by moderators only' using errcode = 'insufficient_privilege';
    end if;
    if tg_op = 'INSERT' and (new.moderated_by is not null or new.moderated_at is not null or new.moderation_note is not null) then
      raise exception 'Moderation fields are set by moderators only' using errcode = 'insufficient_privilege';
    end if;

    -- Editing a live post's content sends it back through review.
    if tg_op = 'UPDATE' and old.status = 'published' and new.status = 'published' and (
         new.caption is distinct from old.caption
      or new.media_urls is distinct from old.media_urls
      or new.max_viewer_age is distinct from old.max_viewer_age) then
      new.status := 'in_review';
    end if;

    if not (new.status = 'draft' or new.status = 'in_review'
            or (tg_op = 'UPDATE' and new.status = 'published' and old.status = 'published')) then
      raise exception 'Posts are published by review, not directly' using errcode = 'insufficient_privilege';
    end if;

    if new.status = 'in_review'
       and not private.post_review_required() then
      new.status := 'published';
    end if;
  end if;

  if new.max_viewer_age is not null
     and (tg_op = 'INSERT' or new.max_viewer_age is distinct from old.max_viewer_age) then
    author_age := private.profile_age(new.author_id);
    if author_age is not null and new.max_viewer_age < author_age then
      raise exception 'A post''s viewer age limit cannot be younger than its author'
        using errcode = 'check_violation';
    end if;
  end if;

  return new;
end;
$$;

revoke all on function private.post_review_required() from public, anon;
grant execute on function private.post_review_required() to authenticated, service_role;
revoke all on function private.guard_post_write() from public, anon;
grant execute on function private.guard_post_write() to authenticated, service_role;

drop trigger if exists posts_guard_write on public.posts;
create trigger posts_guard_write
before insert or update on public.posts
for each row execute function private.guard_post_write();

drop policy if exists "Authors and moderators can view posts" on public.posts;
create policy "Visible posts" on public.posts for select to authenticated
using (private.can_view_post(author_id, status, max_viewer_age));

drop policy if exists "Adult users can create their own posts" on public.posts;
create policy "Adults create their own posts" on public.posts for insert to authenticated
with check (author_id = auth.uid() and private.current_user_is_adult());

drop policy if exists "Authors can update their unmoderated posts" on public.posts;
create policy "Authors edit their own live or pending posts" on public.posts for update to authenticated
using (author_id = auth.uid() and status in ('draft', 'in_review', 'published'))
with check (author_id = auth.uid() and private.current_user_is_adult());

drop policy if exists "Authors can delete their posts" on public.posts;
create policy "Authors delete their own unmoderated posts" on public.posts for delete to authenticated
using (author_id = auth.uid() and status in ('draft', 'in_review', 'published'));

-- "Moderators can manage posts" (FOR ALL) is kept as-is.

-- ===========================================================================
-- Interactions (fix 4)
-- ===========================================================================

create or replace function private.enforce_interaction_target()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target record;
begin
  select p.author_id, p.status, p.max_viewer_age into target
  from public.posts p where p.id = new.post_id;

  if not found or target.status <> 'published' then
    raise exception 'Interactions require a published post' using errcode = 'check_violation';
  end if;

  if not private.can_view_post(target.author_id, target.status, target.max_viewer_age) then
    raise exception 'This post is not available to you' using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

-- ===========================================================================
-- Ratings (fix 7): private rows, server-maintained totals
-- ===========================================================================

create or replace function private.sync_post_rating_totals()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    update public.posts
       set rating_count = rating_count - 1, rating_sum = rating_sum - old.score
     where id = old.post_id;
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    update public.posts
       set rating_count = rating_count + 1, rating_sum = rating_sum + new.score
     where id = new.post_id;
  end if;
  return null;
end;
$$;

revoke all on function private.sync_post_rating_totals() from public, anon, authenticated;

drop trigger if exists ratings_sync_totals on public.ratings;
create trigger ratings_sync_totals
after insert or update of score, post_id or delete on public.ratings
for each row execute function private.sync_post_rating_totals();

-- Backfill (no-op on an empty table; correct on any data).
update public.posts p
   set rating_count = coalesce(r.n, 0), rating_sum = coalesce(r.s, 0)
  from (select post_id, count(*)::int n, sum(score)::int s from public.ratings group by post_id) r
 where r.post_id = p.id;

drop policy if exists "Eligible adult users can view ratings" on public.ratings;
create policy "Users see their own ratings" on public.ratings for select to authenticated
using (user_id = auth.uid() or private.current_user_is_moderator());

-- ===========================================================================
-- Leaderboard (fix 8): live query, Bayesian-ranked
-- ===========================================================================

drop function if exists public.get_post_leaderboard(integer);
drop function if exists public.refresh_post_leaderboard();
drop materialized view if exists public.post_leaderboard;

create or replace function public.get_post_leaderboard(
  result_limit integer default 50,
  since timestamptz default null
)
returns table (
  post_id uuid,
  author_id uuid,
  created_at timestamptz,
  rating_count integer,
  average_rating numeric,
  rank_score numeric
)
language sql
stable
security definer
set search_path = ''
as $$
  with visible as (
    select p.id, p.author_id, p.created_at, p.rating_count, p.rating_sum
    from public.posts p
    where p.status = 'published'
      and p.rating_count > 0
      and (since is null or p.created_at >= since)
      and private.can_view_post(p.author_id, p.status, p.max_viewer_age)
  ),
  prior as (
    -- Bayesian prior: every post starts with 5 virtual ratings at the
    -- site-wide mean, so a single 5-spark rating can't top the board.
    select 5::numeric as weight,
           coalesce(sum(rating_sum)::numeric / nullif(sum(rating_count), 0), 3) as mean
    from visible
  )
  select v.id, v.author_id, v.created_at, v.rating_count,
         round(v.rating_sum::numeric / v.rating_count, 2),
         round((prior.weight * prior.mean + v.rating_sum) / (prior.weight + v.rating_count), 4)
  from visible v cross join prior
  where private.current_user_is_adult()
  order by 6 desc, v.rating_count desc, v.created_at desc
  limit greatest(1, least(coalesce(result_limit, 50), 100));
$$;

revoke all on function public.get_post_leaderboard(integer, timestamptz) from public, anon;
grant execute on function public.get_post_leaderboard(integer, timestamptz) to authenticated;

-- ===========================================================================
-- Storage (fix 9)
-- ===========================================================================

drop policy if exists "Adults read media of visible posts" on storage.objects;
create policy "Read media of visible posts" on storage.objects for select to authenticated
using (
  bucket_id = 'post-media'
  and (
    (storage.foldername(name))[1] = auth.uid()::text
    or private.current_user_is_moderator()
    or exists (
      select 1 from public.posts p
      where p.media_urls @> array[objects.name]
        and private.can_view_post(p.author_id, p.status, p.max_viewer_age)
    )
  )
);

-- ===========================================================================
-- Privileges (fix 10)
-- ===========================================================================

revoke all on public.profiles, public.posts, public.ratings, public.comments,
              public.bookmarks, public.reports from anon;
revoke execute on function public.is_adult(date) from public, anon;
grant execute on function public.is_adult(date) to authenticated, service_role;
grant execute on all functions in schema private to service_role;
