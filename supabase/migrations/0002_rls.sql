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
