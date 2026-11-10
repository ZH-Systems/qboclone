-- GitHub Actions only: lightweight Supabase Auth compatibility schema.
-- Never apply this bootstrap to a real Supabase database.
create role authenticated nologin;
create role anon nologin;
create schema auth;
create table auth.users(
  id uuid primary key,
  email text,
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
