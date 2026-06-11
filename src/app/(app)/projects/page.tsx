'use client';
import { useState } from 'react';
import { useQuery, useStatus } from '@powersync/react';
import { db } from '@/lib/powersync/db';
import { supabase } from '@/lib/supabase/client';

export default function ProjectsPage() {
  const status = useStatus();
  const { data: projects } = useQuery<{ id: string; name: string; status: string }>(
    `select id, name, status from projects where status = 'active' order by created_at desc`,
  );
  const [name, setName] = useState('');

  async function createProject(e: React.FormEvent) {
    e.preventDefault();
    const { data } = await supabase.auth.getUser();
    const userId = data.user?.id;
    if (!userId || !name.trim()) return;
    // org_id: single-org v1 — first membership row synced locally
    const orgRow = await db.get<{ org_id: string }>(
      `select org_id from projects limit 1`,
    ).catch(() => null);
    const orgId = orgRow?.org_id ?? (await fetchOrgId(userId));
    await db.execute(
      `insert into projects (id, org_id, name, status, created_at)
       values (uuid(), ?, ?, 'active', datetime('now'))`,
      [orgId, name.trim()],
    );
    setName('');
  }

  return (
    <main className="mx-auto max-w-lg p-4">
      {!status.connected && (
        <p className="mb-2 rounded bg-amber-100 p-2 text-sm">
          Offline — changes will sync
        </p>
      )}
      <h1 className="mb-4 text-xl font-bold">Projects</h1>
      <form onSubmit={createProject} className="mb-4 flex gap-2">
        <input className="flex-1 rounded border p-2" placeholder="New project name"
          value={name} onChange={(e) => setName(e.target.value)} />
        <button className="rounded bg-black px-4 text-white" type="submit">Add</button>
      </form>
      <ul className="divide-y">
        {projects.map((p) => (
          <li key={p.id} className="p-3">{p.name}</li>
        ))}
      </ul>
    </main>
  );
}

async function fetchOrgId(userId: string): Promise<string> {
  const { data, error } = await supabase
    .from('org_members').select('org_id').eq('user_id', userId).limit(1).single();
  if (error || !data) throw new Error('No org membership found');
  return data.org_id;
}
