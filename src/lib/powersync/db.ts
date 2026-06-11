'use client';
import { PowerSyncDatabase } from '@powersync/web';
import { AppSchema } from './schema';
import { SupabaseConnector } from './connector';

export const db = new PowerSyncDatabase({
  schema: AppSchema,
  database: { dbFilename: 'punchlist.db' },
});

let connecting = false;
export async function connectPowerSync() {
  if (connecting) return;
  if (!process.env.NEXT_PUBLIC_POWERSYNC_URL) {
    console.warn('NEXT_PUBLIC_POWERSYNC_URL not set — running local-only, writes stay queued');
    return;
  }
  connecting = true;
  try {
    await db.connect(new SupabaseConnector());
  } catch (e) {
    connecting = false; // allow retry on next mount
    console.error('PowerSync connect failed', e);
  }
}
