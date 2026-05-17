// Doc 1 timing web/admin live parity (2026-05-08) - tests for the
// admin-side business-timing override routes. Pins:
//   * `admin_reason` is required on every write.
//   * Admin writes flow through the same audit sink + idempotency
//     cache as operator-scoped writes.
//   * The mutation listener fires once per successful write so the
//     outbox/invalidation proof is end-to-end (not "mobile poll
//     eventually catches up").
//   * Per-operator URL parsing rejects malformed paths and unknown
//     profile ids.
//
// The admin router is exercised directly (no HTTP socket) because
// the dispatcher in `advisor_proxy.dart` is a thin shim that only
// resolves auth/idempotency before delegating; the auth/idempotency
// envelope is already covered by the existing operator tests.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/services/business_timing/business_timing_profile_validator.dart';

import '../../tool/advisor_proxy/admin_business_timing_routes.dart';
import '../../tool/advisor_proxy/operator_routes.dart';

const String _kOpA = '11111111-1111-1111-1111-111111111111';
const String _kOpB = '22222222-2222-2222-2222-222222222222';
const String _kAdmin = '33333333-3333-3333-3333-333333333333';
const String _kProfile = '44444444-4444-4444-4444-444444444444';

Map<String, Object?> _validBody({
  String adminReason = 'Customer requested change',
}) {
  return <String, Object?>{
    'admin_reason': adminReason,
    'scopeKind': 'operator',
    'scopeId': _kOpA,
    'effectiveAtBusinessDate': '2026-06-01',
    'ianaTimezone': 'America/Toronto',
    'weekStartDay': 'monday',
    'businessDayStartLocal': '04:00',
    'servicePeriods': const <Map<String, Object?>>[
      <String, Object?>{
        'key': 'lunch',
        'label': 'Lunch',
        'startLocal': '11:00',
        'endLocal': '15:00',
      },
      <String, Object?>{
        'key': 'dinner',
        'label': 'Dinner',
        'startLocal': '17:00',
        'endLocal': '22:00',
      },
    ],
  };
}

