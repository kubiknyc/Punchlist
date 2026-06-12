# Codebase Structure

**Analysis Date:** 2026-06-12

## Directory Layout

```
punchlist/
├── src/
│   ├── app/                      # Next.js App Router pages
│   │   ├── (app)/                # Authenticated app route group
│   │   │   └── projects/
│   │   │       └── page.tsx      # Project list + creation (client component)
│   │   ├── login/
│   │   │   └── page.tsx          # Login page (Supabase auth)
│   │   ├── layout.tsx            # Root layout (fonts, providers)
│   │   ├── page.tsx              # Root page (redirects)
│   │   ├── providers.tsx         # PowerSyncContext provider setup
│   │   └── globals.css           # Tailwind v4 entry
│   ├── lib/
│   │   ├── domain/               # Pure TS business rules (no I/O)
│   │   │   └── status.ts         # Status transitions, roles, conflict resolution
│   │   ├── powersync/            # Offline-first data layer
│   │   │   ├── db.ts             # PowerSyncDatabase instance + connect logic
│   │   │   ├── schema.ts         # Local SQLite schema (mirrors Postgres)
│   │   │   └── connector.ts      # SupabaseConnector (upload queue → Supabase)
│   │   └── supabase/             # Auth-only Supabase paths
│   │       ├── client.ts         # Browser client (createBrowserClient)
│   │       └── middleware.ts     # Session refresh for Next.js middleware
│   └── middleware.ts             # Next.js middleware entry (wraps updateSession)
├── supabase/
│   ├── migrations/               # Numbered SQL migrations (never edit applied ones)
│   │   ├── 0001_schema.sql       # Tables: orgs, profiles, org_members, projects,
│   │   │                         #   locations, punch_items, punch_item_events, photos
│   │   ├── 0002_rls.sql          # Row-level security policies
│   │   └── 0003_rls_fixes.sql    # RLS hardening (trigger holes, explicit grants)
│   ├── tests/
│   │   └── rls.test.sql          # pgTAP RLS security tests
│   └── config.toml               # Supabase local stack config
├── powersync/
│   └── sync-rules.yaml           # PowerSync bucket definitions (deployed to service, not bundled)
├── tests/
│   └── unit/
│       └── status.test.ts        # Vitest unit tests for domain rules
├── docs/
│   └── superpowers/
│       ├── specs/                # Design specs (2026-06-10-punchlist-design.md)
│       └── plans/                # Implementation plans (Plan 1 complete, Plan 2 written)
├── CLAUDE.md                     # Project guidance for Claude Code
├── AGENTS.md                     # Next.js version warning for agents
├── package.json                  # npm scripts: dev, build, lint, test, verify
├── tsconfig.json                 # Strict mode, @/* → src/* alias
├── vitest.config.ts              # Unit test config (tests/unit/**/*.test.ts)
└── next.config.ts                # Next.js config (minimal)
```

## Key Locations

| What | Where |
|------|-------|
| Domain business rules | `src/lib/domain/status.ts` |
| Local DB schema | `src/lib/powersync/schema.ts` |
| DB instance / connect | `src/lib/powersync/db.ts` |
| Upload connector | `src/lib/powersync/connector.ts` |
| React data provider | `src/app/providers.tsx` |
| Auth session refresh | `src/middleware.ts` → `src/lib/supabase/middleware.ts` |
| Postgres schema | `supabase/migrations/0001_schema.sql` |
| RLS policies | `supabase/migrations/0002_rls.sql`, `0003_rls_fixes.sql` |
| RLS tests | `supabase/tests/rls.test.sql` |
| Sync rules | `powersync/sync-rules.yaml` |
| Unit tests | `tests/unit/status.test.ts` |
| Design spec | `docs/superpowers/specs/2026-06-10-punchlist-design.md` |
| Implementation plans | `docs/superpowers/plans/` |

## Naming Conventions

- **Migrations:** numbered `supabase/migrations/000N_*.sql` — add new ones, never edit applied ones
- **Route groups:** Next.js parenthesized groups, e.g. `src/app/(app)/` for authenticated pages
- **Tests:** `tests/unit/<module>.test.ts` mirrors `src/lib/domain/<module>.ts`
- **Path alias:** `@/*` resolves to `src/*` (used in all imports)
- **Files:** lowercase, kebab/flat names; React pages are `page.tsx` per App Router convention

## Where to Add New Code

- **New business rule:** pure function in `src/lib/domain/`, unit test in `tests/unit/`
- **New table/column:** new numbered migration in `supabase/migrations/`, mirror in `src/lib/powersync/schema.ts`, RLS policy + test in `supabase/tests/rls.test.sql`, bucket update in `powersync/sync-rules.yaml`
- **New page:** `src/app/(app)/<route>/page.tsx` for authenticated views
- **New access-control change:** touches all three layers — RLS migration, sync rules, client transition rules (`src/lib/domain/status.ts`)

---

*Structure analysis: 2026-06-12*
