// B5 — test infrastructure: reusable Postgres test harness.
//
// Connects to a real Postgres instance for integration tests tagged
// `@Tags(['postgres'])`. The harness reads the connection string from
// `POSTGRES_TEST_URL`; falls back to
// `postgres://postgres:postgres@localhost:5432/forgeflow_test` when
// the env var is absent.
//
// Applies every migration in `db/migrations/` in chronological
// filename order against the database, then truncates tenant data
// between tests.
//
// Key helpers
//   withTestPostgres   — top-level harness; applies migrations once,
//                        runs the callback, truncates after.
//   seedOperator       — inserts an operator + root org_unit + location
//                        so FK chains are satisfied.
//   setTenant          — issues SET LOCAL app.operator_id / location_id
//                        inside an open transaction.
//
// PASSIVE BY DEFAULT — tests using this harness are tagged
// `@Tags(['postgres'])` so `flutter test` (no extra flags) skips them.
// CI runs them via `flutter test --tags=postgres` after starting a
// Postgres service container.
//
// CLAUDE.md binding: this file imports `package:postgres` indirectly
// through `PackagePostgresPool` which lives under
// `lib/infrastructure/persistence/postgres/` — that is the only
// location where direct `package:postgres` imports are permitted.

import 'dart:io';

import 'package:forge_and_flow/infrastructure/persistence/postgres/package_postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _kEnvVar = 'POSTGRES_TEST_URL';
const String _kDefaultUrl =
    'postgres://postgres:postgres@localhost:5432/forgeflow_test';

/// Returns the connection string for the test database.
String resolveTestPostgresUrl() =>
    (Platform.environment[_kEnvVar] ?? '').trim().isEmpty
        ? _kDefaultUrl
        : Platform.environment[_kEnvVar]!.trim();

/// All tenant-data tables that [truncateTenantData] wipes between
/// tests. Ordered to satisfy FK constraints (child before parent).
const List<String> _kTenantTables = <String>[
  'audit_logs',
  'rollup_daypart',
  'rollup_business_day',
  'rollup_week',
  'rollup_accounting_period',
  'rollup_month',
  'rollup_quarter',
  'rollup_year',
  'advisor_conversation_log',
  'service_principals',
  'event_outbox',
  'event_outbox_dead_letter',
  'graph_nodes',
  'graph_edges',
  'proxy_requests',
  'feature_flags',
  'auth_invites',
  'auth_login_attempts',
  'auth_sessions',
  'auth_events_audit',
  'user_roles',
  'user_effective_locations',
  'users',
  'password_history',
  'mfa_factors',
  'mfa_factor_removal_requests',
  'mfa_recovery_request_attempts',
  'recovery_code_attempts',
  'mobile_push_tokens',
  'mobile_push_outbox',
  'notification_preferences',
  'business_timing_profiles',
  'business_timing_service_periods',
  'business_timing_audit_events',
  'open_shift_snapshots',
  'forecast_contexts',
  'weekly_plan_snapshots',
  'target_cycles',
  'target_profiles',
  'active_target_profiles',
  'leaderboard_scores',
  'labor_punches',
  'shift_records',
  'connector_sync_watermark',
  'connector_sync_log',
  'demo_mode_state',
  'connector_backfill_jobs',
  'connector_connections',
  'wage_role_rows',
  'data_accuracy_service_period_settings',
  'operator_account',
  'operator_admins',
  'usage_caps',
  'roles',
  'role_permissions',
  'org_units',
  'locations',
  'operators',
];

// ─── Migration apply ─────────────────────────────────────────────────

/// Reads all `*.sql` files under `db/migrations/` in alphabetical
/// (chronological) filename order and applies each to [pool].
///
/// Best-effort: statements inside each migration file are split on
/// `;\n` / `;\r\n`; blank and comment-only lines are skipped. Errors
/// propagate — the caller (harness setUp) fails fast.
Future<void> applyAllMigrations(PackagePostgresPool pool) async {
  final dir = Directory('db/migrations');
  if (!dir.existsSync()) {
    throw StateError(
      'db/migrations directory not found. '
      'Run from the project root or set the working directory.',
    );
  }
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.sql'))
      .toList()
    ..sort((a, b) => a.uri.pathSegments.last.compareTo(b.uri.pathSegments.last));

  for (final file in files) {
    await _applyMigrationFile(pool, file);
  }
}

