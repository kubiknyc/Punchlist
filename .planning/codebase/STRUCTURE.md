# Codebase Structure

**Analysis Date:** 2026-06-12

## Directory Layout

```
punchlist/
├── src/                        # Application source code
│   ├── app/                    # Next.js App Router pages and layouts
│   │   ├── (app)/              # Authenticated app route group
│   │   │   └── projects/
│   │   │       └── page.tsx    # Project list + creation (client component)
│   │   ├── login/
│   │   │   └── page.tsx        # Login page (Supabase auth)
│   │   ├── favicon.ico         # App favicon
│   │   ├── globals.css         # Tailwind v4 entry point
│   │   ├── layout.tsx          # Root layout (fonts, providers, metadata)
│   │   ├── page.tsx            # Root page (redirects)
│   │   └── providers.tsx       # PowerSyncContext provider setup
│   ├── lib/                    # Reusable application logic
│   │   ├── domain/             # Pure TS business rules (no I/O)
│   │   │   └── status.ts       # Status transitions, roles, conflict resolution
│   │   ├── powersync/          # Offline-first data layer
│   │   │   ├── db.ts           # PowerSyncDatabase instance + connect logic
│   │   │   ├── schema.ts       # Local SQLite schema (mirrors Postgres)
│   │   │   └── connector.ts    # SupabaseConnector (upload queue → Supabase)
│   │   └── supabase/           # Auth-only Supabase paths
│   │       ├── client.ts       # Browser client (createBrowserClient)
│   │       └── middleware.ts   # Session refresh for Next.js middleware
│   └── middleware.ts           # Next.js middleware entry (wraps updateSession)
├── supabase/                   # Postgres backend and local dev stack
│   ├── migrations/             # Numbered SQL migrations (never edit applied ones)
│   │   ├── 0001_schema.sql     # Tables: orgs, profiles, org_members, projects,
│   │   │                       #   locations, punch_items, punch_item_events, photos
│   │   ├── 0002_rls.sql        # Row-level security policies
│   │   └── 0003_rls_fixes.sql  # RLS hardening (trigger holes, explicit grants)
│   ├── tests/
│   │   └── rls.test.sql        # pgTAP RLS security tests
│   ├── .branches/              # Supabase CLI branch tracking (generated, not committed)
│   ├── .temp/                  # Supabase CLI temp files (generated, not committed)
│   ├── snippets/               # Supabase SQL snippets directory (empty)
│   ├── .gitignore              # Supabase-generated gitignore
│   └── config.toml             # Supabase local stack configuration
├── powersync/
│   └── sync-rules.yaml         # PowerSync bucket definitions (deployed to service, not bundled)
├── tests/                      # Test files
│   └── unit/
│       └── status.test.ts      # Vitest unit tests for domain rules
├── public/                     # Static assets served by Next.js
│   ├── file.svg
│   ├── globe.svg
│   ├── next.svg
│   ├── vercel.svg
│   └── window.svg
├── docs/                       # Project documentation
│   └── superpowers/
│       ├── specs/              # Design specifications
│       │   └── 2026-06-10-punchlist-design.md
│       └── plans/              # Implementation plans
│           ├── 2026-06-11-punchlist-foundation.md (Plan 1 - complete)
│           └── 2026-06-11-punchlist-field-workflows.md (Plan 2 - written, not started)
├── .planning/                  # GSD planning documents and config
│   ├── codebase/               # Codebase analysis (ARCHITECTURE.md, STRUCTURE.md, etc.)
│   ├── research/               # Research notes (if any)
│   ├── PROJECT.md              # Project metadata
│   └── config.json             # Planning tool configuration
├── .claude/                    # Claude Code settings
│   └── settings.local.json     # IDE settings for Claude
├── CLAUDE.md                   # Project guidance for Claude Code (codebase invariants, conventions)
├── AGENTS.md                   # Next.js version warning for agents
├── README.md                   # Project overview
├── package.json                # npm scripts: dev, build, lint, test, verify
├── package-lock.json           # Locked dependency versions
├── tsconfig.json               # Strict mode, @/* → src/* alias, type checking
├── next.config.ts              # Next.js configuration
├── vitest.config.ts            # Unit test framework configuration
├── eslint.config.mjs           # ESLint configuration (flat config)
├── postcss.config.mjs          # PostCSS configuration (Tailwind v4)
├── next-env.d.ts               # Next.js generated type definitions
└── .gitignore                  # Git ignore rules
```

