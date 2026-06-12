# Punchlist

## What This Is

Punchlist is an offline-first construction punch list PWA for general contractors. A GC/super walks the job site with a phone, logs defects with photos organized by project and location, and assigns them to subcontractors with due dates; subs see only their assigned items, fix them, and mark them done with proof photos; the GC verifies on the next walk. Built for one GC company at launch (internal tool), architected multi-tenant from day one so it can become a SaaS product without rework.

## Core Value

Every core field workflow — logging a defect with a photo, assigning it, marking it done, verifying it — works with zero connectivity and syncs correctly when the network returns.

## Requirements

### Validated

<!-- Inferred from existing code (Plan 1 complete, commit history through 1a2cf10) -->

- ✓ Offline-first data layer: all UI reads/writes go to in-browser SQLite (PowerSync), never directly to Supabase — existing (`src/lib/powersync/`)
- ✓ Bidirectional sync: PowerSync download via `powersync/sync-rules.yaml` buckets, upload via `SupabaseConnector` with permanent-rejection discard so the queue never wedges — existing
- ✓ Auth with session refresh middleware and `/login` redirect — existing (`src/middleware.ts`, `src/lib/supabase/`)
- ✓ Multi-tenant schema with `org_id` on all tables; roles `admin`/`member`/`sub` — existing (`supabase/migrations/0001_schema.sql`)
- ✓ Three-layer access control: Postgres RLS (pgTAP-tested), PowerSync sync rules, client transition rules — existing
- ✓ Status domain rules in pure TS: `open → in_progress → done → verified`, subs cannot verify/kick back, stage-precedence conflict resolution — existing (`src/lib/domain/status.ts`, unit-tested)
- ✓ Project list + creation UI backed by local DB — existing (`src/app/(app)/projects/page.tsx`)

### Active

<!-- Current scope: Plan 2 (field workflows) + Plan 3 (desktop/reports/PWA/E2E) + production deployment -->

**Field workflows (Plan 2 — written, not started):**
- [ ] GC can quick-add a punch item (location, trade, description, photo, assignee) one-thumbed in under 15 seconds
- [ ] Photos capture offline with client-side compression, queue in IndexedDB, background-upload to Supabase Storage with pending-count UI feedback
- [ ] Status changes record history events, enforced server-side via `record_status_event` Postgres RPC (client rule and RPC kept equivalent)
- [ ] Punch list page per project with location grouping and filters
- [ ] Item detail page with photos, status history, and role-appropriate status actions
- [ ] Sub "My items" view; role-based home routing
- [ ] `org_member_profiles` denormalized table for offline access to names/roles

**Desktop & reporting (Plan 3 scope):**
- [ ] Desktop layout: tables, filters, bulk actions over punch items
- [ ] Formatted PDF reports generated server-side (Next.js API route on Vercel)
- [ ] Reports emailed to subs/owners via transactional email (Resend)
- [ ] PWA: installable, service worker offline shell — app opens offline without a login wall
- [ ] Admin can invite users by email and assign roles (invitation-only, no self-signup)
- [ ] E2E test coverage of golden paths

**Production:**
- [ ] Deployed and live: Supabase project + PowerSync instance configured, app on Vercel, usable by a real crew

### Out of Scope

- Billing / subscriptions — internal tool at launch; SaaS conversion deferred without architectural regret (multi-tenant schema already in place)
- Self-signup — invitation-only in v1 per spec
- Push notifications — deferrable; sync-on-open is sufficient for v1 field use
- In-app messaging — kick-back notes cover the v1 communication need
- Floor-plan pin drops — location text/grouping is sufficient for v1
- CSV import — no migration need for launch org
- Native app stores — PWA covers phone install; one codebase is a core architecture decision

## Context

- **Stack:** Next.js 16 (App Router) + TypeScript strict + Tailwind v4 on Vercel; Supabase (Postgres source of truth, Auth, Storage, RLS); PowerSync sync service; in-browser SQLite via wa-sqlite.
- **State:** Plan 1 (foundation) is complete and committed. Plan 2 (field workflows) is fully written as a 10-task implementation plan at `docs/superpowers/plans/2026-06-11-punchlist-field-workflows.md` — it should be mined for phase planning, not re-derived. Design spec: `docs/superpowers/specs/2026-06-10-punchlist-design.md`.
- **Codebase map:** `.planning/codebase/` (7 docs, analyzed 2026-06-12). Key concerns tracked there: middleware login wall vs. offline-open requirement (resolved by Plan 3 service worker), no error tracking, no CI pipeline.
- **The core invariant:** UI never reads/writes Supabase directly for app data. A change to who-can-see/do-what touches all three access-control layers (RLS migrations + sync rules + client transition rules) and each RLS change needs a pgTAP case in `supabase/tests/rls.test.sql`.

## Constraints

- **Tech stack**: Next.js + Supabase + PowerSync locked in — Plan 1 foundation built on it; spec explicitly chose it over Expo/custom sync
- **Security**: RLS tests are a requirement — any RLS change ships with a corresponding pgTAP case
- **Migrations**: numbered `supabase/migrations/000N_*.sql`, append-only — never edit applied migrations
- **Offline**: every core field workflow must work with zero connectivity — drives all data-layer decisions
- **Quality gate**: `npm run verify` (lint + tsc + vitest + build) must pass before committing; `npx supabase test db` for RLS changes
- **Sync storage bound**: closed projects excluded from sync to bound phone storage

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Next.js PWA + PowerSync over native Expo or hand-rolled sync | One codebase for phone + desktop; purpose-built sync engine instead of bug-prone custom sync | ✓ Good (Plan 1 validated) |
| Multi-tenant `org_id` from day one | SaaS conversion without rework | ✓ Good |
| Status conflicts resolve by stage precedence (never downgrade) | Stale offline writes must not undo field progress | ✓ Good (unit + pgTAP tested) |
| Permanent upload rejections discarded, transient retried | Upload queue must never wedge; server state re-syncs down | ✓ Good |
| Status enforcement moves server-side (`record_status_event` RPC) in Plan 2 | Client-only rules are bypassable; client + RPC kept equivalent | — Pending |
| PDF generation server-side on Vercel, emailed via Resend | Consistent output; emailing implies connectivity, so online-only is acceptable | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-06-12 after initialization*
