# Punchlist Plan 2: Field Workflows

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A GC can walk a site and quick-add punch items with photos in under 15 seconds, a sub can see their items and mark them done with proof photos, and a GC can verify or kick back — all offline-capable, with status history that survives sync conflicts by stage precedence.

**Architecture:** All UI reads/writes go to local SQLite (PowerSync). Status changes are written locally as `punch_item_events` rows plus an optimistic item update; on upload, event inserts are routed to a `record_status_event` Postgres RPC that validates the actor, appends history, and applies the status with compare-and-set + stage-precedence conflict resolution (the Plan-1 `resolveStatusConflict` rule, now enforced server-side). Photos are captured as compressed blobs in IndexedDB plus a `photos` row; a background uploader pushes blobs to Supabase Storage and patches `storage_path`/`uploaded_at`. A denormalized `org_member_profiles` table (maintained by DB triggers) gives the client offline access to roles and member names without syncing raw `org_members`/`profiles`.

**Tech Stack:** Same as Plan 1 — Next.js 16 + TypeScript + Tailwind, Supabase, PowerSync (`@powersync/web`, `@powersync/react`), Vitest, pgTAP.

**Spec:** `docs/superpowers/specs/2026-06-10-punchlist-design.md`
**Prior plan:** `docs/superpowers/plans/2026-06-11-punchlist-foundation.md` (Plan 1, complete)

