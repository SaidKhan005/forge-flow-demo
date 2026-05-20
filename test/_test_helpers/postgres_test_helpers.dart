// Shared Postgres test-harness skip + URL-resolution helpers.
//
// Bucket 4f of the 2026-05-20 test-suite tightening audit consolidated
// the three independent copies of the "POSTGRES_TEST_URL → skip-reason"
// boilerplate that lived inline at the top of each `@Tags(['postgres'])`
// test file:
//
//   * `test/infrastructure/persistence/postgres/demo_flip_race_test.dart`
//   * `test/db/migrations/forward_apply_populated_db_test.dart`
//   * `test/services/backfill/backfill_dispatch_audit_emission_test.dart`
//
// Each copy did the same thing — read `POSTGRES_TEST_URL` from the
// process env (one file also accepted `--dart-define=POSTGRES_TEST_URL`),
// compute a skip reason when the var was unset, and wire it into the
// `skip:` argument of `test(...)`. The string contents drifted between
// copies; this helper pins one canonical form.
//
// Why a separate file from `test/infrastructure/postgres_test_harness.dart`?
// -------------------------------------------------------------------------
// `postgres_test_harness.dart` is the live-Postgres harness (opens a
// `PackagePostgresPool`, applies migrations, truncates between tests).
// Importing it on a test binary that may NOT have Postgres available
// pulls in the `PackagePostgresPool` graph at file-load time — fine when
// the test will be skipped, but the skip decision itself should not
// require the harness be imported. This helper exposes the decision
// (skip-reason + URL resolution) as a tiny, dependency-free surface so
// the caller can compute the skip BEFORE touching the harness graph.
//
// `postgres_import_lint` posture
// ------------------------------
// `test/` is in `_defaultAllowedDirs` of `tool/postgres_import_lint.dart`,
// so a future caller that wants to add `package:postgres` types here
// would not trip the lint. This file deliberately imports nothing from
// `package:postgres` — its only dependency is `dart:io` for env reads.
//
// Usage:
//   final skipReason = postgresSkipReasonOrNull();
//   test(
//     '... contract ...',
//     () async {
//       await withTestPostgres((pool, wrapper) async { ... });
//     },
//     tags: <String>['postgres'],
//     skip: skipReason,
//   );

import 'dart:io';

/// Env-var name read by `flutter test --tags=postgres` runs and by the
/// shared `postgres_test_harness.dart`. Kept as a public constant so
/// callers that want a different gating var can compose against it
/// (none today, but it documents the convention).
const String kPostgresTestUrlEnvVar = 'POSTGRES_TEST_URL';

/// Default URL used when `POSTGRES_TEST_URL` is unset and the harness
/// is asked to open a connection anyway. Mirrors the constant in
/// `postgres_test_harness.dart`; duplicated here intentionally so this
/// file stays dependency-free.
const String kDefaultPostgresTestUrl =
    'postgres://postgres:postgres@localhost:5432/forgeflow_test';

/// Returns the trimmed value of `POSTGRES_TEST_URL` when present and
/// non-empty, or `null` otherwise.
///
/// Reads from `Platform.environment` only. Callers that ALSO accept a
/// `--dart-define=POSTGRES_TEST_URL` value should combine via
/// [resolvePostgresTestUrlOrDefine].
String? readPostgresTestUrl() {
  final raw = Platform.environment[kPostgresTestUrlEnvVar];
  if (raw == null) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Like [readPostgresTestUrl] but also honours
/// `String.fromEnvironment('POSTGRES_TEST_URL')` (i.e. a
/// `--dart-define=POSTGRES_TEST_URL=...` build-time value). The dart-define
/// value wins when both are present, matching the precedence
/// `backfill_dispatch_audit_emission_test.dart` used before this helper
/// landed.
String? readPostgresTestUrlOrDefine() {
  const definedUrl = String.fromEnvironment(kPostgresTestUrlEnvVar);
  if (definedUrl.isNotEmpty) return definedUrl;
  return readPostgresTestUrl();
}

/// `true` when `POSTGRES_TEST_URL` resolves to a non-empty value. Use
/// this when the test body needs to short-circuit BEFORE registering
/// `test(...)` cases (the backfill-dispatch audit-emission file does
/// this: it prints a diagnostic line and registers a single
/// `setup_skipped` test). For per-test gating prefer
/// [postgresSkipReasonOrNull] passed to the `skip:` argument.
bool hasPostgresTestUrl() => readPostgresTestUrl() != null;

/// Returns a human-readable skip reason when `POSTGRES_TEST_URL` is
/// unset, suitable for `test(..., skip: ...)`. Returns `null` when the
/// env var is set (which makes `test(...)` run the body).
///
/// The reason string is the canonical form for postgres-tagged tests:
/// "requires live Postgres (POSTGRES_TEST_URL not set); run via
/// `flutter test --tags=postgres`". Callers that want a custom suffix
/// (e.g. "with a container") pass [extraGuidance].
String? postgresSkipReasonOrNull({String? extraGuidance}) {
  if (hasPostgresTestUrl()) return null;
  const base =
      'requires live Postgres (POSTGRES_TEST_URL not set); '
      "run via `flutter test --tags=postgres`";
  if (extraGuidance == null || extraGuidance.isEmpty) return base;
  return '$base $extraGuidance';
}

/// Returns the resolved URL, falling back to [kDefaultPostgresTestUrl]
/// when `POSTGRES_TEST_URL` is unset. Mirrors `resolveTestPostgresUrl()`
/// in `postgres_test_harness.dart`; re-exposed here so callers that need
/// just the URL string (e.g. for diagnostic logging) do not have to
/// import the full harness graph.
String resolvePostgresTestUrlWithFallback() =>
    readPostgresTestUrl() ?? kDefaultPostgresTestUrl;
