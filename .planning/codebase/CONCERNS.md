# Codebase Concerns

**Analysis Date:** 2026-06-12

## Tech Debt

**Unimplemented RPC-based status enforcement (Plan 2 incomplete):**
- Issue: Status transitions are validated on the client side in `src/lib/domain/status.ts`, but the Postgres `record_status_event` RPC designed in Plan 2 (documented in `docs/superpowers/plans/2026-06-11-punchlist-field-workflows.md` Task 1) has not been implemented. Client code currently routes `punch_item_events` inserts to raw Supabase table ops instead of the RPC, so the server-side conflict precedence logic and stage-aware status validation do not run.
- Files: `src/lib/powersync/connector.ts`, `supabase/migrations/0002_rls.sql` (RPC stub only), missing `supabase/migrations/0004_field_workflows.sql`
- Impact: Offline GC-vs-GC conflicts resolve by last-write-wins, not by stage precedence. A GC who takes an item from `done` to `open` offline, then goes online while another GC verifies the same item, could have their kickback silently lost. The spec's guarantee that "a later-stage status is never downgraded by a stale offline write" holds only against sub writes (enforced by the trigger in Task 3 of Plan 1), not GC writes.
- Fix approach: Implement the `record_status_event(p_id, p_item_id, p_from, p_to, p_note)` RPC as documented (Task 1 Step 3 of Plan 2), then route `punch_item_events` inserts through `mapCrudOp` to call the RPC instead of upserting the table directly.

**Missing upload-mapper and connector refactoring (Plan 2 incomplete):**
- Issue: `src/lib/powersync/connector.ts` handles all CRUD operations generically. Per Plan 2 Task 2, it should route `punch_item_events` inserts through a pure `mapCrudOp()` function in `src/lib/powersync/upload-mapper.ts` (not yet created), which maps table/op pairs to upload actions (RPC, upsert, update, delete, or skip). Without this, status changes cannot be properly routed to the RPC.
- Files: `src/lib/powersync/connector.ts` (needs refactoring), missing `src/lib/powersync/upload-mapper.ts`, missing test `tests/unit/upload-mapper.test.ts`
- Impact: Status event uploads bypass the RPC entirely, losing conflict precedence and server-side validation. GC-vs-GC conflicts are not resolved safely.
- Fix approach: Extract the connector loop into `mapCrudOp(CrudLike): UploadAction` (pure function, TDD with tests), then refactor connector to call it for each op and dispatch RPC/upsert/update/delete accordingly.

**No denormalized org_member_profiles table (Plan 2 incomplete):**
- Issue: Plan 2 Task 1 requires a `org_member_profiles` denormalized table (maintained by triggers from `org_members` + `profiles`) to enable PowerSync buckets to sync member directory data to clients. Currently missing: the migration `supabase/migrations/0004_field_workflows.sql`, the sync rules in `powersync/sync-rules.yaml`, and the schema table in `src/lib/powersync/schema.ts`.
- Files: Missing `supabase/migrations/0004_field_workflows.sql`, `powersync/sync-rules.yaml` incomplete, `src/lib/powersync/schema.ts` does not include `org_member_profiles`
- Impact: Client code cannot look up subcontractor names or roles offline. The punch list page attempts to use `org_member_profiles` in joins but it does not exist, causing query failures. Sub visibility: subs cannot render their assignments' assignee names or see the subcontractor directory. GC filtering by assignee fails.
- Fix approach: Create the migration with the `org_member_profiles` table and its maintenance triggers (sync triggers on `org_members` and `profiles`), add to PowerSync schema, update sync rules to include the new buckets.

