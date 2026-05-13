// Lane B B11.2.b — StepUpChallengesRepository.
//
// Persistence layer for `public.auth_step_up_challenges`. Every read
// and write goes through `OperatorScopedRepository.withTenant` so the
// per-tenant RLS policy admits the row (primary defense: repository
// pattern; backup: RLS).
//
// Authority:
//   * db/migrations/202605131400_b11_2_auth_step_up_challenges.sql
//     (table + wrapper-only RLS policy + operator-leading indexes).
//   * docs/contracts/hardening_rls_and_repository_pattern_contract.md
//     (every operator-scoped table goes through OperatorScopedRepository;
//     no raw `package:postgres` import outside this directory).
//   * tool/advisor_proxy/auth_step_up_routes.dart owns the
//     `StepUpChallengesGateway` interface + value objects; the
//     `RepositoryStepUpChallengesGateway` adapter (defined in that
//     file) wraps this repository, mirroring the B11.1 split between
//     `HandoffCodesRepository` (lib/) and `RepositoryHandoffCodesGateway`
//     (tool/advisor_proxy/).
//   * B11.1 precedent: handoff_codes_repository.dart (mirrored idiom for
//     opaque code, inline reaper, TTL discipline, atomic UPDATE …
//     RETURNING, lookup-for-replay-check via `withSystem`).
//
// Methods:
//   * emit            — INSERT a fresh challenge row. The opaque
//                       challenge_id is generated server-side via
//                       `Random.secure()` re-encoded as 22-char
//                       base64-url (matches the migration's CHECK
//                       constraint `^[A-Za-z0-9_-]+$`, 22..64 chars).
//                       Returns the challenge_id.
//   * consume         — Atomic UPDATE … RETURNING. Sets
//                       consumed_at = now() and returns the redeemed
//                       row only when the predicate
//                       (consumed_at IS NULL AND expires_at > now()
//                        AND route_path = $route AND user_id = $user
//                        AND operator_id = caller's operator) holds.
//                       A returned-empty result is the signal for
//                       "no match"; the caller classifies via
//                       lookupForReplayCheck.
//   * lookupForReplayCheck — Reads the current state of a challenge
//                       (operator_id, user_id, route_path, expires_at,
//                       consumed_at) without mutating it. Runs through
//                       `withSystem` so the caller can detect "challenge
//                       exists in a different operator" for the
//                       oracle-safe 401 classifier in StepUpChallengeRouter.

import 'dart:convert';
import 'dart:math' as math;

import '../operator_scoped_repository.dart';
import '../postgres_executor.dart';
import '../tenant_context.dart';

/// Projection of an atomic-consume success. Returned by
/// [StepUpChallengesRepository.consume] when the predicate matched.
class StepUpChallengeConsumeRow {
  const StepUpChallengeConsumeRow({
    required this.challengeId,
    required this.operatorId,
    required this.locationId,
    required this.userId,
    required this.routePath,
    required this.requiredAcr,
    required this.requiredFreshnessSeconds,
    required this.consumedAt,
  });

  final String challengeId;
  final String operatorId;
  final String locationId;
  final String userId;
  final String routePath;
  final String requiredAcr;
  final int requiredFreshnessSeconds;
  final DateTime consumedAt;
}

/// Snapshot of a challenge row used by the consume failure classifier.
/// Returned by [StepUpChallengesRepository.lookupForReplayCheck] when
/// the challenge exists anywhere (in any operator); the caller compares
/// fields and collapses every cross-operator / wrong-route / wrong-user
/// case to a 401 so the id cannot be used as an oracle.
class StepUpChallengeStateRow {
  const StepUpChallengeStateRow({
    required this.operatorId,
    required this.userId,
    required this.routePath,
    required this.expiresAt,
    required this.consumedAt,
  });

  final String operatorId;
  final String userId;
  final String routePath;
  final DateTime expiresAt;
  final DateTime? consumedAt;
}

class StepUpChallengesRepository extends OperatorScopedRepository {
  StepUpChallengesRepository(super.tenantWrapper);

