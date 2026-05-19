// CODE_OPS_DEBT Theme B#1 — UserPiiErasureService unit tests.
//
// The service is repository-only: every test injects a recording
// fake so the orchestration logic (grace-window resolution, snapshot
// capture-and-restore on reverse, status read passthrough, batch
// apply) can be pinned without a live database.
//
// Carry-over follow-up #3 (2026-05-08): the
// `business_date IANA-tz resolver` group exercises the new resolver
// callback. The fake repo records the `businessDate` parameter the
// service forwards so the test can assert that an `America/
// Los_Angeles` 04:00 UTC erasure lands on `2026-05-07`, not `2026-05-08`.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/user_pii_erasure_repository.dart';
import 'package:forge_and_flow/services/auth/user_pii_erasure_service.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _userA = '33333333-3333-3333-3333-333333333333';
const String _adminA = '44444444-4444-4444-4444-444444444444';
const String _erasureA = '55555555-5555-5555-5555-555555555555';

UserPiiErasureRequestRecord _record({
  String erasureId = _erasureA,
  DateTime? gracePeriodEndsAt,
  DateTime? appliedAt,
  DateTime? reversedAt,
  Map<String, Object?>? piiSnapshot,
}) {
  return UserPiiErasureRequestRecord(
    erasureId: erasureId,
    operatorId: _opA,
    userId: _userA,
    requestedByUserId: _adminA,
    requestedAt: DateTime.utc(2026, 5, 8, 12),
    businessDate: '2026-05-08',
    gracePeriodEndsAt:
        gracePeriodEndsAt ?? DateTime.utc(2026, 5, 9, 12),
    appliedAt: appliedAt,
    reversedAt: reversedAt,
    piiSnapshot: piiSnapshot ?? const <String, Object?>{
      'display_name': 'Aria',
      'email': 'aria@example.test',
      'first_name': 'Aria',
      'last_name': 'Op',
      'avatar_url': null,
    },
  );
}

// We use `implements` rather than `extends` so the fake never needs
// a real tenant pool. Dart treats this as an interface
// implementation; all overridden methods provide the canonical-path
// behaviour the service exercises.
//
// `noSuchMethod` returns null for any unimplemented seam — this keeps
// the fake compact while letting tests grow. The trade-off is that a
// future call into an unmocked seam returns `Future<dynamic>`-shaped
// `null`; the tests below assert against the recorded `calls` list
// instead of relying on `noSuchMethod` returns.
class _FakeErasureRepo implements UserPiiErasureRepository {
  _FakeErasureRepo({
    this.snapshotResult,
    this.findPendingResult,
    this.dueRows = const <UserPiiErasureRequestRecord>[],
    this.locationForUser = _locA,
  });

  UserPiiErasureRequestRecord? snapshotResult;
  UserPiiErasureRequestRecord? findPendingResult;
  UserPiiErasureRequestRecord? findLatestResult;
  int markReversedResult;
  int applyResult;
  List<UserPiiErasureRequestRecord> dueRows;
  String? locationForUser;

  final List<String> calls = <String>[];
  final List<UserPiiSnapshot> restoredSnapshots = <UserPiiSnapshot>[];

  /// Captures the `businessDate` the service forwarded on the most
  /// recent `snapshotPiiAndInsertPending` call. Carry-over follow-up
  /// #3 asserts the resolver-driven path produces the restaurant-local
  /// date, not the UTC truncation.
  String? lastBusinessDate;

  @override
  Future<UserPiiErasureRequestRecord?> snapshotPiiAndInsertPending({
    required String erasureId,
    required String operatorId,
    required String locationId,
    required String userId,
    required String requestedByUserId,
    required DateTime requestedAt,
    required String businessDate,
    required DateTime gracePeriodEndsAt,
  }) async {
    calls.add('snapshotPiiAndInsertPending:$erasureId:$userId');
    lastBusinessDate = businessDate;
    return snapshotResult;
  }