**Status history not enforced server-side (Plan 2 incomplete):**
- Issue: The `punch_item_events` table is trusted to record status transitions correctly, but there is no server-side trigger or RPC to enforce them. A malicious client could insert arbitrary `from_status` → `to_status` pairs, or a stale offline write could record a transition that violates the spec.
- Files: `src/lib/domain/status.ts` (client rule only), missing RPC implementation
- Impact: Trust boundary is weak. The RPC documented in Plan 2 Task 1 Step 3 is designed to catch this (validates `canTransition()` server-side, applies stage precedence), but it is not implemented.
- Fix approach: Implement the RPC and route events through it (see "Missing upload-mapper" above).

**Connector does not discard rejected photo uploads (Plan 2 incomplete):**
- Issue: Photo blob storage logic is documented in Plan 2 Task 4 (compression, IndexedDB queue, background uploader) but not yet implemented. `src/lib/powersync/connector.ts` has no logic to handle photo `storage_path` patches from the uploader; it would try to upsert the photos row directly, which could fail RLS if the uploader is a sub trying to patch a photo created by another user.
- Files: Missing `src/lib/photos/compress.ts`, `src/lib/photos/blob-store.ts`, `src/lib/photos/uploader.ts`, `src/lib/photos/use-photo-url.ts`, `src/lib/photos/use-pending-count.ts`
- Impact: Photo uploads cannot work until the uploader is implemented and the connector routes them (e.g., patching `photos.storage_path` after a successful blob upload should skip RLS errors gracefully).
- Fix approach: Implement the photo pipeline (Plan 2 Task 4), then ensure connector handles permanent rejections (already does with error code checks).

**Frontend lacks required Plan 2 UI components (Plan 2 incomplete):**
- Issue: The punch list, quick-add, item detail, and sub "my items" pages are documented in Plan 2 Tasks 6–9 but not implemented. `src/app/page.tsx` is still the default Next.js scaffold. Core components missing: `PhotoCapture`, `PhotoGrid`, `StatusButtons`, `StatusChip`, `OfflineBanner`.
- Files: `src/app/page.tsx` (is a scaffold, not role-based router), missing `src/app/(app)/projects/[id]/page.tsx`, missing `src/app/(app)/projects/[id]/new-item/page.tsx`, missing `src/app/(app)/items/[id]/page.tsx`, missing `src/app/(app)/my-items/page.tsx`, missing `src/components/` (all)
- Impact: The app has no usable UI. Users can log in and see the projects page (Task 9 of Plan 1), but cannot create items, view details, or mark them done. The entire punch list workflow is missing.
- Fix approach: Implement Plan 2 Tasks 6–9: punch list page with location grouping, quick-add with camera, item detail with photos and status actions, sub my-items view, and supporting components.

**Home page not role-aware (Plan 2 incomplete):**
- Issue: `src/app/page.tsx` is a default Next.js scaffold (`<main>` with "To get started, edit the page.tsx file"). Should be replaced with a role-based redirect: subs → `/my-items`, GCs → `/projects`. This requires the `useRole()` hook from Plan 2 Task 5, which depends on the `org_member_profiles` sync data.
- Files: `src/app/page.tsx`
- Impact: Users land on a Next.js template page, not the app.
- Fix approach: Replace `src/app/page.tsx` with the role-aware redirect documented in Plan 2 Task 9 Step 2.