void main() {
  group('AdminBusinessTimingRouter', () {
    late _RecordingTimingGateway gateway;
    late _RecordingAuditSink audit;
    late _RecordingMutationListener listener;
    late AdminBusinessTimingRouter router;

    setUp(() {
      gateway = _RecordingTimingGateway();
      audit = _RecordingAuditSink();
      listener = _RecordingMutationListener();
      router = AdminBusinessTimingRouter(
        businessTimingGateway: gateway,
        auditSink: audit,
        mutationListener: listener,
      );
    });

    test('matches the canonical admin paths and rejects others', () {
      expect(
        AdminBusinessTimingRouter.matches(
          '/v1/admin/operators/$_kOpA/business-timing-profiles',
          'GET',
        ),
        isTrue,
      );
      expect(
        AdminBusinessTimingRouter.matches(
          '/v1/admin/operators/$_kOpA/business-timing-profiles',
          'POST',
        ),
        isTrue,
      );
      expect(
        AdminBusinessTimingRouter.matches(
          '/v1/admin/operators/$_kOpA/business-timing-profiles/$_kProfile',
          'PATCH',
        ),
        isTrue,
      );
      // Missing operator id, missing profile id on PATCH, and
      // `/v1/operator/...` paths must NOT match.
      expect(
        AdminBusinessTimingRouter.matches(
          '/v1/admin/operators//business-timing-profiles',
          'POST',
        ),
        isFalse,
      );
      expect(
        AdminBusinessTimingRouter.matches(
          '/v1/admin/operators/$_kOpA/business-timing-profiles',
          'PATCH',
        ),
        isFalse,
      );
      expect(
        AdminBusinessTimingRouter.matches(
          '/v1/operator/business-timing-profiles',
          'POST',
        ),
        isFalse,
      );
    });

    test('GET lists profiles for the URL operator only', () async {
      gateway.seed(_kOpA, _kProfile);
      gateway.seed(_kOpB, 'other-profile');
      final result = await router.handle(
        method: 'GET',
        path: '/v1/admin/operators/$_kOpA/business-timing-profiles',
        actorUserId: _kAdmin,
        actorKind: 'user',
        idempotencyKey: '',
        body: const <String, Object?>{},
      );
      expect(result.statusCode, equals(200));
      final profiles = result.body['profiles'] as List<Object?>;
      expect(profiles, hasLength(1));
      expect(
        (profiles.single as Map<String, Object?>)['profileId'],
        equals(_kProfile),
      );
    });

    test('POST without admin_reason is rejected', () async {
      final body = _validBody()..remove('admin_reason');
      final result = await router.handle(
        method: 'POST',
        path: '/v1/admin/operators/$_kOpA/business-timing-profiles',
        actorUserId: _kAdmin,
        actorKind: 'user',
        idempotencyKey: 'idem-no-reason',
        body: body,
      );
      expect(result.statusCode, equals(400));
      expect(result.body['error'], equals('missing_admin_reason'));
      expect(gateway.createCalls, equals(0));
      expect(audit.records, isEmpty);
      expect(listener.events, isEmpty);
    });

    test('POST with whitespace-only admin_reason is rejected', () async {
      final body = _validBody(adminReason: '   ');
      final result = await router.handle(
        method: 'POST',
        path: '/v1/admin/operators/$_kOpA/business-timing-profiles',
        actorUserId: _kAdmin,
        actorKind: 'user',
        idempotencyKey: 'idem-blank-reason',
        body: body,
      );
      expect(result.statusCode, equals(400));
      expect(result.body['error'], equals('missing_admin_reason'));
    });

    test('POST happy path audits + invalidates with admin_reason', () async {
      final result = await router.handle(
        method: 'POST',
        path: '/v1/admin/operators/$_kOpA/business-timing-profiles',
        actorUserId: _kAdmin,
        actorKind: 'user',
        idempotencyKey: 'idem-admin-create',
        body: _validBody(adminReason: 'Operator emergency rollback'),
      );
      expect(result.statusCode, equals(201));
      expect(gateway.createCalls, equals(1));
      expect(audit.records, hasLength(1));
      final record = audit.records.single;
      expect(record['eventKind'], equals('business_timing_profile_created'));
      final payload = record['payload'] as Map<String, Object?>;
      expect(
        payload['admin_reason'],
        equals('Operator emergency rollback'),
      );
      expect(payload['admin_origin'], equals('admin_console'));
      // Outbox/invalidation proof: listener fired exactly once.
      expect(listener.events, hasLength(1));
      expect(
        listener.events.single['eventKind'],
        equals('business_timing_profile_created'),
      );
      expect(listener.events.single['operatorId'], equals(_kOpA));
    });

    test('POST with operator-scope mismatch is rejected', () async {
      final body = _validBody()..['scopeId'] = _kOpB;
      final result = await router.handle(
        method: 'POST',
        path: '/v1/admin/operators/$_kOpA/business-timing-profiles',
        actorUserId: _kAdmin,
        actorKind: 'user',
        idempotencyKey: 'idem-cross',
        body: body,
      );
      expect(result.statusCode, equals(400));
      expect(result.body['error'], equals('scope_id_mismatch'));
      expect(gateway.createCalls, equals(0));
      expect(listener.events, isEmpty);
    });

    test('PATCH on missing profile returns 404 + no listener fire', () async {
      final result = await router.handle(
        method: 'PATCH',
        path: '/v1/admin/operators/$_kOpA/business-timing-profiles/'
            'unknown-profile',
        actorUserId: _kAdmin,
        actorKind: 'user',
        idempotencyKey: 'idem-missing',
        body: <String, Object?>{
          'admin_reason': 'Support escalation',
          'businessDayStartLocal': '03:00',
        },
      );
      expect(result.statusCode, equals(404));
      expect(result.body['error'], equals('profile_not_found'));
      expect(listener.events, isEmpty);
    });

    test('PATCH happy path audits + invalidates', () async {
      gateway.seed(_kOpA, _kProfile);
      final result = await router.handle(
        method: 'PATCH',
        path: '/v1/admin/operators/$_kOpA/business-timing-profiles/$_kProfile',
        actorUserId: _kAdmin,
        actorKind: 'user',
        idempotencyKey: 'idem-admin-patch',
        body: <String, Object?>{
          'admin_reason': 'Adjust closing hour',
          'businessDayStartLocal': '03:00',
        },
      );
      expect(result.statusCode, equals(200));
      expect(gateway.updateCalls, equals(1));
      expect(audit.records, hasLength(1));
      expect(
        (audit.records.single['payload'] as Map<String, Object?>)['admin_reason'],
        equals('Adjust closing hour'),
      );
      expect(listener.events, hasLength(1));
      expect(
        listener.events.single['eventKind'],
        equals('business_timing_profile_updated'),
      );
    });

    test('idempotent replay returns same response without re-running gateway',
        () async {
      final first = await router.handle(
        method: 'POST',
        path: '/v1/admin/operators/$_kOpA/business-timing-profiles',
        actorUserId: _kAdmin,
        actorKind: 'user',
        idempotencyKey: 'idem-admin-replay',
        body: _validBody(),
      );
      final second = await router.handle(
        method: 'POST',
        path: '/v1/admin/operators/$_kOpA/business-timing-profiles',
        actorUserId: _kAdmin,
        actorKind: 'user',
        idempotencyKey: 'idem-admin-replay',
        body: _validBody(),
      );
      expect(first.statusCode, equals(201));
      expect(second.statusCode, equals(201));
      expect(first.body['profileId'], equals(second.body['profileId']));
      expect(gateway.createCalls, equals(1));
      // Listener stays at one too because the second hit replays from
      // the cache and never re-runs the compute closure.
      expect(listener.events, hasLength(1));
    });

    test(
        'OperatorWriteRouter still fires the listener on operator writes',
        () async {
      final operatorRouter = OperatorWriteRouter(
        accountGateway: _NoopAccountGateway(),
        businessTimingGateway: gateway,
        auditSink: audit,
        mutationListener: listener,
      );
      final result = await operatorRouter.handle(
        method: 'POST',
        path: operatorBusinessTimingProfilesPath,
        operatorId: _kOpA,
        actorUserId: 'op-user',
        actorKind: 'user',
        idempotencyKey: 'idem-op-create',
        body: <String, Object?>{
          'scopeKind': 'operator',
          'scopeId': _kOpA,
          'effectiveAtBusinessDate': '2026-06-01',
          'ianaTimezone': 'America/Toronto',
          'weekStartDay': 'monday',
          'businessDayStartLocal': '04:00',
          'servicePeriods': <Map<String, Object?>>[
            <String, Object?>{
              'key': 'lunch',
              'label': 'Lunch',
              'startLocal': '11:00',
              'endLocal': '15:00',
            },
            <String, Object?>{
              'key': 'dinner',
              'label': 'Dinner',
              'startLocal': '17:00',
              'endLocal': '22:00',
            },
          ],
        },
      );
      expect(result.statusCode, equals(201));
      expect(listener.events, hasLength(1));
      expect(
        listener.events.single['eventKind'],
        equals('business_timing_profile_created'),
      );
    });
  });
}

