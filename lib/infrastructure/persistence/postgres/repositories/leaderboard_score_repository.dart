// Phase 9.5.0 — LeaderboardScoreRepository (skeleton).
//
// Persistence seam for the El Podio learning leaderboard's
// `public.leaderboard_scores` ledger landed in
// `db/migrations/202605030000_phase_9_5_0_leaderboard_schema_rls.sql`.
//
// Scope of THIS slice:
//
//   * `recordScore` — append one score event for the authenticated
//     learner. Producers (Phase 9.5.x learning persistence + Phase
//     9.75 Recognition) call this from inside an authenticated request
//     so `OperatorContext` (operator_id, location_id, user_id) is
//     available on the call stack.
//   * `listScoresForUser` — read the appended history for one user
//     inside the caller's tenant. The launch leaderboard projects
//     this into ranks at the read service layer (Phase 9.5.x); the
//     repository ships only the durable shape so the projection has
//     a stable seam to bind against.
//
// Out of scope (deliberate, per the 9.5.0 prompt):
//
//   * Rank projection (top-N for a window, tie-breakers, current
//     rank for one user) — Phase 9.5.x read service.
//   * UPDATE / DELETE methods — the table is append-only at the
//     grant shape. Corrections (badge revocation, etc.) MUST land as
//     a fresh row with negative points so the append-only posture
//     holds and the audit story is preserved.
//
// Hard rules carried from
// `db/migrations/202605030000_phase_9_5_0_leaderboard_schema_rls.sql`:
//
//   * `(operator_id, location_id)` are required on every row; the
//     composite FK rejects a row attributed to a location that does
//     not belong to the operator. The repository injects both from
//     `TenantContext` so producers cannot accidentally short-circuit
//     the RLS-Ready scaffolding.
//   * `business_date` is computed by the caller from
//     `location.timezone` + `business_day_rollover_hour`
//     (CLAUDE.md Time Guardrails). This repository does not derive
//     it in SQL — re-deriving would force a `locations` read in the
//     hot path. The CHECK constraint guards against pre-2000 dates;
//     a producer bug with an obviously-wrong `businessDate` fails
//     fast at the constraint instead of being silently aggregated
//     into the wrong week.
//   * `score_event_type` is canonical at the producer; the DB CHECK
//     enforces shape (1..64 chars, no leading/trailing whitespace)
//     and the runtime owns the canonical enum.
//   * Per-tenant RLS via wrapper functions; SET LOCAL ordering and
//     `app.bypass_rls_audit = 'tenant'` are stamped by the parent
//     `OperatorScopedRepository.withTenant` path. No raw
//     `current_setting` reads here.
//   * Every B-tree index on the table leads with `operator_id` so the
//     planner can fold the per-tenant RLS predicate into the index
//     probe; `where operator_id = @operator_id::uuid` is bound on
//     every read so the planner has the leading column to seek on.

import 'dart:convert';

import '../operator_scoped_repository.dart';
import '../tenant_context.dart';

/// One row from the `public.leaderboard_scores` append log. Stable
/// shape so the Phase 9.5.x projection layer (and the 9.5.UX read
/// service) can bind without a follow-up edit when the projection
/// gains more columns.
class LeaderboardScoreRow {
  const LeaderboardScoreRow({
    required this.scoreEventId,
    required this.operatorId,
    required this.locationId,
    required this.userId,
    required this.scoreEventType,
    required this.points,
    required this.occurredAt,
    required this.businessDate,
    required this.payload,
    required this.createdAt,
  });

  final String scoreEventId;
  final String operatorId;
  final String locationId;
  final String userId;
  final String scoreEventType;
  final int points;
  final DateTime occurredAt;
  final DateTime businessDate;
  final Map<String, Object?> payload;
  final DateTime createdAt;
}

class LeaderboardScoreRepository extends OperatorScopedRepository {
  LeaderboardScoreRepository(super.tenantWrapper);

  /// Append one score event to `public.leaderboard_scores` inside the
  /// caller's tenant transaction. Returns the generated
  /// `score_event_id`.
  ///
  /// `businessDate` is computed by the caller (the runtime
  /// business-date helper that other operator-scoped writers use)
  /// from the operator's location timezone and rollover hour;
  /// re-deriving in SQL would require a `locations` read in the hot
  /// path. The DB CHECK guards against obviously-wrong values without
  /// re-projecting.
  ///
  /// The repository formats `businessDate.year`/`.month`/`.day`
  /// verbatim (no UTC conversion) — the caller MUST construct a
  /// `DateTime` whose calendar fields already represent the
  /// operator-local business day. A UTC-converted value supplied
  /// here would shift the day near midnight and silently bin the
  /// score under the wrong week.
  ///
  /// `occurredAt` is the source-truth instant (timestamptz column)
  /// and IS `.toUtc()`'d on the way down — that one is a wall-clock
  /// instant, not a day anchor.
  ///
  /// `payload` defaults to an empty object; the migration's CHECK
  /// constraint enforces `jsonb_typeof = 'object'` so non-object
  /// payloads fail fast at the constraint.
  Future<String> recordScore({
    required String operatorId,
    required String locationId,
    required String userId,
    required String scoreEventType,
    required int points,
    required DateTime occurredAt,
    required DateTime businessDate,
    Map<String, Object?> payload = const <String, Object?>{},
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    final occurredUtc = occurredAt.toUtc();
    final businessDateText = _formatBusinessDate(businessDate);
    return withTenant<String>(ctx, (exec) async {
      final rows = await exec.query(
        'insert into public.leaderboard_scores ('
        'operator_id, location_id, user_id, score_event_type, '
        'points, occurred_at, business_date, payload) '
        'values ('
        '@operator_id::uuid, @location_id::uuid, @user_id::uuid, '
        '@score_event_type, @points, @occurred_at::timestamptz, '
        '@business_date::date, @payload::jsonb) '
        'returning score_event_id::text as score_event_id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'user_id': userId,
          'score_event_type': scoreEventType,
          'points': points,
          'occurred_at': occurredUtc,
          'business_date': businessDateText,
          'payload': jsonEncode(payload),
        },
      );
      if (rows.isEmpty) {
        throw StateError(
          'leaderboard_scores insert returned no rows — RLS may have '
          'denied the row at WITH CHECK',
        );
      }
      final id = rows.single['score_event_id'];
      if (id is! String || id.isEmpty) {
        throw StateError(
          'leaderboard_scores insert returned a malformed score_event_id',
        );
      }
      return id;
    });
  }

