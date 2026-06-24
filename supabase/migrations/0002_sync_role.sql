-- ============================================================================
-- 0002_sync_role.sql  ·  TPF Platform
-- Fixes the GoTrue timing gap: for admin/dashboard-created users, app_metadata
-- is written AFTER the AFTER-INSERT trigger fires, so profiles.role was wrong
-- and a stray client_records row was created for non-clients.
--
-- Access control was never affected (RLS reads the JWT). This only corrects the
-- profiles.role mirror and the client_records spine.
-- ============================================================================

-- ---------- SYNC FUNCTION ---------------------------------------------------
-- Fires when raw_app_meta_data changes. Mirrors the role into profiles and
-- reconciles client_records SAFELY (never deletes a populated record).
create or replace function public.sync_user_role()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role app_role := case
    when (new.raw_app_meta_data ->> 'role') in ('client','founder','operator','org_admin')
      then (new.raw_app_meta_data ->> 'role')::app_role
    else 'client'
  end;
begin
  -- mirror role (profile is guaranteed to exist by the time metadata is set)
  update public.profiles
     set role = v_role
   where id = new.id
     and role is distinct from v_role;

  if v_role = 'client' then
    -- ensure the spine exists for clients
    insert into public.client_records (client_id)
    values (new.id)
    on conflict (client_id) do nothing;
  else
    -- remove only a STRAY (untouched) record for non-clients.
    -- Guard: never destroy a record that carries diagnostic data.
    delete from public.client_records
     where client_id = new.id
       and archetype        is null
       and prisoner_pattern is null
       and key              is null;
  end if;

  return new;
end;
$$;

-- column-scoped trigger -> does NOT fire on every login (last_sign_in_at etc.)
create trigger on_auth_user_role_synced
  after update of raw_app_meta_data on auth.users
  for each row execute function public.sync_user_role();

-- ============================================================================
-- ONE-OFF RECONCILE — repairs users created before this trigger existed
-- (e.g. the founder test user already in the DB). Idempotent.
-- ============================================================================
do $$
begin
  -- 1. mirror every profile's role from its current app_metadata
  update public.profiles p
     set role = case
       when (u.raw_app_meta_data ->> 'role') in ('client','founder','operator','org_admin')
         then (u.raw_app_meta_data ->> 'role')::app_role
       else 'client'
     end
    from auth.users u
   where u.id = p.id
     and p.role is distinct from case
       when (u.raw_app_meta_data ->> 'role') in ('client','founder','operator','org_admin')
         then (u.raw_app_meta_data ->> 'role')::app_role
       else 'client'
     end;

  -- 2. drop stray, empty client_records belonging to non-clients
  delete from public.client_records c
   using public.profiles p
   where c.client_id = p.id
     and p.role <> 'client'
     and c.archetype is null
     and c.prisoner_pattern is null
     and c.key is null;

  -- 3. ensure every client has a spine row
  insert into public.client_records (client_id)
  select p.id
    from public.profiles p
   where p.role = 'client'
     and not exists (
       select 1 from public.client_records c where c.client_id = p.id
     );
end $$;

-- ============================================================================
-- VERIFY (after push)
--   select p.id, p.role, (c.id is not null) as has_client_record
--   from public.profiles p
--   left join public.client_records c on c.client_id = p.id;
-- Expect: founders/operators -> role correct, has_client_record = false;
--         clients            -> role='client',  has_client_record = true.
--
-- Then re-check via dashboard: edit the founder test user's App Metadata
-- (toggle role) and confirm profiles.role follows and no stray record appears.
-- ============================================================================