**Deferred to Plan 3 (explicitly not here):** desktop table + bulk ops, PDF reports, Resend email, invitations, PWA manifest/service worker, Playwright E2E, item field editing UI, server-side "after photo required for done" enforcement (client-enforced here), excluding closed projects' child rows from sync, syncing a sub's location *parent* row (subs see the item's direct location name only in v1), `middleware.ts` → `proxy.ts` rename.

---

## File structure created/modified by this plan

```
src/
  lib/
    domain/trades.ts                 # canonical trade list (pure)
    domain/grouping.ts               # group items by location for display (pure)
    powersync/upload-mapper.ts       # pure CRUD-op -> upload-action mapper
    powersync/schema.ts              # MODIFY: + org_member_profiles table
    powersync/connector.ts           # MODIFY: use upload-mapper, handle rpc/skip
    data/use-session.ts              # current user id hook
    data/use-role.ts                 # current user role from org_member_profiles
    data/status-actions.ts           # changeStatus(): local event + optimistic update
    photos/compress.ts               # image downscale (pure math + canvas)
    photos/blob-store.ts             # IndexedDB blob storage for pending photos
    photos/uploader.ts               # background upload loop w/ backoff
    photos/use-photo-url.ts          # resolve local blob or Storage URL
    photos/use-pending-count.ts      # queued-photo count for the banner
  components/
    offline-banner.tsx               # offline + queued-photos banner (all pages)
    status-chip.tsx                  # colored status label
    photo-capture.tsx                # camera input -> compress -> blob + row
    photo-grid.tsx                   # before/after photo display
    status-buttons.tsx               # role-aware transition buttons + kickback note
  app/
    page.tsx                         # MODIFY: role-based redirect (/projects | /my-items)
    login/page.tsx                   # MODIFY: pending state on submit button
    (app)/projects/page.tsx          # MODIFY: link rows to project page, local-first org lookup
    (app)/projects/[id]/page.tsx     # punch list: grouped, filtered, big +
    (app)/projects/[id]/new-item/page.tsx  # quick-add flow
    (app)/items/[id]/page.tsx        # item detail: photos, history, actions
    (app)/my-items/page.tsx          # sub home: assigned items across projects
    providers.tsx                    # MODIFY: start photo uploader
supabase/
  migrations/0004_field_workflows.sql  # org_member_profiles + triggers, status RPC,
                                       # storage bucket + policies, location index
  tests/field.test.sql                 # pgTAP: RPC, profiles denorm, RLS
powersync/sync-rules.yaml              # MODIFY: + org_member_profiles buckets
tests/unit/
  grouping.test.ts
  trades.test.ts
  upload-mapper.test.ts
  compress.test.ts
  uploader.test.ts
```

---

### Task 1: Database — member profiles denorm, status RPC, storage bucket

**Files:**
- Create: `supabase/migrations/0004_field_workflows.sql`
- Test: `supabase/tests/field.test.sql`

- [ ] **Step 1: Write the failing pgTAP tests**

Create `supabase/tests/field.test.sql`:

```sql
begin;
select plan(13);

-- Seed
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'gc@test.dev'),
  ('00000000-0000-0000-0000-0000000000b1', 'sub1@test.dev');
insert into profiles (id, full_name, company_name) values
  ('00000000-0000-0000-0000-0000000000a1', 'GC', null),
  ('00000000-0000-0000-0000-0000000000b1', 'Sub One', 'Apex Plumbing');
insert into orgs (id, name) values ('00000000-0000-0000-0000-00000000aaaa', 'Acme GC');
insert into org_members (org_id, user_id, role) values
  ('00000000-0000-0000-0000-00000000aaaa', '00000000-0000-0000-0000-0000000000a1', 'member'),
  ('00000000-0000-0000-0000-00000000aaaa', '00000000-0000-0000-0000-0000000000b1', 'sub');
insert into projects (id, org_id, name) values
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000aaaa', 'Tower A');
insert into punch_items (id, org_id, project_id, title, assigned_to, created_by) values
  ('00000000-0000-0000-0000-000000001101', '00000000-0000-0000-0000-00000000aaaa',
   '00000000-0000-0000-0000-000000000001', 'Fix drywall',
   '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a1');

-- org_member_profiles is maintained by trigger
select is(
  (select count(*) from org_member_profiles where org_id = '00000000-0000-0000-0000-00000000aaaa'),
  2::bigint, 'org_member_profiles backfilled/triggered for both members');
select is(
  (select company_name from org_member_profiles
   where user_id = '00000000-0000-0000-0000-0000000000b1'),
  'Apex Plumbing', 'profile fields denormalized');

-- profile update propagates
update profiles set full_name = 'Sub Uno' where id = '00000000-0000-0000-0000-0000000000b1';
select is(
  (select full_name from org_member_profiles
   where user_id = '00000000-0000-0000-0000-0000000000b1'),
  'Sub Uno', 'profile rename propagates to denorm table');

-- RLS: sub sees only own row, GC sees all
set local role authenticated;
set local "request.jwt.claims" to '{"sub":"00000000-0000-0000-0000-0000000000b1"}';
select is((select count(*) from org_member_profiles), 1::bigint, 'sub sees only own member profile');
set local "request.jwt.claims" to '{"sub":"00000000-0000-0000-0000-0000000000a1"}';
select is((select count(*) from org_member_profiles), 2::bigint, 'GC sees all member profiles');

-- RPC: sub walks an allowed transition
set local "request.jwt.claims" to '{"sub":"00000000-0000-0000-0000-0000000000b1"}';
select lives_ok(
  $$ select record_status_event('00000000-0000-0000-0000-00000000e001',
       '00000000-0000-0000-0000-000000001101', 'open', 'in_progress', null) $$,
  'sub can record open -> in_progress');
select is(
  (select status from punch_items where id = '00000000-0000-0000-0000-000000001101'),
  'in_progress'::punch_status, 'item status applied');
select is(
  (select count(*) from punch_item_events where item_id = '00000000-0000-0000-0000-000000001101'),
  1::bigint, 'history event recorded');

-- RPC: sub cannot verify
select throws_ok(
  $$ select record_status_event('00000000-0000-0000-0000-00000000e002',
       '00000000-0000-0000-0000-000000001101', 'in_progress', 'verified', null) $$,
  'not allowed');

-- RPC: GC can verify after sub marks done
select lives_ok(
  $$ select record_status_event('00000000-0000-0000-0000-00000000e003',
       '00000000-0000-0000-0000-000000001101', 'in_progress', 'done', null) $$,
  'sub can record in_progress -> done');
set local "request.jwt.claims" to '{"sub":"00000000-0000-0000-0000-0000000000a1"}';
select lives_ok(
  $$ select record_status_event('00000000-0000-0000-0000-00000000e004',
       '00000000-0000-0000-0000-000000001101', 'done', 'verified', null) $$,
  'GC can verify');

-- Conflict precedence: GC kicks back, then a stale sub write arrives.
-- CAS fails (current is 'open', event says from 'in_progress'); precedence keeps
-- the later stage: done > open, so 'done' wins. History records both.
select lives_ok(
  $$ select record_status_event('00000000-0000-0000-0000-00000000e005',
       '00000000-0000-0000-0000-000000001101', 'verified', 'open', 'redo edges') $$,
  'GC can kick back');
set local "request.jwt.claims" to '{"sub":"00000000-0000-0000-0000-0000000000b1"}';
select record_status_event('00000000-0000-0000-0000-00000000e006',
  '00000000-0000-0000-0000-000000001101', 'in_progress', 'done', null);
select is(
  (select status from punch_items where id = '00000000-0000-0000-0000-000000001101'),
  'done'::punch_status, 'stale write resolves by stage precedence, not LWW');

select * from finish();
rollback;
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/punchlist && npx supabase test db`
Expected: `field.test.sql` fails (`org_member_profiles` does not exist). `rls.test.sql` still passes 12/12.

- [ ] **Step 3: Write the migration**

Create `supabase/migrations/0004_field_workflows.sql`:

```sql
-- ============================================================
-- 1. org_member_profiles: denormalized member directory.
-- PowerSync data queries can only filter one table by bucket
-- parameters, and profiles has no org_id — so we maintain a
-- flat table by trigger and sync that instead.
-- ============================================================
create table org_member_profiles (
  org_id uuid not null references orgs(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  -- PowerSync requires a synced `id` primary key column
  id uuid primary key default gen_random_uuid(),
  role org_role not null,
  full_name text not null default '',
  company_name text,
  unique (org_id, user_id)
);

alter table org_member_profiles enable row level security;
-- GC roles see the whole directory; subs see only their own row.
create policy omp_select on org_member_profiles for select
  using (is_gc(org_id) or user_id = auth.uid());
-- No insert/update/delete policies: clients never write this table.

create or replace function sync_org_member_profile() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    delete from org_member_profiles
      where org_id = old.org_id and user_id = old.user_id;
    return old;
  end if;
  insert into org_member_profiles (org_id, user_id, role, full_name, company_name)
  select new.org_id, new.user_id, new.role, p.full_name, p.company_name
  from profiles p where p.id = new.user_id
  on conflict (org_id, user_id) do update
    set role = excluded.role,
        full_name = excluded.full_name,
        company_name = excluded.company_name;
  return new;
end;
$$;

create trigger org_members_sync_profiles
  after insert or update or delete on org_members
  for each row execute function sync_org_member_profile();

create or replace function sync_profile_to_member_profiles() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update org_member_profiles
    set full_name = new.full_name, company_name = new.company_name
    where user_id = new.id;
  return new;
end;
$$;

create trigger profiles_sync_member_profiles
  after update on profiles
  for each row execute function sync_profile_to_member_profiles();

-- Backfill existing memberships
insert into org_member_profiles (org_id, user_id, role, full_name, company_name)
select m.org_id, m.user_id, m.role, p.full_name, p.company_name
from org_members m join profiles p on p.id = m.user_id
on conflict (org_id, user_id) do nothing;

-- ============================================================
-- 2. Status transition RPC: validates the actor, appends history,
-- applies status with CAS + stage precedence (spec conflict rule).
-- Idempotent on event id so PowerSync upload retries are safe.
-- ============================================================
create or replace function status_stage(s punch_status) returns int
immutable language sql as $$
  select case s
    when 'open' then 0 when 'in_progress' then 1
    when 'done' then 2 when 'verified' then 3 end
$$;

create or replace function record_status_event(
  p_id uuid, p_item_id uuid, p_from punch_status, p_to punch_status, p_note text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_item punch_items%rowtype;
  v_actor uuid := auth.uid();
  v_new punch_status;
begin
  if v_actor is null then
    raise exception 'authentication required';
  end if;
  select * into v_item from punch_items where id = p_item_id for update;
  if not found then
    raise exception 'item not found';
  end if;
  if is_gc(v_item.org_id) then
    null; -- GC roles: any transition (verify, kick back, reopen)
  elsif v_item.assigned_to = v_actor and (p_from, p_to) in
    (('open','in_progress'),('in_progress','done'),('open','done'),('in_progress','open')) then
    null; -- sub: only their items, only allowed transitions
  else
    raise exception 'not allowed';
  end if;

  insert into punch_item_events (id, org_id, item_id, actor_id, from_status, to_status, note)
  values (p_id, v_item.org_id, p_item_id, v_actor, p_from, p_to, p_note)
  on conflict (id) do nothing;

  -- CAS: if the item is where the actor thought, apply directly (this is
  -- what makes intentional kick-backs work). Otherwise resolve by stage
  -- precedence: a stale offline write never silently downgrades.
  if v_item.status = p_from then
    v_new := p_to;
  elsif status_stage(p_to) >= status_stage(v_item.status) then
    v_new := p_to;
  else
    v_new := v_item.status;
  end if;
  update punch_items set status = v_new where id = p_item_id;
end;
$$;

grant execute on function record_status_event(uuid, uuid, punch_status, punch_status, text)
  to authenticated;

-- ============================================================
-- 3. Photos storage bucket + access policies.
-- Object path convention: {org_id}/{item_id}/{photo_id}.jpg
-- ============================================================
insert into storage.buckets (id, name, public)
values ('photos', 'photos', false)
on conflict (id) do nothing;

create policy storage_photos_gc_all on storage.objects for all to authenticated
  using (bucket_id = 'photos' and is_gc(((storage.foldername(name))[1])::uuid))
  with check (bucket_id = 'photos' and is_gc(((storage.foldername(name))[1])::uuid));

create policy storage_photos_sub_select on storage.objects for select to authenticated
  using (bucket_id = 'photos' and exists (
    select 1 from punch_items i
    where i.id = ((storage.foldername(name))[2])::uuid
      and i.assigned_to = auth.uid()));

create policy storage_photos_sub_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'photos' and exists (
    select 1 from punch_items i
    where i.id = ((storage.foldername(name))[2])::uuid
      and i.assigned_to = auth.uid()));

-- ============================================================
-- 4. Index the sub-visibility correlated lookups (review issue).
-- ============================================================
create index punch_items_location_idx on punch_items (location_id);
```

- [ ] **Step 4: Apply and run tests**

Run: `cd ~/punchlist && npx supabase db reset && npx supabase test db`
Expected: migrations 0001–0004 apply cleanly; both test files pass (12 + 13 = 25 tests).

- [ ] **Step 5: Commit**

```bash
git add supabase && git commit -m "feat(db): member-profiles denorm, status RPC with precedence, photos bucket"
```

---

### Task 2: Client sync plumbing — schema, sync rules, upload mapper

**Files:**
- Create: `src/lib/powersync/upload-mapper.ts`
- Modify: `src/lib/powersync/schema.ts` (add `org_member_profiles`)
- Modify: `src/lib/powersync/connector.ts` (route ops through the mapper)
- Modify: `powersync/sync-rules.yaml`
- Test: `tests/unit/upload-mapper.test.ts`

- [ ] **Step 1: Write the failing mapper tests**

Create `tests/unit/upload-mapper.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { mapCrudOp } from '@/lib/powersync/upload-mapper';

describe('mapCrudOp', () => {
  it('routes punch_item_events inserts to the status RPC', () => {
    const action = mapCrudOp({
      table: 'punch_item_events', op: 'PUT', id: 'e1',
      opData: { item_id: 'i1', from_status: 'open', to_status: 'in_progress', note: null,
                org_id: 'o1', actor_id: 'u1', created_at: 'x' },
    });
    expect(action).toEqual({
      kind: 'rpc', fn: 'record_status_event',
      args: { p_id: 'e1', p_item_id: 'i1', p_from: 'open', p_to: 'in_progress', p_note: null },
    });
  });

  it('strips status from punch_items patches (RPC owns status)', () => {
    const action = mapCrudOp({
      table: 'punch_items', op: 'PATCH', id: 'i1',
      opData: { status: 'done', updated_at: 't' },
    });
    expect(action).toEqual({ kind: 'skip' });
  });

  it('keeps non-status punch_items patch columns', () => {
    const action = mapCrudOp({
      table: 'punch_items', op: 'PATCH', id: 'i1',
      opData: { status: 'done', due_date: '2026-07-01' },
    });
    expect(action).toEqual({
      kind: 'update', table: 'punch_items', id: 'i1', data: { due_date: '2026-07-01' },
    });
  });

  it('passes other tables through unchanged', () => {
    expect(mapCrudOp({ table: 'projects', op: 'PUT', id: 'p1', opData: { name: 'A' } }))
      .toEqual({ kind: 'upsert', table: 'projects', row: { id: 'p1', name: 'A' } });
    expect(mapCrudOp({ table: 'photos', op: 'PATCH', id: 'ph1', opData: { storage_path: 's' } }))
      .toEqual({ kind: 'update', table: 'photos', id: 'ph1', data: { storage_path: 's' } });
    expect(mapCrudOp({ table: 'locations', op: 'DELETE', id: 'l1' }))
      .toEqual({ kind: 'delete', table: 'locations', id: 'l1' });
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm test`
Expected: FAIL — `Cannot find module '@/lib/powersync/upload-mapper'`.

- [ ] **Step 3: Implement the mapper**

Create `src/lib/powersync/upload-mapper.ts`:

```ts
export type CrudLike = {
  table: string;
  op: 'PUT' | 'PATCH' | 'DELETE';
  id: string;
  opData?: Record<string, unknown>;
};

export type UploadAction =
  | { kind: 'rpc'; fn: 'record_status_event'; args: Record<string, unknown> }
  | { kind: 'upsert'; table: string; row: Record<string, unknown> }
  | { kind: 'update'; table: string; id: string; data: Record<string, unknown> }
  | { kind: 'delete'; table: string; id: string }
  | { kind: 'skip' };

/**
 * Pure mapping from a local CRUD op to the server call that applies it.
 * Status changes travel as punch_item_events -> record_status_event RPC,
 * which owns history + conflict precedence; raw status patches are dropped
 * so a stale local status can never overwrite the server's resolution.
 */
export function mapCrudOp(op: CrudLike): UploadAction {
  if (op.table === 'punch_item_events' && op.op === 'PUT') {
    const d = op.opData ?? {};
    return {
      kind: 'rpc',
      fn: 'record_status_event',
      args: {
        p_id: op.id,
        p_item_id: d.item_id,
        p_from: d.from_status ?? null,
        p_to: d.to_status,
        p_note: d.note ?? null,
      },
    };
  }
  if (op.table === 'punch_items' && op.op === 'PATCH') {
    const { status: _status, updated_at: _u, ...rest } = op.opData ?? {};
    if (Object.keys(rest).length === 0) return { kind: 'skip' };
    return { kind: 'update', table: op.table, id: op.id, data: rest };
  }
  if (op.op === 'PUT') return { kind: 'upsert', table: op.table, row: { id: op.id, ...op.opData } };
  if (op.op === 'PATCH') return { kind: 'update', table: op.table, id: op.id, data: op.opData ?? {} };
  return { kind: 'delete', table: op.table, id: op.id };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test`
Expected: all unit tests PASS.

- [ ] **Step 5: Route the connector through the mapper**

Replace the `uploadData` loop body in `src/lib/powersync/connector.ts`. The full new file:

```ts
import {
  AbstractPowerSyncDatabase,
  PowerSyncBackendConnector,
  UpdateType,
} from '@powersync/web';
import { supabase } from '@/lib/supabase/client';
import { mapCrudOp, type CrudLike } from './upload-mapper';

const OP_NAMES: Record<UpdateType, CrudLike['op']> = {
  [UpdateType.PUT]: 'PUT',
  [UpdateType.PATCH]: 'PATCH',
  [UpdateType.DELETE]: 'DELETE',
};

export class SupabaseConnector implements PowerSyncBackendConnector {
  async fetchCredentials() {
    const endpoint = process.env.NEXT_PUBLIC_POWERSYNC_URL;
    if (!endpoint) return null;
    const { data } = await supabase.auth.getSession();
    if (!data.session) return null;
    return {
      endpoint,
      token: data.session.access_token,
    };
  }

  async uploadData(database: AbstractPowerSyncDatabase) {
    const tx = await database.getNextCrudTransaction();
    if (!tx) return;
    try {
      for (const op of tx.crud) {
        const action = mapCrudOp({
          table: op.table,
          op: OP_NAMES[op.op],
          id: op.id,
          opData: op.opData,
        });
        if (action.kind === 'skip') continue;
        if (action.kind === 'rpc') {
          const { error } = await supabase.rpc(action.fn, action.args);
          if (error) throw error;
        } else if (action.kind === 'upsert') {
          const { error } = await supabase.from(action.table).upsert(action.row);
          if (error) throw error;
        } else if (action.kind === 'update') {
          const { error } = await supabase.from(action.table).update(action.data).eq('id', action.id);
          if (error) throw error;
        } else {
          const { error } = await supabase.from(action.table).delete().eq('id', action.id);
          if (error) throw error;
        }
      }
      await tx.complete();
    } catch (e: unknown) {
      // Permanent rejections (RLS denial, constraint violation, RPC guard)
      // must not wedge the upload queue: discard the local op; server state
      // re-syncs down. Earlier ops in the transaction stay applied — server
      // state is authoritative and re-syncs.
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

- [ ] **Step 6: Add org_member_profiles to the client schema**

In `src/lib/powersync/schema.ts`, add before `AppSchema`:

```ts
const org_member_profiles = new Table({
  org_id: column.text,
  user_id: column.text,
  role: column.text,
  full_name: column.text,
  company_name: column.text,
});
```

and change the schema export to:

```ts
export const AppSchema = new Schema({
  projects, locations, punch_items, punch_item_events, photos, org_member_profiles,
});
```

- [ ] **Step 7: Update sync rules**

Replace `powersync/sync-rules.yaml` with:

```yaml
bucket_definitions:
  # GC roles get the whole org. Spec: closed projects are excluded from sync
  # to bound phone storage — applied to projects here; excluding their
  # items/photos too needs project status denormalized onto child rows
  # (deferred to Plan 3).
  gc_org:
    parameters: >
      select org_id from org_members
      where user_id = request.user_id() and role in ('admin','member')
    data:
      - select * from projects where org_id = bucket.org_id and status = 'active'
      - select * from locations where org_id = bucket.org_id
      - select * from punch_items where org_id = bucket.org_id
      - select * from punch_item_events where org_id = bucket.org_id
      - select * from photos where org_id = bucket.org_id
      - select * from org_member_profiles where org_id = bucket.org_id

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

  # Everyone gets their own membership row (role lookup for routing)
  own_membership:
    parameters: >
      select id as omp_id from org_member_profiles
      where user_id = request.user_id()
    data:
      - select * from org_member_profiles where id = bucket.omp_id
```

- [ ] **Step 8: Verify typecheck and build**

Run: `npx tsc --noEmit && npm run build`
Expected: clean.

- [ ] **Step 9: Commit**

```bash
git add src/lib/powersync powersync tests
git commit -m "feat(sync): route status events through RPC, sync member profiles"
```

---

### Task 3: Domain helpers — trades and location grouping (TDD)

**Files:**
- Create: `src/lib/domain/trades.ts`, `src/lib/domain/grouping.ts`
- Test: `tests/unit/trades.test.ts`, `tests/unit/grouping.test.ts`

- [ ] **Step 1: Write the failing tests**

Create `tests/unit/trades.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { TRADES } from '@/lib/domain/trades';

describe('TRADES', () => {
  it('is a non-empty list of unique lowercase identifiers', () => {
    expect(TRADES.length).toBeGreaterThan(5);
    expect(new Set(TRADES).size).toBe(TRADES.length);
    for (const t of TRADES) expect(t).toMatch(/^[a-z_]+$/);
  });
});
```

Create `tests/unit/grouping.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { groupItemsByLocation, locationLabel } from '@/lib/domain/grouping';

const locations = [
  { id: 'f2', project_id: 'p1', parent_id: null, name: 'Floor 2' },
  { id: 'u204', project_id: 'p1', parent_id: 'f2', name: 'Unit 204' },
];

describe('locationLabel', () => {
  it('renders parent > child for nested locations', () => {
    expect(locationLabel('u204', locations)).toBe('Floor 2 › Unit 204');
  });
  it('renders a top-level location plainly', () => {
    expect(locationLabel('f2', locations)).toBe('Floor 2');
  });
  it('falls back for unknown/missing locations', () => {
    expect(locationLabel(null, locations)).toBe('No location');
    expect(locationLabel('nope', locations)).toBe('No location');
  });
});

describe('groupItemsByLocation', () => {
  const items = [
    { id: 'i1', location_id: 'u204', title: 'a' },
    { id: 'i2', location_id: 'f2', title: 'b' },
    { id: 'i3', location_id: null, title: 'c' },
    { id: 'i4', location_id: 'u204', title: 'd' },
  ];
  it('groups items under location labels, unlocated last', () => {
    const groups = groupItemsByLocation(items, locations);
    expect(groups.map((g) => g.label)).toEqual(['Floor 2', 'Floor 2 › Unit 204', 'No location']);
    expect(groups[1].items.map((i) => i.id)).toEqual(['i1', 'i4']);
    expect(groups[2].items.map((i) => i.id)).toEqual(['i3']);
  });
  it('returns empty array for no items', () => {
    expect(groupItemsByLocation([], locations)).toEqual([]);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm test`
Expected: FAIL — modules not found.

- [ ] **Step 3: Implement**

Create `src/lib/domain/trades.ts`:

```ts
export const TRADES = [
  'plumbing', 'electrical', 'hvac', 'drywall', 'paint', 'flooring',
  'carpentry', 'masonry', 'roofing', 'landscaping', 'glazing', 'other',
] as const;

export type Trade = (typeof TRADES)[number];
```

Create `src/lib/domain/grouping.ts`:

```ts
export type LocationRow = {
  id: string;
  project_id: string;
  parent_id: string | null;
  name: string;
};

export type Locatable = { id: string; location_id: string | null };

export const NO_LOCATION = 'No location';

export function locationLabel(locationId: string | null, locations: LocationRow[]): string {
  const loc = locations.find((l) => l.id === locationId);
  if (!loc) return NO_LOCATION;
  const parent = loc.parent_id ? locations.find((l) => l.id === loc.parent_id) : null;
  return parent ? `${parent.name} › ${loc.name}` : loc.name;
}

export function groupItemsByLocation<T extends Locatable>(
  items: T[],
  locations: LocationRow[],
): Array<{ label: string; items: T[] }> {
  const byLabel = new Map<string, T[]>();
  for (const item of items) {
    const label = locationLabel(item.location_id, locations);
    const bucket = byLabel.get(label) ?? [];
    bucket.push(item);
    byLabel.set(label, bucket);
  }
  return [...byLabel.entries()]
    .sort(([a], [b]) =>
      a === NO_LOCATION ? 1 : b === NO_LOCATION ? -1 : a.localeCompare(b))
    .map(([label, groupItems]) => ({ label, items: groupItems }));
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/lib/domain tests
git commit -m "feat(domain): trade list and location grouping helpers"
```

---

### Task 4: Photo pipeline — compression, blob store, uploader (TDD on pure parts)

**Files:**
- Create: `src/lib/photos/compress.ts`, `src/lib/photos/blob-store.ts`, `src/lib/photos/uploader.ts`
- Test: `tests/unit/compress.test.ts`, `tests/unit/uploader.test.ts`

- [ ] **Step 1: Write the failing tests for the pure parts**

Create `tests/unit/compress.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { computeTargetSize, MAX_EDGE_PX } from '@/lib/photos/compress';

describe('computeTargetSize', () => {
  it('caps the long edge at MAX_EDGE_PX preserving aspect', () => {
    expect(computeTargetSize(4000, 3000)).toEqual({ width: 1600, height: 1200 });
    expect(computeTargetSize(3000, 4000)).toEqual({ width: 1200, height: 1600 });
  });
  it('leaves small images untouched', () => {
    expect(computeTargetSize(800, 600)).toEqual({ width: 800, height: 600 });
    expect(computeTargetSize(MAX_EDGE_PX, MAX_EDGE_PX)).toEqual({ width: 1600, height: 1600 });
  });
  it('rounds to whole pixels', () => {
    const { width, height } = computeTargetSize(3333, 2111);
    expect(Number.isInteger(width)).toBe(true);
    expect(Number.isInteger(height)).toBe(true);
    expect(Math.max(width, height)).toBe(MAX_EDGE_PX);
  });
});
```

Create `tests/unit/uploader.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { nextRetryDelayMs, storagePath } from '@/lib/photos/uploader';

describe('nextRetryDelayMs', () => {
  it('backs off exponentially and caps at 5 minutes', () => {
    expect(nextRetryDelayMs(0)).toBe(5_000);
    expect(nextRetryDelayMs(1)).toBe(10_000);
    expect(nextRetryDelayMs(2)).toBe(20_000);
    expect(nextRetryDelayMs(10)).toBe(300_000);
  });
});

describe('storagePath', () => {
  it('builds the org/item/photo path the storage policies expect', () => {
    expect(storagePath({ org_id: 'o', item_id: 'i', id: 'p' })).toBe('o/i/p.jpg');
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npm test`
Expected: FAIL — modules not found.

- [ ] **Step 3: Implement compression**

Create `src/lib/photos/compress.ts`:

```ts
export const MAX_EDGE_PX = 1600;
export const JPEG_QUALITY = 0.8;

export function computeTargetSize(width: number, height: number): { width: number; height: number } {
  const longEdge = Math.max(width, height);
  if (longEdge <= MAX_EDGE_PX) return { width, height };
  const scale = MAX_EDGE_PX / longEdge;
  return { width: Math.round(width * scale), height: Math.round(height * scale) };
}

/** Downscale + re-encode a captured image. Browser-only (canvas). */
export async function compressImage(file: Blob): Promise<Blob> {
  const bitmap = await createImageBitmap(file);
  try {
    const { width, height } = computeTargetSize(bitmap.width, bitmap.height);
    const canvas = document.createElement('canvas');
    canvas.width = width;
    canvas.height = height;
    const ctx = canvas.getContext('2d');
    if (!ctx) return file;
    ctx.drawImage(bitmap, 0, 0, width, height);
    return await new Promise<Blob>((resolve, reject) => {
      canvas.toBlob(
        (blob) => (blob ? resolve(blob) : reject(new Error('toBlob failed'))),
        'image/jpeg',
        JPEG_QUALITY,
      );
    });
  } finally {
    bitmap.close();
  }
}
```

- [ ] **Step 4: Implement the blob store**

Create `src/lib/photos/blob-store.ts`:

```ts
/** IndexedDB store for photo blobs awaiting upload, keyed by photo id. */
const DB_NAME = 'punchlist-photo-blobs';
const STORE = 'blobs';

function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => req.result.createObjectStore(STORE);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function withStore<T>(
  mode: IDBTransactionMode,
  fn: (store: IDBObjectStore) => IDBRequest<T>,
): Promise<T> {
  const db = await openDb();
  try {
    return await new Promise<T>((resolve, reject) => {
      const req = fn(db.transaction(STORE, mode).objectStore(STORE));
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
  } finally {
    db.close();
  }
}

export const blobStore = {
  put: (id: string, blob: Blob) => withStore('readwrite', (s) => s.put(blob, id)),
  get: (id: string) => withStore<Blob | undefined>('readonly', (s) => s.get(id)),
  delete: (id: string) => withStore('readwrite', (s) => s.delete(id)),
};
```

- [ ] **Step 5: Implement the uploader**

Create `src/lib/photos/uploader.ts`:

```ts
import { db } from '@/lib/powersync/db';
import { supabase } from '@/lib/supabase/client';
import { blobStore } from './blob-store';

const BASE_DELAY_MS = 5_000;
const MAX_DELAY_MS = 300_000;
const SCAN_INTERVAL_MS = 30_000;

export function nextRetryDelayMs(attempt: number): number {
  return Math.min(BASE_DELAY_MS * 2 ** attempt, MAX_DELAY_MS);
}

export function storagePath(p: { org_id: string; item_id: string; id: string }): string {
  return `${p.org_id}/${p.item_id}/${p.id}.jpg`;
}

type PendingPhoto = { id: string; org_id: string; item_id: string };

const attempts = new Map<string, { count: number; notBefore: number }>();
let running = false;

async function uploadOne(photo: PendingPhoto): Promise<void> {
  const blob = await blobStore.get(photo.id);
  if (!blob) return; // row synced from another device; nothing local to upload
  const path = storagePath(photo);
  const { error } = await supabase.storage.from('photos').upload(path, blob, {
    contentType: 'image/jpeg',
    upsert: true,
  });
  if (error) throw error;
  await db.execute(
    `update photos set storage_path = ?, uploaded_at = datetime('now') where id = ?`,
    [path, photo.id],
  );
  await blobStore.delete(photo.id);
  attempts.delete(photo.id);
}

export async function uploadPendingPhotos(): Promise<void> {
  if (typeof navigator !== 'undefined' && !navigator.onLine) return;
  const pending = await db.getAll<PendingPhoto>(
    `select id, org_id, item_id from photos where uploaded_at is null`,
  );
  const now = Date.now();
  for (const photo of pending) {
    const state = attempts.get(photo.id);
    if (state && now < state.notBefore) continue;
    try {
      await uploadOne(photo);
    } catch (e) {
      const count = (state?.count ?? 0) + 1;
      attempts.set(photo.id, { count, notBefore: now + nextRetryDelayMs(count - 1) });
      console.error(`photo upload failed (attempt ${count})`, e);
    }
  }
}

/** Start the background loop. Call once from the client provider. */
export function startPhotoUploader(): () => void {
  if (running) return () => {};
  running = true;
  const interval = setInterval(() => void uploadPendingPhotos(), SCAN_INTERVAL_MS);
  const onOnline = () => void uploadPendingPhotos();
  window.addEventListener('online', onOnline);
  void uploadPendingPhotos();
  return () => {
    running = false;
    clearInterval(interval);
    window.removeEventListener('online', onOnline);
  };
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `npm test`
Expected: PASS (compress + uploader pure functions).

- [ ] **Step 7: Wire the uploader into the provider**

Replace `src/app/providers.tsx` with:

```tsx
'use client';
import { useEffect } from 'react';
import { PowerSyncContext } from '@powersync/react';
import { db, connectPowerSync } from '@/lib/powersync/db';
import { startPhotoUploader } from '@/lib/photos/uploader';

export function Providers({ children }: { children: React.ReactNode }) {
  useEffect(() => {
    void connectPowerSync();
    return startPhotoUploader();
  }, []);
  return <PowerSyncContext.Provider value={db}>{children}</PowerSyncContext.Provider>;
}
```

- [ ] **Step 8: Verify typecheck and build**

Run: `npx tsc --noEmit && npm run build`
Expected: clean.

- [ ] **Step 9: Commit**

```bash
git add src/lib/photos src/app/providers.tsx tests
git commit -m "feat(photos): compression, local blob queue, background uploader"
```

---

### Task 5: Data hooks and status actions

**Files:**
- Create: `src/lib/data/use-session.ts`, `src/lib/data/use-role.ts`, `src/lib/data/status-actions.ts`
- Create: `src/lib/photos/use-photo-url.ts`, `src/lib/photos/use-pending-count.ts`
- Create: `src/components/offline-banner.tsx`, `src/components/status-chip.tsx`

- [ ] **Step 1: Session hook**

Create `src/lib/data/use-session.ts`:

```ts
'use client';
import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase/client';

/** Current auth user id, null while loading or signed out. */
export function useUserId(): string | null {
  const [userId, setUserId] = useState<string | null>(null);
  useEffect(() => {
    void supabase.auth.getSession().then(({ data }) => {
      setUserId(data.session?.user.id ?? null);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((_event, session) => {
      setUserId(session?.user.id ?? null);
    });
    return () => sub.subscription.unsubscribe();
  }, []);
  return userId;
}
```

- [ ] **Step 2: Role hook**

Create `src/lib/data/use-role.ts`:

```ts
'use client';
import { useQuery } from '@powersync/react';
import type { Role } from '@/lib/domain/status';
import { useUserId } from './use-session';

/**
 * Current user's org role from the synced member directory.
 * Returns null while unknown (loading, or directory not synced yet —
 * e.g. before the PowerSync instance is provisioned). Callers should
 * treat null as "GC-style default" for routing only, never for
 * authorization — the server enforces real permissions.
 */
export function useRole(): Role | null {
  const userId = useUserId();
  const { data } = useQuery<{ role: Role }>(
    `select role from org_member_profiles where user_id = ? limit 1`,
    [userId ?? ''],
  );
  return data[0]?.role ?? null;
}
```

- [ ] **Step 3: Status change helper**

Create `src/lib/data/status-actions.ts`:

```ts
import { db } from '@/lib/powersync/db';
import { canTransition, type PunchStatus, type Role } from '@/lib/domain/status';

/**
 * Record a status change: append a local history event and optimistically
 * update the item. On upload the event becomes a record_status_event RPC
 * call, which re-validates and resolves conflicts by stage precedence.
 */
export async function changeStatus(params: {
  itemId: string;
  from: PunchStatus;
  to: PunchStatus;
  role: Role;
  userId: string;
  note?: string;
}): Promise<void> {
  const { itemId, from, to, role, userId, note } = params;
  if (!canTransition(role, from, to)) {
    throw new Error(`transition ${from} -> ${to} not allowed for ${role}`);
  }
  await db.writeTransaction(async (tx) => {
    await tx.execute(
      `insert into punch_item_events (id, org_id, item_id, actor_id, from_status, to_status, note, created_at)
       select uuid(), org_id, id, ?, ?, ?, ?, datetime('now') from punch_items where id = ?`,
      [userId, from, to, note ?? null, itemId],
    );
    await tx.execute(
      `update punch_items set status = ?, updated_at = datetime('now') where id = ?`,
      [to, itemId],
    );
  });
}
```

- [ ] **Step 4: Photo URL + pending count hooks**

Create `src/lib/photos/use-photo-url.ts`:

```ts
'use client';
import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase/client';
import { blobStore } from './blob-store';

const urlCache = new Map<string, string>();

/** Resolve a photo to a displayable URL: local blob first, then Storage. */
export function usePhotoUrl(photo: { id: string; storage_path: string | null }): string | null {
  const [url, setUrl] = useState<string | null>(urlCache.get(photo.id) ?? null);
  useEffect(() => {
    let cancelled = false;
    if (urlCache.has(photo.id)) return;
    void (async () => {
      const local = await blobStore.get(photo.id);
      if (local) {
        const objectUrl = URL.createObjectURL(local);
        urlCache.set(photo.id, objectUrl);
        if (!cancelled) setUrl(objectUrl);
        return;
      }
      if (!photo.storage_path) return;
      const { data, error } = await supabase.storage
        .from('photos')
        .download(photo.storage_path);
      if (error || !data) return;
      const objectUrl = URL.createObjectURL(data);
      urlCache.set(photo.id, objectUrl);
      if (!cancelled) setUrl(objectUrl);
    })();
    return () => {
      cancelled = true;
    };
  }, [photo.id, photo.storage_path]);
  return url;
}
```

Create `src/lib/photos/use-pending-count.ts`:

```ts
'use client';
import { useQuery } from '@powersync/react';

/** Number of photos captured locally and not yet uploaded. */
export function usePendingPhotoCount(): number {
  const { data } = useQuery<{ n: number }>(
    `select count(*) as n from photos where uploaded_at is null`,
  );
  return data[0]?.n ?? 0;
}
```

- [ ] **Step 5: Shared banner + status chip**

Create `src/components/offline-banner.tsx`:

```tsx
'use client';
import { useStatus } from '@powersync/react';
import { usePendingPhotoCount } from '@/lib/photos/use-pending-count';

export function OfflineBanner() {
  const status = useStatus();
  const pending = usePendingPhotoCount();
  if (status.connected && pending === 0) return null;
  return (
    <p className="mb-2 rounded bg-amber-100 p-2 text-sm">
      {!status.connected && 'Offline — changes will sync'}
      {!status.connected && pending > 0 && ' · '}
      {pending > 0 && `${pending} photo${pending === 1 ? '' : 's'} queued`}
    </p>
  );
}
```

Create `src/components/status-chip.tsx`:

```tsx
import type { PunchStatus } from '@/lib/domain/status';

const STYLES: Record<PunchStatus, string> = {
  open: 'bg-red-100 text-red-800',
  in_progress: 'bg-blue-100 text-blue-800',
  done: 'bg-yellow-100 text-yellow-800',
  verified: 'bg-green-100 text-green-800',
};

const LABELS: Record<PunchStatus, string> = {
  open: 'Open',
  in_progress: 'In progress',
  done: 'Done',
  verified: 'Verified',
};

export function StatusChip({ status }: { status: PunchStatus }) {
  return (
    <span className={`rounded px-2 py-0.5 text-xs font-semibold ${STYLES[status]}`}>
      {LABELS[status]}
    </span>
  );
}
```

- [ ] **Step 6: Verify typecheck**

Run: `npx tsc --noEmit`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add src/lib/data src/lib/photos src/components
git commit -m "feat(web): session/role hooks, status-change helper, shared banner and chip"
```

---

### Task 6: Punch list page (`/projects/[id]`)

**Files:**
- Create: `src/app/(app)/projects/[id]/page.tsx`
- Modify: `src/app/(app)/projects/page.tsx` (link rows, use OfflineBanner, local-first org lookup)

- [ ] **Step 1: Build the punch list page**

Create `src/app/(app)/projects/[id]/page.tsx`:

```tsx
'use client';
import { use, useMemo, useState } from 'react';
import Link from 'next/link';
import { useQuery } from '@powersync/react';
import { groupItemsByLocation, type LocationRow } from '@/lib/domain/grouping';
import { TRADES } from '@/lib/domain/trades';
import type { PunchStatus } from '@/lib/domain/status';
import { OfflineBanner } from '@/components/offline-banner';
import { StatusChip } from '@/components/status-chip';

type ItemRow = {
  id: string;
  title: string;
  trade: string | null;
  status: PunchStatus;
  due_date: string | null;
  assigned_to: string | null;
  location_id: string | null;
  assignee_name: string | null;
};

const STATUSES: PunchStatus[] = ['open', 'in_progress', 'done', 'verified'];

export default function ProjectPage({ params }: { params: Promise<{ id: string }> }) {
  const { id: projectId } = use(params);
  const [statusFilter, setStatusFilter] = useState('');
  const [tradeFilter, setTradeFilter] = useState('');
  const [assigneeFilter, setAssigneeFilter] = useState('');

  const { data: project } = useQuery<{ name: string }>(
    `select name from projects where id = ?`, [projectId],
  );
  const { data: items } = useQuery<ItemRow>(
    `select i.id, i.title, i.trade, i.status, i.due_date, i.assigned_to, i.location_id,
            omp.full_name as assignee_name
     from punch_items i
     left join org_member_profiles omp on omp.user_id = i.assigned_to
     where i.project_id = ? order by i.created_at desc`,
    [projectId],
  );
  const { data: locations } = useQuery<LocationRow>(
    `select id, project_id, parent_id, name from locations where project_id = ?`,
    [projectId],
  );
  const { data: subs } = useQuery<{ user_id: string; full_name: string }>(
    `select user_id, full_name from org_member_profiles where role = 'sub' order by full_name`,
  );

  const groups = useMemo(() => {
    const filtered = items.filter(
      (i) =>
        (!statusFilter || i.status === statusFilter) &&
        (!tradeFilter || i.trade === tradeFilter) &&
        (!assigneeFilter || i.assigned_to === assigneeFilter),
    );
    return groupItemsByLocation(filtered, locations);
  }, [items, locations, statusFilter, tradeFilter, assigneeFilter]);

  return (
    <main className="mx-auto max-w-lg p-4 pb-24">
      <OfflineBanner />
      <div className="mb-3 flex items-center justify-between">
        <h1 className="text-xl font-bold">{project[0]?.name ?? 'Project'}</h1>
        <Link href="/projects" className="text-sm text-blue-600">All projects</Link>
      </div>
      <div className="mb-4 flex gap-2 text-sm">
        <select className="flex-1 rounded border p-2" value={statusFilter}
          onChange={(e) => setStatusFilter(e.target.value)} aria-label="Filter by status">
          <option value="">All statuses</option>
          {STATUSES.map((s) => <option key={s} value={s}>{s.replace('_', ' ')}</option>)}
        </select>
        <select className="flex-1 rounded border p-2" value={tradeFilter}
          onChange={(e) => setTradeFilter(e.target.value)} aria-label="Filter by trade">
          <option value="">All trades</option>
          {TRADES.map((t) => <option key={t} value={t}>{t}</option>)}
        </select>
        <select className="flex-1 rounded border p-2" value={assigneeFilter}
          onChange={(e) => setAssigneeFilter(e.target.value)} aria-label="Filter by assignee">
          <option value="">Anyone</option>
          {subs.map((s) => <option key={s.user_id} value={s.user_id}>{s.full_name}</option>)}
        </select>
      </div>
      {groups.length === 0 && (
        <p className="py-8 text-center text-sm text-gray-500">No punch items yet.</p>
      )}
      {groups.map((group) => (
        <section key={group.label} className="mb-4">
          <h2 className="mb-1 text-sm font-semibold text-gray-500">{group.label}</h2>
          <ul className="divide-y rounded border">
            {group.items.map((item) => (
              <li key={item.id}>
                <Link href={`/items/${item.id}`} className="flex items-center gap-2 p-3">
                  <span className="flex-1">
                    <span className="block font-medium">{item.title}</span>
                    <span className="block text-xs text-gray-500">
                      {[item.trade, item.assignee_name, item.due_date && `due ${item.due_date}`]
                        .filter(Boolean).join(' · ')}
                    </span>
                  </span>
                  <StatusChip status={item.status} />
                </Link>
              </li>
            ))}
          </ul>
        </section>
      ))}
      <Link
        href={`/projects/${projectId}/new-item`}
        aria-label="Add punch item"
        className="fixed bottom-6 right-6 flex h-14 w-14 items-center justify-center rounded-full bg-black text-3xl text-white shadow-lg"
      >
        +
      </Link>
    </main>
  );
}
```

- [ ] **Step 2: Update the projects list page**

Replace `src/app/(app)/projects/page.tsx` with (changes: rows link to project page, OfflineBanner component, org lookup tries the synced directory before the network):

```tsx
'use client';
import { useState } from 'react';
import Link from 'next/link';
import { useQuery } from '@powersync/react';
import { db } from '@/lib/powersync/db';
import { supabase } from '@/lib/supabase/client';
import { OfflineBanner } from '@/components/offline-banner';

export default function ProjectsPage() {
  const { data: projects } = useQuery<{ id: string; name: string; status: string }>(
    `select id, name, status from projects where status = 'active' order by created_at desc`,
  );
  const [name, setName] = useState('');
  const [error, setError] = useState<string | null>(null);

  async function createProject(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    try {
      const { data } = await supabase.auth.getUser();
      const userId = data.user?.id;
      if (!userId || !name.trim()) return;
      const orgId = await resolveOrgId(userId);
      await db.execute(
        `insert into projects (id, org_id, name, status, created_at)
         values (uuid(), ?, ?, 'active', datetime('now'))`,
        [orgId, name.trim()],
      );
      setName('');
    } catch {
      setError('Could not create project — go online once so your organization can sync.');
    }
  }

  return (
    <main className="mx-auto max-w-lg p-4">
      <OfflineBanner />
      <h1 className="mb-4 text-xl font-bold">Projects</h1>
      <form onSubmit={createProject} className="mb-4 flex gap-2">
        <input className="flex-1 rounded border p-2" placeholder="New project name"
          value={name} onChange={(e) => setName(e.target.value)} />
        <button className="rounded bg-black px-4 text-white" type="submit">Add</button>
      </form>
      {error && <p className="mb-4 text-sm text-red-600">{error}</p>}
      <ul className="divide-y rounded border">
        {projects.map((p) => (
          <li key={p.id}>
            <Link href={`/projects/${p.id}`} className="block p-3">{p.name}</Link>
          </li>
        ))}
      </ul>
    </main>
  );
}

/** Local-first org lookup: synced membership row, existing project, then network. */
async function resolveOrgId(userId: string): Promise<string> {
  const local = await db.getAll<{ org_id: string }>(
    `select org_id, 0 as pri from org_member_profiles where user_id = ?
     union all
     select org_id, 1 as pri from projects
     order by pri limit 1`,
    [userId],
  );
  if (local[0]?.org_id) return local[0].org_id;
  const { data, error } = await supabase
    .from('org_members').select('org_id').eq('user_id', userId).limit(1).single();
  if (error || !data) throw new Error('No org membership found');
  return data.org_id;
}
```

- [ ] **Step 3: Verify build, then manually verify**

Run: `npx tsc --noEmit && npm run build`
Expected: clean.

Manual check (`npm run dev`, logged in as `gc@test.dev`):
1. `/projects` lists projects; clicking one opens `/projects/<id>` with empty punch list and a floating `+`.
2. Filters render (statuses, trades, "Anyone").

- [ ] **Step 4: Commit**

```bash
git add "src/app/(app)"
git commit -m "feat(web): punch list page with location groups and filters"
```

---

### Task 7: Quick-add flow (`/projects/[id]/new-item`)

**Files:**
- Create: `src/components/photo-capture.tsx`
- Create: `src/app/(app)/projects/[id]/new-item/page.tsx`

- [ ] **Step 1: Photo capture component**

Create `src/components/photo-capture.tsx`:

```tsx
'use client';
import { useRef, useState } from 'react';
import { compressImage } from '@/lib/photos/compress';
import { blobStore } from '@/lib/photos/blob-store';

export type CapturedPhoto = { id: string; previewUrl: string };

/**
 * Camera-first capture: stores the compressed blob in IndexedDB keyed by a
 * client-generated photo id. The caller inserts the photos row (which needs
 * the item id) when the parent record is saved.
 */
export function PhotoCapture({
  onCapture,
  label = 'Take photo',
}: {
  onCapture: (photo: CapturedPhoto) => void;
  label?: string;
}) {
  const inputRef = useRef<HTMLInputElement>(null);
  const [busy, setBusy] = useState(false);

  async function onChange(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    e.target.value = '';
    if (!file) return;
    setBusy(true);
    try {
      const blob = await compressImage(file);
      const id = crypto.randomUUID();
      await blobStore.put(id, blob);
      onCapture({ id, previewUrl: URL.createObjectURL(blob) });
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <input ref={inputRef} type="file" accept="image/*" capture="environment"
        className="hidden" onChange={onChange} />
      <button type="button" disabled={busy}
        onClick={() => inputRef.current?.click()}
        className="w-full rounded border-2 border-dashed p-6 text-center font-semibold disabled:opacity-50">
        {busy ? 'Processing…' : `📷 ${label}`}
      </button>
    </>
  );
}
```

- [ ] **Step 2: Quick-add page**

Create `src/app/(app)/projects/[id]/new-item/page.tsx`:

```tsx
'use client';
import { use, useState } from 'react';
import Image from 'next/image';
import { useRouter } from 'next/navigation';
import { useQuery } from '@powersync/react';
import { db } from '@/lib/powersync/db';
import { TRADES } from '@/lib/domain/trades';
import type { LocationRow } from '@/lib/domain/grouping';
import { locationLabel } from '@/lib/domain/grouping';
import { useUserId } from '@/lib/data/use-session';
import { PhotoCapture, type CapturedPhoto } from '@/components/photo-capture';

const LAST_LOCATION_KEY = (projectId: string) => `punchlist:last-location:${projectId}`;

export default function NewItemPage({ params }: { params: Promise<{ id: string }> }) {
  const { id: projectId } = use(params);
  const router = useRouter();
  const userId = useUserId();

  const { data: locations } = useQuery<LocationRow>(
    `select id, project_id, parent_id, name from locations where project_id = ? order by name`,
    [projectId],
  );
  const { data: subs } = useQuery<{ user_id: string; full_name: string; company_name: string | null }>(
    `select user_id, full_name, company_name from org_member_profiles
     where role = 'sub' order by full_name`,
  );

  const [photo, setPhoto] = useState<CapturedPhoto | null>(null);
  const [locationId, setLocationId] = useState(() =>
    typeof window === 'undefined' ? '' : localStorage.getItem(LAST_LOCATION_KEY(projectId)) ?? '');
  const [newLocationName, setNewLocationName] = useState('');
  const [title, setTitle] = useState('');
  const [trade, setTrade] = useState('');
  const [assignee, setAssignee] = useState('');
  const [dueDate, setDueDate] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  async function save(e: React.FormEvent) {
    e.preventDefault();
    if (!userId || !title.trim() || saving) return;
    setSaving(true);
    setError(null);
    try {
      const itemId = crypto.randomUUID();
      await db.writeTransaction(async (tx) => {
        const org = await tx.getAll<{ org_id: string }>(
          `select org_id from projects where id = ?`, [projectId]);
        const orgId = org[0]?.org_id;
        if (!orgId) throw new Error('project not found locally');

        let locId: string | null = locationId || null;
        if (locationId === '__new__' && newLocationName.trim()) {
          locId = crypto.randomUUID();
          await tx.execute(
            `insert into locations (id, org_id, project_id, parent_id, name, created_at)
             values (?, ?, ?, null, ?, datetime('now'))`,
            [locId, orgId, projectId, newLocationName.trim()],
          );
        } else if (locationId === '__new__') {
          locId = null;
        }

        await tx.execute(
          `insert into punch_items
             (id, org_id, project_id, location_id, title, trade, status, priority,
              due_date, assigned_to, created_by, created_at, updated_at)
           values (?, ?, ?, ?, ?, ?, 'open', 2, ?, ?, ?, datetime('now'), datetime('now'))`,
          [itemId, orgId, projectId, locId, title.trim(), trade || null,
           dueDate || null, assignee || null, userId],
        );
        if (photo) {
          await tx.execute(
            `insert into photos (id, org_id, item_id, kind, storage_path, uploaded_at, created_by, created_at)
             values (?, ?, ?, 'before', null, null, ?, datetime('now'))`,
            [photo.id, orgId, itemId, userId],
          );
        }
        if (locId) {
          localStorage.setItem(LAST_LOCATION_KEY(projectId), locId);
        }
      });
      router.push(`/projects/${projectId}`);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not save item');
      setSaving(false);
    }
  }

  return (
    <main className="mx-auto max-w-lg p-4">
      <h1 className="mb-4 text-xl font-bold">New punch item</h1>
      <form onSubmit={save} className="flex flex-col gap-3">
        {photo ? (
          <Image src={photo.previewUrl} alt="Defect" width={400} height={300} unoptimized
            className="max-h-64 w-full rounded object-cover" />
        ) : (
          <PhotoCapture onCapture={setPhoto} label="Take defect photo" />
        )}
        <select className="rounded border p-3" value={locationId}
          onChange={(e) => setLocationId(e.target.value)} aria-label="Location">
          <option value="">No location</option>
          {locations.map((l) => (
            <option key={l.id} value={l.id}>{locationLabel(l.id, locations)}</option>
          ))}
          <option value="__new__">+ New location…</option>
        </select>
        {locationId === '__new__' && (
          <input className="rounded border p-3" placeholder="Location name (e.g. Unit 204)"
            value={newLocationName} onChange={(e) => setNewLocationName(e.target.value)} />
        )}
        <input className="rounded border p-3" placeholder="What needs fixing?" required
          value={title} onChange={(e) => setTitle(e.target.value)} />
        <select className="rounded border p-3" value={trade}
          onChange={(e) => setTrade(e.target.value)} aria-label="Trade">
          <option value="">Trade (optional)</option>
          {TRADES.map((t) => <option key={t} value={t}>{t}</option>)}
        </select>
        <select className="rounded border p-3" value={assignee}
          onChange={(e) => setAssignee(e.target.value)} aria-label="Assign to">
          <option value="">Unassigned</option>
          {subs.map((s) => (
            <option key={s.user_id} value={s.user_id}>
              {s.full_name}{s.company_name ? ` (${s.company_name})` : ''}
            </option>
          ))}
        </select>
        <input className="rounded border p-3" type="date" value={dueDate}
          onChange={(e) => setDueDate(e.target.value)} aria-label="Due date" />
        {error && <p className="text-sm text-red-600">{error}</p>}
        <button className="rounded bg-black p-3 font-semibold text-white disabled:opacity-50"
          type="submit" disabled={saving}>
          {saving ? 'Saving…' : 'Save item'}
        </button>
      </form>
    </main>
  );
}
```

- [ ] **Step 3: Verify build, then manually verify the quick-add loop**

Run: `npx tsc --noEmit && npm run build`
Expected: clean.

Manual check (`npm run dev` as `gc@test.dev`):
1. From a project, tap `+` → capture/select a photo (desktop: any image file) → preview shows.
2. Pick "+ New location…", type "Unit 204", fill title "Fix drywall", trade plumbing, save.
3. Lands back on the punch list with the item grouped under "Unit 204".
4. DevTools offline → add another item (photo + existing location) → still instant.

- [ ] **Step 4: Commit**

```bash
git add src/components "src/app/(app)"
git commit -m "feat(web): camera-first quick-add flow with inline location creation"
```

---

### Task 8: Item detail page with photos, history, and status actions

**Files:**
- Create: `src/components/photo-grid.tsx`, `src/components/status-buttons.tsx`
- Create: `src/app/(app)/items/[id]/page.tsx`

- [ ] **Step 1: Photo grid component**

Create `src/components/photo-grid.tsx`:

```tsx
'use client';
import Image from 'next/image';
import { usePhotoUrl } from '@/lib/photos/use-photo-url';

export type PhotoRow = {
  id: string;
  kind: 'before' | 'after';
  storage_path: string | null;
  uploaded_at: string | null;
};

function Photo({ photo }: { photo: PhotoRow }) {
  const url = usePhotoUrl(photo);
  return (
    <div className="relative">
      {url ? (
        <Image src={url} alt={photo.kind} width={200} height={150} unoptimized
          className="h-28 w-full rounded object-cover" />
      ) : (
        <div className="h-28 w-full animate-pulse rounded bg-gray-200" />
      )}
      {!photo.uploaded_at && (
        <span className="absolute bottom-1 right-1 rounded bg-amber-500 px-1 text-xs text-white">
          pending upload
        </span>
      )}
    </div>
  );
}

export function PhotoGrid({ photos, kind }: { photos: PhotoRow[]; kind: 'before' | 'after' }) {
  const filtered = photos.filter((p) => p.kind === kind);
  if (filtered.length === 0) return null;
  return (
    <section className="mb-4">
      <h2 className="mb-1 text-sm font-semibold text-gray-500">
        {kind === 'before' ? 'Defect photos' : 'Proof of fix'}
      </h2>
      <div className="grid grid-cols-3 gap-2">
        {filtered.map((p) => <Photo key={p.id} photo={p} />)}
      </div>
    </section>
  );
}
```

- [ ] **Step 2: Status buttons component**

Create `src/components/status-buttons.tsx`:

```tsx
'use client';
import { useState } from 'react';
import type { PunchStatus, Role } from '@/lib/domain/status';
import { changeStatus } from '@/lib/data/status-actions';

/**
 * Role-aware transition buttons. The "after photo required for done" rule
 * is enforced here (spec): the Done button is disabled until an after photo
 * exists. Kick back requires a note (spec).
 */
export function StatusButtons({
  itemId, status, role, userId, hasAfterPhoto, onNeedAfterPhoto,
}: {
  itemId: string;
  status: PunchStatus;
  role: Role;
  userId: string;
  hasAfterPhoto: boolean;
  onNeedAfterPhoto: () => void;
}) {
  const [kickbackNote, setKickbackNote] = useState('');
  const [showKickback, setShowKickback] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function go(to: PunchStatus, note?: string) {
    setError(null);
    try {
      await changeStatus({ itemId, from: status, to, role, userId, note });
      setShowKickback(false);
      setKickbackNote('');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not update status');
    }
  }

  const isGC = role === 'admin' || role === 'member';
  const btn = 'rounded p-3 font-semibold text-white disabled:opacity-50';

  return (
    <div className="flex flex-col gap-2">
      {/* Sub + GC working actions */}
      {status === 'open' && (
        <button className={`${btn} bg-blue-600`} onClick={() => go('in_progress')}>
          Start work
        </button>
      )}
      {(status === 'open' || status === 'in_progress') && (
        hasAfterPhoto ? (
          <button className={`${btn} bg-yellow-600`} onClick={() => go('done')}>
            Mark done
          </button>
        ) : (
          <button className={`${btn} bg-yellow-600`} onClick={onNeedAfterPhoto}>
            Add proof photo to finish
          </button>
        )
      )}
      {status === 'in_progress' && (
        <button className="rounded border p-3 font-semibold" onClick={() => go('open')}>
          Stop work
        </button>
      )}
      {/* GC-only verification actions */}
      {isGC && status === 'done' && (
        <button className={`${btn} bg-green-600`} onClick={() => go('verified')}>
          ✓ Verify fix
        </button>
      )}
      {isGC && (status === 'done' || status === 'verified') && !showKickback && (
        <button className="rounded border border-red-300 p-3 font-semibold text-red-700"
          onClick={() => setShowKickback(true)}>
          Kick back
        </button>
      )}
      {showKickback && (
        <div className="flex flex-col gap-2 rounded border border-red-300 p-3">
          <textarea className="rounded border p-2 text-sm" placeholder="What still needs fixing? (required)"
            value={kickbackNote} onChange={(e) => setKickbackNote(e.target.value)} />
          <div className="flex gap-2">
            <button className={`${btn} flex-1 bg-red-600`} disabled={!kickbackNote.trim()}
              onClick={() => go('open', kickbackNote.trim())}>
              Send back to open
            </button>
            <button className="rounded border px-4 font-semibold"
              onClick={() => setShowKickback(false)}>
              Cancel
            </button>
          </div>
        </div>
      )}
      {error && <p className="text-sm text-red-600">{error}</p>}
    </div>
  );
}
```

- [ ] **Step 3: Item detail page**

Create `src/app/(app)/items/[id]/page.tsx`:

```tsx
'use client';
import { use, useState } from 'react';
import Link from 'next/link';
import { useQuery } from '@powersync/react';
import { db } from '@/lib/powersync/db';
import type { PunchStatus } from '@/lib/domain/status';
import { useRole } from '@/lib/data/use-role';
import { useUserId } from '@/lib/data/use-session';
import { OfflineBanner } from '@/components/offline-banner';
import { StatusChip } from '@/components/status-chip';
import { PhotoGrid, type PhotoRow } from '@/components/photo-grid';
import { StatusButtons } from '@/components/status-buttons';
import { PhotoCapture, type CapturedPhoto } from '@/components/photo-capture';

type ItemDetail = {
  id: string; org_id: string; project_id: string; title: string;
  description: string | null; trade: string | null; status: PunchStatus;
  due_date: string | null; assigned_to: string | null;
  location_name: string | null; assignee_name: string | null;
};

type EventRow = {
  id: string; from_status: PunchStatus | null; to_status: PunchStatus;
  note: string | null; created_at: string; actor_name: string | null;
};

export default function ItemPage({ params }: { params: Promise<{ id: string }> }) {
  const { id: itemId } = use(params);
  const role = useRole();
  const userId = useUserId();
  const [capturing, setCapturing] = useState(false);

  const { data: itemRows } = useQuery<ItemDetail>(
    `select i.id, i.org_id, i.project_id, i.title, i.description, i.trade, i.status,
            i.due_date, i.assigned_to,
            l.name as location_name, omp.full_name as assignee_name
     from punch_items i
     left join locations l on l.id = i.location_id
     left join org_member_profiles omp on omp.user_id = i.assigned_to
     where i.id = ?`,
    [itemId],
  );
  const { data: photos } = useQuery<PhotoRow>(
    `select id, kind, storage_path, uploaded_at from photos
     where item_id = ? order by created_at`,
    [itemId],
  );
  const { data: events } = useQuery<EventRow>(
    `select e.id, e.from_status, e.to_status, e.note, e.created_at,
            omp.full_name as actor_name
     from punch_item_events e
     left join org_member_profiles omp on omp.user_id = e.actor_id
     where e.item_id = ? order by e.created_at desc`,
    [itemId],
  );

  const item = itemRows[0];
  if (!item) return <main className="p-4">Loading…</main>;
  const hasAfterPhoto = photos.some((p) => p.kind === 'after');

  async function addAfterPhoto(photo: CapturedPhoto) {
    if (!item || !userId) return;
    await db.execute(
      `insert into photos (id, org_id, item_id, kind, storage_path, uploaded_at, created_by, created_at)
       values (?, ?, ?, 'after', null, null, ?, datetime('now'))`,
      [photo.id, item.org_id, item.id, userId],
    );
    setCapturing(false);
  }

  return (
    <main className="mx-auto max-w-lg p-4">
      <OfflineBanner />
      <Link href={`/projects/${item.project_id}`} className="text-sm text-blue-600">
        ‹ Back to punch list
      </Link>
      <div className="mb-1 mt-2 flex items-center justify-between">
        <h1 className="text-xl font-bold">{item.title}</h1>
        <StatusChip status={item.status} />
      </div>
      <p className="mb-4 text-sm text-gray-500">
        {[item.location_name, item.trade, item.assignee_name,
          item.due_date && `due ${item.due_date}`].filter(Boolean).join(' · ')}
      </p>
      {item.description && <p className="mb-4 text-sm">{item.description}</p>}

      <PhotoGrid photos={photos} kind="before" />
      <PhotoGrid photos={photos} kind="after" />

      {capturing ? (
        <div className="mb-4"><PhotoCapture onCapture={addAfterPhoto} label="Take proof photo" /></div>
      ) : (
        <button className="mb-4 w-full rounded border p-2 text-sm"
          onClick={() => setCapturing(true)}>
          + Add {item.status === 'verified' ? '' : 'proof '}photo
        </button>
      )}

      {role && userId && (
        <StatusButtons itemId={item.id} status={item.status} role={role} userId={userId}
          hasAfterPhoto={hasAfterPhoto} onNeedAfterPhoto={() => setCapturing(true)} />
      )}

      <section className="mt-6">
        <h2 className="mb-1 text-sm font-semibold text-gray-500">History</h2>
        <ul className="divide-y rounded border text-sm">
          {events.map((e) => (
            <li key={e.id} className="p-2">
              <span className="font-medium">{e.actor_name ?? 'Someone'}</span>
              {' '}{e.from_status ? `${e.from_status} → ` : ''}{e.to_status}
              {e.note && <span className="block text-gray-500">“{e.note}”</span>}
              <span className="block text-xs text-gray-400">{e.created_at}</span>
            </li>
          ))}
          {events.length === 0 && <li className="p-2 text-gray-500">No changes yet.</li>}
        </ul>
      </section>
    </main>
  );
}
```

- [ ] **Step 4: Verify build, then manually verify the GC flow**

Run: `npx tsc --noEmit && npm run build`
Expected: clean.

Manual check as `gc@test.dev`:
1. Open the item created in Task 7 → photo shows under "Defect photos", status chip Open.
2. Start work → chip flips to In progress, history gains a row instantly (offline-capable).
3. Add proof photo → Mark done → Verify fix appears → verify → chip Verified.
4. Kick back requires a note; sending back sets Open with the note in history.

- [ ] **Step 5: Commit**

```bash
git add src/components "src/app/(app)"
git commit -m "feat(web): item detail with photos, offline status history, verify/kickback"
```

---

### Task 9: Sub "My items" view, role-based home, login polish

**Files:**
- Create: `src/app/(app)/my-items/page.tsx`
- Modify: `src/app/page.tsx` (role-based redirect)
- Modify: `src/app/login/page.tsx` (pending state)

- [ ] **Step 1: My items page**

Create `src/app/(app)/my-items/page.tsx`:

```tsx
'use client';
import Link from 'next/link';
import { useQuery } from '@powersync/react';
import type { PunchStatus } from '@/lib/domain/status';
import { useUserId } from '@/lib/data/use-session';
import { OfflineBanner } from '@/components/offline-banner';
import { StatusChip } from '@/components/status-chip';

type MyItem = {
  id: string; title: string; trade: string | null; status: PunchStatus;
  due_date: string | null; project_name: string; location_name: string | null;
};

export default function MyItemsPage() {
  const userId = useUserId();
  const { data: items } = useQuery<MyItem>(
    `select i.id, i.title, i.trade, i.status, i.due_date,
            p.name as project_name, l.name as location_name
     from punch_items i
     join projects p on p.id = i.project_id
     left join locations l on l.id = i.location_id
     where i.assigned_to = ? and i.status != 'verified'
     order by p.name, l.name, i.due_date`,
    [userId ?? ''],
  );

  const byProject = new Map<string, MyItem[]>();
  for (const item of items) {
    const bucket = byProject.get(item.project_name) ?? [];
    bucket.push(item);
    byProject.set(item.project_name, bucket);
  }

  return (
    <main className="mx-auto max-w-lg p-4">
      <OfflineBanner />
      <h1 className="mb-4 text-xl font-bold">My items</h1>
      {items.length === 0 && (
        <p className="py-8 text-center text-sm text-gray-500">
          Nothing assigned to you right now.
        </p>
      )}
      {[...byProject.entries()].map(([project, projectItems]) => (
        <section key={project} className="mb-4">
          <h2 className="mb-1 text-sm font-semibold text-gray-500">{project}</h2>
          <ul className="divide-y rounded border">
            {projectItems.map((item) => (
              <li key={item.id}>
                <Link href={`/items/${item.id}`} className="flex items-center gap-2 p-3">
                  <span className="flex-1">
                    <span className="block font-medium">{item.title}</span>
                    <span className="block text-xs text-gray-500">
                      {[item.location_name, item.trade, item.due_date && `due ${item.due_date}`]
                        .filter(Boolean).join(' · ')}
                    </span>
                  </span>
                  <StatusChip status={item.status} />
                </Link>
              </li>
            ))}
          </ul>
        </section>
      ))}
    </main>
  );
}
```

- [ ] **Step 2: Role-based home redirect**

Replace `src/app/page.tsx` with:

```tsx
'use client';
import { useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { useRole } from '@/lib/data/use-role';

export default function Home() {
  const router = useRouter();
  const role = useRole();
  useEffect(() => {
    // Subs land on their assignments; GC roles (and unknown-while-syncing)
    // land on projects. Authorization is server-side; this is just routing.
    router.replace(role === 'sub' ? '/my-items' : '/projects');
  }, [role, router]);
  return null;
}
```

- [ ] **Step 3: Login pending state**

In `src/app/login/page.tsx`, add a `pending` state and disable the button while signing in. Replace the component body:

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
  const [pending, setPending] = useState(false);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (pending) return;
    setPending(true);
    setError(null);
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) {
      setError(error.message);
      setPending(false);
      return;
    }
    router.push('/');
    router.refresh();
  }

  return (
    <main className="mx-auto flex min-h-dvh max-w-sm flex-col justify-center gap-4 p-6">
      <h1 className="text-2xl font-bold">Punchlist</h1>
      <form onSubmit={onSubmit} className="flex flex-col gap-3">
        <input className="rounded border p-3" type="email" placeholder="Email" autoComplete="email"
          value={email} onChange={(e) => setEmail(e.target.value)} required />
        <input className="rounded border p-3" type="password" placeholder="Password"
          autoComplete="current-password"
          value={password} onChange={(e) => setPassword(e.target.value)} required />
        {error && <p className="text-sm text-red-600">{error}</p>}
        <button className="rounded bg-black p-3 font-semibold text-white disabled:opacity-50"
          type="submit" disabled={pending}>
          {pending ? 'Signing in…' : 'Sign in'}
        </button>
      </form>
    </main>
  );
}
```

- [ ] **Step 4: Seed a sub user and verify the sub flow manually**

```bash
# create sub user (service-role key from `npx supabase status -o json`)
curl -s -X POST "http://127.0.0.1:54321/auth/v1/admin/users" \
  -H "apikey: $SR" -H "Authorization: Bearer $SR" -H "Content-Type: application/json" \
  -d '{"email":"sub@test.dev","password":"test1234","email_confirm":true}'
```

Then in the local Studio SQL editor:

```sql
insert into profiles (id, full_name, company_name)
  select id, 'Sam Sub', 'Apex Plumbing' from auth.users where email = 'sub@test.dev'
  on conflict do nothing;
insert into org_members (org_id, user_id, role)
  select '11111111-1111-1111-1111-111111111111', id, 'sub'
  from auth.users where email = 'sub@test.dev'
  on conflict do nothing;
```

Manual check:
1. As `gc@test.dev`: assign an item to Sam Sub from quick-add.
2. Log out, log in as `sub@test.dev` → lands on `/my-items`.

Note: until the PowerSync instance is provisioned, the sub's local DB won't
receive the item (no downstream sync) — verify the page renders and shows the
empty state without errors. The role redirect uses the synced directory, so it
also falls back to `/projects` — this is the documented pre-provisioning
limitation, not a bug.

- [ ] **Step 5: Verify build and unit tests**

Run: `npm run verify`
Expected: lint, typecheck, all unit tests, build pass.

- [ ] **Step 6: Commit**

```bash
git add src/app
git commit -m "feat(web): sub my-items view, role-based home, login pending state"
```

---

### Task 10: Docs, env template, full verification

**Files:**
- Create: `.env.example`
- Modify: `README.md`

- [ ] **Step 1: Write the env template**

Create `.env.example`:

```bash
# From `npx supabase status` (local) or the Supabase dashboard (hosted)
NEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:54321
NEXT_PUBLIC_SUPABASE_ANON_KEY=
# PowerSync instance URL — leave empty for local-only development
# (writes queue locally and upload when an instance is configured)
NEXT_PUBLIC_POWERSYNC_URL=
```

- [ ] **Step 2: Rewrite the README**

Replace `README.md` with:

```markdown
# Punchlist

Construction punch list app for general contractors. A GC walks the site
logging defects with photos, assigns them to subcontractors, and verifies
fixes; subs see their items and mark them done with proof photos. Fully
offline-first.

**Stack:** Next.js (App Router) + TypeScript + Tailwind · Supabase
(Postgres/Auth/Storage/RLS) · PowerSync (in-browser SQLite sync).

**Docs:** design spec and implementation plans live in `docs/superpowers/`.

## Local development

Prereqs: Node 22+, Docker (for local Supabase).

```bash
npm install
npx supabase start          # local Postgres/Auth/Storage stack
cp .env.example .env.local  # fill values from `npx supabase status`
npm run dev
```

Create a test login (replace $SR with the service-role key from
`npx supabase status -o json`):

```bash
curl -s -X POST "http://127.0.0.1:54321/auth/v1/admin/users" \
  -H "apikey: $SR" -H "Authorization: Bearer $SR" -H "Content-Type: application/json" \
  -d '{"email":"gc@test.dev","password":"test1234","email_confirm":true}'
```

Then seed an org + membership in Studio's SQL editor
(`npx supabase status` → Studio URL):

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

## Tests

```bash
npm run verify        # lint + typecheck + unit tests + build
npx supabase test db  # pgTAP RLS/RPC tests (security requirements)
```

## PowerSync provisioning (required for device sync)

The app runs local-only without it (writes queue). To enable sync:

1. Create an instance at https://powersync.journeyapps.com (or self-host).
2. Connect it to the Supabase Postgres (PowerSync's "Supabase" guide).
3. Deploy `powersync/sync-rules.yaml` to the instance.
4. Set `NEXT_PUBLIC_POWERSYNC_URL` in `.env.local` / Vercel env.
```

- [ ] **Step 3: Full verification**

Run: `npm run verify && npx supabase test db`
Expected: everything passes (unit suite + 25 pgTAP tests).

- [ ] **Step 4: Golden-path manual walkthrough (offline included)**

As `gc@test.dev` with DevTools network Offline for steps 2–4:
1. Online: log in, open a project.
2. Offline: quick-add an item with photo → instant, banner shows queued photo.
3. Offline: open the item, Start work → history row appears instantly.
4. Offline: add proof photo, Mark done.
5. Online: banner clears as the photo uploads (check `photos` row gains
   `storage_path` in Studio once a PowerSync instance is provisioned;
   without one, confirm no console errors and the queue persists).

- [ ] **Step 5: Commit**

```bash
git add README.md .env.example
git commit -m "docs: README with local setup, tests, and PowerSync provisioning"
```

---

## Definition of done for Plan 2

- `npm run verify` passes (lint, typecheck, ~20 unit tests, build).
- `npx supabase test db` passes (25 pgTAP tests including RPC precedence).
- Manual golden paths demonstrated: GC quick-add with photo (offline),
  GC verify/kick-back with note, sub my-items rendering, photo upload queue
  with pending badges.
- All work committed to `claude/affectionate-dirac-x2hcqe`.
