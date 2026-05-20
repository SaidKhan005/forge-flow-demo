// Shared fixtures and helpers for the admin_operator_location_*
// widget-test files. Extracted in Bucket 5h of the 2026-05-20 test-suite
// tightening audit when `test/admin_operator_location_screen_test.dart`
// (~2,131 lines, 31 testWidgets) was split into three focused files:
// list-and-search (master/detail navigation), lifecycle (onboarding,
// suspend/reactivate, add/edit/remove location, timezone dialogs), and
// admin-and-hierarchy (AI plan, hierarchy create/move/lifecycle, auth
// gate). The helpers below were verbatim file-private declarations
// inside the original monolith's `void main()`; they are promoted to
// library-public so each split file can import a single source of
// truth instead of duplicating ~130 LOC.
//
// Bounded-pump helpers (`pumpEventually`, `pumpUntil`) deliberately
// are NOT redeclared here. The split files import them from the
// existing shared helper at `test/_test_helpers/widget_pump_helpers.dart`
// (PR #1111, Bucket 4c) so the migration to bounded pumps stays
// single-source.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/models/operator_location_admin_models.dart';
import 'package:forge_and_flow/admin/services/admin_business_timing_resolution_gateway.dart';
import 'package:forge_and_flow/admin/services/admin_business_timing_resolution_projection.dart';
import 'package:forge_and_flow/admin/services/operator_location_admin_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

import '_test_helpers/widget_pump_helpers.dart';

/// Standard MaterialApp wrapper used by the admin operator/location
/// widget tests. Mirrors the in-app `AppTheme.themeData` so layout +
/// theming behave the same as production.
Widget wrap(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: AppTheme.themeData,
  home: child,
);

/// Builds a minimal `OperatorAdminBundle` with one location. All fields
/// have sensible defaults so individual tests only override what they
/// need (operator id, primary location id, business name, suspended).
OperatorAdminBundle seedBundle({
  String operatorId = 'op-seed-1',
  String primaryLocationId = 'loc-seed-1',
  String businessName = 'Seed Cafe',
  bool suspended = false,
}) {
  final created = DateTime.utc(2026, 1, 1);
  return OperatorAdminBundle(
    operator: OperatorAdminRecord(
      operatorId: operatorId,
      businessName: businessName,
      ownerEmail: 'owner@seed.test',
      subscriptionTier: 'launch',
      preferredCurrency: 'CAD',
      primaryLocationId: primaryLocationId,
      suspendedAt: suspended ? DateTime.utc(2026, 4, 1) : null,
      createdAt: created,
      updatedAt: created,
    ),
    locations: <LocationAdminRecord>[
      LocationAdminRecord(
        locationId: primaryLocationId,
        operatorId: operatorId,
        parentOrgUnitId: 'org-root',
        name: 'HQ',
        address: '',
        timezone: 'America/Toronto',
        businessDayRolloverHour: 4,
        createdAt: created,
        updatedAt: created,
      ),
    ],
  );
}

/// Fix #4 / S4 (G42): seed the READ-ONLY admin business-timing
/// resolution gateway with a real canonical-shaped candidate chain
/// so the per-location Timing dialog renders the REAL resolved
/// `EffectiveBusinessTimingProfile` (replacing the deleted synthetic
/// `_AdminTimingResolution.forScope` fabrication).
InMemoryAdminBusinessTimingResolutionGateway seedTimingGateway({
  required String operatorId,
  required String locationId,
  String timezone = 'America/Toronto',
  String dayStart = '04:00',
  String weekStart = 'monday',
  List<AdminResolutionServicePeriod>? periods,
}) {
  final gw = InMemoryAdminBusinessTimingResolutionGateway();
  gw.put(
    operatorId,
    locationId,
    AdminBusinessTimingResolution(
      operatorId: operatorId,
      locationId: locationId,
      businessDate: '2026-05-01',
      ianaTimezone: timezone,
      candidates: <AdminResolutionCandidate>[
        AdminResolutionCandidate(
          profileId: '$operatorId-default',
          scopeType: 'operator',
          scopeId: operatorId,
          scopeLabel: 'Operator default',
          scopeDepthRank: 0,
          ianaTimezone: timezone,
          effectiveAtBusinessDate: '2026-05-01',
          weekStartDay: weekStart,
          businessDayStartLocal: dayStart,
          servicePeriods:
              periods ??
              <AdminResolutionServicePeriod>[
                const AdminResolutionServicePeriod(
                  key: 'lunch',
                  label: 'Lunch',
                  startLocal: '11:00',
                  endLocal: '16:00',
                  rollsPastMidnight: false,
                  shortLabel: 'L',
                  sortOrder: 1,
                  applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
                ),
                const AdminResolutionServicePeriod(
                  key: 'dinner',
                  label: 'Dinner',
                  startLocal: '16:00',
                  endLocal: '22:00',
                  rollsPastMidnight: false,
                  shortLabel: 'D',
                  sortOrder: 2,
                  applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
                ),
              ],
        ),
      ],
    ),
  );
  return gw;
}

/// Opens the admin timezone-picker for `fieldKey`, searches for the
/// given IANA `timezone`, and taps the matching option.
Future<void> chooseTimezone(
  WidgetTester tester,
  Key fieldKey,
  String timezone,
) async {
  final field = find.byKey(fieldKey);
  await tester.ensureVisible(field);
  await pumpEventually(tester);
  await tester.tap(field);
  await pumpEventually(tester);

  await tester.enterText(
    find.byKey(const Key('admin_timezone_search_field')),
    timezone,
  );
  await pumpEventually(tester);

  final option = find.byKey(Key('admin_timezone_option_text_$timezone'));
  await tester.tap(option);
  await pumpEventually(tester);
}

/// Taps the appropriate scope option in the admin hierarchy scope
/// prompt. No-op if the prompt isn't currently mounted.
Future<void> chooseScopePrompt(
  WidgetTester tester, {
  required String operatorId,
  required String scopeType,
  String? orgUnitId,
  String? locationId,
}) async {
  if (find
      .byKey(const Key('admin_hierarchy_scope_prompt'))
      .evaluate()
      .isEmpty) {
    return;
  }
  final cacheKey =
      '$operatorId|$scopeType|${orgUnitId ?? ''}|${locationId ?? ''}';
  final option = find.byKey(Key('admin_hierarchy_scope_option_$cacheKey'));
  await tester.ensureVisible(option);
  await pumpEventually(tester);
  await tester.tap(option);
  await pumpEventually(tester);
}

/// Test-double gateway that throws an `email_in_use` 409 with rich
/// conflict details on `patchOperator`. Used by the Account-profile
/// conflict-details widget test (lifecycle bucket). Promoted from
/// file-private to library-public during the Bucket 5h split.
class EmailConflictOperatorGateway extends InMemoryOperatorLocationAdminGateway {
  EmailConflictOperatorGateway({required super.seed});

  @override
  Future<OperatorAdminRecord> patchOperator(
    OperatorPatchCommand command,
  ) async {
    throw const OperatorLocationAdminGatewayError(
      statusCode: 409,
      errorCode: 'email_in_use',
      message: 'Contact email is already used by another account.',
      details: <String, Object?>{
        'email_conflicts': <Object?>[
          <String, Object?>{
            'email': 'taken@business.test',
            'source': 'business_contact',
            'operator_id': 'op-existing-business',
            'business_name': 'Conflict Bistro',
            'location_id': 'loc-existing-business',
            'location_name': 'Downtown',
            'status': 'active',
          },
        ],
      },
    );
  }
}
