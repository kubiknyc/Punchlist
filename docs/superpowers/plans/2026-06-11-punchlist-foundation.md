# Punchlist Plan 1: Foundation & Offline Data Core

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A deployable Next.js app where a user can log in, create projects and punch items while fully offline, and have them sync to Supabase Postgres via PowerSync.

**Architecture:** Next.js (App Router) PWA on Vercel; Supabase for Postgres/Auth/RLS; PowerSync keeps an in-browser SQLite that the UI reads/writes exclusively, syncing bidirectionally with Postgres. Business rules (status transitions, conflict precedence) live in a pure TypeScript module shared by UI and sync code.

**Tech Stack:** Next.js 15 + TypeScript + Tailwind, Supabase (`@supabase/supabase-js`, `@supabase/ssr`), PowerSync (`@powersync/web`, `@powersync/react`), Vitest, pgTAP (via `supabase test db`).

**Spec:** `docs/superpowers/specs/2026-06-10-punchlist-design.md`

**Follow-up plans (not in this document):** Plan 2 (field workflows: punch list UI, quick-add, photos, sub view), Plan 3 (office: desktop table, PDF, email, invites, E2E).

---

## File structure created by this plan

```
src/
  lib/
    domain/status.ts            # status transition + conflict rules (pure TS)
    supabase/client.ts          # browser Supabase client
    supabase/middleware.ts      # session refresh helper
    powersync/schema.ts         # client-side SQLite schema
    powersync/connector.ts      # PowerSync <-> Supabase upload/credentials
    powersync/db.ts             # PowerSyncDatabase singleton + provider
  app/
    login/page.tsx              # email/password login
    (app)/projects/page.tsx     # project list + create (offline-capable)
    layout.tsx                  # root layout wrapping PowerSync provider
  middleware.ts                 # Next.js auth middleware
supabase/
  migrations/0001_schema.sql
  migrations/0002_rls.sql
  tests/rls.test.sql
powersync/sync-rules.yaml       # deployed to PowerSync service (not bundled)
tests/unit/status.test.ts
```

---

### Task 1: Scaffold the Next.js app

**Files:**
- Create: entire Next.js scaffold at repo root (`package.json`, `src/app/*`, configs)

- [ ] **Step 1: Scaffold into a temp dir and copy in (create-next-app refuses dirs containing `docs/`)**

```bash
cd /tmp && npx create-next-app@latest punchlist-scaffold \
  --typescript --tailwind --eslint --app --src-dir --import-alias "@/*" --no-turbopack --use-npm --yes
cp -rn /tmp/punchlist-scaffold/. /home/user/Punchlist/
cd /home/user/Punchlist && rm -rf /tmp/punchlist-scaffold
```

- [ ] **Step 2: Install runtime + test dependencies**

```bash
npm i @supabase/supabase-js @supabase/ssr @powersync/web @powersync/react @journeyapps/wa-sqlite
npm i -D vitest
```

- [ ] **Step 3: Add Vitest config and test script**

Create `vitest.config.ts`:

```ts
import { defineConfig } from 'vitest/config';
export default defineConfig({
  test: { include: ['tests/unit/**/*.test.ts'] },
});
```

In `package.json` scripts, add: `"test": "vitest run"`.

- [ ] **Step 4: Verify the app builds**

Run: `npm run build`
Expected: build completes with no errors.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "chore: scaffold Next.js app with Tailwind, Vitest, Supabase and PowerSync deps"
```

---

### Task 2: Database schema migration

**Files:**
- Create: `supabase/migrations/0001_schema.sql`

- [ ] **Step 1: Initialize Supabase locally**

```bash
npx supabase init
npx supabase start
```

Expected: local stack starts; note the printed `API URL` and `anon key` for `.env.local` later.

- [ ] **Step 2: Write the schema migration**

Create `supabase/migrations/0001_schema.sql`:

```sql
create type org_role as enum ('admin','member','sub');
create type project_status as enum ('active','closed');
create type punch_status as enum ('open','in_progress','done','verified');

create table orgs (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);

create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  phone text,
  company_name text,
  created_at timestamptz not null default now()
);