  /// Inline reaper horizon. Rows whose expires_at is more than this far
  /// in the past are deleted at the head of every emit transaction so
  /// the partial active-only index stays small. 1 day picked to match
  /// the B11.1 handoff codes idiom and give operators a comfortable
  /// observability window when diagnosing a "why did step-up not fire?"
  /// trail.
  static const Duration kReaperHorizon = Duration(days: 1);

  /// Hard ceiling on challenge TTL — mirrors the migration's CHECK
  /// constraint `expires_at <= created_at + interval '15 minutes'`. The
  /// emit path clamps requested TTLs to this ceiling defensively.
  static const Duration kChallengeTtlCeiling = Duration(minutes: 15);

  Future<String> emit({
    required String operatorId,
    required String locationId,
    required String userId,
    required String routePath,
    required String requiredAcr,
    required int requiredFreshnessSeconds,
    required Duration challengeTtl,
    required String sourceActorKind,
    required String? sourceDeviceFingerprint,
    DateTime Function()? now,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<String>(ctx, (PostgresExecutor exec) async {
      // Inline reaper — drop expired rows so the partial active-only
      // index stays small. Bounded by the per-tenant RLS policy.
      await exec.execute(
        'delete from public.auth_step_up_challenges '
        'where operator_id = @operator_id::uuid '
        'and expires_at < @reap_floor::timestamptz',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'reap_floor':
              (now ?? DateTime.now)()
                  .toUtc()
                  .subtract(kReaperHorizon)
                  .toIso8601String(),
        },
      );

      final challengeId = _generateOpaqueChallengeId();
      // Bound the challenge TTL to the migration's hard ceiling (15
      // minutes). Defense-in-depth in case a buggy caller passes a
      // longer TTL — the migration's CHECK would reject the row, but
      // we'd rather refuse the bad value in Dart with a clamped
      // duration than fail late.
      final ttlSeconds = challengeTtl.inSeconds
          .clamp(1, kChallengeTtlCeiling.inSeconds);
      final rows = await exec.query(
        'insert into public.auth_step_up_challenges ('
        'challenge_id, operator_id, location_id, user_id, route_path, '
        'required_acr, required_freshness_seconds, expires_at, '
        'source_actor_kind, source_device_fingerprint) '
        'values ('
        '@challenge_id, @operator_id::uuid, @location_id::uuid, '
        '@user_id::uuid, @route_path, '
        '@required_acr, @required_freshness_seconds, '
        "now() + (@ttl_seconds || ' seconds')::interval, "
        '@source_actor_kind, @source_device_fingerprint) '
        'returning challenge_id',
        parameters: <String, Object?>{
          'challenge_id': challengeId,
          'operator_id': operatorId,
          'location_id': locationId,
          'user_id': userId,
          'route_path': routePath,
          'required_acr': requiredAcr,
          'required_freshness_seconds': requiredFreshnessSeconds,
          'ttl_seconds': ttlSeconds.toString(),
          'source_actor_kind': sourceActorKind,
          'source_device_fingerprint': sourceDeviceFingerprint,
        },
      );
      if (rows.isEmpty) {
        throw StateError(
          'auth_step_up_challenges insert returned no rows — RLS '
          'policy may have blocked the row even though SET LOCAL ran',
        );
      }
      final stored = rows.single['challenge_id'];
      if (stored is! String || stored.isEmpty) {
        throw StateError(
          'auth_step_up_challenges insert returned a malformed challenge_id',
        );
      }
      return stored;
    });
  }

