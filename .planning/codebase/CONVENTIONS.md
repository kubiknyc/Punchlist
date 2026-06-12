# Coding Conventions

**Analysis Date:** 2026-06-12

## Naming Patterns

**Files:**
- TypeScript/TSX files use lowercase with hyphens for multi-word names: `db.ts`, `status.ts`, `connector.ts`, `schema.ts`
- React components (pages) use lowercase with hyphens: `page.tsx`, `projects/page.tsx`
- Index/barrel files named `index.*` (not observed in current codebase, but standard Next.js)

**Functions:**
- camelCase for regular functions: `connectPowerSync()`, `canTransition()`, `resolveStatusConflict()`, `fetchOrgId()`, `updateSession()`
- Component functions are PascalCase: `Providers`, `LoginPage`, `RootLayout`, `ProjectsPage`, `Home`
- Async functions clearly marked as such: `async function fetchOrgId()`, `async function createProject()`
- Event handlers use `on` prefix: `onSubmit()` in `src/app/login/page.tsx`

**Variables:**
- camelCase for all variable names: `connecting`, `orgId`, `setName`, `setError`, `userId`, `projects`, `email`, `password`
- React state uses destructuring pattern: `const [name, setName] = useState('')`
- Constants and enums use UPPERCASE_SNAKE_CASE when appropriate: `SUB_TRANSITIONS`, `STATUS_ORDER`, `UpdateType.PUT`, `UpdateType.PATCH`, `UpdateType.DELETE`

**Types:**
- PascalCase for type names: `PunchStatus`, `Role`, `Database`, `Metadata`
- Union types use pipe syntax: `type PunchStatus = 'open' | 'in_progress' | 'done' | 'verified'`
- Type imports use `type` keyword: `import type { NextRequest } from 'next/server'`, `import type { Metadata } from "next"`

**Table/Column Names (Database):**
- Tables use snake_case: `punch_items`, `punch_item_events`, `org_members`
- Columns use snake_case: `org_id`, `project_id`, `location_id`, `created_at`, `updated_at`, `assigned_to`, `from_status`, `to_status`

## Code Style

**Formatting:**
- Indentation: 2 spaces (observed consistently in all files)
- Line length: No hard limit enforced, but lines generally kept readable
- String quotes: Mix of single and double quotes (both observed), but tends toward single quotes in component files (`'use client'`, `'/login'`)
- Semicolons: Always present at end of statements

**Linting:**
- Tool: ESLint 9 with Next.js config (`eslint-config-next`)
- Config: `eslint.config.mjs` (flat config format)
- Extends: `eslint-config-next/core-web-vitals` and `eslint-config-next/typescript`
- Ignored directories: `.next`, `out`, `build`, `next-env.d.ts`
- No Prettier config detected; formatting is ESLint-based

**Strict TypeScript:**
- `tsconfig.json` has `"strict": true` enabled
- All types must be explicitly defined; no implicit `any`
- `"noEmit": true` for type-checking (no code generation from tsc)
- Path aliases configured: `"@/*": "./src/*"` for clean imports

## Import Organization

**Order:**
1. React and external library imports (React, Next.js, third-party packages)
2. Path alias imports (`@/*`) for internal modules
3. No blank lines observed between groups in current code

**Examples from codebase:**
```typescript
// src/app/providers.tsx
import { useEffect } from 'react';
import { PowerSyncContext } from '@powersync/react';
import { db, connectPowerSync } from '@/lib/powersync/db';
```

```typescript
// src/lib/powersync/connector.ts
import {
  AbstractPowerSyncDatabase,
  PowerSyncBackendConnector,
  UpdateType,
} from '@powersync/web';
import { supabase } from '@/lib/supabase/client';
```

**Path Aliases:**
- `@/*` maps to `src/*` (configured in `tsconfig.json`)
- Used throughout for clean, non-relative imports: `import { supabase } from '@/lib/supabase/client'`
- Enables moving files without updating import paths

## Error Handling

