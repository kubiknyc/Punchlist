import {
  AbstractPowerSyncDatabase,
  PowerSyncBackendConnector,
  UpdateType,
} from '@powersync/web';
import { supabase } from '@/lib/supabase/client';

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
