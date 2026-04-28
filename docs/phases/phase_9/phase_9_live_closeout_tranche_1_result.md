# Phase 9 Live-Closeout Tranche 1 Result

Updated: 2026-04-26.

Status: COMPLETE for tranche 1.

## Scope

Tranche 1 covered the live foundations needed before the remaining Phase 9
auth bindings:

- Production RS256 Firebase ID-token verification in the proxy.
- Real Dart Postgres driver adapter behind the repository seam.
- Staging-only auth-table RLS policy apply.
- Staging-only service-role / forge-admin table grants for those RLS policies.
- Live staging Firebase custom-token exchange plus local verifier smoke.

Not included: Production1 RLS mutation, real app login UI binding, operator
data load, production user traffic, iOS build verification, MFA live binding,
HIBP egress, Cloud Armor, reCAPTCHA, or admin-console HTTP/UI surfaces.

## Files Changed

- `pubspec.yaml`, `pubspec.lock`
- `tool/advisor_proxy/advisor_proxy.dart`
- `tool/advisor_proxy/main.dart`
- `lib/infrastructure/persistence/postgres/postgres_executor.dart`
- `lib/infrastructure/persistence/postgres/package_postgres_executor.dart`
- `db/migrations/202604260001_auth_rls_service_role_grants.sql`
- `test/advisor_proxy_test.dart`
- `test/operator_scoped_repository_test.dart`
- `docs/phases/phase_9/phase_9_execution_backlog.md`
- `docs/phases/phase_9/phase_9_context_checkpoint.md`
- `docs/phases/phase_9/phase_9_live_closeout_tranche_1_result.md`
- `PROJECT_TRACKER.md`

## Live Staging Work

Applied to staging only:

- `db/migrations/202604260000_auth_rls_per_tenant_policies.sql`
- `db/migrations/202604260001_auth_rls_service_role_grants.sql`

Verification highlights:

- `forge_admin_bypass=true`
- `service_role_has_forge_admin=true`
- `auth_tables_with_rls=12`
- `expected_policy_count=16`
- old auth service-role stubs count: `0`
- `service_role_permission_keys=81`
- bogus-tenant `service_role` read on `user_roles`: `0`
- `forge_admin` positive read path works
- `permission_keys` remains SELECT-only for `service_role`
- mutable auth tables grant DML to `service_role` and `forge_admin`
- audit tables preserve append-only grants for both roles

## Firebase Smoke

Used the existing staging Firebase web app without printing the web API key.
A one-off custom token was exchanged for an ID token, the local proxy verifier
validated that token against the live Firebase securetoken JWKS, and the smoke
user plus temporary token artifacts were removed.

Smoke results:

- `firebase_signin_smoke=ok`
- `firebase_rs256_verifier_smoke=ok`
- `firebase_smoke_cleanup=ok`

## Tests

- `dart analyze tool/advisor_proxy lib/infrastructure/persistence/postgres test/advisor_proxy_test.dart test/operator_scoped_repository_test.dart` - clean.
- `flutter test test/advisor_proxy_test.dart` - 119/119 passed.
- `flutter test test/operator_scoped_repository_test.dart` - 32/32 passed.
- Full `dart analyze` - clean.
- Focused Phase 9 sweep - 357/357 passed.

Full repo `flutter test` was not rerun after tranche 1. Known unrelated broad
suite failures remain documented in `docs/KNOWN_FAILING_TESTS.md`.

## Remaining Phase 9 Live Work

Next work starts with B4/B5/B6 in
`docs/phases/phase_9/phase_9_execution_backlog.md`:

- Firebase Auth client binding.
- Secure session storage binding.
- Auth session ledger writes.

Production1 auth-table RLS remains gated until staging soaks and the user
explicitly authorizes production mutation.
