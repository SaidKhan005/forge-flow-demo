import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/screens/benchmarks_screen.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_benchmarks_gateway.dart';
import 'package:forge_and_flow/operator_web/services/web_team_hierarchy_gateway.dart';
import 'package:forge_and_flow/operator_web/widgets/web_app_shell.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import 'package:forge_and_flow/services/baseline/benchmark_override_resolver.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  const session = OperatorWebSession(
    uid: 'user-a',
    email: 'alex@example.test',
    displayName: 'Alex',
    operatorId: 'op-a',
    businessName: 'Brio Restaurants',
    primaryLocationId: 'loc-a',
    primaryLocationName: 'Main Street',
    roles: <String>['operator_owner'],
    mfaEnrolled: true,
  );

  const selectedLocation = OperatorWebManagementScopeOption(
    key: 'location:loc-a',
    kind: OperatorWebManagementScopeKind.location,
    id: 'loc-a',
    label: 'Main Street',
    helper: 'Location',
    parentOrgUnitId: 'ou-near',
  );

  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: child),
  );

  Future<void> sizeViewport(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  group('BenchmarksScreen', () {
    testWidgets('shows HP11 effective and inherited source visibility',
        (tester) async {
      await sizeViewport(tester);
      final benchmarks = _FakeBenchmarksGateway()
        ..rows.addAll(<BenchmarkOverrideCandidate>[
          _candidate(
            overrideId: 'operator-wide',
            scopeType: BenchmarkOverrideScopeType.operatorWide,
            value: 16,
            sourceLabel: 'All locations',
          ),
          _candidate(
            overrideId: 'ou-near',
            scopeType: BenchmarkOverrideScopeType.orgUnit,
            orgUnitId: 'ou-near',
            value: 12,
            sourceLabel: 'Downtown',
          ),
        ]);

      await tester.pumpWidget(
        wrap(
          BenchmarksScreen(
            session: session,
            selectedScope: selectedLocation,
            hierarchyGateway: _FakeHierarchyGateway(),
            benchmarksGateway: benchmarks,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('operator_web_benchmarks_screen')),
        findsOneWidget,
      );
      expect(find.text('Benchmarks'), findsOneWidget);
      expect(
        find.byKey(const Key('operator_web_benchmarks_effective_summary')),
        findsOneWidget,
      );
      expect(find.textContaining('Selected scope: Main Street'), findsOneWidget);
      expect(find.text('Effective value: 12.00'), findsOneWidget);
      expect(find.text('Inherited source: Downtown'), findsOneWidget);
      expect(
        find.byKey(const Key('inheritance_tree_annotation_loc-a')),
        findsOneWidget,
      );
    });

    testWidgets('saving a location override updates the selected scope',
        (tester) async {
      await sizeViewport(tester);
      final benchmarks = _FakeBenchmarksGateway()
        ..rows.add(
          _candidate(
            overrideId: 'ou-near',
            scopeType: BenchmarkOverrideScopeType.orgUnit,
            orgUnitId: 'ou-near',
            value: 12,
            sourceLabel: 'Downtown',
          ),
        );

      await tester.pumpWidget(
        wrap(
          BenchmarksScreen(
            session: session,
            selectedScope: selectedLocation,
            hierarchyGateway: _FakeHierarchyGateway(),
            benchmarksGateway: benchmarks,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('operator_web_benchmarks_value_field')),
        '9.5',
      );
      await tester.tap(find.byKey(const Key('operator_web_benchmarks_save')));
      await tester.pumpAndSettle();

      expect(benchmarks.setCalls, 1);
      expect(benchmarks.lastScopeType, BenchmarkOverrideScopeType.location);
      expect(benchmarks.lastTargetLocationId, 'loc-a');
      expect(find.text('Effective value: 9.50'), findsOneWidget);
      expect(find.text('Inherited source: Location'), findsOneWidget);
    });
  });
}

class _FakeHierarchyGateway implements WebTeamHierarchyGateway {
  @override
  Future<TeamOrgHierarchyListed> listOrgHierarchy(
    TeamOrgHierarchyListCommand command,
  ) async {
    return const TeamOrgHierarchyListed(
      orgUnits: <TeamOrgUnitEntry>[
        TeamOrgUnitEntry(
          orgUnitId: 'ou-root',
          parentOrgUnitId: null,
          unitType: 'region',
          path: 'ou_root',
          label: 'East',
        ),
        TeamOrgUnitEntry(
          orgUnitId: 'ou-near',
          parentOrgUnitId: 'ou-root',
          unitType: 'district',
          path: 'ou_root.ou_near',
          label: 'Downtown',
        ),
      ],
      locations: <TeamOrgLocationEntry>[
        TeamOrgLocationEntry(
          locationId: 'loc-a',
          parentOrgUnitId: 'ou-near',
          orgUnitPath: 'ou_root.ou_near',
          label: 'Main Street',
        ),
      ],
    );
  }

  @override
  Future<TeamOrgUnitCreated> createOrgUnit(
    TeamOrgUnitCreateCommand command, {
    required String idempotencyKey,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<TeamLocationOrgUnitMoved> moveLocationToOrgUnit(
    TeamLocationOrgUnitMoveCommand command, {
    required String idempotencyKey,
  }) {
    throw UnimplementedError();
  }
}

class _FakeBenchmarksGateway implements OperatorWebBenchmarksGateway {
  final List<BenchmarkOverrideCandidate> rows = <BenchmarkOverrideCandidate>[];
  int setCalls = 0;
  BenchmarkOverrideScopeType? lastScopeType;
  String? lastTargetLocationId;

  @override
  Future<List<BenchmarkOverrideCandidate>> listOverrides({
    required String operatorId,
    required String locationId,
    required String actorUserId,
  }) async {
    return rows.toList(growable: false);
  }

  @override
  Future<BenchmarkOverrideCandidate> setOverride({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required BenchmarkOverrideScopeType scopeType,
    required String? orgUnitId,
    required String? targetLocationId,
    required String metricKey,
    required double overrideValue,
  }) async {
    setCalls += 1;
    lastScopeType = scopeType;
    lastTargetLocationId = targetLocationId;
    rows.removeWhere(
      (row) =>
          row.metricKey == metricKey &&
          row.scopeType == scopeType &&
          row.orgUnitId == orgUnitId &&
          row.locationId == targetLocationId,
    );
    final row = _candidate(
      overrideId: 'loc-direct',
      scopeType: scopeType,
      orgUnitId: orgUnitId,
      locationId: targetLocationId,
      value: overrideValue,
      sourceLabel: 'Location',
    );
    rows.add(row);
    return row;
  }

  @override
  Future<BenchmarkOverrideCandidate?> clearOverride({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String overrideId,
  }) async {
    rows.removeWhere((row) => row.overrideId == overrideId);
    return null;
  }
}

BenchmarkOverrideCandidate _candidate({
  required String overrideId,
  required BenchmarkOverrideScopeType scopeType,
  String? orgUnitId,
  String? locationId,
  required double value,
  String sourceLabel = 'Org unit',
}) {
  return BenchmarkOverrideCandidate(
    overrideId: overrideId,
    operatorId: 'op-a',
    scopeType: scopeType,
    orgUnitId: orgUnitId,
    locationId: locationId,
    metricKey: 'target_cplh',
    value: value,
    effectiveFrom: DateTime.utc(2026, 5, 13, 12),
    effectiveUntil: null,
    createdBy: 'user-a',
    sourceLabel: sourceLabel,
  );
}
