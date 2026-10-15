#!/usr/bin/env bash
# Applies every migration to a fresh scratch database on a plain local
# Postgres (with supabase_stub.sql standing in for Supabase), then runs the
# security tests.
#
#   PGHOST=/tmp PGPORT=5432 PGUSER=postgres supabase/tests/run_local.sh
#
# Requires a superuser connection. Creates and drops a database named
# dashing_test.
set -euo pipefail
cd "$(dirname "$0")/../.."

DB=dashing_test
PSQL=(psql -v ON_ERROR_STOP=1 -q -X)

"${PSQL[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB"
"${PSQL[@]}" -d postgres -c "do \$\$ begin
  if not exists (select from pg_roles where rolname = 'authenticated') then
    create role anon nologin noinherit;
    create role authenticated nologin noinherit;
    create role service_role nologin noinherit bypassrls;
    create role supabase_admin nologin;
  end if; end \$\$;"

sed '/^create role /d' supabase/tests/supabase_stub.sql | "${PSQL[@]}" -d "$DB"

for f in supabase/migrations/*.sql; do
  echo "applying $(basename "$f")"
  "${PSQL[@]}" -d "$DB" -1 -f "$f"
done

"${PSQL[@]}" -d "$DB" -f supabase/tests/security_tests.sql
