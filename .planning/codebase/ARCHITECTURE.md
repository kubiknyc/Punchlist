# Architecture

**Analysis Date:** 2026-06-12

## Pattern Overview

**Overall:** Offline-first, synced PWA with three-layer access control

**Key Characteristics:**
- UI reads/writes an in-browser SQLite database (never Supabase directly for app data)
- PowerSync syncs the browser database bidirectionally with Postgres
- Access control enforced at three layers: Postgres RLS, PowerSync sync rules, and client transition rules
- Authentication is the only direct Supabase path (session refresh in middleware)
- Domain rules live as pure TypeScript functions with unit tests, no I/O

## Layers

**Authentication (Middleware):**
- Purpose: Validate sessions and redirect unauthenticated users to `/login`
- Location: `src/middleware.ts` → `src/lib/supabase/middleware.ts`
- Contains: Session refresh via `@supabase/ssr` server client
- Depends on: Supabase Auth API
- Used by: Next.js request pipeline

**Data Access (PowerSync + Browser SQLite):**
- Purpose: Provide offline-capable data storage to React components
- Location: `src/lib/powersync/`
- Contains: 
  - `db.ts`: PowerSync database instance and connection orchestration
  - `schema.ts`: SQLite schema definition (tables: projects, locations, punch_items, punch_item_events, photos)
  - `connector.ts`: Upstream connector implementing PowerSync's backend interface
- Depends on: Supabase Auth (for credentials), PowerSync service
- Used by: React components via `@powersync/react` hooks (`useQuery`, `useStatus`)

**Domain Rules (Pure TypeScript):**
- Purpose: Implement stateless, testable business logic for status transitions
- Location: `src/lib/domain/status.ts`
- Contains: 
  - Role-based transition validation: subs can move `open → in_progress → done` and `in_progress → open`, GC roles (admin/member) can transition to any status
  - Conflict resolution: offline writes preserve later-stage status (e.g., `verified` never downgrades to `done`)
  - Type definitions: `PunchStatus`, `Role`, `STATUS_ORDER`
- Depends on: Nothing
- Used by: Client pages, upstream validation, server-side RPC (Plan 2)

**UI Layer (Next.js App Router):**
- Purpose: Render views and handle user interactions
- Location: `src/app/`
- Contains:
  - Layout and providers setup (`layout.tsx`, `providers.tsx`)
  - Authentication flow (`login/page.tsx`)
  - App routes (`(app)/projects/page.tsx`)
- Depends on: PowerSync context, Supabase browser client
- Used by: Browser/PWA runtime

**Backend Integration (Supabase):**
- Purpose: Authoritative data store and user identity source
- Location: External service; local schema in `supabase/migrations/`
- Contains: 
  - Postgres tables with enums (`org_role`, `project_status`, `punch_status`)
  - RLS policies enforcing data isolation (`supabase/migrations/0002_rls.sql`, `0003_rls_fixes.sql`)
  - Auth users via `auth.users` table
- Depends on: Nothing
- Used by: PowerSync connector, Supabase Auth, RLS engine

**PowerSync Sync Service:**
- Purpose: Bidirectional sync between browser SQLite and Postgres
- Location: External; configured in `powersync/sync-rules.yaml`
- Contains:
  - Bucket definitions (`gc_org`, `sub_items`) that route data based on user role and assignments
  - Download logic: GC roles receive their entire org (active projects only); subs receive only assigned items + context
  - Upload logic: handled by `src/lib/powersync/connector.ts`
- Depends on: Postgres, Supabase Auth
- Used by: PowerSync SDK in browser

## Data Flow

**Initial Load:**

1. Browser loads; `src/app/layout.tsx` wraps app in `Providers`
2. `Providers` initializes PowerSync database (`db.ts`) and calls `connectPowerSync()`
3. Middleware checks session; unauthenticated requests redirect to `/login`
4. If authenticated and `NEXT_PUBLIC_POWERSYNC_URL` is set: `SupabaseConnector` fetches access token and connects to PowerSync service
5. PowerSync downloads initial bucket data according to `sync-rules.yaml` based on user role
6. Pages render and read from local SQLite via PowerSync hooks

**Writing Data:**

1. Component calls `db.execute()` or `db.upsert()` to insert/update a row in local SQLite
2. PowerSync queues the operation in its sync queue
3. On the next upload cycle (connection permitting), `SupabaseConnector.uploadData()` replays the queued CRUD against Supabase
4. Supabase RLS policies evaluate access; if denied (code `42501`), the connector discards the operation so the queue doesn't wedge
5. Server state re-syncs down to the browser on the next download cycle
6. Component re-renders with fresh data from `useQuery()`

**Status Transition Conflict Resolution:**

1. Offline device updates status from `done` to `in_progress`
2. Meanwhile, online device marks it `verified`
3. Both changes queue locally; when both devices sync:
   - Offline device downloads `verified` status, resolves conflict via `resolveStatusConflict('in_progress', 'verified')` → keeps `verified`
   - Online device may receive the `in_progress` upload, but RLS/RPC will reject or the conflict rule applies upstream

**Access Control Enforcement:**

1. **Postgres RLS (source of truth):**
   - GC roles (admin/member) can read/write all items in their org
   - Subs can read items assigned to them + related events/photos
   - Status transition validation via RPC (Plan 2: `record_status_event`)

