begin;
select plan(12);

-- Seed: two orgs (cross-tenant isolation), one GC user + two subs in org A,
-- one member in org B.
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'gc@test.dev'),
  ('00000000-0000-0000-0000-0000000000b1', 'sub1@test.dev'),
  ('00000000-0000-0000-0000-0000000000b2', 'sub2@test.dev'),
  ('00000000-0000-0000-0000-0000000000c1', 'rival@test.dev');
insert into profiles (id, full_name) values
  ('00000000-0000-0000-0000-0000000000a1', 'GC'),
  ('00000000-0000-0000-0000-0000000000b1', 'Sub One'),
  ('00000000-0000-0000-0000-0000000000b2', 'Sub Two'),
  ('00000000-0000-0000-0000-0000000000c1', 'Rival GC');
insert into orgs (id, name) values
  ('00000000-0000-0000-0000-00000000aaaa', 'Acme GC'),
  ('00000000-0000-0000-0000-00000000bbbb', 'Rival Org');
insert into org_members (org_id, user_id, role) values
  ('00000000-0000-0000-0000-00000000aaaa', '00000000-0000-0000-0000-0000000000a1', 'member'),
  ('00000000-0000-0000-0000-00000000aaaa', '00000000-0000-0000-0000-0000000000b1', 'sub'),
  ('00000000-0000-0000-0000-00000000aaaa', '00000000-0000-0000-0000-0000000000b2', 'sub'),
  ('00000000-0000-0000-0000-00000000bbbb', '00000000-0000-0000-0000-0000000000c1', 'member');
insert into projects (id, org_id, name) values
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000aaaa', 'Tower A');
insert into punch_items (id, org_id, project_id, title, assigned_to, created_by) values
  ('00000000-0000-0000-0000-000000001101', '00000000-0000-0000-0000-00000000aaaa',
   '00000000-0000-0000-0000-000000000001', 'Fix drywall',
   '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-000000001102', '00000000-0000-0000-0000-00000000aaaa',
   '00000000-0000-0000-0000-000000000001', 'Paint touch-up',
   '00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000a1');

-- As service role / admin scripts (no JWT): trigger must not block
-- non-status updates (RLS is bypassed, triggers are not).
select lives_ok(
  $$ update punch_items set priority = 1
     where id = '00000000-0000-0000-0000-000000001102' $$,
  'service-role path can update non-status columns');

-- As GC: sees both items
set local role authenticated;
set local "request.jwt.claims" to '{"sub":"00000000-0000-0000-0000-0000000000a1"}';
select is((select count(*) from punch_items), 2::bigint, 'GC sees all org items');

-- As a member of another org: sees nothing of org A
set local "request.jwt.claims" to '{"sub":"00000000-0000-0000-0000-0000000000c1"}';
select is((select count(*) from punch_items), 0::bigint, 'other org sees no items');
select is((select count(*) from projects), 0::bigint, 'other org sees no projects');

-- As sub1: sees only own item
set local "request.jwt.claims" to '{"sub":"00000000-0000-0000-0000-0000000000b1"}';
select is((select count(*) from punch_items), 1::bigint, 'sub sees only assigned items');
select is((select title from punch_items), 'Fix drywall', 'sub sees the right item');

-- As sub1: cannot reassign own item (only status changes allowed)
select throws_ok(
  $$ update punch_items set assigned_to = '00000000-0000-0000-0000-0000000000b2'
     where id = '00000000-0000-0000-0000-000000001101' $$,
  'subs may only change status');

-- As sub1: cannot backdate created_at (whole-row guard)
select throws_ok(
  $$ update punch_items set created_at = '2020-01-01'
     where id = '00000000-0000-0000-0000-000000001101' $$,
  'subs may only change status');

-- As sub1: may walk the allowed transition...
select lives_ok(
  $$ update punch_items set status = 'in_progress'
     where id = '00000000-0000-0000-0000-000000001101' $$,
  'sub can move open -> in_progress');

-- ...but cannot self-verify
select throws_ok(
  $$ update punch_items set status = 'verified'
     where id = '00000000-0000-0000-0000-000000001101' $$,
  'invalid status transition for sub: in_progress -> verified');

-- As sub1: cannot forge a 'verified' history event
select throws_ok(
  $$ insert into punch_item_events (org_id, item_id, actor_id, to_status)
     values ('00000000-0000-0000-0000-00000000aaaa',
             '00000000-0000-0000-0000-000000001101',
             '00000000-0000-0000-0000-0000000000b1', 'verified') $$,
  '42501');

-- As sub1: may record an allowed-status event
select lives_ok(
  $$ insert into punch_item_events (org_id, item_id, actor_id, from_status, to_status)
     values ('00000000-0000-0000-0000-00000000aaaa',
             '00000000-0000-0000-0000-000000001101',
             '00000000-0000-0000-0000-0000000000b1', 'open', 'in_progress') $$,
  'sub can record an allowed status event');

select * from finish();
rollback;