  Future<StepUpChallengeConsumeRow?> consume({
    required String callerOperatorId,
    required String callerLocationId,
    required String callerUserId,
    required String callerRoutePath,
    required String challengeId,
  }) {
    final ctx = TenantContext(
      operatorId: callerOperatorId,
      locationId: callerLocationId,
      userId: callerUserId,
    );
    return withTenant<StepUpChallengeConsumeRow?>(ctx,
        (PostgresExecutor exec) async {
      // Atomic UPDATE … RETURNING with the full one-shot predicate.
      // Mirrors B11.1's handoff_codes redeem idiom: the predicate
      // (consumed_at IS NULL AND expires_at > now() AND route_path =
      // $route AND user_id = $user AND operator_id = $operator) is the
      // replay-protection invariant. A returned-empty result is the
      // signal for "predicate did not match"; the caller classifies via
      // lookupForReplayCheck.
      //
      // operator_id is also re-asserted in the WHERE as defense-in-
      // depth so even a misconfigured RLS posture would still refuse to
      // consume a row from a different operator (returns 0 rows).
      final rows = await exec.query(
        'update public.auth_step_up_challenges '
        'set consumed_at = now() '
        'where challenge_id = @challenge_id '
        'and operator_id = @operator_id::uuid '
        'and user_id = @user_id::uuid '
        'and route_path = @route_path '
        'and consumed_at is null '
        'and expires_at > now() '
        'returning '
        'challenge_id, '
        'operator_id::text as operator_id, '
        'location_id::text as location_id, '
        'user_id::text as user_id, '
        'route_path, '
        'required_acr, '
        'required_freshness_seconds, '
        'consumed_at',
        parameters: <String, Object?>{
          'challenge_id': challengeId,
          'operator_id': callerOperatorId,
          'user_id': callerUserId,
          'route_path': callerRoutePath,
        },
      );
      if (rows.isEmpty) return null;
      final row = rows.single;
      return StepUpChallengeConsumeRow(
        challengeId: row['challenge_id'] as String,
        operatorId: row['operator_id'] as String,
        locationId: row['location_id'] as String,
        userId: row['user_id'] as String,
        routePath: row['route_path'] as String,
        requiredAcr: row['required_acr'] as String,
        requiredFreshnessSeconds: row['required_freshness_seconds'] as int,
        consumedAt: _asUtcDateTime(row['consumed_at']),
      );
    });
  }

  /// Reads the current state of [challengeId] without mutating it.
  /// Runs through `withSystem` (BYPASSRLS) so the caller can detect
  /// "challenge exists in a different operator" for the oracle-safe
  /// classifier in `StepUpChallengeRouter`. The reason string is
  /// audited; the row data is only used to produce 401/410 status
  /// codes (no row content leaks back to the client).
  Future<StepUpChallengeStateRow?> lookupForReplayCheck({
    required String challengeId,
  }) {
    return withSystem<StepUpChallengeStateRow?>(
      (PostgresExecutor exec) async {
        final rows = await exec.query(
          'select '
          'operator_id::text as operator_id, '
          'user_id::text as user_id, '
          'route_path, '
          'expires_at, '
          'consumed_at '
          'from public.auth_step_up_challenges '
          'where challenge_id = @challenge_id '
          'limit 1',
          parameters: <String, Object?>{
            'challenge_id': challengeId,
          },
        );
        if (rows.isEmpty) return null;
        final row = rows.single;
        return StepUpChallengeStateRow(
          operatorId: row['operator_id'] as String,
          userId: row['user_id'] as String,
          routePath: row['route_path'] as String,
          expiresAt: _asUtcDateTime(row['expires_at']),
          consumedAt: row['consumed_at'] == null
              ? null
              : _asUtcDateTime(row['consumed_at']),
        );
      },
      reason: 'auth.step_up.lookup_for_replay_check',
    );
  }

  /// Generates a 22-character base64-url body of 16 random bytes
  /// (~128 bits of entropy). Padding stripped, '+' / '/' replaced
  /// with '-' / '_' so the id matches the migration's
  /// `^[A-Za-z0-9_-]+$` shape constraint and is URL-safe.
  ///
  /// Addendum A1 (B11 token-in-URL prohibition): the proxy reads this
  /// value from the `Step-Up-Challenge-Id` REQUEST HEADER, never from
  /// URL parameters. URL-safety is provided so that future hash-
  /// fragment correlation (browser-side, never transmitted to the
  /// proxy) is possible without re-encoding.
  static String _generateOpaqueChallengeId() {
    final rnd = math.Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  static DateTime _asUtcDateTime(Object? value) {
    if (value is DateTime) return value.toUtc();
    if (value is String) return DateTime.parse(value).toUtc();
    throw StateError('auth_step_up_challenges row missing timestamp');
  }
}