  @override
  Future<UserPiiErasureRequestRecord?> findPendingById({
    required String operatorId,
    required String locationId,
    required String userId,
    required String erasureId,
  }) async {
    calls.add('findPendingById:$erasureId');
    return findPendingResult;
  }

  @override
  Future<UserPiiErasureRequestRecord?> findLatestForUser({
    required String operatorId,
    required String locationId,
    required String userId,
  }) async {
    calls.add('findLatestForUser:$userId');
    return findLatestResult;
  }

  @override
  Future<int> markReversed({
    required String operatorId,
    required String locationId,
    required String userId,
    required String erasureId,
    required String reversedByUserId,
    required String? reversalReason,
    required DateTime reversedAt,
  }) async {
    calls.add('markReversed:$erasureId:$reversedByUserId');
    return markReversedResult;
  }

  @override
  Future<int> restoreSnapshotToUser({
    required String operatorId,
    required String locationId,
    required String userId,
    required UserPiiSnapshot snapshot,
  }) async {
    calls.add('restoreSnapshotToUser:$userId');
    restoredSnapshots.add(snapshot);
    return 1;
  }

  @override
  Future<int> applyRowAndWipeSnapshot({
    required String operatorId,
    required String locationId,
    required String userId,
    required String erasureId,
    required DateTime appliedAt,
  }) async {
    calls.add('applyRowAndWipeSnapshot:$erasureId');
    return applyResult;
  }

  @override
  Future<List<UserPiiErasureRequestRecord>> listDuePending({
    required DateTime now,
    int limit = 100,
  }) async {
    calls.add('listDuePending');
    return dueRows;
  }

  @override
  Future<String?> resolveLocationForUser({
    required String operatorId,
    required String userId,
  }) async {
    calls.add('resolveLocationForUser:$userId');
    return locationForUser;
  }

  // The remaining repo seams are not exercised by the service.
  @override
  Future<UserPiiErasureRequestRecord> insertPending({
    required String erasureId,
    required String operatorId,
    required String locationId,
    required String userId,
    required String requestedByUserId,
    required DateTime requestedAt,
    required String businessDate,
    required DateTime gracePeriodEndsAt,
    required UserPiiSnapshot piiSnapshot,
  }) =>
      throw UnimplementedError();

  @override
  AuditLogsRepository get auditLogsRepository =>
      const AuditLogsRepository();