2. **PowerSync sync rules:**
   - `gc_org` bucket: GC users pull entire org (minus closed projects)
   - `sub_items` bucket: Subs pull only assigned items + context
   - Uploaded writes are validated by RLS on re-entry

3. **Client transition rules:**
   - `canTransition(role, from, to)` blocks invalid moves before sending to server
   - Prevents UI from offering disallowed actions

**State Management:**

- Component state: React hooks (`useState`) for UI ephemera (form inputs, error messages)
- Sync state: PowerSync SDK's `useStatus()` indicates connectivity (`status.connected`)
- App data: SQLite queries via `useQuery()` — always read from the local database
- Auth: `supabase.auth.getUser()` or `supabase.auth.getSession()` for user identity

## Key Abstractions

**PowerSyncDatabase:**
- Purpose: In-process SQLite database exposed as a React context
- Examples: `src/lib/powersync/db.ts`
- Pattern: Singleton exported as `db`, provided to children via `PowerSyncContext.Provider` in `src/app/providers.tsx`
- Usage: Components consume via `usePowerSync()` hook or call `db.getAll()`, `db.execute()` directly

**SupabaseConnector:**
- Purpose: PowerSync backend connector that replays queued CRUD and handles permanent vs. transient errors
- Examples: `src/lib/powersync/connector.ts`
- Pattern: Implements `PowerSyncBackendConnector` interface; called by PowerSync to sync up/down
- Error handling: Discards permanent rejections (RLS, constraints), rethrows transient errors for retry

**Domain Rules Module:**
- Purpose: Pure functions for role-based access and conflict resolution
- Examples: `src/lib/domain/status.ts`
- Pattern: No I/O, no side effects; unit-tested in `tests/unit/status.test.ts`
- Reuse: Called from client pages; server-side RPC will mirror same logic (Plan 2)

**Supabase Clients:**
- Purpose: Separate instances for server (middleware) vs. browser contexts
- Examples: 
  - `src/lib/supabase/client.ts`: Browser client via `createBrowserClient()`
  - `src/lib/supabase/middleware.ts`: Server client via `createServerClient()`
- Pattern: Required because browser has no access to Supabase keys in server context; SSR server client has access to request/response cookies

## Entry Points

**Web Browser:**
- Location: `src/app/layout.tsx`
- Triggers: User navigates to the app URL
- Responsibilities: Initialize Tailwind globals, wrap tree in Providers (PowerSync context), render root layout

**Authentication:**
- Location: `src/app/login/page.tsx`
- Triggers: Unauthenticated user or explicit `/login` visit
- Responsibilities: Email/password sign-in form, error handling, redirect to `/projects` on success

**App (Projects Dashboard):**
- Location: `src/app/(app)/projects/page.tsx`
- Triggers: Authenticated user navigates to `/projects`
- Responsibilities: List active projects, create new project, show offline status indicator

**Middleware (Every Request):**
- Location: `src/middleware.ts` → `src/lib/supabase/middleware.ts`
- Triggers: Every HTTP request matching the config matcher
- Responsibilities: Refresh session, redirect to `/login` if not authenticated, pass through otherwise

**PowerSync Connection (Browser Only):**
- Location: `src/app/providers.tsx` → `src/lib/powersync/db.ts`
- Triggers: On component mount via `useEffect` in `Providers`
- Responsibilities: Initialize database, connect to PowerSync service, begin sync cycles

## Error Handling

**Strategy:** Distinguish permanent vs. transient errors; discard permanent ones so sync queue never wedges

**Patterns:**

1. **Permanent Errors (Discarded):**
   - RLS denial (`42501`): User lacks permission; server state is authoritative
   - Constraint violation (`23505`, `23503`): Business rule violated; local op was invalid
   - `P0001`: Custom Postgres exception (future RPC validation)
   - Handler: Log error, mark transaction complete, don't retry

2. **Transient Errors (Rethrown):**
   - Network failures: Device offline or service unreachable
   - Handler: Rethrow to PowerSync; it retries on next sync cycle

3. **Client-Side Errors:**
   - UI form validation: Checked before calling `db.execute()`
   - Business rule violations: `canTransition()` blocks invalid moves before queuing
   - Missing org: Handled in `createProject()` — falls back to online lookup

## Cross-Cutting Concerns

**Logging:** `console.warn()` / `console.error()` at key points
- PowerSync connection failure in `connectPowerSync()`
- Permanent error discards in `SupabaseConnector.uploadData()`
- Offline project creation fallback in `ProjectsPage`

**Validation:**
- Domain rules enforce transitions: `canTransition()` before UI allows action
- RLS enforces access at database layer
- Supabase Auth enforces session validity in middleware

**Authentication:**
- Middleware intercepts every request; redirects to `/login` if not authenticated
- Browser client refreshes access token via `@supabase/ssr` cookie handling
- PowerSync credentials fetched fresh on each sync via `fetchCredentials()`

**Offline Support:**
- PowerSync handles queue of local writes when offline
- `useStatus()` shows `status.connected` to UI
- First-ever project creation requires one online lookup (Plan 3 service worker will fix)

---

*Architecture analysis: 2026-06-12*
