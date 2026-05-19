import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/auth/auth_session.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/dao/manual_cover_entry_dao.dart';
import 'package:forge_and_flow/services/manual_covers_write_service.dart';
import 'package:forge_and_flow/services/sync/sync_proxy_client.dart';

void main() {
  test('writes canonical server covers then mirrors locally', () async {
    final calls = <_ManualCoversCall>[];
    final mirrored = <ManualCoverEntry>[];
    final client = _RecordingManualCoversClient(calls);
    final writer = AuthSessionManualCoversWriter(
      client: client,
      authSessionProvider: _session,
      localMirrorWriter: (entry) async => mirrored.add(entry),
    );
    const entry = ManualCoverEntry(
      restaurantId: 'loc-1',
      businessDate: '2026-05-10',
      daypart: 'brunch',
      covers: 84,
      recordedAt: '2026-05-10T18:00:00Z',
    );

    await writer.save(entry);

    expect(calls, hasLength(1));
    expect(calls.single.operatorId, 'op-1');
    expect(calls.single.locationId, 'loc-1');
    expect(calls.single.restaurantId, 'loc-1');
    expect(calls.single.businessDate, '2026-05-10');
    expect(calls.single.servicePeriodKey, 'brunch');
    expect(calls.single.covers, 84);
    expect(calls.single.idempotencyKey, startsWith('mobile-covers-'));
    expect(mirrored, hasLength(1));
    expect(mirrored.single.businessDate, entry.businessDate);
    expect(mirrored.single.daypart, entry.daypart);
    expect(mirrored.single.covers, entry.covers);
  });

  test('uses the active restaurant as the canonical route location', () async {
    final calls = <_ManualCoversCall>[];
    final client = _RecordingManualCoversClient(calls);
    final writer = AuthSessionManualCoversWriter(
      client: client,
      authSessionProvider: _session,
      localMirrorWriter: (_) async {},
    );

    await writer.save(
      const ManualCoverEntry(
        restaurantId: 'loc-2',
        businessDate: '2026-05-10',
        daypart: 'dinner',
        covers: 101,
        recordedAt: '2026-05-10T23:00:00Z',
      ),
    );

    expect(calls, hasLength(1));
    expect(calls.single.operatorId, 'op-1');
    expect(calls.single.locationId, 'loc-2');
    expect(calls.single.restaurantId, 'loc-2');
  });

  test('fails before local mirror when auth session is missing', () async {
    final mirrored = <ManualCoverEntry>[];
    final writer = AuthSessionManualCoversWriter(
      client: _RecordingManualCoversClient(<_ManualCoversCall>[]),
      authSessionProvider: () => null,
      localMirrorWriter: (entry) async => mirrored.add(entry),
    );

    await expectLater(
      writer.save(
        const ManualCoverEntry(
          restaurantId: 'loc-1',
          businessDate: '2026-05-10',
          daypart: 'dinner',
          covers: 84,
          recordedAt: '2026-05-10T18:00:00Z',
        ),
      ),
      throwsA(
        isA<ManualCoversWriteException>().having(
          (error) => error.code,
          'code',
          'auth_session_required',
        ),
      ),
    );
    expect(mirrored, isEmpty);
  });

  test('fails before server write when active location is missing', () async {
    final calls = <_ManualCoversCall>[];
    final mirrored = <ManualCoverEntry>[];
    final writer = AuthSessionManualCoversWriter(
      client: _RecordingManualCoversClient(calls),
      authSessionProvider: _session,
      localMirrorWriter: (entry) async => mirrored.add(entry),
    );

    await expectLater(
      writer.save(
        const ManualCoverEntry(
          restaurantId: '',
          businessDate: '2026-05-10',
          daypart: 'dinner',
          covers: 84,
          recordedAt: '2026-05-10T18:00:00Z',
        ),
      ),
      throwsA(
        isA<ManualCoversWriteException>().having(
          (error) => error.code,
          'code',
          'active_location_required',
        ),
      ),
    );
    expect(calls, isEmpty);
    expect(mirrored, isEmpty);
  });
}

AuthSession? _session() {
  final now = DateTime.utc(2026, 5, 10, 18);
  return AuthSession(
    userId: 'user-1',
    operatorId: 'op-1',
    locationId: 'loc-1',
    firebaseIdToken: 'token',
    issuedAt: now,
    expiresAt: now.add(const Duration(hours: 1)),
    lastFreshAuthAt: now,
    roles: const <String>['operator_owner'],
    mfaEnrolled: true,
  );
}

class _RecordingManualCoversClient implements ManualCoversWriteClient {
  const _RecordingManualCoversClient(this.calls);

  final List<_ManualCoversCall> calls;

  @override
  Future<void> submitManualCovers({
    required String operatorId,
    required String locationId,
    required String businessDate,
    required String servicePeriodKey,
    required int covers,
    required String idempotencyKey,
    String? restaurantId,
    String? recordedAt,
  }) async {
    calls.add(
      _ManualCoversCall(
        operatorId: operatorId,
        locationId: locationId,
        restaurantId: restaurantId,
        businessDate: businessDate,
        servicePeriodKey: servicePeriodKey,
        covers: covers,
        recordedAt: recordedAt,
        idempotencyKey: idempotencyKey,
      ),
    );
  }
}

class _ManualCoversCall {
  const _ManualCoversCall({
    required this.operatorId,
    required this.locationId,
    required this.restaurantId,
    required this.businessDate,
    required this.servicePeriodKey,
    required this.covers,
    required this.recordedAt,
    required this.idempotencyKey,
  });

  final String operatorId;
  final String locationId;
  final String? restaurantId;
  final String businessDate;
  final String servicePeriodKey;
  final int covers;
  final String? recordedAt;
  final String idempotencyKey;
}