  /// Read every leaderboard row attributed to one user inside the
  /// caller's tenant, optionally bounded by `[fromBusinessDate,
  /// toBusinessDate]` (inclusive). Sorted `business_date desc,
  /// occurred_at desc` so the most recent activity surfaces first
  /// without a separate ORDER BY at the projection layer.
  ///
  /// The WHERE clause leads with `operator_id` so the planner folds
  /// the RLS predicate into the
  /// `leaderboard_scores_operator_user_date_idx` probe.
  Future<List<LeaderboardScoreRow>> listScoresForUser({
    required String operatorId,
    required String locationId,
    required String userId,
    DateTime? fromBusinessDate,
    DateTime? toBusinessDate,
    String? actorUserId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    final params = <String, Object?>{
      'operator_id': operatorId,
      'user_id': userId,
    };
    final clauses = <String>[
      'operator_id = @operator_id::uuid',
      'user_id = @user_id::uuid',
    ];
    if (fromBusinessDate != null) {
      clauses.add('business_date >= @from_business_date::date');
      params['from_business_date'] = _formatBusinessDate(fromBusinessDate);
    }
    if (toBusinessDate != null) {
      clauses.add('business_date <= @to_business_date::date');
      params['to_business_date'] = _formatBusinessDate(toBusinessDate);
    }
    final whereClause = clauses.join(' and ');
    return withTenant<List<LeaderboardScoreRow>>(ctx, (exec) async {
      final rows = await exec.query(
        'select score_event_id::text as score_event_id, '
        'operator_id::text as operator_id, '
        'location_id::text as location_id, '
        'user_id::text as user_id, '
        'score_event_type, points, occurred_at, business_date, '
        'payload, created_at '
        'from public.leaderboard_scores '
        'where $whereClause '
        'order by business_date desc, occurred_at desc',
        parameters: params,
      );
      return rows.map(_projectRow).toList(growable: false);
    });
  }

  static LeaderboardScoreRow _projectRow(Map<String, Object?> row) {
    final scoreEventId = row['score_event_id'];
    final operatorId = row['operator_id'];
    final locationId = row['location_id'];
    final userId = row['user_id'];
    final scoreEventType = row['score_event_type'];
    final points = row['points'];
    final occurredAt = row['occurred_at'];
    final businessDate = row['business_date'];
    final createdAt = row['created_at'];
    if (scoreEventId is! String ||
        scoreEventId.isEmpty ||
        operatorId is! String ||
        operatorId.isEmpty ||
        locationId is! String ||
        locationId.isEmpty ||
        userId is! String ||
        userId.isEmpty ||
        scoreEventType is! String ||
        scoreEventType.isEmpty ||
        points is! int ||
        occurredAt is! DateTime ||
        businessDate is! DateTime ||
        createdAt is! DateTime) {
      throw StateError(
        'leaderboard_scores select returned a malformed row',
      );
    }
    final payloadRaw = row['payload'];
    final Map<String, Object?> payload;
    if (payloadRaw is Map<String, Object?>) {
      payload = payloadRaw;
    } else if (payloadRaw is Map) {
      payload = payloadRaw.map(
        (key, value) => MapEntry(key.toString(), value as Object?),
      );
    } else if (payloadRaw is String && payloadRaw.isNotEmpty) {
      final decoded = jsonDecode(payloadRaw);
      if (decoded is! Map) {
        throw StateError(
          'leaderboard_scores payload decoded to non-object JSON',
        );
      }
      payload = decoded.map(
        (key, value) => MapEntry(key.toString(), value as Object?),
      );
    } else {
      payload = const <String, Object?>{};
    }
    return LeaderboardScoreRow(
      scoreEventId: scoreEventId,
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
      scoreEventType: scoreEventType,
      points: points,
      occurredAt: occurredAt,
      businessDate: businessDate,
      payload: payload,
      createdAt: createdAt,
    );
  }

  /// Formats a business-date `DateTime` as `YYYY-MM-DD` using its
  /// supplied `.year`/`.month`/`.day` verbatim — NO UTC conversion.
  ///
  /// Business dates are operator-local day anchors per
  /// `phase_7_55_time_boundary_contract.md`. The producer (the runtime
  /// business-date resolver, owned by 9.5.x) constructs a `DateTime`
  /// whose calendar fields already represent the operator-local day;
  /// `.toUtc()` here would shift the day boundary near midnight in
  /// non-UTC zones (a 23:30 local instant in `America/Toronto` is
  /// 03:30 UTC the next day, which would silently bin the score under
  /// the wrong week). Treating the supplied value as already-canonical
  /// keeps the day anchor stable.
  static String _formatBusinessDate(DateTime businessDate) {
    return '${businessDate.year.toString().padLeft(4, '0')}-'
        '${businessDate.month.toString().padLeft(2, '0')}-'
        '${businessDate.day.toString().padLeft(2, '0')}';
  }
}
