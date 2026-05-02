// HARD-A — Postgres data-access seam for `public.advisor_proxy_usage_counters`.
//
// The proxy reads + writes this table to enforce per-minute request and
// monthly cost caps. The runtime interface that the proxy plugs into
// (`ProxyUsageCounterStore`) lives in `tool/advisor_proxy/advisor_proxy.dart`;
// `tool/` cannot be imported from `lib/`, so this file owns the SQL
// + the immutable snapshot value object, and `proxy_bootstrap.dart`
// adapts it to the runtime interface.
//
// Hard-Promise reminders carried from CLAUDE.md:
//   * Raw `package:postgres` imports are forbidden outside this folder
//     (`lib/infrastructure/persistence/postgres/`). The store stays here
//     so the lint can keep enforcing that boundary; we go through
//     [OperatorScopedRepository] / [TenantTransactionWrapper] without
//     adding any direct driver imports.
//   * Operator-scoped reads/writes flow through
//     [OperatorScopedRepository] so the repository pattern is the
//     primary defense; RLS on the table is the backup. The
//     `advisor_proxy_usage_counters` policy admits the proxy's
//     service-role connection; tenant SET LOCAL still pins
//     `app.operator_id` so any future per-operator policy slot in
//     cleanly without retrofitting this code.
//
// Bucket model (matches `db/migrations/202604250004`):
//   * `minute_bucket` is the UTC minute the request lands in. Every
//     write upserts the (operator, location, tier, minute) row.
//   * `month_bucket` is the first day of the same UTC month. Denormal-
//     ized so the monthly cost rollup is a single SUM over the month's
//     minute rows.
//
// Concurrency:
//   * The unique constraint on `(operator_id, location_id, tier_id,
//     minute_bucket)` lets concurrent writers collapse to a single row
//     via `ON CONFLICT ... DO UPDATE`. The accompanying test asserts
//     this empirically.

import 'operator_scoped_repository.dart';
import 'tenant_context.dart';

/// Immutable usage rollup for one (operator, location, tier) at a
/// single point in time. The proxy maps this into its runtime
/// `UsageSnapshot` shape via the adapter in `proxy_bootstrap.dart`.
class AdvisorProxyUsageSnapshot {
  const AdvisorProxyUsageSnapshot({
    required this.requestsThisMinute,
    required this.costCentsThisMonth,
    required this.minuteBucketStart,
    required this.monthBucketStart,
  });

  final int requestsThisMinute;
  final int costCentsThisMonth;
  final DateTime minuteBucketStart;
  final DateTime monthBucketStart;
}

class AdvisorProxyUsageCounterStore extends OperatorScopedRepository {
  AdvisorProxyUsageCounterStore(super.tenantWrapper);

  /// Reads the current minute's request count + the current month's
  /// total cost (cents) for one (operator, location, tier).
  Future<AdvisorProxyUsageSnapshot> readSnapshot({
    required String operatorId,
    required String locationId,
    required String tierId,
    required DateTime now,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    final minuteBucket = _truncateToMinuteUtc(now);
    final monthBucket = _truncateToMonthUtc(now);
    return withTenant<AdvisorProxyUsageSnapshot>(ctx, (exec) async {
      final minuteRows = await exec.query(
        'select request_count '
        'from public.advisor_proxy_usage_counters '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'and tier_id = @tier_id '
        'and minute_bucket = @minute_bucket',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'tier_id': tierId,
          'minute_bucket': minuteBucket.toIso8601String(),
        },
      );
      final requestsThisMinute = minuteRows.isEmpty
          ? 0
          : (minuteRows.first['request_count'] as num?)?.toInt() ?? 0;

      final monthRows = await exec.query(
        'select coalesce(sum(cost_cents), 0) as cost_cents_this_month '
        'from public.advisor_proxy_usage_counters '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'and tier_id = @tier_id '
        'and month_bucket = @month_bucket::date',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'tier_id': tierId,
          'month_bucket': _formatDateOnly(monthBucket),
        },
      );
      final costCentsThisMonth = monthRows.isEmpty
          ? 0
          : (monthRows.first['cost_cents_this_month'] as num?)?.toInt() ?? 0;

      return AdvisorProxyUsageSnapshot(
        requestsThisMinute: requestsThisMinute,
        costCentsThisMonth: costCentsThisMonth,
        minuteBucketStart: minuteBucket,
        monthBucketStart: monthBucket,
      );
    });
  }

  /// Upserts the current minute bucket — increments `request_count` by
  /// one and adds [costCentsToAdd] to `cost_cents`. Concurrent calls
  /// targeting the same (operator, location, tier, minute) collapse to
  /// one row through the unique tenant-leading key.
  Future<void> upsertIncrement({
    required String operatorId,
    required String locationId,
    required String tierId,
    required DateTime now,
    required int costCentsToAdd,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    final minuteBucket = _truncateToMinuteUtc(now);
    final monthBucket = _truncateToMonthUtc(now);
    return withTenant<void>(ctx, (exec) async {
      await exec.execute(
        'insert into public.advisor_proxy_usage_counters '
        '(operator_id, location_id, tier_id, minute_bucket, '
        ' month_bucket, request_count, cost_cents) '
        'values (@operator_id::uuid, @location_id::uuid, @tier_id, '
        ' @minute_bucket, @month_bucket::date, 1, @cost_cents) '
        'on conflict (operator_id, location_id, tier_id, minute_bucket) '
        'do update set '
        '  request_count = '
        '    public.advisor_proxy_usage_counters.request_count + 1, '
        '  cost_cents = '
        '    public.advisor_proxy_usage_counters.cost_cents + '
        '    excluded.cost_cents',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'tier_id': tierId,
          'minute_bucket': minuteBucket.toIso8601String(),
          'month_bucket': _formatDateOnly(monthBucket),
          'cost_cents': costCentsToAdd,
        },
      );
    });
  }

  static DateTime _truncateToMinuteUtc(DateTime now) {
    final utc = now.toUtc();
    return DateTime.utc(utc.year, utc.month, utc.day, utc.hour, utc.minute);
  }

  static DateTime _truncateToMonthUtc(DateTime now) {
    final utc = now.toUtc();
    return DateTime.utc(utc.year, utc.month);
  }

  static String _formatDateOnly(DateTime value) {
    final utc = value.toUtc();
    final yyyy = utc.year.toString().padLeft(4, '0');
    final mm = utc.month.toString().padLeft(2, '0');
    final dd = utc.day.toString().padLeft(2, '0');
    return '$yyyy-$mm-$dd';
  }
}
