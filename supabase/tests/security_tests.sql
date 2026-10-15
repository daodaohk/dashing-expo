-- Dashing security tests.
--
-- Run against a scratch database that has supabase_stub.sql and every
-- migration applied (see run_local.sh). Each check prints PASS/FAIL; the
-- script ends by raising an error if anything failed.
--
-- Cast (ages are computed from today's date):
--   alice 24, bob 40, carol 20, dave 25, mo 30 (moderator)

\set ON_ERROR_STOP 1
\set QUIET 1
\o /dev/null

create schema tests;
grant usage on schema tests to authenticated, anon;
create table tests.results (n serial, label text, ok boolean);
grant all on tests.results to authenticated, anon;
grant usage on sequence tests.results_n_seq to authenticated, anon;

create function tests.check(label text, ok boolean) returns void language plpgsql as $$
begin
  insert into tests.results (label, ok) values (label, coalesce(ok, false));
  raise notice '% %', case when coalesce(ok, false) then 'PASS' else 'FAIL' end, label;
end $$;

-- Runs sql; passes only if it raises an error.
create function tests.fails(label text, sql text) returns void language plpgsql as $$
begin
  begin
    execute sql;
  exception when others then
    perform tests.check(label || '  [' || sqlerrm || ']', true);
    return;
  end;
  perform tests.check(label || '  [no error raised]', false);
end $$;

-- Runs sql; passes only if it does not raise.
create function tests.works(label text, sql text) returns void language plpgsql as $$
begin
  begin
    execute sql;
  exception when others then
    perform tests.check(label || '  [' || sqlerrm || ']', false);
    return;
  end;
  perform tests.check(label, true);
end $$;

grant execute on all functions in schema tests to authenticated, anon;

create function tests.login(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, false);
$$;
grant execute on function tests.login(uuid) to authenticated, anon;

-- ---------------------------------------------------------------------------
-- Fixtures (as admin)
-- ---------------------------------------------------------------------------

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000000a1'), ('00000000-0000-0000-0000-0000000000b1'),
  ('00000000-0000-0000-0000-0000000000c1'), ('00000000-0000-0000-0000-0000000000d1'),
  ('00000000-0000-0000-0000-0000000000e1');

insert into public.profiles (id, username, date_of_birth, country, city, is_moderator) values
  ('00000000-0000-0000-0000-0000000000a1', 'alice', current_date - interval '24 years' - interval '30 days', 'PT', 'Lisbon', false),
  ('00000000-0000-0000-0000-0000000000b1', 'bob',   current_date - interval '40 years' - interval '30 days', 'GB', 'London', false),
  ('00000000-0000-0000-0000-0000000000c1', 'carol', current_date - interval '20 years' - interval '30 days', 'KR', 'Seoul', false),
  ('00000000-0000-0000-0000-0000000000d1', 'dave',  current_date - interval '25 years' - interval '30 days', 'MX', 'CDMX', false),
  ('00000000-0000-0000-0000-0000000000e1', 'moe',   current_date - interval '30 years' - interval '30 days', 'HK', 'Hong Kong', true);

\set alice '''00000000-0000-0000-0000-0000000000a1'''
\set bob   '''00000000-0000-0000-0000-0000000000b1'''
\set carol '''00000000-0000-0000-0000-0000000000c1'''
\set dave  '''00000000-0000-0000-0000-0000000000d1'''
\set mo    '''00000000-0000-0000-0000-0000000000e1'''

-- ---------------------------------------------------------------------------
-- Alice (24) posts with an "Under 25" ceiling (stored as 24)
-- ---------------------------------------------------------------------------

select tests.login(:alice); set role authenticated;

select tests.works('signed-in user can query posts (was: permission denied)', 'select count(*) from public.posts');
select tests.fails('cannot publish directly, skipping review',
  $q$insert into public.posts (author_id, media_urls, status) values (auth.uid(), array['x/1.jpg'], 'published')$q$);
select tests.fails('cannot set a ceiling younger than yourself (24 -> Under 21)',
  $q$insert into public.posts (author_id, media_urls, status, max_viewer_age) values (auth.uid(), array['x/1.jpg'], 'in_review', 20)$q$);
select tests.fails('cannot post as someone else',
  $q$insert into public.posts (author_id, media_urls, status) values ('00000000-0000-0000-0000-0000000000b1', array['x/1.jpg'], 'in_review')$q$);
select tests.fails('cannot pre-fill moderation fields',
  $q$insert into public.posts (author_id, media_urls, status, moderation_note) values (auth.uid(), array['x/1.jpg'], 'in_review', 'ok')$q$);
select tests.works('can submit a post with ceiling = own age',
  $q$insert into public.posts (id, author_id, caption, media_urls, status, max_viewer_age, rating_count, rating_sum)
     values ('11111111-0000-0000-0000-000000000001', auth.uid(), 'Linen weekend', array['00000000-0000-0000-0000-0000000000a1/p1/0.jpg'], 'in_review', 24, 5, 25)$q$);
reset role;
select tests.check('client-supplied rating totals were zeroed on insert',
  (select rating_count = 0 and rating_sum = 0 from public.posts where id = '11111111-0000-0000-0000-000000000001'));

-- Pending post: only author + moderator see it
select tests.login(:carol); set role authenticated;
select tests.check('others cannot see a post in review', (select count(*) = 0 from public.posts));
reset role;
select tests.login(:mo); set role authenticated;
select tests.check('moderator sees the post in review', (select count(*) = 1 from public.posts));
select tests.works('moderator approves the post',
  $q$update public.posts set status = 'published' where id = '11111111-0000-0000-0000-000000000001'$q$);
reset role;
select tests.check('approval records who moderated',
  (select moderated_by = '00000000-0000-0000-0000-0000000000e1' and moderated_at is not null from public.posts where id = '11111111-0000-0000-0000-000000000001'));

-- Ceiling enforcement
select tests.login(:carol); set role authenticated;
select tests.check('carol (20) can see the Under-25 post', (select count(*) = 1 from public.posts));
select tests.works('carol can rate it', $q$insert into public.ratings (post_id, user_id, score) values ('11111111-0000-0000-0000-000000000001', auth.uid(), 5)$q$);
select tests.works('carol can comment (was: broken trigger)', $q$insert into public.comments (post_id, author_id, body) values ('11111111-0000-0000-0000-000000000001', auth.uid(), 'Great texture mix')$q$);
select tests.works('carol can bookmark', $q$insert into public.bookmarks (post_id, user_id) values ('11111111-0000-0000-0000-000000000001', auth.uid())$q$);
select tests.check('rating total kept on the post', (select rating_count = 1 and rating_sum = 5 from public.posts where id = '11111111-0000-0000-0000-000000000001'));
select tests.works('carol can change her rating', $q$update public.ratings set score = 3 where user_id = auth.uid()$q$);
select tests.check('changed rating updates the total', (select rating_count = 1 and rating_sum = 3 from public.posts where id = '11111111-0000-0000-0000-000000000001'));
select tests.fails('carol cannot rate twice', $q$insert into public.ratings (post_id, user_id, score) values ('11111111-0000-0000-0000-000000000001', auth.uid(), 4)$q$);
reset role;

select tests.login(:bob); set role authenticated;
select tests.check('bob (40) cannot see the Under-25 post', (select count(*) = 0 from public.posts));
select tests.fails('bob cannot rate a post he cannot see', $q$insert into public.ratings (post_id, user_id, score) values ('11111111-0000-0000-0000-000000000001', auth.uid(), 1)$q$);
select tests.fails('bob cannot comment on it', $q$insert into public.comments (post_id, author_id, body) values ('11111111-0000-0000-0000-000000000001', auth.uid(), 'hi')$q$);
select tests.check('bob cannot read comments on it', (select count(*) = 0 from public.comments));
reset role;

select tests.login(:dave); set role authenticated;
select tests.check('dave (25) cannot see the Under-25 post', (select count(*) = 0 from public.posts));
reset role;

-- Rating privacy and integrity
select tests.login(:alice); set role authenticated;
select tests.check('author cannot see who rated her post', (select count(*) = 0 from public.ratings));
select tests.check('author sees the rating total on her post', (select rating_count = 1 from public.posts where id = '11111111-0000-0000-0000-000000000001'));
select tests.fails('author cannot edit rating totals', $q$update public.posts set rating_count = 99, rating_sum = 495 where id = '11111111-0000-0000-0000-000000000001'$q$);
select tests.works('author edits caption of a live post', $q$update public.posts set caption = 'Linen, leather' where id = '11111111-0000-0000-0000-000000000001'$q$);
reset role;
select tests.check('editing a live post sends it back to review', (select status = 'in_review' from public.posts where id = '11111111-0000-0000-0000-000000000001'));
update public.posts set status = 'published' where id = '11111111-0000-0000-0000-000000000001';

-- Public author cards
select tests.login(:carol); set role authenticated;
select tests.check('author cards are visible to other adults (was: own card only)',
  (select count(*) = 2 from public.get_profile_cards(array['00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b1']::uuid[])));
select tests.check('others still cannot read private profile rows', (select count(*) = 1 from public.profiles));
reset role;

-- Profile rules
select tests.login(:alice); set role authenticated;
select tests.fails('cannot change own date of birth', $q$update public.profiles set date_of_birth = '2006-01-01' where id = auth.uid()$q$);
select tests.fails('cannot make self a moderator', $q$update public.profiles set is_moderator = true where id = auth.uid()$q$);
select tests.fails('default ceiling cannot be younger than self', $q$update public.profiles set default_max_viewer_age = 20 where id = auth.uid()$q$);
select tests.works('default ceiling at or above own age is allowed', $q$update public.profiles set default_max_viewer_age = 29 where id = auth.uid()$q$);
select tests.works('ordinary profile edits still work', $q$update public.profiles set bio = 'Thoughtful layers' where id = auth.uid()$q$);
reset role;

-- Leaderboard
select tests.login(:bob); set role authenticated;
select tests.works('bob submits an unrestricted post', $q$insert into public.posts (id, author_id, media_urls, status) values ('22222222-0000-0000-0000-000000000002', auth.uid(), array['00000000-0000-0000-0000-0000000000b1/p2/0.jpg'], 'in_review')$q$);
reset role;
update public.posts set status = 'published' where id = '22222222-0000-0000-0000-000000000002';
select tests.login(:dave); set role authenticated;
select tests.works('dave rates bob''s post', $q$insert into public.ratings (post_id, user_id, score) values ('22222222-0000-0000-0000-000000000002', auth.uid(), 4)$q$);
select tests.check('dave''s leaderboard excludes the Under-25 post', (select count(*) = 1 from public.get_post_leaderboard(50)));
reset role;
select tests.login(:carol); set role authenticated;
select tests.check('carol''s leaderboard includes both posts', (select count(*) = 2 from public.get_post_leaderboard(50)));
reset role;

-- Aged-out ceiling: once the author is older than the ceiling, her own age applies
update public.profiles set date_of_birth = current_date - interval '25 years' - interval '1 day'
 where id = '00000000-0000-0000-0000-0000000000a1';
select tests.login(:dave); set role authenticated;
select tests.check('after alice turns 25, dave (25) can see her post', (select count(*) = 1 from public.posts where id = '11111111-0000-0000-0000-000000000001'));
reset role;
select tests.login(:bob); set role authenticated;
select tests.check('bob (40) still cannot', (select count(*) = 0 from public.posts where id = '11111111-0000-0000-0000-000000000001'));
reset role;

-- Storage
insert into storage.buckets (id, name) values ('post-media', 'post-media') on conflict do nothing;
insert into storage.objects (bucket_id, name) values
  ('post-media', '00000000-0000-0000-0000-0000000000a1/p1/0.jpg'),
  ('post-media', '00000000-0000-0000-0000-0000000000a1/draft/0.jpg');
select tests.login(:carol); set role authenticated;
select tests.check('viewer can read media of a post she can see', (select count(*) = 1 from storage.objects));
reset role;
select tests.login(:bob); set role authenticated;
select tests.check('bob cannot read media of the restricted post', (select count(*) = 0 from storage.objects));
select tests.fails('bob cannot upload into alice''s folder', $q$insert into storage.objects (bucket_id, name) values ('post-media', '00000000-0000-0000-0000-0000000000a1/x/0.jpg')$q$);
reset role;
select tests.login(:alice); set role authenticated;
select tests.check('author can read her own unpublished media (was: blocked)', (select count(*) = 2 from storage.objects));
reset role;

-- Moderation cannot be undone by the author
select tests.login(:mo); set role authenticated;
select tests.works('moderator removes the post', $q$update public.posts set status = 'removed', moderation_note = 'test' where id = '11111111-0000-0000-0000-000000000001'$q$);
reset role;
select tests.login(:alice); set role authenticated;
update public.posts set status = 'published', moderated_by = null, moderated_at = null, moderation_note = null
 where id = '11111111-0000-0000-0000-000000000001';
select tests.fails('author cannot delete a removed post', $q$do $d$ begin delete from public.posts where id = '11111111-0000-0000-0000-000000000001'; if not found then raise exception 'not deleted'; end if; end $d$$q$);
reset role;
select tests.check('removed post stays removed after the author tries to restore it (was: restorable)',
  (select status = 'removed' from public.posts where id = '11111111-0000-0000-0000-000000000001'));

-- Review switch
update private.app_settings set require_post_review = false;
select tests.login(:bob); set role authenticated;
select tests.works('with review off, a submission goes live', $q$insert into public.posts (id, author_id, media_urls, status) values ('33333333-0000-0000-0000-000000000003', auth.uid(), array['b/3.jpg'], 'in_review')$q$);
reset role;
select tests.check('...and is published', (select status = 'published' from public.posts where id = '33333333-0000-0000-0000-000000000003'));
update private.app_settings set require_post_review = true;

-- Signed-out access
select set_config('request.jwt.claims', '', false); set role anon;
select tests.fails('signed-out requests cannot read posts', 'select count(*) from public.posts');
select tests.fails('signed-out requests cannot read profiles', 'select count(*) from public.profiles');
select tests.fails('signed-out requests cannot call the leaderboard', 'select * from public.get_post_leaderboard(5)');
reset role;

-- ---------------------------------------------------------------------------
\o
\unset QUIET
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from tests.results;
do $$ begin
  if exists (select 1 from tests.results where not ok) then
    raise exception 'Security tests failed';
  end if;
end $$;
