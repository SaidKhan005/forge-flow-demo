// AI Metrics — append-only cap-refusal event recorder (write path).
//
// One row is written into `public.usage_cap_events` each time the proxy
// REFUSES a provider call because the call's projected spend would breach
// a cap defined in `public.usage_caps`. The admin "AI Metrics" /
// Observability "Limit hits" panel projects that table (the read producer
// `_observabilityCapEventsSql` landed in PR #1267). This file is the
// WRITE path the migration `202605240000_ai_metrics_usage_cap_events.sql`
// promised ("the producer repository — a later slice — carries the SET
// LOCAL ordering and the tenant-scoped INSERT shape").
//
// Why this lives OUTSIDE `advisor_proxy.dart`:
//
//   * `advisor_proxy.dart` is the bleed-stopped monolith
//     (`tool/advisor_proxy_size_lint.dart`). New write logic + SQL +
//     business_date derivation go into a decomposed file per the seam
//     map; only a MINIMAL best-effort call is added at the refusal site.
//   * This file does NOT import `package:postgres`. Only
//     `lib/infrastructure/persistence/postgres/` may. It depends on the
//     `PostgresExecutor` / `TenantTransactionWrapper` seams, mirroring
//     `advisor_response_cache.dart`.
//
// Hard rules carried from CLAUDE.md and the migration:
//
//   1. NON-BLOCKING / hot-path safe. Recording runs ONLY on the refusal
//      branch, ONLY AFTER the refusal is decided, and in its OWN tenant
//      transaction (the cap-check transaction has already committed and
//      released its connection, so there is no nested transaction and no
//      pool-starvation risk). The whole write is wrapped in a private
//      try/catch: any failure is swallowed and structured-logged at
//      WARNING; `recordRefusal` NEVER throws. A logging failure can never
//      convert a refusal into a success, change the response, or escape
//      the hot path. The refusal decision, status code, and latency of
//      the allow/replay paths are untouched.
//
//   2. Tenant-scoped write seam (RLS-Ready Schema). The INSERT runs inside
//      `TenantTransactionWrapper.runInTenantContext`, which `SET LOCAL`s
//      `app.operator_id` / `app.location_id` before the body, so the
//      per-tenant RLS INSERT policy
//      `usage_cap_events_per_tenant_insert` (operator_id =
//      app_current_operator() AND location_id = app_current_location())
//      admits the row. The repository pattern is the primary defense; RLS
//      is the backup. No bare pool-level execution.
//
//   3. business_date derived at write from the canonical business-timing
//      profile chain (Time Guardrails). The recorder resolves the
//      effective IANA timezone and business_day_start_local_time through
//      `SinkBusinessDateProjector.projectBusinessDateForLocation`, which
//      reads operator -> org_unit -> location profiles inside the same
//      tenant transaction, then binds `@business_date::date` into the
//      insert. It never reads legacy `business_day_rollover_hour`.
//
//   4. One row per refusal. The table defaults `event_id` to
//      `gen_random_uuid()`; this recorder issues exactly one INSERT per
//      refusal and never retries, so a single refusal produces a single
//      row. (Idempotency on retried-then-refused requests is the proxy's
//      idempotency-key reservation, which short-circuits to a replay
//      before the cap-check runs again.)
//
//   5. cap_usd / attempted_usd honesty. A refusal is raised when the
//      per-invocation cap OR the monthly cap would be breached. The
//      per-invocation breach is the more specific/immediate one, so when
//      `perInvocationExceeded` is true the event snapshots the
//      per-invocation cap and the single call's projected cost (which by
//      definition exceeded it). Otherwise the monthly cap is recorded
//      against the projected month-end total (`monthlyUsed +
//      estimatedCost`) — the figure that actually breached the monthly
//      budget — so the panel reads "tried to spend X against a Y cap"
//      with attempted_usd > cap_usd in both cases. Both values are
//      non-negative, satisfying the table CHECKs.

import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/business_timing_profiles_repository.dart';
import 'package:forge_and_flow/services/integration/sink_business_date_projector.dart';
import 'package:forge_and_flow/services/observability/log.dart';

/// USD amounts (`cap_usd` / `attempted_usd`) snapshotted onto a refusal
/// event. Cents are converted to a fixed-4 decimal string, matching the
/// `cost_usd` binding shape `PostgresProxyAccountingStore._usageParameters`
/// already uses for `usage_logs`, so the numeric(12,4) column receives a
/// canonical value.
String _centsToUsd4(int cents) => (cents / 100).toStringAsFixed(4);

/// The (cap, attempted) pair to snapshot for a refusal, plus which cap
/// tripped — kept as a tiny value object so the decision is unit-testable
/// without a Postgres round-trip.
class CapEventAmounts {
  const CapEventAmounts({
    required this.capUsd,
    required this.attemptedUsd,
    required this.breachedCap,
  });

  /// USD cap that was in force and breached (fixed-4 string).
  final String capUsd;

  /// Projected USD cost that breached the cap (fixed-4 string).
  final String attemptedUsd;

  /// `'per_invocation'` or `'monthly'` — which cap the event attributes
  /// the refusal to. Not persisted (the table has no such column); used
  /// for the structured-log breadcrumb and tests.
  final String breachedCap;