class _RecordingTimingGateway implements OperatorBusinessTimingWriteGateway {
  int createCalls = 0;
  int updateCalls = 0;
  int replaceCalls = 0;

  // Fix #4 / S2 — admin cross-tenant resolution recording. The handler
  // must only ever pass the URL operator/location through; these let
  // the route tests assert the gateway received exactly the URL scope
  // and the audit `reason`.
  int resolveAsSystemCalls = 0;
  String? lastResolveAsSystemOperatorId;
  String? lastResolveAsSystemLocationId;
  String? lastResolveAsSystemBusinessDate;
  String? lastResolveAsSystemReason;
  List<OperatorBusinessTimingResolutionCandidate>? _systemChain;

  void seedSystemChain(
    List<OperatorBusinessTimingResolutionCandidate> chain,
  ) {
    _systemChain = chain;
  }

  final Map<String, OperatorBusinessTimingProfileRecord> _seeded =
      <String, OperatorBusinessTimingProfileRecord>{};

  void seed(String operatorId, String profileId) {
    _seeded['$operatorId|$profileId'] = OperatorBusinessTimingProfileRecord(
      profileId: profileId,
      scopeKind: 'operator',
      scopeId: operatorId,
      effectiveAtBusinessDate: '2026-05-01',
      ianaTimezone: 'America/Toronto',
      weekStartDay: 'monday',
      businessDayStartLocal: '04:00',
      servicePeriods: const <OperatorBusinessTimingServicePeriodRecord>[
        OperatorBusinessTimingServicePeriodRecord(
          key: 'lunch',
          label: 'Lunch',
          startLocal: '11:00',
          endLocal: '15:00',
          rollsPastMidnight: false,
        ),
      ],
      createdAt: DateTime.utc(2026, 5, 1),
      updatedAt: DateTime.utc(2026, 5, 1),
    );
  }

