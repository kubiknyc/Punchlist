-- Table privileges: current Supabase images no longer auto-grant DML on
-- public tables to API roles — grants must be explicit. RLS (0002) remains
-- the row filter; these grants only enable the verbs RLS then constrains.
-- anon gets nothing: the app is invitation-only with no public reads.
grant usage on schema public to authenticated, service_role;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant all on all tables in schema public to service_role;
alter default privileges in schema public
  grant select, insert, update, delete on tables to authenticated;
alter default privileges in schema public
  grant all on tables to service_role;

-- Code-review fixes for 0002:
--  1. Sub-update guard compared an allowlist of columns, leaving id/created_at
--     mutable by subs and silently rotting as the schema grows. Invert it:
--     subs may change nothing but status (updated_at is system-managed).
--  2. The guard ran for service_role/postgres (auth.uid() is null) and blocked
--     legitimate server-side/admin updates — triggers are not bypassed by RLS.
--  3. events_sub_insert let subs forge 'verified' history rows.
--  4. updated_at was only refreshed on the sub path; use a generic trigger.

create or replace function enforce_sub_item_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- Service role / admin scripts (no JWT) and GC roles pass through.
  if auth.uid() is null or is_gc(old.org_id) then return new; end if;
  -- Sub path: every column except status (and system-managed updated_at)
  -- must be unchanged. Whole-row comparison so new columns are guarded
  -- by default.
  if to_jsonb(new) - 'status' - 'updated_at'
     is distinct from
     to_jsonb(old) - 'status' - 'updated_at' then
    raise exception 'subs may only change status';
  end if;
  if not (old.status, new.status) in
     (('open','in_progress'),('in_progress','done'),('open','done'),
      ('in_progress','open'),(old.status, old.status)) then
    raise exception 'invalid status transition for sub: % -> %', old.status, new.status;
  end if;
  return new;
end;
$$;

-- Subs may record only the transitions they are allowed to make; 'verified'
-- history rows must come from GC roles.
drop policy if exists events_sub_insert on punch_item_events;
create policy events_sub_insert on punch_item_events for insert
  with check (actor_id = auth.uid()
    and to_status in ('open','in_progress','done')
    and exists (select 1 from punch_items i where i.id = item_id and i.assigned_to = auth.uid()));

-- Generic updated_at maintenance for all writers (GC, sub, service role).
-- Trigger name sorts after punch_items_sub_guard so it runs second.
create or replace function set_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger punch_items_updated_at before update on punch_items
  for each row execute function set_updated_at();