## Directory Purposes

**src/:**
- Contains all application source code
- Organized by feature/concern (app pages, lib utilities, middleware)

**src/app/:**
- Next.js App Router pages and layouts
- Uses route groups `(app)` for authenticated pages and layout boundaries
- `providers.tsx` wraps the React tree with PowerSyncContext

**src/lib/domain/:**
- Pure TypeScript business logic with no external dependencies or I/O
- Rules: status transitions, role-based access, conflict resolution
- Unit-tested in `tests/unit/`

**src/lib/powersync/:**
- Local SQLite database instance and sync logic
- `schema.ts` defines the local schema (mirrors Postgres tables)
- `connector.ts` implements upload queue → Supabase replication
- `db.ts` provides the database connection and initialization

**src/lib/supabase/:**
- Supabase authentication paths only (NOT data reads/writes)
- `client.ts` is the browser client (session-aware)
- `middleware.ts` handles token refresh in Next.js middleware

**supabase/migrations/:**
- Numbered SQL migrations: `000N_*.sql`
- Never edit a migration once applied to production
- Create new migrations for schema changes
- RLS policies defined in migrations, tested in `supabase/tests/rls.test.sql`

**supabase/.branches/ and .temp/:**
- Generated by Supabase CLI for local development
- Not committed to git

**powersync/:**
- `sync-rules.yaml` defines which data each user receives
- Deployed to PowerSync service (not bundled with app)
- Changes require service redeployment, not app redeploy

**tests/unit/:**
- Unit tests for domain logic
- File naming mirrors source: `tests/unit/<module>.test.ts` ↔ `src/lib/domain/<module>.ts`

**public/:**
- Static assets (SVGs, images) served by Next.js
- Accessible via `/filename.ext` at runtime

**docs/superpowers/:**
- Design specification: `2026-06-10-punchlist-design.md` (full feature spec)
- Implementation plans: `2026-06-11-punchlist-foundation.md` (Plan 1, complete), `2026-06-11-punchlist-field-workflows.md` (Plan 2, design written)

**.planning/:**
- Generated by GSD planning tools
- `codebase/` contains architecture, structure, conventions, testing, concerns, stack, integrations analyses
- `.planning/config.json` stores tool state
- `.planning/PROJECT.md` project metadata

**.claude/ and config files:**
- `.claude/settings.local.json`: IDE preferences for Claude Code
- `eslint.config.mjs`: ESLint rules (flat config format)
- `postcss.config.mjs`: PostCSS plugins (includes Tailwind v4)
- `tsconfig.json`: TypeScript compiler options (strict mode, path aliases)
- `next.config.ts`: Next.js build and server configuration

## Key File Locations

| What | Where |
|------|-------|
| Domain business rules | `src/lib/domain/status.ts` |
| Local DB schema | `src/lib/powersync/schema.ts` |
| DB instance / connect | `src/lib/powersync/db.ts` |
| Upload connector | `src/lib/powersync/connector.ts` |
| React data provider | `src/app/providers.tsx` |
| Root layout | `src/app/layout.tsx` |
| Login page | `src/app/login/page.tsx` |
| Projects page | `src/app/(app)/projects/page.tsx` |
| Auth session refresh | `src/middleware.ts` → `src/lib/supabase/middleware.ts` |
| Browser client | `src/lib/supabase/client.ts` |
| Postgres schema | `supabase/migrations/0001_schema.sql` |
| RLS policies | `supabase/migrations/0002_rls.sql`, `0003_rls_fixes.sql` |
| RLS tests | `supabase/tests/rls.test.sql` |
| Sync rules | `powersync/sync-rules.yaml` |
| Unit tests | `tests/unit/status.test.ts` |
| Design spec | `docs/superpowers/specs/2026-06-10-punchlist-design.md` |
| Implementation plans | `docs/superpowers/plans/` |
| TypeScript config | `tsconfig.json` |
| ESLint config | `eslint.config.mjs` |
| PostCSS/Tailwind config | `postcss.config.mjs` |
| Next.js config | `next.config.ts` |
| Vitest config | `vitest.config.ts` |

## Naming Conventions

