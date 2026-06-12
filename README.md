# Punchlist

Offline-first construction punch list app for general contractors. A GC walks the job site with a phone, logs defects with photos organized by project and location, and assigns them to subcontractors with due dates. Subs see their assigned items, fix them, and mark them done with proof photos; the GC verifies fixes on the next walk. Designed offline-first: every core workflow is built to work without connectivity and sync when it returns.

## Stack

- **Frontend:** Next.js (App Router) + TypeScript + Tailwind (PWA install + service worker planned for Plan 3)
- **Local data:** PowerSync in-browser SQLite — the UI never waits on the network
- **Backend:** Supabase (Postgres, Auth, Storage, Row-Level Security)
- **Sync:** PowerSync service between local SQLite and Postgres, with sync rules mirroring RLS

## Getting started

```bash
npm install
npm run dev
```

Open [http://localhost:3000](http://localhost:3000).

Create `.env.local` with:

```
NEXT_PUBLIC_SUPABASE_URL=...
NEXT_PUBLIC_SUPABASE_ANON_KEY=...
NEXT_PUBLIC_POWERSYNC_URL=...
```

Without `NEXT_PUBLIC_POWERSYNC_URL` the app runs local-only: data persists in the browser and writes stay queued until sync is configured.

## Development

```bash
npm run verify     # lint + typecheck + unit tests + build (run before committing)
npm test           # unit tests (Vitest)
supabase test db   # RLS security tests (pgTAP, needs local Supabase stack)
```

## Documentation

- Design spec: [`docs/superpowers/specs/2026-06-10-punchlist-design.md`](docs/superpowers/specs/2026-06-10-punchlist-design.md)
- Implementation plans: [`docs/superpowers/plans/`](docs/superpowers/plans/)
- Contributor/agent guidance: [`CLAUDE.md`](CLAUDE.md)