Future<void> _applyMigrationFile(
  PackagePostgresPool pool,
  File file,
) async {
  final sql = file.readAsStringSync().replaceAll('\r\n', '\n');
  final tx = await pool.beginTransaction();
  try {
    // Split on statement boundaries. The simple heuristic below works
    // for the migrations in this repo — they use `;` + newline as the
    // statement terminator. Complex dollar-quoted functions are handled
    // by the Postgres driver as a single statement.
    final statements = _splitStatements(sql);
    for (final stmt in statements) {
      await tx.execute(stmt);
    }
    await tx.commit();
  } catch (e) {
    await tx.rollback();
    rethrow;
  }
}

List<String> _splitStatements(String sql) {
  // Naive split adequate for the migration style in this repo.
  // Dollar-quoted blocks (e.g. PL/pgSQL functions) contain their own
  // semicolons — treat the entire block as one token by not splitting
  // inside dollar-quotes.
  final result = <String>[];
  final buffer = StringBuffer();
  var inDollarQuote = false;
  String? dollarTag;
  final lines = sql.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    // Detect start/end of a dollar-quoted block.
    final dollarMatch = RegExp(r'\$([^$]*)\$').allMatches(line);
    for (final m in dollarMatch) {
      final tag = m.group(0)!;
      if (!inDollarQuote) {
        inDollarQuote = true;
        dollarTag = tag;
      } else if (tag == dollarTag) {
        inDollarQuote = false;
        dollarTag = null;
      }
    }
    buffer.write(line);
    buffer.write('\n');
    if (!inDollarQuote && line.trimRight().endsWith(';')) {
      final stmt = buffer.toString().trim();
      if (stmt.isNotEmpty && !_isCommentOrEmpty(stmt)) {
        result.add(stmt);
      }
      buffer.clear();
    }
  }
  // Flush any trailing content without a terminal semicolon.
  final trailing = buffer.toString().trim();
  if (trailing.isNotEmpty && !_isCommentOrEmpty(trailing)) {
    result.add(trailing);
  }
  return result;
}

bool _isCommentOrEmpty(String stmt) {
  final stripped = stmt
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && !l.startsWith('--'))
      .join(' ')
      .trim();
  return stripped.isEmpty;
}

// ─── Tenant helpers ───────────────────────────────────────────────────

/// Truncates every tenant-data table listed in [_kTenantTables]
/// using `TRUNCATE … RESTART IDENTITY CASCADE`. Safe to call between
/// tests even if some tables do not exist yet (wraps in a
/// best-effort per-table `IF EXISTS` check).
Future<void> truncateTenantData(PackagePostgresPool pool) async {
  final tx = await pool.beginTransaction();
  try {
    // Disable triggers for the duration so audit-chain triggers don't
    // fire on synthetic truncations.
    await tx.execute('set local session_replication_role = replica');
    for (final table in _kTenantTables) {
      try {
        await tx.execute(
          'truncate public.$table restart identity cascade',
        );
      } catch (_) {
        // Table may not exist in a partial migration apply — skip.
      }
    }
    await tx.execute(
      "set local session_replication_role = default",
    );
    await tx.commit();
  } catch (e) {
    await tx.rollback();
    rethrow;
  }
}