**Migrations:**
- Format: `supabase/migrations/000N_<description>.sql`
- Example: `0001_schema.sql`, `0002_rls.sql`
- Rule: Add new ones, never edit applied ones

**Route groups (Next.js):**
- Format: `src/app/(<groupName>)/`
- Example: `src/app/(app)/` for authenticated pages
- Used to apply layouts and middleware only to certain routes

**Route files (Next.js):**
- Format: `src/app/<route>/page.tsx` for pages, `layout.tsx` for layouts
- Example: `src/app/(app)/projects/page.tsx`

**Test files:**
- Format: `tests/unit/<module>.test.ts`
- Pattern: mirrors source structure
- Example: `tests/unit/status.test.ts` tests `src/lib/domain/status.ts`

**Source files:**
- Casing: lowercase filenames, kebab-case for multi-word names
- Extensions: `.ts` for utilities, `.tsx` for React components
- Example: `status.ts`, `powersync-context.tsx` (hypothetical)

**Path alias:**
- Format: `@/*` resolves to `src/*`
- Used: all imports use `@/` prefix
- Example: `import { db } from '@/lib/powersync/db'`

**Directories:**
- Casing: lowercase, kebab-case for multi-word names
- Example: `src/lib/powersync/`, `src/lib/supabase/`

**TypeScript/Config files:**
- Format: lowercase, dotfiles for hidden configs
- Examples: `tsconfig.json`, `.eslintrc` (not present; using flat config), `eslint.config.mjs`, `postcss.config.mjs`

## Where to Add New Code

**New business rule or domain logic:**
- File: Create in `src/lib/domain/<module>.ts` (pure TS, no I/O)
- Test: Add unit test in `tests/unit/<module>.test.ts`
- Example: adding a new status transition rule

**New table or column in Postgres:**
- Migration: Create `supabase/migrations/000N_<description>.sql` (increment N)
- Schema sync: Update `src/lib/powersync/schema.ts` to include new table/columns
- RLS: Add policies to migration + test in `supabase/tests/rls.test.sql`
- Sync rules: Update `powersync/sync-rules.yaml` to include new table in appropriate buckets
- Upload logic: If needed, update `src/lib/powersync/connector.ts`

**New page or route:**
- Authenticated page: `src/app/(app)/<feature>/page.tsx`
- Unauthenticated page: `src/app/<feature>/page.tsx`
- Shared layout: create `src/app/(group)/layout.tsx` and nest routes under `src/app/(group)/<route>/page.tsx`
- Example: adding a punch items list page at `/punch-items`:
  - Create `src/app/(app)/punch-items/page.tsx`

**New API-like logic (server-side):**
- Server Actions: colocate with page file as `'use server'` functions
- Example: mutation to create project in `src/app/(app)/projects/page.tsx`

**New reusable component:**
- If used once: colocate with page (`src/app/(app)/projects/`)
- If used 2+ times: extract to `src/components/<feature>/` (currently not present, can be created)
- Note: current codebase appears to inline most components in pages

**Utilities and helpers:**
- Non-domain: add to `src/lib/<category>/<module>.ts`
- Domain logic: must go in `src/lib/domain/`
- Example: string formatting helper → `src/lib/format.ts` or similar

**Access-control changes (critical pattern):**
- Rule change: update `src/lib/domain/status.ts` (client validation)
- Postgres enforcement: update RLS in `supabase/migrations/000N_rls.sql`
- Sync rules: update `powersync/sync-rules.yaml` to match new roles/buckets
- Test: prove the change in `supabase/tests/rls.test.sql`
- These three layers must stay in sync

**Environment configuration:**
- Build-time config: `next.config.ts`
- Runtime (browser): `NEXT_PUBLIC_*` vars (no `.env` committed; see CLAUDE.md)
- Example: `NEXT_PUBLIC_SUPABASE_URL` in `.env.local`

## Special Directories

**node_modules/:**
- Installed dependencies (not committed)
- Contains Next.js, React, Tailwind, PowerSync, Supabase clients, etc.

**.next/:**
- Next.js build output (not committed)
- Generated during `npm run build`

**.git/:**
- Git repository metadata (not user code)

**supabase/.branches/ and .temp/:**
- Generated by Supabase CLI
- Not committed; used for local development tracking

**public/:**
- Static assets served at root path
- Example: `/file.svg` maps to `public/file.svg`

---

*Structure analysis: 2026-06-12*
