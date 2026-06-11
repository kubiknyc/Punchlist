'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { supabase } from '@/lib/supabase/client';

export default function LoginPage() {
  const router = useRouter();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) { setError(error.message); return; }
    router.push('/projects');
    router.refresh();
  }

  return (
    <main className="mx-auto flex min-h-dvh max-w-sm flex-col justify-center gap-4 p-6">
      <h1 className="text-2xl font-bold">Punchlist</h1>
      <form onSubmit={onSubmit} className="flex flex-col gap-3">
        <input className="rounded border p-3" type="email" placeholder="Email"
          value={email} onChange={(e) => setEmail(e.target.value)} required />
        <input className="rounded border p-3" type="password" placeholder="Password"
          value={password} onChange={(e) => setPassword(e.target.value)} required />
        {error && <p className="text-sm text-red-600">{error}</p>}
        <button className="rounded bg-black p-3 font-semibold text-white" type="submit">
          Sign in
        </button>
      </form>
    </main>
  );
}
