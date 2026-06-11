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