  // The base also exposes withTenant / withSystem from
  // OperatorScopedRepository; the fake's overrides above bypass them
  // entirely. noSuchMethod swallows any incidental calls.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

void main() {
  group('UserPiiErasureService.requestErasure', () {
    test('returns the erasure summary on a successful insert',
        () async {
      final repo = _FakeErasureRepo(snapshotResult: _record());
      final service = UserPiiErasureService(
        erasureRepository: repo,
        gracePeriod: const Duration(hours: 24),
        now: () => DateTime.utc(2026, 5, 8, 12),
      );
      final result = await service.requestErasure(
        operatorId: _opA,
        locationId: _locA,
        targetUserId: _userA,
        requestedByUserId: _adminA,
        businessDate: '2026-05-08',
      );
      expect(result, isNotNull);
      expect(result!.erasureId, equals(_erasureA));
      expect(repo.calls.first, startsWith('snapshotPiiAndInsertPending:'));
    });

    test('returns null when the user row is missing', () async {
      final repo = _FakeErasureRepo(snapshotResult: null);
      final service = UserPiiErasureService(
        erasureRepository: repo,
        gracePeriod: const Duration(hours: 24),
        now: () => DateTime.utc(2026, 5, 8, 12),
      );
      final result = await service.requestErasure(
        operatorId: _opA,
        locationId: _locA,
        targetUserId: _userA,
        requestedByUserId: _adminA,
        businessDate: '2026-05-08',
      );
      expect(result, isNull);
    });
  });

  group(
    'UserPiiErasureService.requestErasure — IANA-tz business_date '
    'resolver (carry-over follow-up #3)',
    () {
      test(
        '04:00 UTC for America/Los_Angeles → business_date is the prior '
        'PT day, not the UTC day',
        () async {
          final repo = _FakeErasureRepo(snapshotResult: _record());
          // 2026-05-08 04:00 UTC = 2026-05-07 21:00 PDT (UTC-7).
          // Default rollover hour 0 means the local wall clock at
          // 21:00 belongs to 2026-05-07. The resolver MUST win over
          // the UTC fallback.
          final resolverCalls = <String>[];
          final service = UserPiiErasureService(
            erasureRepository: repo,
            gracePeriod: const Duration(hours: 24),
            now: () => DateTime.utc(2026, 5, 8, 4),
            businessDateResolver: ({
              required String operatorId,
              required String locationId,
              required DateTime requestedAt,
            }) async {
              resolverCalls.add('$operatorId:$locationId:'
                  '${requestedAt.toIso8601String()}');
              // Hand-rolled IANA projection so the test does not need
              // the timezone database initialised. 2026-05-08T04:00Z
              // → 2026-05-07T21:00 PDT → business date 2026-05-07.
              expect(requestedAt, equals(DateTime.utc(2026, 5, 8, 4)));
              return '2026-05-07';
            },
          );
          final result = await service.requestErasure(
            operatorId: _opA,
            locationId: _locA,
            targetUserId: _userA,
            requestedByUserId: _adminA,
          );
          expect(result, isNotNull);
          expect(repo.lastBusinessDate, equals('2026-05-07'));
          expect(resolverCalls, hasLength(1));
        },
      );

      test(
        'falls back to UTC truncation when no resolver is bound and no '
        'override is passed',
        () async {
          final repo = _FakeErasureRepo(snapshotResult: _record());
          final service = UserPiiErasureService(
            erasureRepository: repo,
            gracePeriod: const Duration(hours: 24),
            now: () => DateTime.utc(2026, 5, 8, 4),
          );
          await service.requestErasure(
            operatorId: _opA,
            locationId: _locA,
            targetUserId: _userA,
            requestedByUserId: _adminA,
          );
          expect(repo.lastBusinessDate, equals('2026-05-08'));
        },
      );

      test(
        'caller-provided businessDate override wins when no resolver is '
        'bound',
        () async {
          final repo = _FakeErasureRepo(snapshotResult: _record());
          final service = UserPiiErasureService(
            erasureRepository: repo,
            gracePeriod: const Duration(hours: 24),
            now: () => DateTime.utc(2026, 5, 8, 4),
          );
          await service.requestErasure(
            operatorId: _opA,
            locationId: _locA,
            targetUserId: _userA,
            requestedByUserId: _adminA,
            businessDate: '2026-05-07',
          );
          expect(repo.lastBusinessDate, equals('2026-05-07'));
        },
      );

      test(
        'resolver returning null → falls back to UTC truncation '
        '(does not block the erasure)',
        () async {
          final repo = _FakeErasureRepo(snapshotResult: _record());
          final service = UserPiiErasureService(
            erasureRepository: repo,
            gracePeriod: const Duration(hours: 24),
            now: () => DateTime.utc(2026, 5, 8, 4),
            businessDateResolver: ({
              required String operatorId,
              required String locationId,
              required DateTime requestedAt,
            }) async =>
                null,
          );
          await service.requestErasure(
            operatorId: _opA,
            locationId: _locA,
            targetUserId: _userA,
            requestedByUserId: _adminA,
          );
          expect(repo.lastBusinessDate, equals('2026-05-08'));
        },
      );

      test(
        'resolver throwing → falls back to UTC truncation (transient '
        'tz read does not block the erasure write)',
        () async {
          final repo = _FakeErasureRepo(snapshotResult: _record());
          final service = UserPiiErasureService(
            erasureRepository: repo,
            gracePeriod: const Duration(hours: 24),
            now: () => DateTime.utc(2026, 5, 8, 4),
            businessDateResolver: ({
              required String operatorId,
              required String locationId,
              required DateTime requestedAt,
            }) async =>
                throw StateError('tz read flapped'),
          );
          await service.requestErasure(
            operatorId: _opA,
            locationId: _locA,
            targetUserId: _userA,
            requestedByUserId: _adminA,
          );
          expect(repo.lastBusinessDate, equals('2026-05-08'));
        },
      );
    },
  );

  group('UserPiiErasureService.reverseErasure', () {
    test(
      'within grace window: reads snapshot, marks reversed, restores '
      'PII back onto users',
      () async {
        final repo = _FakeErasureRepo(
          findPendingResult: _record(
            gracePeriodEndsAt: DateTime.utc(2026, 5, 9, 12),
          ),
        );
        final service = UserPiiErasureService(
          erasureRepository: repo,
          gracePeriod: const Duration(hours: 24),
          now: () => DateTime.utc(2026, 5, 8, 14),
        );
        final outcome = await service.reverseErasure(
          operatorId: _opA,
          locationId: _locA,
          targetUserId: _userA,
          erasureId: _erasureA,
          reversedByUserId: _adminA,
          reversalReason: 'admin changed mind',
        );
        expect(outcome.reversed, isTrue);
        expect(outcome.graceExpired, isFalse);
        expect(repo.restoredSnapshots, hasLength(1));
        expect(repo.restoredSnapshots.single.email,
            equals('aria@example.test'));
      },
    );

    test('outside grace window: returns graceExpired=true; no restore',
        () async {
      final repo = _FakeErasureRepo(
        findPendingResult: _record(
          gracePeriodEndsAt: DateTime.utc(2026, 5, 8, 13),
        ),
      );
      final service = UserPiiErasureService(
        erasureRepository: repo,
        gracePeriod: const Duration(hours: 24),
        now: () => DateTime.utc(2026, 5, 9, 12),
      );
      final outcome = await service.reverseErasure(
        operatorId: _opA,
        locationId: _locA,
        targetUserId: _userA,
        erasureId: _erasureA,
        reversedByUserId: _adminA,
      );
      expect(outcome.reversed, isFalse);
      expect(outcome.graceExpired, isTrue);
      expect(repo.restoredSnapshots, isEmpty);
    });

    test('row missing: returns notFound=true', () async {
      final repo = _FakeErasureRepo(findPendingResult: null);
      final service = UserPiiErasureService(
        erasureRepository: repo,
        gracePeriod: const Duration(hours: 24),
      );
      final outcome = await service.reverseErasure(
        operatorId: _opA,
        locationId: _locA,
        targetUserId: _userA,
        erasureId: _erasureA,
        reversedByUserId: _adminA,
      );
      expect(outcome.notFound, isTrue);
      expect(outcome.reversed, isFalse);
    });
  });

  group('UserPiiErasureService.applyDuePending', () {
    test(
      'walks each due row, resolves a location, applies the NULL-out',
      () async {
        final repo = _FakeErasureRepo(
          dueRows: <UserPiiErasureRequestRecord>[_record()],
        );
        final service = UserPiiErasureService(
          erasureRepository: repo,
          gracePeriod: const Duration(hours: 24),
          now: () => DateTime.utc(2026, 5, 9, 13),
        );
        final batch = await service.applyDuePending();
        expect(batch.scanned, equals(1));
        expect(batch.applied, equals(1));
        expect(repo.calls, contains('applyRowAndWipeSnapshot:$_erasureA'));
      },
    );

    test(
      'skips rows whose location cannot be resolved (no apply, '
      'increments skippedNoLocation)',
      () async {
        final repo = _FakeErasureRepo(
          dueRows: <UserPiiErasureRequestRecord>[_record()],
          locationForUser: null,
        );
        final service = UserPiiErasureService(
          erasureRepository: repo,
          gracePeriod: const Duration(hours: 24),
        );
        final batch = await service.applyDuePending();
        expect(batch.scanned, equals(1));
        expect(batch.applied, equals(0));
        expect(batch.skippedNoLocation, equals(1));
        expect(
          repo.calls,
          isNot(contains('applyRowAndWipeSnapshot:$_erasureA')),
        );
      },
    );
  });
}