**Patterns:**
- Destructuring error objects from async operations: `const { error } = await supabase.auth.getUser()`
- Conditional error checks: `if (error) { /* handle */ }`
- Direct error throwing for app state assertions: `throw new Error('No org membership found')`
- Try-catch for async operations that may need recovery: `try { ... } catch (e: unknown) { ... }`
- Type-safe error handling with unknown cast: `const code = (e as { code?: string })?.code ?? ''`

**Error Classification:**
- Permanent errors (RLS denial `42501`, constraint violations `23505`/`23503`, custom code `P0001`) are caught and logged, then discarded from queue
- Transient errors (network) are re-thrown to allow PowerSync to retry
- User-facing errors set state: `setError(err instanceof Error ? err.message : 'fallback message')`

**Example from `src/lib/powersync/connector.ts`:**
```typescript
try {
  for (const op of tx.crud) {
    const table = supabase.from(op.table);
    if (op.op === UpdateType.PUT) {
      const { error } = await table.upsert({ id: op.id, ...op.opData });
      if (error) throw error;
    }
  }
  await tx.complete();
} catch (e: unknown) {
  const code = (e as { code?: string })?.code ?? '';
  if (['42501', '23505', '23503', 'P0001'].includes(code)) {
    console.error('Discarding rejected local write', e);
    await tx.complete();
  } else {
    throw e;
  }
}
```

## Logging

**Framework:** `console` (no dedicated logging library observed)

**Patterns:**
- `console.warn()` for non-fatal issues: `console.warn('NEXT_PUBLIC_POWERSYNC_URL not set — running local-only')`
- `console.error()` for errors: `console.error('PowerSync connect failed', e)`, `console.error('Discarding rejected local write', e)`
- Logging includes context: error objects, URLs, operation names
- No debug logging observed in current code

## Comments

**When to Comment:**
- Explain *why*, not *what*: "Offline conflict rule from the spec" explains the rationale
- Note architectural decisions: "// GC roles may move items to any other status (verify, kick back, reopen)"
- Clarify business rules: "// Permanent rejections must not wedge the upload queue"
- Single-line comments preferred with `//`

**Example from `src/lib/domain/status.ts`:**
```typescript
/** Offline conflict rule from the spec: a later-stage status is never downgraded by a stale write. */
export function resolveStatusConflict(a: PunchStatus, b: PunchStatus): PunchStatus {
```

**JSDoc/TSDoc:**
- Used for exported functions and types
- Format: `/** description */` above function/type
- No parameter documentation observed; rely on clear type names instead

## Function Design

**Size:** Functions are kept small and focused. Example sizes:
- `canTransition()`: 3 lines (simple logic)
- `resolveStatusConflict()`: 1 line (pure function)
- `createProject()`: ~15 lines (async handler with error handling)
- `connectPowerSync()`: ~12 lines (connection setup with guard)

**Parameters:**
- Use destructuring for object parameters: `({ children }: { children: React.ReactNode })`
- Keep parameters minimal; use composition for providers
- Type parameters explicitly: `useQuery<{ id: string; name: string; status: string }>()`

**Return Values:**
- Pure functions return computed values: `STATUS_ORDER[a] >= STATUS_ORDER[b] ? a : b`
- Async functions return promises: `async function updateSession(request: NextRequest): Promise<NextResponse>`
- No implicit `void`; async handlers that don't return are explicitly typed
- Null returned for missing optional values: `fetchCredentials()` returns `null` if no endpoint

## Module Design

**Exports:**
- Named exports preferred: `export function canTransition()`, `export const db = ...`, `export type PunchStatus = ...`
- Default exports for components/pages: `export default function Home()`, `export default function RootLayout()`
- Re-exports group related functionality: `export const AppSchema = ...` from schema.ts

**Barrel Files:**
- Not used in current codebase; each module imports directly from source files
- Example: `import { db } from '@/lib/powersync/db'` not `import { db } from '@/lib/powersync'`

**Class Design:**
- Used for PowerSync integration: `class SupabaseConnector implements PowerSyncBackendConnector`
- Methods are async and follow the interface contract: `async fetchCredentials()`, `async uploadData()`

---

*Convention analysis: 2026-06-12*
