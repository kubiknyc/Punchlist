# Testing Patterns

**Analysis Date:** 2026-06-12

## Test Framework

**Runner:**
- Vitest 4.1.8
- Config: `vitest.config.ts`

**Assertion Library:**
- Vitest built-in assertion APIs (expect)

**Run Commands:**
```bash
npm test                                           # Run all tests (vitest run)
npx vitest run tests/unit/status.test.ts          # Single test file
npx vitest run -t "name"                          # Single test by name
```

## Test File Organization

**Location:**
- Co-located in `tests/unit/` directory at project root
- Pattern: test files in dedicated `tests/unit/` folder, not alongside source

**Naming:**
- Pattern: `{module}.test.ts` 
- Example: `status.test.ts` tests `src/lib/domain/status.ts`

**Structure:**
```
tests/
└── unit/
    └── status.test.ts
```

**Test discovery:**
- Vitest config specifies: `include: ['tests/unit/**/*.test.ts']`
- Only `.test.ts` files in `tests/unit/` are run

## Test Structure

**Suite Organization:**
```typescript
import { describe, it, expect } from 'vitest';
import { canTransition, resolveStatusConflict, STATUS_ORDER } from '@/lib/domain/status';

describe('canTransition', () => {
  it('lets subs walk open -> in_progress -> done', () => {
    expect(canTransition('sub', 'open', 'in_progress')).toBe(true);
  });
  
  it('blocks subs from verifying or un-verifying', () => {
    expect(canTransition('sub', 'done', 'verified')).toBe(false);
  });
});
```

**Patterns:**
- Top-level `describe()` blocks group tests by function
- `it()` blocks test specific behavior with clear, readable descriptions
- Each test is independent; no setup/teardown observed in current tests

**Assertion Pattern:**
- Direct comparison with `expect().toBe()`
- Boolean assertions: `expect(value).toBe(true)` or `expect(value).toBe(false)`
- Length assertions: `expect(Object.keys(STATUS_ORDER)).toHaveLength(4)`

## Test Types

**Unit Tests:**
- Scope: Pure domain logic functions (`src/lib/domain/status.ts`)
- Approach: Direct function calls with role and status parameters
- Example: Testing `canTransition()` with all role/status combinations
- No mocking required (pure functions, no I/O)

**Example from `tests/unit/status.test.ts`:**
```typescript
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
```

**Integration Tests:**
- Not currently present in codebase
- RLS tests exist in `supabase/tests/rls.test.sql` (pgTAP, not JavaScript)
- Run with: `supabase test db` (requires local Supabase stack)

**E2E Tests:**
- Not implemented
- Would test full user workflows (offline sync, conflict resolution, auth flow)

## Mocking

**Framework:** None observed
- Vitest supports `vi` for mocking, but not used in current tests
- Pure function testing requires no mocks

**What to Mock (if needed):**
- External services (Supabase client calls)
- Network requests (PowerSync connector)
- Date/time functions
- Database queries

**What NOT to Mock:**
- Domain logic functions (test directly)
- TypeScript types and constants (test their shape)
- Path aliases (Vitest resolves `@/*` via config)

**If Needed, Use Vitest's `vi` Module:**
```typescript
// Example pattern (not in current code)
import { vi } from 'vitest';

const mockSubabase = {
  from: vi.fn().mockReturnValue({
    upsert: vi.fn().mockResolvedValue({ error: null })
  })
};
```

## Test Data and Fixtures

**Test Data:**
- Inline literals in test cases: `canTransition('sub', 'open', 'in_progress')`
- No separate fixtures file
- Test data is minimal (roles and status strings)

**Example from `tests/unit/status.test.ts`:**
```typescript
// Inline test data
const testCases = [
  { role: 'sub', from: 'open', to: 'in_progress', expected: true },
  { role: 'sub', from: 'done', to: 'verified', expected: false },
  { role: 'member', from: 'done', to: 'verified', expected: true },
];
```

**Factories:**
- Not used; domain logic is simple enough to test with direct values

## Coverage

**Requirements:** None enforced
- No coverage thresholds in vitest.config.ts
- Tests focus on business-critical domain logic (status transitions)

**View Coverage:**
```bash
# No built-in command configured
# To add coverage, would run:
npx vitest run --coverage
```

## Testing Checklist

When writing tests for new domain logic:

1. **Test Happy Path:** Normal use case with valid inputs
2. **Test Role-Based Access:** All roles (admin, member, sub) if relevant
3. **Test All Statuses:** Cover all status values in transitions
4. **Test Invalid Transitions:** Ensure blocked transitions are enforced
5. **Test Edge Cases:** Same state to same state, boundary values
6. **Test Conflicts:** Offline sync conflict resolution rules

## Special Notes

**Domain Logic Testing Strategy:**
- All domain rules in `src/lib/domain/status.ts` are testable as pure functions
- No I/O means tests run instantly with no fixtures or mocks
- Plan 2 adds server-side RLS via `record_status_event` RPC — keep parallel tests in sync:
  - Client rule: `src/lib/domain/status.ts` (unit tested here)
  - Server rule: `supabase/migrations/` (tested via `supabase test db`)

**Test Maintenance:**
- When changing status transitions, update both test cases and the comment explaining the rule
- If RLS rules change, add corresponding test case in `supabase/tests/rls.test.sql`
- Three access-control layers must stay in sync (see CLAUDE.md Architecture section)

---

*Testing analysis: 2026-06-12*
