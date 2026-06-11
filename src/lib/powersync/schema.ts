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
