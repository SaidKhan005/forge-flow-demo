import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/baseline/benchmark_override_resolver.dart';

void main() {
  const resolver = BenchmarkOverrideResolver();
  const operatorId = 'op-a';
  final t0 = DateTime.utc(2026, 5, 13, 10);

  BenchmarkOverrideCandidate row({
    required String id,
    required BenchmarkOverrideScopeType scopeType,
    String? orgUnitId,
    String? locationId,
    double value = 10,
    String metricKey = 'target_cplh',
    DateTime? effectiveFrom,
    DateTime? effectiveUntil,
  }) {
    return BenchmarkOverrideCandidate(
      overrideId: id,
      operatorId: operatorId,
      scopeType: scopeType,
      orgUnitId: orgUnitId,
      locationId: locationId,
      metricKey: metricKey,
      value: value,
      effectiveFrom: effectiveFrom ?? t0,
      effectiveUntil: effectiveUntil,
      createdBy: 'user-a',
      sourceLabel: id,
    );
  }

  group('BenchmarkOverrideResolver', () {
    test('location override beats org-unit and operator-wide values', () {
      final resolved = resolver.resolve(
        metricKey: 'target_cplh',
        operatorId: operatorId,
        ancestorOrgUnitIdsNearestFirst: const <String>['ou-near', 'ou-root'],
        locationId: 'loc-a',
        candidates: <BenchmarkOverrideCandidate>[
          row(
            id: 'operator-wide',
            scopeType: BenchmarkOverrideScopeType.operatorWide,
            value: 15,
          ),
          row(
            id: 'ou-near',
            scopeType: BenchmarkOverrideScopeType.orgUnit,
            orgUnitId: 'ou-near',
            value: 12,
          ),
          row(
            id: 'loc-a',
            scopeType: BenchmarkOverrideScopeType.location,
            locationId: 'loc-a',
            value: 9,
          ),
        ],
        fallbackValue: 20,
      );

      expect(resolved.overrideId, 'loc-a');
      expect(resolved.value, 9);
      expect(resolved.sourceScopeType, BenchmarkOverrideScopeType.location);
    });

    test('nearest configured org-unit wins over farther ancestor', () {
      final resolved = resolver.resolve(
        metricKey: 'target_splh',
        operatorId: operatorId,
        ancestorOrgUnitIdsNearestFirst: const <String>['ou-near', 'ou-root'],
        locationId: 'loc-a',
        candidates: <BenchmarkOverrideCandidate>[
          row(
            id: 'ou-root',
            scopeType: BenchmarkOverrideScopeType.orgUnit,
            orgUnitId: 'ou-root',
            metricKey: 'target_splh',
            value: 18,
          ),
          row(
            id: 'ou-near',
            scopeType: BenchmarkOverrideScopeType.orgUnit,
            orgUnitId: 'ou-near',
            metricKey: 'target_splh',
            value: 14,
          ),
        ],
        fallbackValue: 21,
      );

      expect(resolved.overrideId, 'ou-near');
      expect(resolved.value, 14);
    });

    test('operator-wide is used when no lower scope is configured', () {
      final resolved = resolver.resolve(
        metricKey: 'target_ppa',
        operatorId: operatorId,
        ancestorOrgUnitIdsNearestFirst: const <String>['ou-near'],
        locationId: 'loc-a',
        candidates: <BenchmarkOverrideCandidate>[
          row(
            id: 'operator-wide',
            scopeType: BenchmarkOverrideScopeType.operatorWide,
            metricKey: 'target_ppa',
            value: 4.5,
          ),
        ],
        fallbackValue: 5,
      );

      expect(resolved.overrideId, 'operator-wide');
      expect(resolved.value, 4.5);
      expect(resolved.sourceScopeType, BenchmarkOverrideScopeType.operatorWide);
    });

    test('closed and wrong-metric rows are ignored before fallback', () {
      final resolved = resolver.resolve(
        metricKey: 'target_cplh',
        operatorId: operatorId,
        ancestorOrgUnitIdsNearestFirst: const <String>['ou-near'],
        locationId: 'loc-a',
        candidates: <BenchmarkOverrideCandidate>[
          row(
            id: 'closed',
            scopeType: BenchmarkOverrideScopeType.location,
            locationId: 'loc-a',
            value: 1,
            effectiveUntil: DateTime.utc(2026, 5, 13, 11),
          ),
          row(
            id: 'wrong-metric',
            scopeType: BenchmarkOverrideScopeType.location,
            locationId: 'loc-a',
            metricKey: 'target_ppa',
            value: 2,
          ),
        ],
        fallbackValue: 17,
      );

      expect(resolved.overrideId, isNull);
      expect(resolved.value, 17);
      expect(resolved.sourceScopeType, BenchmarkOverrideScopeType.fallback);
      expect(resolved.sourceLabel, 'Target cycle');
    });
  });
}
