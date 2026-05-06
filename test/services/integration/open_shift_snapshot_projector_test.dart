import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/service_period_definition.dart';
import 'package:forge_and_flow/services/integration/open_shift_snapshot_projector.dart';

const String _operatorA = '11111111-1111-1111-1111-111111111111';
const String _operatorB = '99999999-9999-9999-9999-999999999999';
const String _locationA = '22222222-2222-2222-2222-222222222222';
const String _locationB = '88888888-8888-8888-8888-888888888888';
const String _profileA = '33333333-3333-3333-3333-333333333333';
const String _profileB = '77777777-7777-7777-7777-777777777777';

void main() {
  group('OpenShiftSnapshotProjector', () {
    test(
      'single canonical write produces one service-period snapshot',
      () async {
        final writer = _InMemorySnapshotWriter();
        final projector = _projector(writer);

        final result = await projector.projectFacts(
          operatorId: _operatorA,
          locationId: _locationA,
          facts: <OpenShiftCanonicalFact>[
            _posFact(id: 'check-1', hour: 18, covers: 4, sales: 168),
          ],
        );

        expect(result.isProjected, isTrue);
        expect(result.businessDate, '2026-05-06');
        expect(result.servicePeriodSnapshotsUpserted, 1);
        expect(writer.rows, hasLength(2));

        final dinner = writer.byScopeAndKey('service_period', 'dinner');
        expect(dinner, isNotNull);
        expect(dinner!.businessTimingProfileId, _profileA);
        expect(dinner.businessTimingProfileVersionId, _profileA);
        expect(dinner.servicePeriodKey, 'dinner');
        expect(dinner.servicePeriodLabel, 'Dinner');
        expect(dinner.currentCovers, 4);
        expect(dinner.currentPpa, closeTo(42, 0.001));
      },
    );

    test('many writes in one service period upsert one row', () async {
      final writer = _InMemorySnapshotWriter();
      final projector = _projector(writer);

      final result = await projector.projectFacts(
        operatorId: _operatorA,
        locationId: _locationA,
        facts: <OpenShiftCanonicalFact>[
          _posFact(id: 'check-1', hour: 18, covers: 4, sales: 160),
          _posFact(id: 'check-2', hour: 19, covers: 2, sales: 90),
          _laborFact(
            id: 'punch-1',
            hour: 17,
            endedHour: 21,
            roleName: 'server',
          ),
        ],
      );

      expect(result.servicePeriodSnapshotsUpserted, 1);
      final dinner = writer.byScopeAndKey('service_period', 'dinner')!;
      expect(dinner.currentCovers, 6);
      expect(dinner.scheduledFohHours, 4);
      expect(dinner.currentCplh, closeTo(1.5, 0.001));
      expect(dinner.currentSplh, 0);
      expect(
        writer.rows.where((row) => row.servicePeriodKey == 'dinner'),
        hasLength(1),
      );
    });

    test('live rates use FOH and BOH denominators separately', () async {
      final writer = _InMemorySnapshotWriter();
      final projector = _projector(writer);

      await projector.projectFacts(
        operatorId: _operatorA,
        locationId: _locationA,
        facts: <OpenShiftCanonicalFact>[
          _posFact(id: 'check-1', hour: 18, covers: 12, sales: 600),
          _laborFact(
            id: 'server-punch',
            hour: 17,
            endedHour: 21,
            roleName: 'server',
          ),
          _laborFact(
            id: 'cook-punch',
            hour: 17,
            endedHour: 21,
            roleName: 'cook',
          ),
        ],
      );

      final dinner = writer.byScopeAndKey('service_period', 'dinner')!;
      expect(dinner.scheduledFohHours, 4);
      expect(dinner.scheduledBohHours, 4);
      expect(dinner.currentCplh, closeTo(3, 0.001));
      expect(dinner.currentSplh, closeTo(150, 0.001));
    });

    test('business-date rollover honors minute precision', () async {
      final writer = _InMemorySnapshotWriter();
      final projector = OpenShiftSnapshotProjector(
        timingSource: _FakeTimingSource.withProfile(
          businessDayStartLocalTime: '04:30',
        ),
        snapshotWriter: writer,
      );

      final result = await projector.projectFacts(
        operatorId: _operatorA,
        locationId: _locationA,
        facts: <OpenShiftCanonicalFact>[
          _posFact(
            id: 'late-check',
            hour: 4,
            minute: 15,
            covers: 2,
            sales: 80,
            businessDate: null,
          ),
        ],
      );

      expect(result.isProjected, isTrue);
      expect(result.businessDate, '2026-05-05');
      expect(
        writer.byScopeAndKey('service_period', 'late_night')!.businessDate,
        '2026-05-05',
      );
    });

    test('service-period rollover creates a second row', () async {
      final writer = _InMemorySnapshotWriter();
      final projector = _projector(writer);

      final result = await projector.projectFacts(
        operatorId: _operatorA,
        locationId: _locationA,
        facts: <OpenShiftCanonicalFact>[
          _posFact(id: 'lunch-check', hour: 12, covers: 3, sales: 75),
          _posFact(id: 'dinner-check', hour: 18, covers: 5, sales: 210),
        ],
      );

      expect(result.servicePeriodSnapshotsUpserted, 2);
      expect(writer.byScopeAndKey('service_period', 'lunch'), isNotNull);
      expect(writer.byScopeAndKey('service_period', 'dinner'), isNotNull);
    });

    test('Whole Day row rolls up from period rows', () async {
      final writer = _InMemorySnapshotWriter();
      final projector = _projector(writer);

      await projector.projectFacts(
        operatorId: _operatorA,
        locationId: _locationA,
        facts: <OpenShiftCanonicalFact>[
          _posFact(id: 'lunch-check', hour: 12, covers: 3, sales: 75),
          _reservationFact(id: 'res-1', hour: 18, partySize: 8),
          _posFact(id: 'dinner-check', hour: 18, covers: 5, sales: 210),
        ],
      );

      final wholeDay = writer.byScopeAndKey('whole_day', 'whole_day')!;
      expect(wholeDay.currentCovers, 8);
      expect(wholeDay.forecastCovers, 11);
      expect(wholeDay.currentPpa, closeTo(35.625, 0.001));
      expect(wholeDay.provenance['rollup'], 'service_period_buckets');
      expect(
        wholeDay.provenance['service_period_keys'],
        containsAll(<String>['lunch', 'dinner']),
      );
    });

    test('canonical replay does not duplicate rows or metrics', () async {
      final writer = _InMemorySnapshotWriter();
      final projector = _projector(writer);
      final facts = <OpenShiftCanonicalFact>[
        _posFact(id: 'check-1', hour: 18, covers: 4, sales: 160),
        _posFact(id: 'check-1', hour: 18, covers: 4, sales: 160),
      ];

      await projector.projectFacts(
        operatorId: _operatorA,
        locationId: _locationA,
        facts: facts,
      );
      await projector.projectFacts(
        operatorId: _operatorA,
        locationId: _locationA,
        facts: facts,
      );

      expect(writer.rows, hasLength(2));
      final dinner = writer.byScopeAndKey('service_period', 'dinner')!;
      expect(dinner.currentCovers, 4);
      expect(dinner.currentPpa, closeTo(40, 0.001));
      expect(writer.upsertCount, 4);
    });

    test('cross-tenant facts are ignored and never written', () async {
      final writer = _InMemorySnapshotWriter();
      final projector = _projector(writer);

      final result = await projector.projectFacts(
        operatorId: _operatorA,
        locationId: _locationA,
        facts: <OpenShiftCanonicalFact>[
          _posFact(id: 'check-a', hour: 18, covers: 4, sales: 160),
          _posFact(
            id: 'check-b',
            hour: 18,
            covers: 10,
            sales: 500,
            operatorId: _operatorB,
            locationId: _locationB,
          ),
        ],
      );

      expect(result.ignoredFacts, 1);
      expect(writer.rows.every((row) => row.operatorId == _operatorA), isTrue);
      expect(writer.rows.every((row) => row.locationId == _locationA), isTrue);
      expect(
        writer.byScopeAndKey('service_period', 'dinner')!.currentCovers,
        4,
      );
    });

    test('missing timing profile produces honest unavailable result', () async {
      final writer = _InMemorySnapshotWriter();
      final projector = OpenShiftSnapshotProjector(
        timingSource: _FakeTimingSource.withoutProfile(),
        snapshotWriter: writer,
      );

      final result = await projector.projectFacts(
        operatorId: _operatorA,
        locationId: _locationA,
        facts: <OpenShiftCanonicalFact>[
          _posFact(id: 'check-1', hour: 18, covers: 4, sales: 168),
        ],
      );

      expect(result.isUnavailable, isTrue);
      expect(result.reason, contains('No active business timing profile'));
      expect(writer.rows, isEmpty);
    });

    test('canonical dictionaries are accepted as projector input', () async {
      final writer = _InMemorySnapshotWriter();
      final projector = _projector(writer);

      final result = await projector.projectFactMaps(
        operatorId: _operatorA,
        locationId: _locationA,
        facts: <Map<String, Object?>>[
          <String, Object?>{
            'fact_type': 'cover_fact',
            'operator_id': _operatorA,
            'location_id': _locationA,
            'vendor_id': 'toast',
            'vendor_entity_id': 'check-map',
            'closed_at': DateTime.utc(2026, 5, 6, 18),
            'business_date': '2026-05-06',
            'covers': 2,
            'actual_sales': 84,
          },
        ],
      );

      expect(result.isProjected, isTrue);
      expect(
        writer.byScopeAndKey('service_period', 'dinner')!.currentCovers,
        2,
      );
    });
  });
}