**Incomplete PowerSync sync rules:**
- Issue: `powersync/sync-rules.yaml` is not checked into the repository (should be at the repo root, not bundled into the app—it's deployed to the PowerSync service separately). The CLAUDE.md notes the file should exist and define GC and sub sync buckets. Currently missing or incomplete.
- Files: Missing `powersync/sync-rules.yaml`
- Impact: Without sync rules deployed to PowerSync, the instance will not sync any data. This is expected during development (before the instance is provisioned), but the file should be present and accurate for future deployment.
- Fix approach: Create/commit `powersync/sync-rules.yaml` with the bucket definitions from Plan 2 Task 2 Step 7.

## Missing Critical Features

**No offline-without-login support (Plan 3 required, spec requirement):**
- Problem: The CLAUDE.md spec states "the app must open offline without a login wall," but `src/middleware.ts` redirects unauthenticated requests to `/login` before the page is served. In offline mode, this redirect cannot complete (no network), so the PWA shell cached page is unreachable.
- Impact: First time a user opens the app offline (device never authenticated), they cannot access it even though the spec requires offline-first. The workaround is to go online once to log in, cache the app, then go offline.
- Blocking: Plan 3 task: implement a service worker that serves cached pages offline before middleware runs.

**No PWA manifest or service worker:**
- Problem: The app is documented as a PWA ("offline-first construction punch list PWA"), but has no `manifest.json` or service worker. Without these, mobile browsers will not prompt to install, and pages are not reliably cached.
- Files: Missing `public/manifest.json`, missing `src/app/service-worker.ts` (or equivalent)
- Impact: Users cannot install on home screen; offline experience is unreliable (depends on browser HTTP cache, not app-level caching).
- Blocking: Plan 3 task.

**No field editing UI (Plan 3 deferred):**
- Problem: Users can create punch items with a photo, title, trade, assignee, location, and due date, but cannot edit these fields after creation. Editing is deferred to Plan 3.
- Impact: A GC who misspells a title or assigns to the wrong sub must delete and recreate the item (no deletion UI either).
- Blocking: Plan 3.

**No server-side "after photo required for done" enforcement (Plan 2 Task 8 notes as client-enforced):**
- Problem: The spec rule "an item cannot be marked done without a proof photo" is enforced on the client (StatusButtons component disables the Done button). A malicious offline client or direct Postgres write could bypass this.
- Impact: Trust boundary.
- Fix approach: Add a check in the `record_status_event` RPC (Plan 2 Task 1): if `p_to = 'done'`, verify that at least one `after` photo exists.

**Photos not excluded from closed projects (Plan 3 deferred):**
- Problem: The spec says "closed projects are excluded from sync to bound phone storage." Currently, punch items and photos are not filtered by project status in PowerSync sync rules.
- Impact: If a GC closes a project with 1000+ photos, all of them remain synced to phones and consume storage. Sync rules would need to denormalize `project.status` onto `punch_items` rows to filter downstream.
- Blocking: Plan 3, requires schema changes.

**No location parent sync for subs (Plan 3 deferred):**
- Problem: Subs see only their assigned item's direct `location_id`, not the parent location name. If the hierarchy is Floor 2 › Unit 204, the sub sees only "Unit 204" offline. The spec allows deferring this.
- Impact: Reduced context for subs on large buildings.
- Blocking: Plan 3, low priority.

## Security Considerations

**Client-enforced status transitions (mitigated by server-side RPC in Plan 2):**
- Risk: The client calls `changeStatus()` (TDD in Plan 2 Task 5), which validates `canTransition()` before inserting an event. If a malicious client skips this check and inserts an invalid event, the current implementation (without the RPC) will accept it.
- Files: `src/lib/domain/status.ts` (client rule), missing `record_status_event` RPC
- Current mitigation: The RLS policy on `punch_items` allows subs to UPDATE only their assigned items, and the `enforce_sub_item_update()` trigger (in Plan 1 Task 3, `supabase/migrations/0002_rls.sql` lines 287–310) restricts subs to status-only changes and disallows certain transitions. This provides a second layer of validation.
- Recommendations: Implement the RPC (Plan 2 Task 1) to validate and apply status transitions server-side, making client-side rules advisory only.

**RLS policies assume current role from JWT (trust boundary):**
- Risk: All RLS policies use `auth.uid()` and check role membership in `org_members`. If the JWT is compromised or the JWT secret is leaked, an attacker can impersonate any user and access their data.
- Files: `supabase/migrations/0001_schema.sql`, `supabase/migrations/0002_rls.sql`
- Current mitigation: Supabase Auth handles JWT signing and expiration; `src/middleware.ts` refreshes sessions. The app should never store the JWT secret on the client.
- Recommendations: Monitor Supabase audit logs; use short JWT expiration; rely on Supabase's Auth infrastructure.

**Photo storage RLS assumes folder path = org_id (Plan 2 incomplete):**
- Risk: The `record_status_event` RPC and photo storage policies (Plan 2 Task 1, lines 311–325) assume folder paths are `{org_id}/{item_id}/{photo_id}.jpg`. A malicious client could upload a photo with a path like `attacker-org-id/victim-item-id/photo.jpg` and read victim's item if the parsing is wrong.
- Files: Missing `supabase/migrations/0004_field_workflows.sql`, policy logic uses `storage.foldername(name)[1]::uuid`
- Current mitigation: RLS policies on `punch_items` already prevent a sub from uploading photos for items not assigned to them.
- Recommendations: Test the `storage.foldername()` parsing in pgTAP (Plan 2 Task 1 already includes `field.test.sql`); validate folder structure strictly in the uploader.

**No CORS or CSRF protection documented:**
- Risk: The app is a Next.js SSR app on Vercel. Supabase uses cookie-based auth (via `@supabase/ssr`). CSRF tokens are not mentioned in the code.
- Files: `src/lib/supabase/middleware.ts`
- Current mitigation: `@supabase/ssr` handles cookie serialization safely; Next.js middleware runs on every request. State-changing operations (status changes, photo uploads) go through PowerSync uploads, which require a valid JWT.
- Recommendations: Document CORS/CSRF strategy; rely on Supabase/Next.js frameworks to handle.

## Fragile Areas

**PowerSync sync rules not version-controlled (Plan 2 incomplete):**
- Files: Missing `powersync/sync-rules.yaml`
- Why fragile: Sync rules are deployed to the PowerSync service separately and are not part of the app bundle. If rules change and someone forgets to redeploy, the client will request data it's not authorized to receive, or will not receive data it expects. There is no way to verify rule changes locally.
- Safe modification: Commit sync rules to the repository; add a CI step to validate them (e.g., schema inspection if PowerSync CLI supports it); document the deployment process.
- Test coverage: PowerSync does not provide local validation of sync rules. RLS tests (pgTAP) validate the Postgres side; there is no equivalent for PowerSync bucket parameters. Manual testing required.

**Status transition rule duplication (client + server + DB trigger):**
- Files: `src/lib/domain/status.ts` (client rule), `supabase/migrations/0002_rls.sql` (trigger for subs), missing `record_status_event` RPC
- Why fragile: The spec's status flow (`open → in_progress → done → verified`) and the sub restriction (no verify/downgrade) are expressed in three places: client TypeScript, DB trigger, and (planned) RPC. If the spec changes, all three must be updated in sync.
- Safe modification: Once the RPC is implemented (Plan 2 Task 1), the trigger becomes redundant. Remove it and rely on the RPC + client validation. Keep `src/lib/domain/status.ts` as the source of truth; generate Postgres validation from it if possible.
- Test coverage: The unit test `tests/unit/status.test.ts` (Plan 1 Task 5) covers the TypeScript rule. pgTAP tests (Plan 1 Task 4) cover the trigger. Once the RPC is implemented, add pgTAP tests for it (Plan 2 Task 1 already includes these in `field.test.sql`).

**Organization resolution logic scattered across pages (Plan 2 incomplete):**
- Files: `src/app/(app)/projects/page.tsx` (documented in Plan 2 Task 6) calls `resolveOrgId()`, which tries synced directory, then existing project, then network. Similar logic likely needed elsewhere.
- Why fragile: If org resolution fails (user has no membership row, offline when trying the network), the page will error. The logic is duplicated across components.
- Safe modification: Once `org_member_profiles` is synced (Plan 2 Task 1), org membership is always available offline. Extract resolution into a hook like `useOrgId()` and centralize it.
- Test coverage: No unit tests for `resolveOrgId()`. Add tests for fallback scenarios (local miss, network fail).

**Camera input captured as PNG, needs JPEG compression (Plan 2 incomplete):**
- Files: Missing `src/lib/photos/compress.ts` (planned in Plan 2 Task 4)
- Why fragile: Mobile `<input accept="image/*" capture="environment">` captures in device format (PNG, HEIC, JPEG). Without compression, large photos consume phone storage and upload bandwidth. The plan documents `compressImage()` to downscale and re-encode as JPEG; without it, photos are uncompressed.
- Safe modification: Implement Plan 2 Task 4 compression + blob store + uploader. Test with large photos (4MB+) offline to ensure IndexedDB and upload queue work.
- Test coverage: `tests/unit/compress.test.ts` (Plan 2 Task 4) covers the math; no integration tests for the full photo pipeline yet.

## Performance Bottlenecks

**PowerSync database syncs entire org for GCs (unbounded):**
- Problem: The GC sync rule pulls all projects, locations, punch items, events, and photos for the org. On a large job with 10K items and 50K photos, this sync is slow and consumes storage.
- Files: `powersync/sync-rules.yaml` (to be implemented)
- Cause: The spec says "GCs get their whole org (active projects only)," but does not mention pagination or filtering. Sync happens on every app open.
- Improvement path: Filter by recent `created_at` or status; implement incremental sync; add pagination to the UI (e.g., "load older items"). This is deferred to Plan 3 (office UI with table filtering).

**No database indexes on commonly filtered columns (Plan 2 incomplete):**
- Problem: The punch list page filters by status, trade, and assignee. PowerSync sync rules don't have indexes in Postgres either.
- Files: `supabase/migrations/0001_schema.sql` has minimal indexes; Plan 2 Task 1 adds only `locations.project_id` index
- Cause: Early development, indexes are optimized after profiling.
- Improvement path: Add indexes on `(project_id, status)`, `(assigned_to, status)`, `(trade)` for query plans. pgTAP does not profile query time, so manual load testing required.

**Photo blob uploader blocks on single file, no parallelism:**
- Problem: `uploadPendingPhotos()` (Plan 2 Task 4) uploads photos sequentially with exponential backoff. If there are 10 pending photos and the first fails, the rest wait for a retry.
- Files: Missing `src/lib/photos/uploader.ts` (Plan 2 Task 4)
- Cause: Simplicity; backpressure is safer than hammering the server.
- Improvement path: Parallelize with a concurrency limit (e.g., 3 uploads at a time); implement per-photo retry tracking so one failure doesn't stall others. This is low priority (photo counts are usually small).

## Test Coverage Gaps

**No integration tests for PowerSync sync (offline-online round-trip):**
- What's not tested: A real-world scenario where a user creates an item offline, syncs, then modifies it on another device while the first is offline. PowerSync's test harness is not exposed in the repository.
- Files: `tests/unit/` exists; no integration test suite
- Risk: Sync conflicts, race conditions, and credential refresh bugs are not caught until manual testing or production.
- Priority: High (this is the core feature). Medium-term fix: add Vitest integration tests that mock PowerSync or use a local PowerSync instance.

**No E2E tests (deferred to Plan 3):**
- What's not tested: User workflows (login, quick-add, verify, offline scenario). Playwright is deferred to Plan 3.
- Files: No `e2e/` directory
- Risk: UI bugs, middleware issues, offline-online transitions are not caught until manual testing.
- Priority: High. Medium-term fix: add Playwright E2E tests (Plan 3).

**Photo pipeline not tested (Plan 2 incomplete):**
- What's not tested: Compression (unit tests planned but file missing), blob store (IDB operations), uploader (retries, backoff). The flow is integration-heavy.
- Files: Missing `tests/unit/compress.test.ts`, `tests/unit/uploader.test.ts`, no blob store tests
- Risk: Photo upload failures, local storage exhaustion, and blob cleanup are not caught.
- Priority: Medium. Fix: implement Plan 2 Task 4 tests.

**RLS policies tested only at the table level (no storage/file-level RLS tests):**
- What's not tested: Photo storage bucket RLS policies. pgTAP tests focus on `punch_items`, `profiles`, `org_members`.
- Files: `supabase/tests/rls.test.sql` (Plan 1), missing tests for storage object-level policies
- Risk: A sub might be able to read or write files for items not assigned to them if the storage policies are wrong.
- Priority: High (photos are sensitive). Fix: add pgTAP tests for storage object ACLs (Plan 2 Task 1 includes tests for the RPC but not storage).

**No tests for org_member_profiles trigger logic (Plan 2 incomplete):**
- What's not tested: The triggers that sync `org_members` + `profiles` → `org_member_profiles`. If a profile name changes or a user is removed, does the denormalized table update correctly?
- Files: Missing `supabase/migrations/0004_field_workflows.sql`, missing test cases in `supabase/tests/field.test.sql`
- Risk: Denormalized data becomes stale, subs see wrong assignee names, or removed members remain in the directory.
- Priority: Medium. Fix: add pgTAP test cases in Plan 2 Task 1 (already planned).

## Scaling Limits

**Single-org architecture (no multi-tenancy):**
- Current capacity: Designed for one general contractor organization. User can belong to one org (has one membership row).
- Limit: If a sub works for multiple GCs, they must maintain separate logins. The schema doesn't prevent adding multiple memberships, but the UI doesn't support it.
- Scaling path: Add org switching UI; allow users to have multiple memberships; update sync rules to handle org context per user (instead of single `org_id` parameter).

**Closed projects remain in schema (unbounded rows):**
- Current capacity: Projects are soft-closed (`status = 'closed'`), not deleted. As projects accumulate, the `projects` table grows unbounded.
- Limit: Postgres can handle 1M+ rows easily, but sync rules exclude closed projects (Plan 2), so old project rows eventually de-sync and ghost.
- Scaling path: Implement project archival (move old closed projects to an archive table); add a TTL to soft deletes if needed.

## Dependencies at Risk

**@powersync/web at 1.38.3 (no breaking changes documented):**
- Risk: PowerSync is a young library (v1.x). The connector at `src/lib/powersync/connector.ts` uses `AbstractPowerSyncDatabase`, `PowerSyncBackendConnector`, and `UpdateType`—these could change.
- Impact: A minor version bump could break the connector.
- Migration plan: Pin the version; monitor PowerSync releases; test on local Supabase before updating. The connector is simple and should be easy to adapt.

**Next.js 16.2.9 with App Router (deprecated Turbopack option):**
- Risk: The plan explicitly opted out of Turbopack with `--no-turbopack` (likely due to stability). Turbopack is the future; staying on non-Turbopack might not be supported long.
- Impact: A future Next.js release might drop non-Turbopack support. Build times may become slower over time.
- Migration plan: Test Turbopack on a branch periodically; be ready to re-enable if issues are fixed.

**Tailwind v4 (recently released, limited ecosystem):**
- Risk: Tailwind v4 is very recent. Third-party component libraries may not support it yet; PostCSS plugins might break.
- Impact: If a component library needs to be added, it might not work with v4.
- Migration plan: Keep components custom and small; avoid heavy component libraries (which is already the case here). Tailwind v4 is well-tested; this is low risk.

**@supabase/ssr with cookies (session refresh tight coupling):**
- Risk: The connector's `fetchCredentials()` calls `supabase.auth.getSession()`, which reads cookies set by `@supabase/ssr`. If middleware session refresh fails silently, the connector will get null credentials and uploads will stall.
- Impact: Session expiration + PowerSync upload failure; the app appears to hang offline.
- Migration plan: Add error boundaries; log credential fetch failures; implement session refresh retry logic. Consider storing credentials in a separate signal so they can be accessed without cookies.

---

*Concerns audit: 2026-06-12*
