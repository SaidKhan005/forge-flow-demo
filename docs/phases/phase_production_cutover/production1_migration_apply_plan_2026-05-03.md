# Production1 Migration Apply Plan

Updated: 2026-05-03
Status: Completed for cutoff `202605021900`; production runtime setup remains paused
Owner: F&F launch lane

This plan records the next operational Production1 database step before full
production cloud buildout.

No secret values, DSNs, tokens, or passwords belong in this file.

## Decision

Production1 migration apply was the next operational step and completed on
2026-05-03. The applied batch was 27 files, from
`202604280014_phase_9_0sigma_h2_audit_privacy_role.sql` through
`202605021900_phase_11A_3a_corpus_versions_seed_existing_chunks.sql`, using
`runbooks/phase_9_production1_migration_apply_runbook.md`.

This happens before full production buildout:

1. Apply/verify Production1 migrations. Completed 2026-05-03.
2. Then build production Firebase/proxy/DNS/static-egress/secrets.
3. Then run B43 Production1 audit-anchor deploy.
4. Then proceed toward cutover corpus/operator/live-traffic gates.

## Cutover Relationship

`cutover.1` repeats verification before corpus load. The cutover plan
originally placed "apply/verify queued Production1 migration batch" at the
start of `cutover.1`, but the tracker hoisted the apply event and it is now
complete through the cutoff above.

The apply is still not a corpus load, operator import, proxy deploy, DNS
change, provider call, or traffic switch.

## Future Batches

Anything after
`202605021900_phase_11A_3a_corpus_versions_seed_existing_chunks.sql` is not
part of this batch. New migrations from ongoing staging lanes must update drift
docs and wait for a later Production1 apply event.

After real operator/customer data lands, production migrations must follow the
locked online-migration discipline. The transition point is `cutover.4`.

## Execution Result

2026-05-03 result:

- Staging direct schema sentinels initially exposed a stale registry-only
  state. The exact batch was replayed on staging and then verified clean.
- Two SQL migrations were made replay-safe by dropping existing policies before
  recreating them:
  `202605020001_phase_11A_3b_graphify_review_audit.sql` and
  `202605020452_hardening_auth_login_attempts.sql`.
- Production1 applied all 27 files in order. No backout was needed.
- Production1 verification passed for table/column presence, RLS policies,
  tenant-leading indexes, AGE graph bootstrap/runtime grants, feature-flag
  grants, provider/corpus/admin idempotency tables, and auth lockout tables.
- Production1 still has zero operators, users, advisor source chunks, and
  corpus versions. Negative-tenant fixture smokes remain a cutover data-load
  gate.
- `proxy_migrations_applied` exists; rows remain empty until a Production1
  proxy startup records the runtime migration catalog.

## Execution Gates

Before any apply:

- Review `runbooks/phase_9_production1_migration_apply_runbook.md` in-session.
- Confirm the exact target by name only:
  `forge-flow-production1-pg-cmk`, database `forgeflow`.
- Confirm operator approval for this apply.
- Confirm a fresh Azure backup/restore point is available.
- Confirm staging has already applied the same file set successfully.
- Run local gates:
  - `flutter analyze --fatal-infos`
  - focused migration/auth/proxy tests
  - `dart run tool/rls_policy_lint.dart`
  - `dart run tool/migration_cutoff_lint.dart`
- Confirm no secret values will be pasted into chat or docs.

Stop with `BLOCKED` if any item is missing.

## Apply Scope

Apply in the exact order listed in the runbook. The cutoff file is:

`db/migrations/202605021900_phase_11A_3a_corpus_versions_seed_existing_chunks.sql`

Out of scope:

- Cloud Armor enforcement.
- Production proxy deploy.
- Firebase/Identity Platform setup.
- Static egress/NAT/DNS setup.
- Provider calls.
- Operator/customer data import.
- Corpus load.
- Any migration after the cutoff file.

## Verification

Use the runbook's verification sections for:

- table/column presence,
- RLS policies,
- tenant-leading indexes,
- AGE graph health bootstrap,
- proxy migration registry,
- negative-tenant read smoke where fixtures are available,
- `forge_admin` smoke,
- RLS lint.

Append the execution result to
`runbooks/phase_9_production1_migration_apply_runbook.md` after the apply.
