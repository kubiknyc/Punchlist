# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@AGENTS.md

## What this is

Punchlist is an offline-first construction punch list PWA for general contractors: a GC walks a site logging defects with photos, assigns them to subcontractors, subs mark them done with proof photos, the GC verifies. Full design spec: `docs/superpowers/specs/2026-06-10-punchlist-design.md`. Implementation plans (Plan 1 complete, Plan 2 written but not yet started): `docs/superpowers/plans/`.

## Commands

```bash
npm run dev        # Next.js dev server (http://localhost:3000)
npm run build      # production build
npm run lint       # ESLint
npm test           # vitest run (tests/unit/**/*.test.ts)
npm run verify     # lint + tsc --noEmit + test + build — run before committing
npx vitest run tests/unit/status.test.ts   # single test file
npx vitest run -t "name"                   # single test by name
supabase test db   # pgTAP RLS tests (supabase/tests/rls.test.sql) — needs local Supabase stack
```

Required env vars (`.env.local`): `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `NEXT_PUBLIC_POWERSYNC_URL`. Without the PowerSync URL the app runs local-only with writes queued.

## Architecture

**Stack:** Next.js (App Router) + TypeScript + Tailwind v4 on Vercel; Supabase (Postgres source of truth, Auth, Storage, RLS); PowerSync sync service.

**Offline-first data flow — the core invariant:** the UI never reads or writes Supabase directly for app data. All reads/writes go to an in-browser SQLite database (`src/lib/powersync/db.ts`, schema in `schema.ts`), provided to React via `PowerSyncContext` in `src/app/providers.tsx`. PowerSync syncs it bidirectionally with Postgres:

- **Download:** `powersync/sync-rules.yaml` (deployed to the PowerSync service, not bundled) defines what each user receives — GC roles get their whole org (active projects only; closed projects are excluded to bound phone storage); subs get only their assigned items plus those items' events/photos/locations/project.
- **Upload:** `src/lib/powersync/connector.ts` replays queued local CRUD against Supabase. Permanent rejections (RLS denial `42501`, constraint violations `23505`/`23503`, `P0001`) are deliberately discarded so the upload queue never wedges; transient errors are rethrown so PowerSync retries.

**Three access-control layers must stay in sync.** A change to who can see or do what touches all of:
1. Postgres RLS policies (`supabase/migrations/`, tested in `supabase/tests/rls.test.sql`)
2. PowerSync sync rules (`powersync/sync-rules.yaml`)
3. Client transition rules (`src/lib/domain/status.ts`)

**Domain rules live in pure TS** (`src/lib/domain/`), no I/O, unit-tested in `tests/unit/`. Key rules: roles are `admin`/`member` (GC) and `sub`; status flows `open → in_progress → done → verified`; subs cannot verify or kick back; sync conflicts on status resolve by stage precedence (a later-stage status is never downgraded by a stale offline write). Plan 2 moves status-event enforcement server-side via a `record_status_event` Postgres RPC — keep the client rule and the RPC equivalent.

**Auth** is the one Supabase-direct path: `src/middleware.ts` → `src/lib/supabase/middleware.ts` refreshes sessions and redirects unauthenticated requests to `/login`; the browser client is `src/lib/supabase/client.ts`. Note the tension: the spec requires the app to open offline without a login wall, which the current middleware doesn't satisfy until the Plan 3 service worker exists.

## Conventions

- TypeScript strict mode; path alias `@/*` → `src/*`.
- Migrations are numbered `supabase/migrations/000N_*.sql`; add new ones, never edit applied ones.
- RLS tests are a security requirement: any RLS change needs a corresponding case in `supabase/tests/rls.test.sql` (e.g. proving one sub cannot read another sub's items).