  OperatorBusinessTimingProfileRecord _newRecord(
    String profileId,
    String operatorId,
    ValidatedBusinessTimingProfile validated,
  ) {
    return OperatorBusinessTimingProfileRecord(
      profileId: profileId,
      scopeKind: validated.scopeKind,
      scopeId: validated.scopeId,
      effectiveAtBusinessDate: validated.effectiveAtBusinessDate,
      ianaTimezone: validated.ianaTimezone,
      weekStartDay: validated.weekStartDay,
      businessDayStartLocal: validated.businessDayStartLocal,
      servicePeriods: <OperatorBusinessTimingServicePeriodRecord>[
        for (final p in validated.servicePeriods)
          OperatorBusinessTimingServicePeriodRecord(
            key: p.key,
            label: p.label,
            startLocal: p.startLocal,
            endLocal: p.endLocal,
            rollsPastMidnight: p.rollsPastMidnight,
          ),
      ],
      createdAt: DateTime.utc(2026, 5, 1),
      updatedAt: DateTime.utc(2026, 5, 7),
    );
  }

  @override
  Future<OperatorBusinessTimingProfileRecord> createProfile({
    required String operatorId,
    required String actorUserId,
    required String idempotencyKey,
    required ValidatedBusinessTimingProfile validated,
    required String adminReason,
  }) async {
    createCalls += 1;
    final record = _newRecord(_kProfile, operatorId, validated);
    _seeded['$operatorId|${record.profileId}'] = record;
    return record;
  }

  @override
  Future<OperatorBusinessTimingProfileRecord?> loadProfile({
    required String operatorId,
    required String profileId,
  }) async =>
      _seeded['$operatorId|$profileId'];

  @override
  Future<OperatorBusinessTimingResolutionResult> resolveForLocation({
    required String operatorId,
    required String locationId,
    required String businessDate,
    String? actorUserId,
  }) async {
    return OperatorBusinessTimingResolutionResult(
      operatorId: operatorId,
      locationId: locationId,
      businessDate: businessDate,
      ianaTimezone: null,
      candidates: const <OperatorBusinessTimingResolutionCandidate>[],
    );
  }

  @override
  Future<OperatorBusinessTimingResolutionResult> resolveForLocationAsSystem({
    required String operatorId,
    required String locationId,
    required String businessDate,
    required String reason,
  }) async {
    resolveAsSystemCalls += 1;
    lastResolveAsSystemOperatorId = operatorId;
    lastResolveAsSystemLocationId = locationId;
    lastResolveAsSystemBusinessDate = businessDate;
    lastResolveAsSystemReason = reason;
    final chain = _systemChain ??
        const <OperatorBusinessTimingResolutionCandidate>[];
    return OperatorBusinessTimingResolutionResult(
      operatorId: operatorId,
      locationId: locationId,
      businessDate: businessDate,
      ianaTimezone: chain.isEmpty ? null : chain.first.ianaTimezone,
      candidates: chain,
    );
  }

