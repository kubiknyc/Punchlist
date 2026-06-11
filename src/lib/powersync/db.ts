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
