begin;

revoke execute on function public.get_post_leaderboard(integer) from anon;
grant execute on function public.get_post_leaderboard(integer) to authenticated;

revoke execute on function public.refresh_post_leaderboard() from anon;

commit;
