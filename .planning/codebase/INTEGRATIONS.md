# External Integrations

**Analysis Date:** 2026-06-12

## APIs & External Services

**Authentication & User Management:**
- Supabase Auth (included with Supabase project)
  - SDK: `@supabase/ssr` (server) + `@supabase/supabase-js` (browser)
  - Session refresh: `src/lib/supabase/middleware.ts` (Next.js middleware)
  - Browser client: `src/lib/supabase/client.ts` (createBrowserClient)
  - Implementation: OAuth via Supabase (configured in remote project, not bundled)

**Data Sync Service:**
- PowerSync sync engine
  - SDK: `@powersync/web` (main DB connector) + `@powersync/react` (React hooks)
  - Upload strategy: `src/lib/powersync/connector.ts` (SupabaseConnector class)
  - Sync rules deployed to: `powersync/sync-rules.yaml` (not bundled, deployed separately to PowerSync service)
  - Credentials: Fetches Supabase access token and PowerSync endpoint URL on-demand

**Google Fonts:**
- Next.js font optimization
  - Fonts: Geist Sans, Geist Mono
  - Implementation: `src/app/layout.tsx` (Metadata + CSS variables)

## Data Storage

**Databases:**

**Primary (Source of Truth):**
- Supabase PostgreSQL (cloud-hosted)
  - Connection: `NEXT_PUBLIC_SUPABASE_URL` (env var)
  - Client: `@supabase/supabase-js` (createBrowserClient in `src/lib/supabase/client.ts`)
  - Auth: Row-level security (RLS) policies in `supabase/migrations/000X_rls.sql`
  - Schema: `supabase/migrations/0001_schema.sql`
  - Tables: orgs, profiles, org_members, projects, locations, punch_items, punch_item_events, photos

**Local (Offline):**
- SQLite (browser-embedded via @journeyapps/wa-sqlite)
  - Database file: `punchlist.db` (in-browser IndexedDB or filesystem)
  - Schema: `src/lib/powersync/schema.ts` (TypeScript-defined, synced from PowerSync)
  - Tables: projects, locations, punch_items, punch_item_events, photos
  - Initialization: `src/lib/powersync/db.ts` (PowerSyncDatabase instance)

**File Storage:**
- Supabase Storage (cloud-hosted, part of Supabase project)
  - Purpose: Stores photos (punch item before/after and verification photos)
  - Access: Via Supabase client (not directly exposed, managed by backend RLS)
  - Field reference: photos table `storage_path` column (`src/lib/powersync/schema.ts`)

**Caching:**
- Browser IndexedDB (via PowerSync) - Implicit, no separate service
- No Redis or external cache service configured

## Authentication & Identity

**Auth Provider:**
- Supabase Auth (OAuth/email-based, configured in remote Supabase project)
  - Implementation: `src/lib/supabase/client.ts` (browser client via SSR)
  - Session refresh: `src/lib/supabase/middleware.ts` (Next.js middleware, cookie-based)
  - Entry point: `src/middleware.ts` (wraps updateSession)
  - Redirect: Unauthenticated users redirected to `/login` (`src/app/login/page.tsx`)
  - User lookup: `src/app/(app)/projects/page.tsx` (calls supabase.auth.getUser())

**Roles & Access Control:**
- Client-side role checking: `src/lib/domain/status.ts` (domain rules, unit-tested)
- RLS enforcement: `supabase/migrations/000X_rls.sql`
- PowerSync sync rules: `powersync/sync-rules.yaml` (defines data buckets per role)
- Role types: admin, member (GC roles), sub (subcontractor)

## Monitoring & Observability

**Error Tracking:**
- Not detected (no Sentry, Rollbar, or similar integration)

**Logging:**
- Browser console only (console.error, console.warn in `src/lib/powersync/db.ts` and `src/lib/powersync/connector.ts`)
- No structured logging service detected

## CI/CD & Deployment

**Hosting:**
- Vercel (mentioned in CLAUDE.md; Next.js optimized)
  - Deployment: git push to GitHub triggers Vercel build
  - Environment variables: Set in Vercel dashboard (maps to `.env.local` equivalent)

**Version Control:**
- GitHub: `github.com/kubiknyc/Punchlist` (from CLAUDE.md in parent directory)
- Branch-based deployments (preview + production)

**CI Pipeline:**
- Not explicitly configured (GitHub Actions not detected)
- Manual verification pre-commit: `npm run verify` (lint + typecheck + test + build)

## Environment Configuration

**Required env vars (`.env.local`):**
- `NEXT_PUBLIC_SUPABASE_URL` - Supabase project REST API endpoint
- `NEXT_PUBLIC_SUPABASE_ANON_KEY` - Supabase anonymous key (safe for public use)
- `NEXT_PUBLIC_POWERSYNC_URL` - PowerSync service endpoint (optional: app runs local-only if missing)

**Optional env vars:**
- None detected; all configuration is env-var based or in code

**Secrets location:**
- `.env.local` (development, not committed to git)
- Vercel dashboard environment variables (production)

## Webhooks & Callbacks

**Incoming:**
- Not detected; app is stateless PWA, no server-side webhooks

**Outgoing:**
- PowerSync upload trigger: `src/lib/powersync/connector.ts` monitors CRUD queue and uploads to Supabase API
- No explicit webhook mechanism observed

## Data Sync Flow (Critical Path)

**Download (Postgres → SQLite):**

1. User authenticates via Supabase Auth
2. PowerSync fetches credentials: `src/lib/powersync/connector.ts::fetchCredentials()`
   - Gets user session and PowerSync endpoint from environment
3. PowerSync service uses sync rules: `powersync/sync-rules.yaml`
   - GC roles: receive whole org (active projects only)
   - Sub roles: receive only assigned items + context
4. Changes replicated to local SQLite: `src/lib/powersync/db.ts`
5. React components query via `@powersync/react` hooks: `useQuery()`, `useStatus()`

**Upload (SQLite → Postgres):**

1. Local CRUD operations queued in PowerSync database
2. `src/lib/powersync/connector.ts::uploadData()` executed on schedule
3. For each queued operation:
   - PUT (insert) → `supabase.from(table).upsert()`
   - PATCH (update) → `supabase.from(table).update().eq()`
   - DELETE → `supabase.from(table).delete().eq()`
4. Errors handled:
   - Permanent (RLS denial `42501`, constraint violations, stored procedure errors): discarded (queue never wedges)
   - Transient (network): rethrown for PowerSync retry
5. RLS policies enforce access (`supabase/migrations/000X_rls.sql`)

**Offline Mode:**
- If `NEXT_PUBLIC_POWERSYNC_URL` unset: app runs purely local
- Writes queued in SQLite; never uploaded
- Suitable for demo or offline-only use

---

*Integration audit: 2026-06-12*
