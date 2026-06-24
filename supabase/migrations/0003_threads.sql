-- ============================================================================
-- 0003_threads.sql  ·  TPF Platform
-- Conversation threads + messages for the Audit and Architect instruments.
--
-- Design: messages are written ONLY by edge functions (service role, bypasses
-- RLS). The client may SELECT its own messages but never INSERT directly — all
-- model interaction is mediated by the governed instrument, so prompts/KB are
-- never exposed and registers/guardrails are always enforced server-side.
-- ============================================================================

-- ---------- THREADS ---------------------------------------------------------
-- One thread per (client, program). The Architect thread persists across the 3
-- days. A partial unique index enforces "one thread per program per client".
create table public.threads (
  id          uuid primary key default gen_random_uuid(),
  client_id   uuid    not null references public.profiles(id) on delete cascade,
  program     program not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create unique index threads_client_program_uidx
  on public.threads (client_id, program);

create trigger trg_threads_updated_at
  before update on public.threads
  for each row execute function public.set_updated_at();

-- ---------- MESSAGES --------------------------------------------------------
create table public.messages (
  id          uuid primary key default gen_random_uuid(),
  thread_id   uuid not null references public.threads(id) on delete cascade,
  role        text not null check (role in ('user','assistant')),
  content     text not null,
  -- optional: which Architect day produced this turn ('day_1'|'day_2'|'day_3')
  phase       text,
  created_at  timestamptz not null default now()
);

create index messages_thread_created_idx
  on public.messages (thread_id, created_at);

-- ============================================================================
-- ROW LEVEL SECURITY
-- ============================================================================

-- ---------- THREADS ---------------------------------------------------------
alter table public.threads enable row level security;

-- client: read own threads
create policy threads_select_own on public.threads
  for select using (client_id = auth.uid());

-- founder: read all threads (founder console)
create policy threads_select_founder on public.threads
  for select using (public.current_app_role() = 'founder');

-- NOTE: no client INSERT/UPDATE policy. Threads are created by the edge
-- functions (service role). Founder does not create threads either.

-- ---------- MESSAGES --------------------------------------------------------
alter table public.messages enable row level security;

-- client: read messages in their own threads
create policy messages_select_own on public.messages
  for select using (
    exists (
      select 1 from public.threads t
      where t.id = messages.thread_id
        and t.client_id = auth.uid()
    )
  );

-- founder: read all messages
create policy messages_select_founder on public.messages
  for select using (public.current_app_role() = 'founder');

-- NOTE: no client/founder INSERT policy by design. All writes go through the
-- service role in edge functions. operator (Adam) gets NO access to messages.

-- ============================================================================
-- VERIFY (after push)
--  • As service role: insert a thread (program='audit') + a couple of messages.
--  • Client A JWT  -> sees ONLY its own thread + messages.
--  • Client B JWT  -> sees none of Client A's.
--  • Founder JWT   -> sees all.
--  • Confirm a client JWT CANNOT insert a message (RLS denies; no INSERT policy).
-- ============================================================================
