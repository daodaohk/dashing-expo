-- Dashing private profile location
--
-- Prerequisite: the Dashing backend foundation migration has already created
-- public.profiles, its age gate, and its row-level-security policies.
--
-- Country and city are private profile fields. This migration deliberately
-- does not add date_of_birth, country, or city to public.profile_cards.

begin;

alter table public.profiles
  add column if not exists country text,
  add column if not exists city text;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.profiles'::regclass
      and conname = 'profiles_country_format'
  ) then
    alter table public.profiles
      add constraint profiles_country_format
      check (
        country is null
        or (
          country = btrim(country)
          and char_length(country) between 2 and 100
        )
      );
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.profiles'::regclass
      and conname = 'profiles_city_format'
  ) then
    alter table public.profiles
      add constraint profiles_city_format
      check (
        city is null
        or (
          city = btrim(city)
          and char_length(city) between 1 and 100
        )
      );
  end if;
end;
$$;

-- Existing profiles may predate location collection, so the columns remain
-- nullable at the table level. The client-facing insert/update policies make
-- country and city mandatory for every onboarding write without weakening the
-- foundation's ownership, adult-age, or moderator checks.
alter table public.profiles enable row level security;

drop policy if exists "Users can create their own adult profile" on public.profiles;
create policy "Users can create their own adult profile" on public.profiles
for insert to authenticated
with check (
  id = auth.uid()
  and public.is_adult(date_of_birth)
  and not is_moderator
  and country is not null
  and city is not null
);

drop policy if exists "Users can update their own profile" on public.profiles;
create policy "Users can update their own profile" on public.profiles
for update to authenticated
using (id = auth.uid())
with check (
  id = auth.uid()
  and public.is_adult(date_of_birth)
  and not is_moderator
  and country is not null
  and city is not null
);

-- Do not recreate or widen profile_cards. Its explicit foundation projection
-- excludes date_of_birth, country, and city; security_invoker keeps the view
-- subject to the existing profiles RLS policy.
alter view public.profile_cards set (security_invoker = true);

commit;
