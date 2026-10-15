-- Tighten leaderboard access: reads must go through the age-filtered function
begin;

revoke select on public.post_leaderboard from anon, authenticated;

revoke all on function public.get_post_leaderboard(integer) from public;
grant execute on function public.get_post_leaderboard(integer) to authenticated;

revoke all on function public.refresh_post_leaderboard() from public;
grant execute on function public.refresh_post_leaderboard() to authenticated;

commit;
