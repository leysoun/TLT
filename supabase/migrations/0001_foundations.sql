-- ============================================================================
-- 0001_foundations.sql  ·  TPF Platform
-- Enums · profiles · client_records · role-in-JWT pattern · trigger · RLS
-- ----------------------------------------------------------------------------
-- Authz model: the application role lives in auth.users.raw_app_meta_data
-- (-> the JWT's app_metadata) and is read in RLS via current_app_role().
-- We NEVER write an RLS policy on profiles that SELECTs profiles to read the
-- role -> that causes infinite recursion. profiles.role is only a mirror for
-- joins/display; the JWT is the source of truth for access control.
-- ============================================================================

-- ---------- ENUMS -----------------------------------------------------------
create type app_role   as enum ('client','founder','operator','org_admin');
create type archetype  as enum ('performer','controller','escape_artist',
                                 'watcher','diplomat','pacifist');
create type program    as enum ('audit','architect','reset');
create type proof_type  as enum ('internal','behavioural','external');

-- ---------- HELPERS ---------------------------------------------------------
-- Reads the app role from the JWT (no table access -> no recursion).
create or replace function public.current_app_role()
returns text
language sql
stable
as $$
  select coalesce(auth.jwt() -> 'app_metadata' ->> 'role', 'client')
$$;

-- Generic updated_at maintainer.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ---------- PROFILES (1:1 with auth.users) ----------------------------------
create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  role        app_role    not null default 'client',  -- mirror of JWT, display/joins only
  full_name   text,
  language    text        not null default 'en',       -- en | fr | ar
  org_id      uuid,                                     -- FK added in Phase 3 (orgs)
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create trigger trg_profiles_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- ---------- CLIENT_RECORDS (the spine; one per client) ----------------------
create table public.client_records (
  id               uuid primary key default gen_random_uuid(),
  client_id        uuid not null references public.profiles(id) on delete cascade,
  archetype        archetype,             -- null until the Audit completes
  prisoner_pattern text,                  -- personalised 3-5 word name
  key              text,                  -- exact permission phrase
  current_program  program not null default 'audit',
  current_phase    text,                  -- e.g. 'day_1', 'mirror'
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (client_id)
);

create trigger trg_client_records_updated_at
  before update on public.client_records
  for each row execute function public.set_updated_at();

-- ---------- NEW-USER TRIGGER ------------------------------------------------
-- On signup: create the profile (role read from app_metadata), and create a
-- client_records row only for clients. security definer -> bypasses RLS.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role app_role := coalesce(
    (new.raw_app_meta_data ->> 'role')::app_role,
    'client'
  );
begin
  insert into public.profiles (id, role, full_name, language)
  values (
    new.id,
    v_role,
    new.raw_user_meta_data ->> 'full_name',
    coalesce(new.raw_user_meta_data ->> 'language', 'en')
  );

  if v_role = 'client' then
    insert into public.client_records (client_id) values (new.id);
  end if;

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ============================================================================
-- ROW LEVEL SECURITY
-- ============================================================================

-- ---------- PROFILES --------------------------------------------------------
alter table public.profiles enable row level security;

-- own row
create policy profiles_select_own on public.profiles
  for select using (id = auth.uid());

-- founder sees all (role read from JWT, not from this table -> no recursion)
create policy profiles_select_founder on public.profiles
  for select using (public.current_app_role() = 'founder');

-- update own row (role escalation here is harmless: authz reads the JWT, not the table)
create policy profiles_update_own on public.profiles
  for update using (id = auth.uid())
              with check (id = auth.uid());

-- ---------- CLIENT_RECORDS --------------------------------------------------
alter table public.client_records enable row level security;

-- client: own record
create policy client_records_select_own on public.client_records
  for select using (client_id = auth.uid());

create policy client_records_update_own on public.client_records
  for update using (client_id = auth.uid())
              with check (client_id = auth.uid());

-- founder: read + update all (founder console)
create policy client_records_select_founder on public.client_records
  for select using (public.current_app_role() = 'founder');

create policy client_records_update_founder on public.client_records
  for update using (public.current_app_role() = 'founder')
              with check (public.current_app_role() = 'founder');

-- NOTE: inserts into client_records happen via the security-definer trigger and
-- via the service role (edge functions). No INSERT policy for end users by design.

-- ============================================================================
-- VERIFICATION (run AFTER push, before any UI — see notes below)
-- ============================================================================
-- 1) Confirm the trigger creates rows:
--    Create a test user in the dashboard (Authentication -> Add user) with
--    App Metadata: { "role": "client" }. Then:
--      select p.id, p.role, c.id as client_record
--      from public.profiles p
--      left join public.client_records c on c.client_id = p.id;
--    Expect: profile role='client' AND a client_records row exists.
--
-- 2) Create a second user with App Metadata { "role": "founder" } -> expect a
--    profile with role='founder' and NO client_records row.
--
-- 3) RLS check with a real client JWT (replace <CLIENT_JWT> / <PROJECT>):
--      curl "https://<PROJECT>.supabase.co/rest/v1/client_records?select=*" \
--        -H "apikey: <ANON_KEY>" -H "Authorization: Bearer <CLIENT_JWT>"
--    Expect: ONLY that client's own row. A founder JWT returns all rows.
-- ============================================================================
