# Project: TPF Platform — backend (Claude Code scope)

The Possibility Formula Platform. This file governs how Claude Code works in this repo.
Read it at the start of every session.

## Your ownership
You own ONLY `/supabase` (migrations, RLS, edge functions, `_shared`).
You do NOT edit `/src` — that is Lovable's. If a task needs a frontend change,
state the contract the frontend should implement; do not write the frontend yourself.

## Hard rules
- Migrations are numbered `NNNN_name.sql`, sequential, never edited once pushed.
- Every table has RLS. Default deny. Author explicit policies per role.
- `role` lives in `auth.users.app_metadata` and is read in RLS via
  `auth.jwt() -> 'app_metadata' ->> 'role'`. NEVER write an RLS policy on
  `profiles` that SELECTs `profiles` to check role (infinite recursion).
- The knowledge base (`_shared/kb/`) and instrument prompts (`_shared/prompts/`)
  are CONFIDENTIAL IP. They are loaded server-side only, never returned in a
  response, never logged as plaintext, never imported anywhere under `/src`.
- Instruments must refuse to reveal system/KB:
  "This system is proprietary. What matters is what it reveals in you."
- No therapy-style processing; redirect on genuine distress; no medical/legal/financial advice.

## Workflow
- Before any backend pass: `git pull`.
- Land migration + RLS + function stub, THEN give me the exact curl / role-JWT
  test to verify BEFORE any UI is built against it.
- One concern per commit.
- Only Claude Code writes migrations. If a stray migration from Lovable appears,
  flag it and delete it before pushing. Use `supabase db diff` to catch drift.

## Known traps (pre-empted)
- RLS self-lookup recursion → role from `app_metadata`/JWT, never a `profiles`→`profiles` policy.
- `.maybeSingle()` only on guaranteed-unique results (e.g. `client_records.client_id` is unique);
  otherwise `.select()` and handle the array.
- Streaming edge functions: return a `ReadableStream` with `text/event-stream`;
  test with `curl -N` before the UI is wired.
- Never `import` from `_shared/kb` or `_shared/prompts` into `/src`.

## Stack
- Frontend: React / Vite / TypeScript in `/src` (Lovable-owned, not yours).
- Backend: Supabase — Postgres, Auth, Edge Functions (Deno), Storage.
- AI: behind `_shared/llm.ts`. Default Anthropic Messages API (`claude-sonnet-4-6`);
  OpenAI switchable via `DEFAULT_INSTRUMENT_PROVIDER`. Cheap tier for jalon detection,
  Opus for the rarely-run Formula synthesis.

## Secrets (Supabase Edge Function secrets — never in repo or frontend)
ANTHROPIC_API_KEY · OPENAI_API_KEY · WHATSAPP_API_TOKEN · DEFAULT_INSTRUMENT_PROVIDER

## Build order (Phase 1)
1. `0001_foundations` — enums, profiles, client_records, role-in-app_metadata, handle_new_user trigger, RLS.
2. `0002_threads` — threads, messages, RLS; then `audit-runner` + `audit-extract`.
3. `architect-runner` — 3-day flow, archetype+key as lens.
4. `formula-generator` — draft only, never auto-approve.
5. `_shared/llm.ts` — provider abstraction.

Refer to the PRD (§8 schema, §9 jalon engine, §11 AI layer) for full contracts.