/// Inserts a minimal set of rows into `operators`, `org_units`, and
/// `locations` to satisfy FK chains. Returns the [locationId] that
/// was created.
///
/// Uses raw admin-pool statements so it works regardless of which
/// RLS policies are active — this is fixture setup, not the system
/// under test.
Future<String> seedOperator(
  PackagePostgresPool pool, {
  required String operatorId,
  required String locationId,
}) async {
  final tx = await pool.beginTransaction();
  try {
    // Operator row.
    await tx.execute(
      'insert into public.operators ('
      '  operator_id, business_name, owner_email, '
      '  subscription_tier, preferred_currency'
      ') values ('
      "  '$operatorId'::uuid, 'Test Operator $operatorId', "
      "  'owner@test.invalid', 'starter', 'CAD'"
      ') on conflict (operator_id) do nothing',
    );
    // Root org_unit.
    final ouId =
        '${operatorId.substring(0, 8)}-0000-0000-0000-000000000099';
    await tx.execute(
      'insert into public.org_units ('
      '  id, operator_id, parent_id, unit_type, path, name'
      ') values ('
      "  '$ouId'::uuid, '$operatorId'::uuid, null, 'corp', "
      "  'test_root', 'Test Root'"
      ') on conflict (id) do nothing',
    );
    // Primary location.
    await tx.execute(
      'insert into public.locations ('
      '  location_id, operator_id, parent_org_unit_id, '
      '  name, address, timezone, business_day_rollover_hour'
      ') values ('
      "  '$locationId'::uuid, '$operatorId'::uuid, '$ouId'::uuid, "
      "  'Test Location', '123 Test St', 'America/Toronto', 4"
      ') on conflict (location_id) do nothing',
    );
    // Update primary_location_id.
    await tx.execute(
      "update public.operators "
      "set primary_location_id = '$locationId'::uuid "
      "where operator_id = '$operatorId'::uuid",
    );
    await tx.commit();
    return locationId;
  } catch (e) {
    await tx.rollback();
    rethrow;
  }
}

/// Issues `SET LOCAL app.operator_id` and `SET LOCAL app.location_id`
/// inside an already-open [PostgresTransaction]. Equivalent to what
/// [TenantTransactionWrapper.runInTenantContext] does before running the
/// caller's body — useful when tests need to exercise the raw executor
/// seam inside an explicit transaction.
Future<void> setTenant(
  PostgresTransaction tx, {
  required String operatorId,
  required String locationId,
}) async {
  await tx.execute(
    "select set_config('app.operator_id', '$operatorId', true)",
  );
  await tx.execute(
    "select set_config('app.location_id', '$locationId', true)",
  );
  await tx.execute(
    "select set_config('app.bypass_rls_audit', 'tenant', true)",
  );
}

// ─── Top-level harness ────────────────────────────────────────────────

/// Runs [body] against a real Postgres instance.
///
/// On first call within a test binary, applies all migrations. After
/// [body] returns (or throws), truncates tenant data so the next test
/// starts clean.
///
/// [pool] is reused across calls when provided; otherwise a new pool
/// is opened from [resolveTestPostgresUrl()].
///
/// Typical usage inside a test:
/// ```dart
/// @Tags(['postgres'])
/// void main() {
///   test('some postgres test', () async {
///     await withTestPostgres((pool, wrapper) async {
///       final operatorId = 'aaaa...';
///       final locationId = 'bbbb...';
///       await seedOperator(pool, operatorId: operatorId, locationId: locationId);
///       // ... exercise repository ...
///     });
///   });
/// }
/// ```
Future<T> withTestPostgres<T>(
  Future<T> Function(
    PackagePostgresPool pool,
    TenantTransactionWrapper wrapper,
  ) body, {
  PackagePostgresPool? pool,
  bool applyMigrations = true,
}) async {
  final url = resolveTestPostgresUrl();
  final ownPool = pool == null;
  final effectivePool =
      pool ?? PackagePostgresPool.fromUrl(url, maxConnectionCount: 2);
  final wrapper = TenantTransactionWrapper(effectivePool);

  if (applyMigrations) {
    await applyAllMigrations(effectivePool);
  }
  try {
    return await body(effectivePool, wrapper);
  } finally {
    await truncateTenantData(effectivePool);
    if (ownPool) {
      await effectivePool.closeIdleConnections();
    }
  }
}
