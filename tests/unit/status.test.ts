import { describe, it, expect } from 'vitest';
import { canTransition, resolveStatusConflict, STATUS_ORDER } from '@/lib/domain/status';

describe('canTransition', () => {
  it('lets subs walk open -> in_progress -> done', () => {
    expect(canTransition('sub', 'open', 'in_progress')).toBe(true);
    expect(canTransition('sub', 'in_progress', 'done')).toBe(true);
    expect(canTransition('sub', 'open', 'done')).toBe(true);
  });
  it('blocks subs from verifying or un-verifying', () => {
    expect(canTransition('sub', 'done', 'verified')).toBe(false);
    expect(canTransition('sub', 'verified', 'open')).toBe(false);
  });
  it('lets GC roles verify and kick back', () => {
    expect(canTransition('member', 'done', 'verified')).toBe(true);
    expect(canTransition('admin', 'done', 'open')).toBe(true);
    expect(canTransition('member', 'verified', 'open')).toBe(true);
  });
});

describe('resolveStatusConflict', () => {
  it('keeps the later-stage status', () => {
    expect(resolveStatusConflict('done', 'verified')).toBe('verified');
    expect(resolveStatusConflict('verified', 'in_progress')).toBe('verified');
    expect(resolveStatusConflict('open', 'open')).toBe('open');
  });
});

describe('STATUS_ORDER', () => {
  it('orders all four statuses', () => {
    expect(Object.keys(STATUS_ORDER)).toHaveLength(4);
  });
});
