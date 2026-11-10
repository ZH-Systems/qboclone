-- GitHub Actions only: lightweight Supabase Auth compatibility schema.
-- Never apply this bootstrap to a real Supabase database.
create role authenticated nologin;
create role anon nologin;
create role service_role nologin bypassrls;
create schema extensions;
create extension if not exists pgcrypto with schema extensions;
create schema auth;
create table auth.users(
  id uuid primary key,
  email text,
  email_confirmed_at timestamptz,
  role text,
  aud text,
  created_at timestamptz,
  updated_at timestamptz
);
create function auth.uid() returns uuid
 language sql stable security definer set search_path=''
as $$
 select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid
$$;

grant usage on schema auth to authenticated;
grant execute on function auth.uid() to authenticated;