  /// Computes the amounts from a breached cap status. Prefers the
  /// per-invocation breach (the immediate, single-call overage); falls
  /// back to the monthly breach against the projected month-end total.
  ///
  /// `perInvocationCapCents` / `monthlyCapCents` / `monthlyUsedCents` /
  /// `estimatedCostCents` mirror the public getters on `ProxyCapStatus`.
  factory CapEventAmounts.fromBreach({
    required bool perInvocationExceeded,
    required int perInvocationCapCents,
    required int monthlyCapCents,
    required int monthlyUsedCents,
    required int estimatedCostCents,
  }) {
    if (perInvocationExceeded) {
      return CapEventAmounts(
        capUsd: _centsToUsd4(perInvocationCapCents),
        attemptedUsd: _centsToUsd4(estimatedCostCents),
        breachedCap: 'per_invocation',
      );
    }
    return CapEventAmounts(
      capUsd: _centsToUsd4(monthlyCapCents),
      attemptedUsd: _centsToUsd4(monthlyUsedCents + estimatedCostCents),
      breachedCap: 'monthly',
    );
  }
}

/// INSERT for one cap-refusal event.
///
/// Business date is bound by Dart after resolving the canonical
/// business-timing profile chain (operator -> org unit -> location).
/// `event_id` / `created_at` take their table defaults
/// (`gen_random_uuid()` / `now()`).
const String capEventInsertSql = '''
insert into public.usage_cap_events (
  operator_id,
  location_id,
  usage_class,
  query_class,
  cap_usd,
  attempted_usd,
  occurred_at,
  business_date
)
values (
  @operator_id::uuid,
  @location_id::uuid,
  @usage_class,
  @query_class,
  @cap_usd::numeric,
  @attempted_usd::numeric,
  @occurred_at::timestamptz,
  @business_date::date
)
''';

/// Records cap-breach refusals into `public.usage_cap_events`.
///
/// Best-effort and non-blocking: see the file header (rule 1). Construct
/// once from the proxy's shared `TenantTransactionWrapper` and call
/// [recordRefusal] from the refusal branch AFTER the refusal is decided.
class CapEventRecorder {
  CapEventRecorder({
    required TenantTransactionWrapper wrapper,
    SinkBusinessDateProjector? businessDateProjector,
  }) : _wrapper = wrapper,
       _businessDateProjector =
           businessDateProjector ??
           SinkBusinessDateProjector(
             profilesRepository: BusinessTimingProfilesRepository(wrapper),
           );

  final TenantTransactionWrapper _wrapper;
  final SinkBusinessDateProjector _businessDateProjector;

  /// Inserts exactly one refusal row, swallowing any failure.
  ///
  /// Runs in its own tenant transaction so the cap-check transaction has
  /// already committed (no nesting). NEVER throws: a write failure is
  /// structured-logged at WARNING and the caller still returns the
  /// refusal unchanged.
  Future<void> recordRefusal({
    required String operatorId,
    required String locationId,
    required String? userId,
    required String usageClass,
    required String queryClass,
    required bool perInvocationExceeded,
    required int perInvocationCapCents,
    required int monthlyCapCents,
    required int monthlyUsedCents,
    required int estimatedCostCents,
    required DateTime occurredAt,
  }) async {
    try {
      final amounts = CapEventAmounts.fromBreach(
        perInvocationExceeded: perInvocationExceeded,
        perInvocationCapCents: perInvocationCapCents,
        monthlyCapCents: monthlyCapCents,
        monthlyUsedCents: monthlyUsedCents,
        estimatedCostCents: estimatedCostCents,
      );
      final ctx = TenantContext(
        operatorId: operatorId,
        locationId: locationId,
        userId: userId,
      );
      final affected = await _wrapper.runInTenantContext<int>(ctx, (
        exec,
      ) async {
        final businessDate = await _businessDateProjector
            .projectBusinessDateForLocation(
              exec: exec,
              operatorId: operatorId,
              locationId: locationId,
              instantUtc: occurredAt,
            );
        if (businessDate == null) return 0;
        return exec.execute(
          capEventInsertSql,
          parameters: <String, Object?>{
            'operator_id': operatorId,
            'location_id': locationId,
            'usage_class': usageClass,
            'query_class': queryClass,
            'cap_usd': amounts.capUsd,
            'attempted_usd': amounts.attemptedUsd,
            'occurred_at': occurredAt.toUtc().toIso8601String(),
            'business_date': _formatDate(businessDate),
          },
        );
      });
      if (affected == 0) {
        // Location row not visible (already deleted, or RLS-hidden). The
        // refusal still stands; we simply could not attribute an event.
        log(
          LogSeverity.notice,
          'advisor_proxy.cap_event.not_recorded',
          fields: <String, Object?>{
            'reason': 'location_not_found',
            'usage_class': usageClass,
            'breached_cap': amounts.breachedCap,
          },
        );
      }
    } on Object catch (error, stackTrace) {
      // NON-BLOCKING: never let an observability write break a refusal.
      log(
        LogSeverity.warning,
        'advisor_proxy.cap_event.record_failed',
        fields: <String, Object?>{
          'usage_class': usageClass,
          'query_class': queryClass,
          'error': error.toString(),
          'stack_trace': stackTrace.toString(),
        },
      );
    }
  }
}

String _formatDate(DateTime value) {
  final utc = value.toUtc();
  return '${utc.year.toString().padLeft(4, '0')}-'
      '${utc.month.toString().padLeft(2, '0')}-'
      '${utc.day.toString().padLeft(2, '0')}';
}
