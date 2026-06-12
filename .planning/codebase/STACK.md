# Technology Stack

**Analysis Date:** 2026-06-12

## Languages

**Primary:**
- TypeScript 5.x - All application code, strict mode enabled
- JavaScript/JSX - Build tools, configuration
- SQL - Postgres migrations and RLS policies

## Runtime

**Environment:**
- Node.js v22 - Backend/dev environment
- Web/Browser - Client-side PWA execution
- Postgres 15+ - Database engine (Supabase-hosted)

**Package Manager:**
- npm 10.x
- Lockfile: present (`package-lock.json`)

## Frameworks

**Core:**
- Next.js 16.2.9 - App Router, server/client components, middleware, built-in optimizations
- React 19.2.4 - UI component framework
- TypeScript 5.x - Type safety

**Styling:**
- Tailwind CSS 4.x - Utility-first CSS framework
- PostCSS - CSS processing

**Data & Sync:**
- PowerSync (@powersync/web 1.38.3, @powersync/react 1.10.0) - Offline-first sync engine
- Supabase SDK (@supabase/supabase-js 2.108.1) - Database client, authentication
- Supabase SSR (@supabase/ssr 0.12.0) - Server-side auth session handling
- SQLite (via @journeyapps/wa-sqlite 1.7.0) - Browser-based embedded database

**Testing:**
- Vitest 4.1.8 - Unit test runner and assertions
- Location: `tests/unit/**/*.test.ts`

**Build/Dev:**
- Next.js built-in tooling (Webpack/Turbopack)
- ESLint 9.x - Linting
- TypeScript 5.x - Type checking

## Key Dependencies

**Critical:**
- @powersync/web 1.38.3 - Offline database sync to Postgres via PowerSync service
- @powersync/react 1.10.0 - React hooks for PowerSync queries and status
- @supabase/supabase-js 2.108.1 - Postgres client, auth, storage access
- @supabase/ssr 0.12.0 - Secure server-side session refresh and cookie management
- @journeyapps/wa-sqlite 1.7.0 - Browser SQLite: in-memory persistence for offline-first architecture

**Infrastructure:**
- next 16.2.9 - Full-stack framework, App Router, middleware, image optimization
- react 19.2.4 - View layer
- react-dom 19.2.4 - DOM rendering

**Fonts:**
- @next/font integration - Geist Sans/Mono from Google Fonts (embedded in `src/app/layout.tsx`)

## Configuration

**Environment:**
- `.env.local` - Local development (not committed)
- Required vars: `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `NEXT_PUBLIC_POWERSYNC_URL`
- `NEXT_PUBLIC_*` prefix allows browser access; sensitive API keys kept server-side only

**TypeScript:**
- Config: `tsconfig.json`
- Strict mode: enabled
- Path alias: `@/*` → `src/*`
- Targets: ES2017, esnext modules, bundler resolution

**Build & Testing:**
- Build config: `next.config.ts` (minimal configuration)
- Test config: `vitest.config.ts` - Path alias matching, unit test include pattern
- Linting: ESLint 9 via Next.js config (eslint-config-next 16.2.9)

**Styling:**
- Tailwind CSS v4 with PostCSS
- CSS import: `src/app/globals.css`

## Platform Requirements

**Development:**
- Node.js v22+
- npm 10+
- Git 2.53+
- GitHub CLI (gh) for workflows
- Optional: Supabase CLI for local database testing (`supabase test db`)

**Production:**
- **Hosting:** Vercel (mentioned in CLAUDE.md; Next.js optimized)
- **Database:** Supabase PostgreSQL (cloud-hosted, Auth included)
- **Sync Service:** PowerSync instance (self-hosted or Supabase-integrated)
- **Static Assets:** Vercel CDN

---

*Stack analysis: 2026-06-12*