OpenShiftSnapshotProjector _projector(_InMemorySnapshotWriter writer) {
  return OpenShiftSnapshotProjector(
    timingSource: _FakeTimingSource.withProfile(),
    snapshotWriter: writer,
  );
}

OpenShiftCanonicalFact _posFact({
  required String id,
  required int hour,
  required int covers,
  required double sales,
  int minute = 0,
  String? businessDate = '2026-05-06',
  String operatorId = _operatorA,
  String locationId = _locationA,
}) {
  return OpenShiftCanonicalFact(
    kind: OpenShiftCanonicalFactKind.pos,
    operatorId: operatorId,
    locationId: locationId,
    sourceSystem: 'toast',
    sourceEntityId: id,
    occurredAt: DateTime.utc(2026, 5, 6, hour, minute),
    businessDate: businessDate,
    covers: covers,
    sales: sales,
  );
}

OpenShiftCanonicalFact _reservationFact({
  required String id,
  required int hour,
  required int partySize,
}) {
  return OpenShiftCanonicalFact(
    kind: OpenShiftCanonicalFactKind.reservation,
    operatorId: _operatorA,
    locationId: _locationA,
    sourceSystem: 'opentable',
    sourceEntityId: id,
    occurredAt: DateTime.utc(2026, 5, 6, hour),
    businessDate: '2026-05-06',
    partySize: partySize,
  );
}

