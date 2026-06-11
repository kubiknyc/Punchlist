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
