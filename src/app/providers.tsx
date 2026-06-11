'use client';
import { useEffect } from 'react';
import { PowerSyncContext } from '@powersync/react';
import { db, connectPowerSync } from '@/lib/powersync/db';

export function Providers({ children }: { children: React.ReactNode }) {
  useEffect(() => { void connectPowerSync(); }, []);
  return <PowerSyncContext.Provider value={db}>{children}</PowerSyncContext.Provider>;
}