create table org_members (
  org_id uuid not null references orgs(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  role org_role not null,
  created_at timestamptz not null default now(),
  primary key (org_id, user_id)
);

create table projects (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references orgs(id) on delete cascade,
  name text not null,
  address text,
  status project_status not null default 'active',
  created_at timestamptz not null default now()
);

create table locations (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references orgs(id) on delete cascade,
  project_id uuid not null references projects(id) on delete cascade,
  parent_id uuid references locations(id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now()
);

create table punch_items (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references orgs(id) on delete cascade,
  project_id uuid not null references projects(id) on delete cascade,
  location_id uuid references locations(id) on delete set null,
  title text not null,
  description text,
  trade text,
  status punch_status not null default 'open',
  priority smallint not null default 2,
  due_date date,
  assigned_to uuid references profiles(id),
  created_by uuid not null references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table punch_item_events (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references orgs(id) on delete cascade,
  item_id uuid not null references punch_items(id) on delete cascade,
  actor_id uuid not null references profiles(id),
  from_status punch_status,
  to_status punch_status not null,
  note text,
  created_at timestamptz not null default now()
);

create table photos (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references orgs(id) on delete cascade,
  item_id uuid not null references punch_items(id) on delete cascade,
  kind text not null check (kind in ('before','after')),
  storage_path text,
  uploaded_at timestamptz,
  created_by uuid not null references profiles(id),
  created_at timestamptz not null default now()
);

create index punch_items_project_idx on punch_items (project_id, status);
create index punch_items_assigned_idx on punch_items (assigned_to, status);
create index locations_project_idx on locations (project_id);
```

- [ ] **Step 3: Apply and verify**

Run: `npx supabase db reset`
Expected: migration applies cleanly; `npx supabase db lint` reports no errors.

- [ ] **Step 4: Commit**

```bash
git add supabase && git commit -m "feat: core database schema for orgs, projects, locations, punch items, photos"
```

---

### Task 3: Row-level security and sub-update enforcement

**Files:**
- Create: `supabase/migrations/0002_rls.sql`

- [ ] **Step 1: Write the RLS migration**

Create `supabase/migrations/0002_rls.sql`:

```sql
-- Helper predicates (security definer so they can read org_members under RLS)
create or replace function is_org_member(p_org uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from org_members
    where org_id = p_org and user_id = auth.uid());
$$;

create or replace function is_gc(p_org uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from org_members
    where org_id = p_org and user_id = auth.uid() and role in ('admin','member'));
$$;

alter table orgs enable row level security;
alter table profiles enable row level security;
alter table org_members enable row level security;
alter table projects enable row level security;
alter table locations enable row level security;
alter table punch_items enable row level security;
alter table punch_item_events enable row level security;
alter table photos enable row level security;

create policy orgs_select on orgs for select using (is_org_member(id));

create policy profiles_select on profiles for select using (
  id = auth.uid() or exists (
    select 1 from org_members m1
    join org_members m2 on m1.org_id = m2.org_id
    where m1.user_id = auth.uid() and m2.user_id = profiles.id)
);
create policy profiles_update_own on profiles for update using (id = auth.uid());

create policy org_members_select on org_members for select using (is_org_member(org_id));

-- GC roles: full access to org data
create policy projects_gc_all on projects for all
  using (is_gc(org_id)) with check (is_gc(org_id));
create policy locations_gc_all on locations for all
  using (is_gc(org_id)) with check (is_gc(org_id));
create policy punch_items_gc_all on punch_items for all
  using (is_gc(org_id)) with check (is_gc(org_id));
create policy events_gc_all on punch_item_events for all
  using (is_gc(org_id)) with check (is_gc(org_id));
create policy photos_gc_all on photos for all
  using (is_gc(org_id)) with check (is_gc(org_id));

-- Subs: read items assigned to them, plus those items' context
create policy punch_items_sub_select on punch_items for select
  using (assigned_to = auth.uid());
create policy punch_items_sub_update on punch_items for update
  using (assigned_to = auth.uid()) with check (assigned_to = auth.uid());
create policy events_sub_select on punch_item_events for select
  using (exists (select 1 from punch_items i where i.id = item_id and i.assigned_to = auth.uid()));
create policy events_sub_insert on punch_item_events for insert
  with check (actor_id = auth.uid() and exists
    (select 1 from punch_items i where i.id = item_id and i.assigned_to = auth.uid()));
create policy photos_sub_select on photos for select
  using (exists (select 1 from punch_items i where i.id = item_id and i.assigned_to = auth.uid()));
create policy photos_sub_insert on photos for insert
  with check (created_by = auth.uid() and exists
    (select 1 from punch_items i where i.id = item_id and i.assigned_to = auth.uid()));
create policy locations_sub_select on locations for select
  using (exists (select 1 from punch_items i where i.location_id = locations.id and i.assigned_to = auth.uid()));
create policy projects_sub_select on projects for select
  using (exists (select 1 from punch_items i where i.project_id = projects.id and i.assigned_to = auth.uid()));

-- Subs may only change status, and only along open -> in_progress -> done.
create or replace function enforce_sub_item_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if is_gc(old.org_id) then return new; end if;
  -- sub path: every column except status must be unchanged
  if row(new.title, new.description, new.trade, new.priority, new.due_date,
         new.assigned_to, new.location_id, new.project_id, new.org_id, new.created_by)
     is distinct from
     row(old.title, old.description, old.trade, old.priority, old.due_date,
         old.assigned_to, old.location_id, old.project_id, old.org_id, old.created_by) then
    raise exception 'subs may only change status';
  end if;
  if not (old.status, new.status) in
     (('open','in_progress'),('in_progress','done'),('open','done'),
      ('in_progress','open'),(old.status, old.status)) then
    raise exception 'invalid status transition for sub: % -> %', old.status, new.status;
  end if;
  new.updated_at = now();
  return new;
end;
$$;

create trigger punch_items_sub_guard before update on punch_items
  for each row execute function enforce_sub_item_update();
```

- [ ] **Step 2: Apply migration**

Run: `npx supabase db reset`
Expected: applies cleanly.

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations && git commit -m "feat: RLS policies and sub status-transition guard"
```

---

### Task 4: RLS tests (pgTAP)

**Files:**
- Create: `supabase/tests/rls.test.sql`

- [ ] **Step 1: Write the failing tests**

Create `supabase/tests/rls.test.sql`:

```sql
begin;
select plan(4);

-- Seed: two orgs, one GC user, two subs
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'gc@test.dev'),
  ('00000000-0000-0000-0000-0000000000b1', 'sub1@test.dev'),
  ('00000000-0000-0000-0000-0000000000b2', 'sub2@test.dev');
insert into profiles (id, full_name) values
  ('00000000-0000-0000-0000-0000000000a1', 'GC'),
  ('00000000-0000-0000-0000-0000000000b1', 'Sub One'),
  ('00000000-0000-0000-0000-0000000000b2', 'Sub Two');
insert into orgs (id, name) values ('00000000-0000-0000-0000-00000000aaaa', 'Acme GC');
insert into org_members (org_id, user_id, role) values
  ('00000000-0000-0000-0000-00000000aaaa', '00000000-0000-0000-0000-0000000000a1', 'member'),
  ('00000000-0000-0000-0000-00000000aaaa', '00000000-0000-0000-0000-0000000000b1', 'sub'),
  ('00000000-0000-0000-0000-00000000aaaa', '00000000-0000-0000-0000-0000000000b2', 'sub');
insert into projects (id, org_id, name) values
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000aaaa', 'Tower A');
insert into punch_items (id, org_id, project_id, title, assigned_to, created_by) values
  ('00000000-0000-0000-0000-000000001101', '00000000-0000-0000-0000-00000000aaaa',
   '00000000-0000-0000-0000-000000000001', 'Fix drywall',
   '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-000000001102', '00000000-0000-0000-0000-00000000aaaa',
   '00000000-0000-0000-0000-000000000001', 'Paint touch-up',
   '00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000a1');

-- As GC: sees both items
set local role authenticated;
set local "request.jwt.claims" to '{"sub":"00000000-0000-0000-0000-0000000000a1"}';
select is((select count(*) from punch_items), 2::bigint, 'GC sees all org items');

-- As sub1: sees only own item
set local "request.jwt.claims" to '{"sub":"00000000-0000-0000-0000-0000000000b1"}';
select is((select count(*) from punch_items), 1::bigint, 'sub sees only assigned items');
select is((select title from punch_items), 'Fix drywall', 'sub sees the right item');

-- As sub1: cannot reassign own item (only status changes allowed)
select throws_ok(
  $$ update punch_items set assigned_to = '00000000-0000-0000-0000-0000000000b2'
     where id = '00000000-0000-0000-0000-000000001101' $$,
  'subs may only change status');

select * from finish();
rollback;
```

- [ ] **Step 2: Run the tests**

Run: `npx supabase test db`
Expected: 4/4 pass. If a policy is wrong this catches it now, not in production.

- [ ] **Step 3: Commit**

```bash
git add supabase/tests && git commit -m "test: pgTAP RLS tests for GC/sub visibility and sub update guard"
```

---

### Task 5: Status rules module (TDD)

**Files:**
- Create: `src/lib/domain/status.ts`
- Test: `tests/unit/status.test.ts`

- [ ] **Step 1: Write the failing tests**

Create `tests/unit/status.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { canTransition, resolveStatusConflict, STATUS_ORDER } from '@/lib/domain/status';

describe('canTransition', () => {
  it('lets subs walk open -> in_progress -> done', () => {
    expect(canTransition('sub', 'open', 'in_progress')).toBe(true);
    expect(canTransition('sub', 'in_progress', 'done')).toBe(true);
    expect(canTransition('sub', 'open', 'done')).toBe(true);
  });
  it('blocks subs from verifying or un-verifying', () => {
    expect(canTransition('sub', 'done', 'verified')).toBe(false);
    expect(canTransition('sub', 'verified', 'open')).toBe(false);
  });
  it('lets GC roles verify and kick back', () => {
    expect(canTransition('member', 'done', 'verified')).toBe(true);
    expect(canTransition('admin', 'done', 'open')).toBe(true);
    expect(canTransition('member', 'verified', 'open')).toBe(true);
  });
});

describe('resolveStatusConflict', () => {
  it('keeps the later-stage status', () => {
    expect(resolveStatusConflict('done', 'verified')).toBe('verified');
    expect(resolveStatusConflict('verified', 'in_progress')).toBe('verified');
    expect(resolveStatusConflict('open', 'open')).toBe('open');
  });
});

describe('STATUS_ORDER', () => {
  it('orders all four statuses', () => {
    expect(Object.keys(STATUS_ORDER)).toHaveLength(4);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm test`
Expected: FAIL — `Cannot find module '@/lib/domain/status'`.

- [ ] **Step 3: Implement**

Create `src/lib/domain/status.ts`:

```ts
export type PunchStatus = 'open' | 'in_progress' | 'done' | 'verified';
export type Role = 'admin' | 'member' | 'sub';

export const STATUS_ORDER: Record<PunchStatus, number> = {
  open: 0,
  in_progress: 1,
  done: 2,
  verified: 3,
};

const SUB_TRANSITIONS: ReadonlySet<string> = new Set([
  'open>in_progress',
  'in_progress>done',
  'open>done',
  'in_progress>open',
]);

export function canTransition(role: Role, from: PunchStatus, to: PunchStatus): boolean {
  if (from === to) return false;
  if (role === 'sub') return SUB_TRANSITIONS.has(`${from}>${to}`);
  return true; // GC roles may move items to any other status (verify, kick back, reopen)
}

/** Offline conflict rule from the spec: a later-stage status is never downgraded by a stale write. */
export function resolveStatusConflict(a: PunchStatus, b: PunchStatus): PunchStatus {
  return STATUS_ORDER[a] >= STATUS_ORDER[b] ? a : b;
}
```

If `@/` doesn't resolve in Vitest, add to `vitest.config.ts`:

```ts
import path from 'node:path';
// inside defineConfig:
resolve: { alias: { '@': path.resolve(__dirname, 'src') } },
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/lib/domain tests vitest.config.ts
git commit -m "feat: status transition rules and offline conflict precedence"
```

---

### Task 6: Supabase auth (login + session middleware)

**Files:**
- Create: `src/lib/supabase/client.ts`, `src/lib/supabase/middleware.ts`, `src/middleware.ts`, `src/app/login/page.tsx`
- Create: `.env.local` (not committed)

- [ ] **Step 1: Environment variables**

Create `.env.local` with values from `npx supabase status`:

```bash
NEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:54321
NEXT_PUBLIC_SUPABASE_ANON_KEY=<anon key from supabase status>
NEXT_PUBLIC_POWERSYNC_URL=<filled in Task 8>
```

- [ ] **Step 2: Browser client**

Create `src/lib/supabase/client.ts`:

```ts
import { createBrowserClient } from '@supabase/ssr';

export const supabase = createBrowserClient(
  process.env.NEXT_PUBLIC_SUPABASE_URL!,
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
);
```

- [ ] **Step 3: Session-refresh middleware**

Create `src/lib/supabase/middleware.ts`:

```ts
import { createServerClient } from '@supabase/ssr';
import { NextResponse, type NextRequest } from 'next/server';

export async function updateSession(request: NextRequest) {
  let response = NextResponse.next({ request });
  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll: () => request.cookies.getAll(),
        setAll: (cookies) => {
          cookies.forEach(({ name, value }) => request.cookies.set(name, value));
          response = NextResponse.next({ request });
          cookies.forEach(({ name, value, options }) =>
            response.cookies.set(name, value, options));
        },
      },
    },
  );
  const { data: { user } } = await supabase.auth.getUser();
  const isLogin = request.nextUrl.pathname.startsWith('/login');
  if (!user && !isLogin) {
    return NextResponse.redirect(new URL('/login', request.url));
  }
  return response;
}
```

Create `src/middleware.ts`:

```ts
import { type NextRequest } from 'next/server';
import { updateSession } from '@/lib/supabase/middleware';

export async function middleware(request: NextRequest) {
  return updateSession(request);
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico|manifest.json|.*\\.(?:svg|png|jpg|ico|wasm)$).*)'],
};
```

> Offline note (spec requirement): middleware only runs when the network serves the page. The PWA shell (Plan 3) serves cached pages offline, and PowerSync reads local SQLite — so an expired-cookie redirect never blocks offline use.

- [ ] **Step 4: Login page**

Create `src/app/login/page.tsx`:

```tsx
'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { supabase } from '@/lib/supabase/client';

export default function LoginPage() {
  const router = useRouter();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) { setError(error.message); return; }
    router.push('/projects');
    router.refresh();
  }

  return (
    <main className="mx-auto flex min-h-dvh max-w-sm flex-col justify-center gap-4 p-6">
      <h1 className="text-2xl font-bold">Punchlist</h1>
      <form onSubmit={onSubmit} className="flex flex-col gap-3">
        <input className="rounded border p-3" type="email" placeholder="Email"
          value={email} onChange={(e) => setEmail(e.target.value)} required />
        <input className="rounded border p-3" type="password" placeholder="Password"
          value={password} onChange={(e) => setPassword(e.target.value)} required />
        {error && <p className="text-sm text-red-600">{error}</p>}
        <button className="rounded bg-black p-3 font-semibold text-white" type="submit">
          Sign in
        </button>
      </form>
    </main>
  );
}
```

- [ ] **Step 5: Seed a test user and verify login manually**

```bash
npx supabase db reset
# create a user via the local dashboard (npx supabase status -> Studio URL) or:
curl -s -X POST "http://127.0.0.1:54321/auth/v1/admin/users" \
  -H "apikey: $(npx supabase status -o json | jq -r .SERVICE_ROLE_KEY)" \
  -H "Authorization: Bearer $(npx supabase status -o json | jq -r .SERVICE_ROLE_KEY)" \
  -H "Content-Type: application/json" \
  -d '{"email":"gc@test.dev","password":"test1234","email_confirm":true}'
npm run dev
```

Expected: visiting `http://localhost:3000` redirects to `/login`; signing in as `gc@test.dev` lands on `/projects` (404 until Task 9 — that's fine).

- [ ] **Step 6: Commit**

```bash
git add src .gitignore && git commit -m "feat: Supabase email/password auth with session middleware"
```

---

### Task 7: PowerSync client schema

**Files:**
- Create: `src/lib/powersync/schema.ts`

- [ ] **Step 1: Write the client schema (SQLite mirrors of synced tables)**

Create `src/lib/powersync/schema.ts`:

```ts
import { column, Schema, Table } from '@powersync/web';

const projects = new Table({
  org_id: column.text,
  name: column.text,
  address: column.text,
  status: column.text,
  created_at: column.text,
});

const locations = new Table({
  org_id: column.text,
  project_id: column.text,
  parent_id: column.text,
  name: column.text,
  created_at: column.text,
});

const punch_items = new Table({
  org_id: column.text,
  project_id: column.text,
  location_id: column.text,
  title: column.text,
  description: column.text,
  trade: column.text,
  status: column.text,
  priority: column.integer,
  due_date: column.text,
  assigned_to: column.text,
  created_by: column.text,
  created_at: column.text,
  updated_at: column.text,
});

const punch_item_events = new Table({
  org_id: column.text,
  item_id: column.text,
  actor_id: column.text,
  from_status: column.text,
  to_status: column.text,
  note: column.text,
  created_at: column.text,
});

const photos = new Table({
  org_id: column.text,
  item_id: column.text,
  kind: column.text,
  storage_path: column.text,
  uploaded_at: column.text,
  created_by: column.text,
  created_at: column.text,
});

export const AppSchema = new Schema({
  projects, locations, punch_items, punch_item_events, photos,
});

export type Database = (typeof AppSchema)['types'];
```

- [ ] **Step 2: Verify it typechecks**

Run: `npx tsc --noEmit`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add src/lib/powersync && git commit -m "feat: PowerSync client schema for synced tables"
```

---

### Task 8: PowerSync connector, database singleton, and sync rules

**Files:**
- Create: `src/lib/powersync/connector.ts`, `src/lib/powersync/db.ts`, `powersync/sync-rules.yaml`
- Modify: `src/app/layout.tsx`

- [ ] **Step 1: Write the Supabase connector**

Create `src/lib/powersync/connector.ts`:

```ts
import {
  AbstractPowerSyncDatabase,
  PowerSyncBackendConnector,
  UpdateType,
} from '@powersync/web';
import { supabase } from '@/lib/supabase/client';

export class SupabaseConnector implements PowerSyncBackendConnector {
  async fetchCredentials() {
    const { data } = await supabase.auth.getSession();
    if (!data.session) return null;
    return {
      endpoint: process.env.NEXT_PUBLIC_POWERSYNC_URL!,
      token: data.session.access_token,
    };
  }

  async uploadData(database: AbstractPowerSyncDatabase) {
    const tx = await database.getNextCrudTransaction();
    if (!tx) return;
    try {
      for (const op of tx.crud) {
        const table = supabase.from(op.table);
        if (op.op === UpdateType.PUT) {
          const { error } = await table.upsert({ id: op.id, ...op.opData });
          if (error) throw error;
        } else if (op.op === UpdateType.PATCH) {
          const { error } = await table.update(op.opData!).eq('id', op.id);
          if (error) throw error;
        } else if (op.op === UpdateType.DELETE) {
          const { error } = await table.delete().eq('id', op.id);
          if (error) throw error;
        }
      }
      await tx.complete();
    } catch (e: unknown) {
      // Permanent rejections (RLS denial, constraint violation) must not wedge
      // the upload queue: discard the local op; server state re-syncs down.
      const code = (e as { code?: string })?.code ?? '';
      if (['42501', '23505', '23503', 'P0001'].includes(code)) {
        console.error('Discarding rejected local write', e);
        await tx.complete();
      } else {
        throw e; // transient (network) — PowerSync retries
      }
    }
  }
}
```

- [ ] **Step 2: Database singleton + React provider**

Create `src/lib/powersync/db.ts`:

```ts
'use client';
import { PowerSyncDatabase } from '@powersync/web';
import { AppSchema } from './schema';
import { SupabaseConnector } from './connector';

export const db = new PowerSyncDatabase({
  schema: AppSchema,
  database: { dbFilename: 'punchlist.db' },
});

let connected = false;
export async function connectPowerSync() {
  if (connected) return;
  connected = true;
  await db.connect(new SupabaseConnector());
}
```

Modify `src/app/layout.tsx` to wrap children with the PowerSync context (client component wrapper):

Create `src/app/providers.tsx`:

```tsx
'use client';
import { useEffect } from 'react';
import { PowerSyncContext } from '@powersync/react';
import { db, connectPowerSync } from '@/lib/powersync/db';

export function Providers({ children }: { children: React.ReactNode }) {
  useEffect(() => { void connectPowerSync(); }, []);
  return <PowerSyncContext.Provider value={db}>{children}</PowerSyncContext.Provider>;
}
```

In `src/app/layout.tsx`, wrap `{children}` with `<Providers>` (import from `./providers`).

- [ ] **Step 3: Write sync rules (deployed to the PowerSync service)**

Create `powersync/sync-rules.yaml`:

```yaml
bucket_definitions:
  # GC roles get the whole org
  gc_org:
    parameters: >
      select org_id from org_members
      where user_id = request.user_id() and role in ('admin','member')
    data:
      - select * from projects where org_id = bucket.org_id
      - select * from locations where org_id = bucket.org_id
      - select * from punch_items where org_id = bucket.org_id
      - select * from punch_item_events where org_id = bucket.org_id
      - select * from photos where org_id = bucket.org_id

  # Subs get only their assigned items and those items' context
  sub_items:
    parameters: >
      select id as item_id, project_id, location_id from punch_items
      where assigned_to = request.user_id()
    data:
      - select * from punch_items where id = bucket.item_id
      - select * from punch_item_events where item_id = bucket.item_id
      - select * from photos where item_id = bucket.item_id
      - select * from projects where id = bucket.project_id
      - select * from locations where id = bucket.location_id
```

- [ ] **Step 4: Set up the PowerSync instance**

Manual step (document the outcome in the commit message):
1. Create a free PowerSync Cloud instance at https://powersync.journeyapps.com (or self-host later).
2. Point it at the Supabase Postgres connection (PowerSync docs: "Supabase + PowerSync" integration guide — it uses the Supabase JWT secret to validate tokens).
3. Paste `powersync/sync-rules.yaml` into the instance's sync rules and deploy.
4. Put the instance URL in `.env.local` as `NEXT_PUBLIC_POWERSYNC_URL`.

For local-only development before the cloud instance exists, the app still works: PowerSync reads/writes local SQLite and queues uploads; `connect()` simply retries in the background.

- [ ] **Step 5: Verify build and typecheck**

Run: `npm run build`
Expected: success. (`@powersync/web` needs WASM assets; if the build complains, copy `node_modules/@journeyapps/wa-sqlite/dist/*.wasm` handling per PowerSync's Next.js guide — add `serwist`/`copy-webpack-plugin` config exactly as their docs show.)

- [ ] **Step 6: Commit**

```bash
git add src powersync && git commit -m "feat: PowerSync database, Supabase connector, and sync rules"
```

---

### Task 9: Projects page proving the offline loop

**Files:**
- Create: `src/app/(app)/projects/page.tsx`

- [ ] **Step 1: Build the projects list + create form against local SQLite**

Create `src/app/(app)/projects/page.tsx`:

```tsx
'use client';
import { useState } from 'react';
import { useQuery, useStatus } from '@powersync/react';
import { db } from '@/lib/powersync/db';
import { supabase } from '@/lib/supabase/client';

export default function ProjectsPage() {
  const status = useStatus();
  const { data: projects } = useQuery<{ id: string; name: string; status: string }>(
    `select id, name, status from projects where status = 'active' order by created_at desc`,
  );
  const [name, setName] = useState('');

  async function createProject(e: React.FormEvent) {
    e.preventDefault();
    const { data } = await supabase.auth.getUser();
    const userId = data.user?.id;
    if (!userId || !name.trim()) return;
    // org_id: single-org v1 — first membership row synced locally
    const orgRow = await db.get<{ org_id: string }>(
      `select org_id from projects limit 1`,
    ).catch(() => null);
    const orgId = orgRow?.org_id ?? (await fetchOrgId(userId));
    await db.execute(
      `insert into projects (id, org_id, name, status, created_at)
       values (uuid(), ?, ?, 'active', datetime('now'))`,
      [orgId, name.trim()],
    );
    setName('');
  }

  return (
    <main className="mx-auto max-w-lg p-4">
      {!status.connected && (
        <p className="mb-2 rounded bg-amber-100 p-2 text-sm">
          Offline — changes will sync
        </p>
      )}
      <h1 className="mb-4 text-xl font-bold">Projects</h1>
      <form onSubmit={createProject} className="mb-4 flex gap-2">
        <input className="flex-1 rounded border p-2" placeholder="New project name"
          value={name} onChange={(e) => setName(e.target.value)} />
        <button className="rounded bg-black px-4 text-white" type="submit">Add</button>
      </form>
      <ul className="divide-y">
        {projects.map((p) => (
          <li key={p.id} className="p-3">{p.name}</li>
        ))}
      </ul>
    </main>
  );
}

async function fetchOrgId(userId: string): Promise<string> {
  const { data, error } = await supabase
    .from('org_members').select('org_id').eq('user_id', userId).limit(1).single();
  if (error || !data) throw new Error('No org membership found');
  return data.org_id;
}
```

> `org_members` is not synced to the client, so the first project creation needs one online lookup; afterwards `org_id` comes from local data. Plan 2 replaces this with a synced `org_members` bucket.

- [ ] **Step 2: Seed org membership for the test user**

In local Studio SQL editor (or `npx supabase db query`):

```sql
insert into profiles (id, full_name)
  select id, 'GC Test' from auth.users where email = 'gc@test.dev'
  on conflict do nothing;
insert into orgs (id, name) values ('11111111-1111-1111-1111-111111111111', 'My GC Co')
  on conflict do nothing;
insert into org_members (org_id, user_id, role)
  select '11111111-1111-1111-1111-111111111111', id, 'admin'
  from auth.users where email = 'gc@test.dev'
  on conflict do nothing;
```

- [ ] **Step 3: Verify the offline loop manually**

1. `npm run dev`, log in, create a project — appears instantly (local write).
2. DevTools → Network → set **Offline**. Create another project — still appears instantly, banner shows "Offline — changes will sync".
3. Go back online. Check Supabase Studio → `projects` table: both rows present.

Expected: both projects exist in Postgres; no errors in console.

- [ ] **Step 4: Commit**

```bash
git add src/app && git commit -m "feat: offline-capable projects page over PowerSync"
```

---

### Task 10: Wire up CI-runnable verification

**Files:**
- Modify: `package.json`

- [ ] **Step 1: Add a single verify script**

In `package.json` scripts:

```json
"verify": "npm run lint && npx tsc --noEmit && npm test && npm run build"
```

- [ ] **Step 2: Run it**

Run: `npm run verify`
Expected: lint, typecheck, unit tests, and build all pass.

- [ ] **Step 3: Commit**

```bash
git add package.json && git commit -m "chore: add verify script (lint + typecheck + test + build)"
```

---

## Definition of done for Plan 1

- `npm run verify` passes.
- `npx supabase test db` passes (RLS tests).
- Manual offline loop (Task 9 Step 3) demonstrated: project created offline reaches Postgres after reconnect.
- All work committed to `claude/affectionate-dirac-x2hcqe`.

## Deferred to Plan 2 / Plan 3 (explicitly not here)

- Punch item UI, quick-add flow, camera/photos, sub "My items" (Plan 2)
- Synced `org_members` bucket replacing the `fetchOrgId` online lookup (Plan 2)
- Desktop table, PDF reports, Resend email, invitations, PWA manifest/service worker, Playwright E2E (Plan 3)
