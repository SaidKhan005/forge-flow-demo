# Phase 11a.11c.3 — Staging apply result

> **SUPERSEDED 2026-04-26.** This artifact records the Supabase
> staging apply. Postgres host pivoted to Azure DB Flexible Server in
> `11a.11c.4-6`. Retained as Supabase-historical.

**Status:** APPLIED TO STAGING.

**Generated:** 2026-04-25.

## Result

- Supabase CLI is pinned locally via `package.json` / `package-lock.json`.
- `supabase/config.toml` exists.
- Repo is linked to staging project ref `tngrpfaddcologhrltyo`.
- `supabase db push --dry-run` listed exactly the five expected migrations.
- `supabase db push` applied the five migrations to staging.
- `supabase migration list` shows all five local migrations matched remotely:
  - `202604250001`
  - `202604250002`
  - `202604250003`
  - `202604250004`
  - `202604250005`

## Extension Verification

- `pgcrypto` is installed at `1.3`.
- `vector` is available and installed at `0.8.0`.
- pgvector smoke query succeeded with a finite cosine distance.
- `age` is not listed in `pg_available_extensions` and is not installed on
  this Supabase project.

AGE-dependent graph traversal remains blocked/fallback-only until an
AGE-capable target is provisioned. The corpus storage migration handled this
gracefully by skipping AGE when unavailable.

## Local Env

`.env.local` is the canonical private operator env file for this workspace.
It must remain gitignored and untracked. Future commits should not delete,
rename, or commit it.

The helper scripts load `.env.local` automatically when needed:

```powershell
npm run supabase:staging:setup
npm run supabase:staging:preflight
```
