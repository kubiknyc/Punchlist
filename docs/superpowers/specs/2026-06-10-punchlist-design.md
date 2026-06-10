# Punchlist — Design Spec

**Date:** 2026-06-10
**Status:** Approved for implementation planning

## Summary

Punchlist is a construction punch list app for general contractors. A GC/super
walks the job site with a phone, logs defects with photos organized by project
and location, and assigns them to subcontractors with due dates. Subs log in to
see their assigned items, fix them, and mark them done with proof photos; the
GC verifies fixes on the next walk. Formatted PDF reports go to subs and
owners. The app is fully offline-first — every core workflow works without
connectivity and syncs when it returns.

**Audience:** one GC company at launch (internal tool), architected as
multi-tenant from day one so it can become a SaaS product without rework.

## Users & roles

| Role | Who | Access |
|---|---|---|
| `admin` | GC owner/office | Everything: manage projects, invite/remove people |
| `member` | GC supers & PMs | Full access to all projects in the org |
| `sub` | Subcontractor | Only punch items assigned to them (plus those items' photos/locations) |

- Invitation-only: an admin invites users by email and picks their role. No
  self-signup in v1.
- Subs can move their items `open → in_progress → done`. Only GC roles
  (`admin`/`member`) can mark `verified` or kick an item back to `open` with a
  note.

## Architecture

**Approach:** Next.js PWA + Supabase + PowerSync (chosen over hand-rolled sync
and over a native Expo app: one codebase for phone and desktop, and a
purpose-built sync engine instead of bug-prone custom sync).

- **Frontend:** Next.js (App Router) + TypeScript + Tailwind, deployed on
  Vercel. Installable as a PWA (home-screen icon, offline shell).
- **Local data:** PowerSync in-browser SQLite. All app reads/writes go to the
  local DB; the UI never waits on the network.
- **Backend:** Supabase — Postgres (source of truth), Auth (email/password +
  magic links), Storage (photos), Row-Level Security for tenant and role
  isolation.
- **Sync:** PowerSync service between local SQLite and Postgres. Sync rules
  mirror RLS: GC roles download their org's data; subs download only their
  assigned items. Uploads replay local mutations in order.
- **Photos:** captured locally as queued attachments; a background uploader
  pushes to Supabase Storage when online and swaps the local reference for a
  Storage URL.
- **PDF reports:** generated server-side by a Next.js API route on Vercel
  (same deploy as the app) for consistent output; emailed via a transactional
  email provider (Resend). Requires connectivity — acceptable, since emailing
  a report implies being online.

One responsive web app: phone layout is the field tool, desktop layout adds
tables, filters, bulk actions, and reports. No second codebase.

## Data model

All tables carry `org_id` for tenancy. Seven tables:

- **orgs** — the GC company. One row at launch; SaaS later means more rows.
- **profiles** — one per user (extends Supabase auth): name, phone, company
  name (for subs, e.g. "Apex Plumbing").
- **org_members** — user ↔ org with role: `admin` | `member` | `sub`.
- **projects** — name, address, status (`active` | `closed`).
- **locations** — per project; two-level hierarchy (e.g. "Floor 2" → "Unit
  204"). Items may attach to either level.
- **punch_items** — title, description, trade tag (plumbing, electrical,
  paint, …), status (`open → in_progress → done → verified`), priority, due
  date, `assigned_to` (a sub user), `created_by`, location, and a status
  history (timestamped status changes with actor and optional note).
- **photos** — belongs to a punch item; local-file reference until uploaded,
  then a Storage URL; flagged `before` (defect) or `after` (proof of fix).

**RLS:** GC roles see all rows in their org. Subs see only punch items where
`assigned_to` is them, plus those items' photos and locations. PowerSync sync
rules mirror RLS exactly.

## Screens & workflows

**GC/super on mobile (the site walk):**
1. Project list → project.
2. Punch list grouped by location; filters for status/trade/assignee; big "+".
3. **Quick-add** (one-thumb, < 15 seconds/item): camera first → snap → pick
   location (defaults to last used) → title → trade/assignee → save.
4. Item detail: photos, status history, **Verify** / **Kick back** buttons
   when a sub has marked the item done.

**GC/PM on desktop (the office):**
- Sortable/filterable table of all items; bulk assign and bulk due-date.
- **Reports:** pick project + filters → generate PDF → download or email.

**Sub on mobile:**
- **"My items"** — assigned items across projects, grouped by
  project/location. Item → defect photo → mark in-progress/done. An `after`
  photo is **required** to mark done.

**Invitations:** admin invites by email with a role; invitee sets a password
and lands on their home screen.

**Offline UI:** everything works offline except invitations, PDF generation,
and email. A subtle banner shows "offline — changes will sync" plus queued
photo count. No blocking spinners; no lost work.

## Edge cases & error handling

- **Sync conflicts:** last-write-wins per column, except **status**, which
  resolves by stage precedence (`verified` > `done` > `in_progress` > `open`)
  so a later-stage status is never silently downgraded by a stale offline
  write. Status history records all events.
- **Photo upload failures:** queued locally with retry + exponential backoff;
  "pending upload" badge on affected items. Client-side compression (~1600px
  max edge) before upload.
- **Auth offline:** long-lived sessions; the app opens offline without a
  login wall. If a token expires offline, local read/write continues and
  re-auth happens on reconnect.
- **Storage limits:** request persistent browser storage; closed projects are
  excluded from sync rules to keep phone storage bounded.

## Testing

- **Unit (Vitest):** status-transition rules, conflict precedence, PDF data
  assembly.
- **RLS tests (SQL):** prove a sub cannot read another sub's items — treated
  as a security requirement.
- **E2E (Playwright):** three golden paths — GC quick-add, sub done-flow, GC
  verify-flow — including offline simulation (toggle network, mutate,
  reconnect, assert sync).

## Out of scope for v1

Billing, self-signup, push notifications, in-app messaging, floor-plan pin
drops, CSV import, native app stores. All deferrable without architectural
regret.
