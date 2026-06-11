export type PunchStatus = 'open' | 'in_progress' | 'done' | 'verified';
export type Role = 'admin' | 'member' | 'sub';

export const STATUS_ORDER: Record<PunchStatus, number> = {
  open: 0,
  in_progress: 1,
  done: 2,
  verified: 3,
};

const SUB_TRANSITIONS: ReadonlySet<string> = new Set([
  'open>in_progress',
  'in_progress>done',
  'open>done',
  'in_progress>open',
]);

export function canTransition(role: Role, from: PunchStatus, to: PunchStatus): boolean {
  if (from === to) return false;
  if (role === 'sub') return SUB_TRANSITIONS.has(`${from}>${to}`);
  return true; // GC roles may move items to any other status (verify, kick back, reopen)
}

/** Offline conflict rule from the spec: a later-stage status is never downgraded by a stale write. */
export function resolveStatusConflict(a: PunchStatus, b: PunchStatus): PunchStatus {
  return STATUS_ORDER[a] >= STATUS_ORDER[b] ? a : b;
}