OpenShiftCanonicalFact _laborFact({
  required String id,
  required int hour,
  required int endedHour,
  required String roleName,
}) {
  return OpenShiftCanonicalFact(
    kind: OpenShiftCanonicalFactKind.labor,
    operatorId: _operatorA,
    locationId: _locationA,
    sourceSystem: 'humanity',
    sourceEntityId: id,
    occurredAt: DateTime.utc(2026, 5, 6, hour),
    endedAt: DateTime.utc(2026, 5, 6, endedHour),
    businessDate: '2026-05-06',
    roleName: roleName,
  );
}

class _FakeTimingSource implements OpenShiftTimingProfileSource {
  _FakeTimingSource.withProfile({this.businessDayStartLocalTime = '04:00'})
    : hasProfile = true;
  _FakeTimingSource.withoutProfile()
    : hasProfile = false,
      businessDayStartLocalTime = '04:00';

  final bool hasProfile;
  final String businessDayStartLocalTime;

  @override
  Future<ResolvedOpenShiftTimingProfile?> resolveForBusinessDate({
    required String operatorId,
    required String locationId,
    required String businessDate,
    String? userId,
  }) async {
    if (!hasProfile) return null;
    final isTenantB = operatorId == _operatorB;
    return ResolvedOpenShiftTimingProfile(
      businessTimingProfileId: isTenantB ? _profileB : _profileA,
      businessTimezone: 'UTC',
      businessDayStartLocalTime: businessDayStartLocalTime,
      weekStartDay: DateTime.monday,
      servicePeriods: const <ServicePeriodDefinition>[
        ServicePeriodDefinition(
          id: 'lunch',
          label: 'Lunch',
          shortLabel: 'L',
          sortOrder: 1,
          startLocalTime: '11:00',
          endLocalTime: '15:00',
          rollsPastMidnight: false,
          applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
        ),
        ServicePeriodDefinition(
          id: 'dinner',
          label: 'Dinner',
          shortLabel: 'D',
          sortOrder: 2,
          startLocalTime: '17:00',
          endLocalTime: '22:00',
          rollsPastMidnight: false,
          applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
        ),
        ServicePeriodDefinition(
          id: 'late_night',
          label: 'Late Night',
          shortLabel: 'LN',
          sortOrder: 3,
          startLocalTime: '22:00',
          endLocalTime: '04:30',
          rollsPastMidnight: true,
          applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
        ),
      ],
    );
  }
}

class _InMemorySnapshotWriter implements OpenShiftSnapshotWriter {
  final Map<String, OpenShiftSnapshotProjectionWrite> _rows =
      <String, OpenShiftSnapshotProjectionWrite>{};
  int upsertCount = 0;

  List<OpenShiftSnapshotProjectionWrite> get rows => _rows.values.toList();

  OpenShiftSnapshotProjectionWrite? byScopeAndKey(
    String scope,
    String servicePeriodKey,
  ) {
    for (final row in _rows.values) {
      if (row.snapshotScope == scope &&
          row.servicePeriodKey == servicePeriodKey) {
        return row;
      }
    }
    return null;
  }

  @override
  Future<void> upsert(OpenShiftSnapshotProjectionWrite snapshot) async {
    upsertCount += 1;
    _rows['${snapshot.operatorId}|${snapshot.locationId}|'
            '${snapshot.businessDate}|${snapshot.snapshotScope}|'
            '${snapshot.servicePeriodKey}'] =
        snapshot;
  }
}