  @override
  Future<List<OperatorBusinessTimingProfileRecord>> listProfiles({
    required String operatorId,
  }) async {
    return _seeded.entries
        .where((entry) => entry.key.startsWith('$operatorId|'))
        .map((entry) => entry.value)
        .toList(growable: false);
  }

  @override
  Future<OperatorBusinessTimingProfileRecord> updateProfile({
    required String operatorId,
    required String actorUserId,
    required String idempotencyKey,
    required String profileId,
    required ValidatedBusinessTimingProfile validated,
    required String adminReason,
  }) async {
    updateCalls += 1;
    final record = _newRecord(profileId, operatorId, validated);
    _seeded['$operatorId|$profileId'] = record;
    return record;
  }

  @override
  Future<OperatorBusinessTimingProfileRecord> replaceServicePeriodSet({
    required String operatorId,
    required String actorUserId,
    required String idempotencyKey,
    required String profileId,
    required List<ValidatedServicePeriod> mergedSet,
    required String eventKind,
    required Map<String, Object?> auditPayload,
    required String adminReason,
  }) async {
    replaceCalls += 1;
    final existing = _seeded['$operatorId|$profileId']!;
    final updated = OperatorBusinessTimingProfileRecord(
      profileId: existing.profileId,
      scopeKind: existing.scopeKind,
      scopeId: existing.scopeId,
      effectiveAtBusinessDate: existing.effectiveAtBusinessDate,
      ianaTimezone: existing.ianaTimezone,
      weekStartDay: existing.weekStartDay,
      businessDayStartLocal: existing.businessDayStartLocal,
      servicePeriods: <OperatorBusinessTimingServicePeriodRecord>[
        for (final p in mergedSet)
          OperatorBusinessTimingServicePeriodRecord(
            key: p.key,
            label: p.label,
            startLocal: p.startLocal,
            endLocal: p.endLocal,
            rollsPastMidnight: p.rollsPastMidnight,
          ),
      ],
      createdAt: existing.createdAt,
      updatedAt: DateTime.utc(2026, 5, 7),
    );
    _seeded['$operatorId|$profileId'] = updated;
    return updated;
  }
}

class _RecordingAuditSink implements OperatorWriteAuditSink {
  final List<Map<String, Object?>> records = <Map<String, Object?>>[];
  @override
  Future<void> record({
    required String operatorId,
    required String actorUserId,
    required String actorKind,
    required String eventKind,
    required Map<String, Object?> payload,
    required DateTime occurredAt,
  }) async {
    records.add(<String, Object?>{
      'operatorId': operatorId,
      'actorUserId': actorUserId,
      'actorKind': actorKind,
      'eventKind': eventKind,
      'payload': payload,
      'occurredAt': occurredAt,
    });
  }
}

class _RecordingMutationListener
    implements OperatorBusinessTimingMutationListener {
  final List<Map<String, Object?>> events = <Map<String, Object?>>[];
  @override
  Future<void> onTimingProfileMutated({
    required String operatorId,
    required String profileId,
    required String scopeKind,
    required String scopeId,
    required String eventKind,
    required String actorUserId,
    required String actorKind,
    required DateTime occurredAt,
  }) async {
    events.add(<String, Object?>{
      'operatorId': operatorId,
      'profileId': profileId,
      'scopeKind': scopeKind,
      'scopeId': scopeId,
      'eventKind': eventKind,
      'actorUserId': actorUserId,
      'actorKind': actorKind,
      'occurredAt': occurredAt,
    });
  }
}

class _NoopAccountGateway implements OperatorAccountWriteGateway {
  @override
  Future<OperatorAccountRecord> patchAccount({
    required String operatorId,
    required String actorUserId,
    required String idempotencyKey,
    required ValidatedOperatorAccountPatch patch,
    required String adminReason,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<OperatorAccountRecord?> loadAccount({
    required String operatorId,
  }) async =>
      null;
}
