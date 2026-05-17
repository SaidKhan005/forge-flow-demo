// Phase 8 spine-bridge Lane .B — Data Accuracy screen widget tests.
//
// Covers walkthrough acceptance items A (default render), I (UX
// writing audit — no engineering jargon leaks into the screen), and
// J (walkthrough numbered click-path matches the rendered widgets).
//
// Conditional-card visibility (walk-in surfaces only when POS lacks
// covers AND a reservation system is connected; historical seed
// surfaces only for non-covers-exposing POS) is exercised here too
// since both cuts run off the screen-level state machine the
// walkthrough exercises.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/models/data_accuracy_service_period_setting.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_settings.dart';
import 'package:forge_and_flow/integrations/ui/vendor_connections/in_memory_vendor_connections_gateway.dart';
import 'package:forge_and_flow/integrations/ui/vendor_connections/vendor_connections_models.dart';
import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/domain/models/wage_role_row_record.dart';
import 'package:forge_and_flow/operator_web/screens/data_accuracy_screen.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_data_accuracy_gateway.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_tier_email_gateway.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_wage_authority_gateway.dart';
import 'package:forge_and_flow/operator_web/services/web_vendor_applicability_gateway.dart';
import 'package:forge_and_flow/operator_web/widgets/keyed_service_period_accuracy_card.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  // ─── Test fixtures ───────────────────────────────────────────────

  const ownerSession = OperatorWebSession(
    uid: 'brio-owner',
    email: 'owner@brio-restaurants.com',
    displayName: 'Sam Patel',
    operatorId: 'brio-operator',
    businessName: 'Brio Restaurants',
    primaryLocationId: 'brio-chicago-loop',
    primaryLocationName: 'Brio - Chicago Loop',
    roles: <String>['operator_owner'],
  );

  const locationManagerSession = OperatorWebSession(
    uid: 'brio-loc-manager',
    email: 'loc.manager@brio-restaurants.com',
    displayName: 'Pat Lee',
    operatorId: 'brio-operator',
    businessName: 'Brio Restaurants',
    primaryLocationId: 'brio-chicago-loop',
    primaryLocationName: 'Brio - Chicago Loop',
    roles: <String>['location_manager'],
  );

  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: child),
  );

  Future<void> sizeViewport(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  VendorConnectionsBundle bundleFor({
    required OperatorWebSession session,
    VendorConnectionRow? pos,
    VendorConnectionRow? labor,
    VendorConnectionRow? reservation,
  }) {
    return VendorConnectionsBundle(
      operatorId: session.operatorId,
      locationId: session.primaryLocationId ?? '',
      locationName: session.primaryLocationName,
      posConnection: pos,
      laborConnection: labor,
      reservationConnection: reservation,
      demoFlags: const <VendorCategory, bool>{},
    );
  }

  InMemoryVendorConnectionsGateway gatewayWithBundle(
    OperatorWebSession session,
    VendorConnectionsBundle bundle,
  ) {
    return InMemoryVendorConnectionsGateway(
      seed: <String, VendorConnectionsBundle>{
        '${session.operatorId}/${session.primaryLocationId}': bundle,
      },
    );
  }

  VendorConnectionRow row({
    required String vendorId,
    required String displayName,
    required VendorCategory category,
  }) => VendorConnectionRow(
    connectionId: '$vendorId-conn',
    vendorId: vendorId,
    displayName: displayName,
    category: category,
    status: VendorConnectionStatus.connected,
    metadata: const <String, Object?>{},
  );

  // ─── Acceptance item A — default render ──────────────────────────

  group('DataAccuracyScreen default render', () {
    testWidgets(
      'screen renders 5 default cards (no walk-in, no historical seed) for '
      'Lightspeed POS + QBT + Libro fixture',
      (tester) async {
        await sizeViewport(tester, const Size(1280, 800));

        await tester.pumpWidget(
          wrap(
            DataAccuracyScreen(
              session: ownerSession,
              locationId: ownerSession.primaryLocationId ?? '',
              gateway: InMemoryVendorConnectionsGateway(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('operator_web_data_accuracy_screen')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('data_accuracy_wage_source_card')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('data_accuracy_covers_source_card')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('data_accuracy_polling_tier_status_card')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('data_accuracy_explainer_card')),
          findsOneWidget,
        );

        // Conditional cards stay off in the default fixture.
        expect(
          find.byKey(const Key('data_accuracy_walk_in_handling_card')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('data_accuracy_covers_historical_seed_card')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('data_accuracy_covers_manual_entry_card')),
          findsNothing,
        );
      },
    );

    testWidgets('subtitle names primary location', (tester) async {
      await sizeViewport(tester, const Size(1280, 800));

      await tester.pumpWidget(
        wrap(
          DataAccuracyScreen(
            session: ownerSession,
            locationId: ownerSession.primaryLocationId ?? '',
            gateway: InMemoryVendorConnectionsGateway(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final subtitle = tester.widget<Text>(
        find.byKey(const Key('operator_web_data_accuracy_subtitle')),
      );
      expect(subtitle.data, isNotNull);
      expect(
        subtitle.data!.contains('Brio - Chicago Loop'),
        isTrue,
        reason: 'Subtitle should name the primary location explicitly.',
      );
    });
  });

  group('DataAccuracyScreen permission gate', () {
    testWidgets('forbidden surface for location_manager session', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 800));

      await tester.pumpWidget(
        wrap(
          DataAccuracyScreen(
            session: locationManagerSession,
            locationId: locationManagerSession.primaryLocationId ?? '',
            gateway: InMemoryVendorConnectionsGateway(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('operator_web_data_accuracy_forbidden')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_data_accuracy_screen')),
        findsNothing,
      );
    });
  });

  group('DataAccuracyScreen conditional cards', () {
    testWidgets(
      'walk-in card surfaces only when POS lacks covers AND reservation '
      'system is connected',
      (tester) async {
        await sizeViewport(tester, const Size(1280, 800));

        // Square (covers NOT exposed) + Libro (reservation connected) +
        // QBT (labor connected) — walk-in card SHOULD render.
        final squareGateway = gatewayWithBundle(
          ownerSession,
          bundleFor(
            session: ownerSession,
            pos: row(
              vendorId: 'square',
              displayName: 'Square',
              category: VendorCategory.pos,
            ),
            labor: row(
              vendorId: 'quickbooks_time',
              displayName: 'QuickBooks Time',
              category: VendorCategory.labor,
            ),
            reservation: row(
              vendorId: 'libro',
              displayName: 'Libro',
              category: VendorCategory.reservation,
            ),
          ),
        );

        await tester.pumpWidget(
          wrap(
            DataAccuracyScreen(
              session: ownerSession,
              locationId: ownerSession.primaryLocationId ?? '',
              gateway: squareGateway,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('data_accuracy_walk_in_handling_card')),
          findsOneWidget,
        );

        // Lightspeed (covers exposed) + Libro + QBT — walk-in card
        // should NOT render even with a reservation connected.
        final lightspeedGateway = gatewayWithBundle(
          ownerSession,
          bundleFor(
            session: ownerSession,
            pos: row(
              vendorId: 'lightspeed_lsk',
              displayName: 'Lightspeed Restaurant K-Series',
              category: VendorCategory.pos,
            ),
            labor: row(
              vendorId: 'quickbooks_time',
              displayName: 'QuickBooks Time',
              category: VendorCategory.labor,
            ),
            reservation: row(
              vendorId: 'libro',
              displayName: 'Libro',
              category: VendorCategory.reservation,
            ),
          ),
        );

        await tester.pumpWidget(
          wrap(
            DataAccuracyScreen(
              session: ownerSession,
              locationId: ownerSession.primaryLocationId ?? '',
              gateway: lightspeedGateway,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('data_accuracy_walk_in_handling_card')),
          findsNothing,
        );
      },
    );

    testWidgets('walk-in mode and daily count are saved into settings', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 800));

      final gateway = gatewayWithBundle(
        ownerSession,
        bundleFor(
          session: ownerSession,
          pos: row(
            vendorId: 'square',
            displayName: 'Square',
            category: VendorCategory.pos,
          ),
          labor: row(
            vendorId: 'quickbooks_time',
            displayName: 'QuickBooks Time',
            category: VendorCategory.labor,
          ),
          reservation: row(
            vendorId: 'libro',
            displayName: 'Libro',
            category: VendorCategory.reservation,
          ),
        ),
      );
      final saves = <DataAccuracySettings>[];

      await tester.pumpWidget(
        wrap(
          DataAccuracyScreen(
            session: ownerSession,
            locationId: ownerSession.primaryLocationId ?? '',
            gateway: gateway,
            businessDateIso: '2026-05-06',
            onSaveSettings: saves.add,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final addedRadio = find.byKey(const Key('walk_in_handling_radio_added'));
      await tester.ensureVisible(addedRadio);
      await tester.pumpAndSettle();
      await tester.tap(addedRadio);
      await tester.pumpAndSettle();
      expect(
        saves.last.walkInHandlingMode,
        DataAccuracyWalkInHandlingMode.walkInsAddedToReservations,
      );

      await tester.enterText(
        find.byKey(const Key('walk_in_handling_daily_count_field')),
        '14',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(saves.last.walkInManualEntries['2026-05-06'], 14);
    });

    testWidgets('historical seed card surfaces for non-covers-exposing POS', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 800));

      final squareGateway = gatewayWithBundle(
        ownerSession,
        bundleFor(
          session: ownerSession,
          pos: row(
            vendorId: 'square',
            displayName: 'Square',
            category: VendorCategory.pos,
          ),
        ),
      );

      await tester.pumpWidget(
        wrap(
          DataAccuracyScreen(
            session: ownerSession,
            locationId: ownerSession.primaryLocationId ?? '',
            gateway: squareGateway,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('data_accuracy_covers_historical_seed_card')),
        findsOneWidget,
      );
    });

    testWidgets('switching dinner to manual reveals manual entry sub-card', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1600));

      await tester.pumpWidget(
        wrap(
          DataAccuracyScreen(
            session: ownerSession,
            locationId: ownerSession.primaryLocationId ?? '',
            gateway: InMemoryVendorConnectionsGateway(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const Key('covers_source_chip_dinner_manual')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('covers_source_chip_dinner_manual')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('data_accuracy_covers_manual_entry_card')),
        findsOneWidget,
      );
    });
  });

  group('DataAccuracyScreen polling tier interaction', () {
    testWidgets('request tier change opens the ticket dialog', (tester) async {
      await sizeViewport(tester, const Size(1280, 1600));

      await tester.pumpWidget(
        wrap(
          DataAccuracyScreen(
            session: ownerSession,
            locationId: ownerSession.primaryLocationId ?? '',
            gateway: InMemoryVendorConnectionsGateway(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const Key('polling_tier_request_change_button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('polling_tier_request_change_button')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('polling_tier_change_request_dialog')),
        findsOneWidget,
      );
    });

    // Wave 2 U-FU-tier-email — dialog submit invokes the gateway and
    // renders the success toast. The gateway is the demo
    // in-memory variant so no network traffic happens.
    testWidgets(
        'dialog submit invokes tier-email gateway and shows "emailed" toast',
        (tester) async {
      await sizeViewport(tester, const Size(1280, 1600));
      final gateway = InMemoryOperatorWebTierEmailGateway();

      await tester.pumpWidget(
        wrap(
          DataAccuracyScreen(
            session: ownerSession,
            locationId: ownerSession.primaryLocationId ?? '',
            gateway: InMemoryVendorConnectionsGateway(),
            tierEmailGateway: gateway,
            tierEmailIdempotencyKeyFactory: () => 'idem-test-1',
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const Key('polling_tier_request_change_button')),
      );
      await tester.tap(
        find.byKey(const Key('polling_tier_request_change_button')),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('polling_tier_change_request_reason_field')),
        'Dinner rush needs faster numbers — please review.',
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('polling_tier_change_request_submit')),
      );
      await tester.pumpAndSettle();

      expect(gateway.submissions, hasLength(1));
      final submitted = gateway.submissions.single;
      expect(submitted.currentTier, 'Standard');
      expect(submitted.requestedCadence, 'Faster than current tier');
      expect(
        submitted.businessReason,
        'Dinner rush needs faster numbers — please review.',
      );
      expect(gateway.idempotencyKeys, equals(<String>['idem-test-1']));

      expect(
        find.byKey(const Key('polling_tier_email_toast_sent')),
        findsOneWidget,
      );
      expect(
        find.text('Request submitted and emailed to F&F support.'),
        findsOneWidget,
      );
    });

    // Wave 2 U-FU-tier-email — email failure path: the gateway is
    // wired but returns `emailFailed`. The dialog renders the muted
    // toast so the operator knows the request is durable even if
    // SendGrid did not accept the send.
    testWidgets('dialog submit shows muted toast when gateway reports email failure',
        (tester) async {
      await sizeViewport(tester, const Size(1280, 1600));
      final gateway = InMemoryOperatorWebTierEmailGateway(
        defaultKind: OperatorTierEmailResultKind.emailFailed,
      );

      await tester.pumpWidget(
        wrap(
          DataAccuracyScreen(
            session: ownerSession,
            locationId: ownerSession.primaryLocationId ?? '',
            gateway: InMemoryVendorConnectionsGateway(),
            tierEmailGateway: gateway,
            tierEmailIdempotencyKeyFactory: () => 'idem-test-2',
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const Key('polling_tier_request_change_button')),
      );
      await tester.tap(
        find.byKey(const Key('polling_tier_request_change_button')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('polling_tier_change_request_reason_field')),
        'A reason',
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('polling_tier_change_request_submit')),
      );
      await tester.pumpAndSettle();

      // The gateway was still invoked — audit-row write happens
      // upstream, the email failure is the muted-toast case.
      expect(gateway.submissions, hasLength(1));
      expect(
        find.byKey(const Key('polling_tier_email_toast_failed')),
        findsOneWidget,
      );
      expect(
        find.text('Request submitted to F&F support.'),
        findsOneWidget,
      );
    });

    // Wave 2 U-FU-tier-email — cancelling the dialog must NOT call
    // the gateway. The submit button stays disabled on empty input
    // so this exercise the cancel path explicitly.
    testWidgets('dialog cancel does NOT invoke the gateway', (tester) async {
      await sizeViewport(tester, const Size(1280, 1600));
      final gateway = InMemoryOperatorWebTierEmailGateway();

      await tester.pumpWidget(
        wrap(
          DataAccuracyScreen(
            session: ownerSession,
            locationId: ownerSession.primaryLocationId ?? '',
            gateway: InMemoryVendorConnectionsGateway(),
            tierEmailGateway: gateway,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const Key('polling_tier_request_change_button')),
      );
      await tester.tap(
        find.byKey(const Key('polling_tier_request_change_button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('polling_tier_change_request_cancel')),
      );
      await tester.pumpAndSettle();

      expect(gateway.submissions, isEmpty);
      expect(
        find.byKey(const Key('polling_tier_email_toast_sent')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('polling_tier_email_toast_failed')),
        findsNothing,
      );
    });
  });

  // ─── Acceptance item I — UX writing audit ────────────────────────

  group('DataAccuracyScreen UX writing audit', () {
    testWidgets('subtitle and screen body avoid engineering jargon', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1600));

      await tester.pumpWidget(
        wrap(
          DataAccuracyScreen(
            session: ownerSession,
            locationId: ownerSession.primaryLocationId ?? '',
            gateway: InMemoryVendorConnectionsGateway(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Substring checks done case-insensitively. The list mirrors
      // the V1 lean-cut banned-token guidance — none of these
      // strings should leak into operator-facing copy on this screen.
      const bannedSubstrings = <String>[
        'operator_id',
        'location_id',
        'jsonb',
        'RLS',
        'pg_partman',
        'parse_warnings',
        'parse_partial',
        'email_outbox',
        'kms',
        'KMS',
        'SIGTERM',
        'advisory_lock',
      ];

      // First check: subtitle text in particular.
      final subtitle = tester.widget<Text>(
        find.byKey(const Key('operator_web_data_accuracy_subtitle')),
      );
      for (final banned in bannedSubstrings) {
        expect(
          subtitle.data!.toLowerCase().contains(banned.toLowerCase()),
          isFalse,
          reason: 'Subtitle leaked banned substring "$banned"',
        );
      }

      // Sweep every Text in the rendered tree and assert no banned
      // substring slips through the rest of the surface either.
      final textElements = find.byType(Text).evaluate();
      for (final element in textElements) {
        final widget = element.widget as Text;
        final data = widget.data;
        if (data == null || data.isEmpty) continue;
        final lower = data.toLowerCase();
        for (final banned in bannedSubstrings) {
          expect(
            lower.contains(banned.toLowerCase()),
            isFalse,
            reason: 'Rendered Text leaked banned substring "$banned": "$data"',
          );
        }
      }
    });
  });

  // ─── Acceptance item J — walkthrough click-path match ────────────

  group('DataAccuracyScreen walkthrough click-path', () {
    testWidgets(
      'walkthrough match: J — click-path numbered steps render the exact '
      'widgets the doc names',
      (tester) async {
        await sizeViewport(tester, const Size(1280, 2000));

        await tester.pumpWidget(
          wrap(
            DataAccuracyScreen(
              session: ownerSession,
              locationId: ownerSession.primaryLocationId ?? '',
              gateway: InMemoryVendorConnectionsGateway(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Step 2 — screen renders.
        expect(
          find.byKey(const Key('operator_web_data_accuracy_screen')),
          findsOneWidget,
        );

        // Step 3 — the 5 default cards are present.
        expect(
          find.byKey(const Key('data_accuracy_wage_source_card')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('data_accuracy_covers_source_card')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('data_accuracy_polling_tier_status_card')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('data_accuracy_explainer_card')),
          findsOneWidget,
        );

        // Step — flip the wage source toggle to manual mix.
        await tester.ensureVisible(
          find.byKey(const Key('wage_source_radio_manual_mix')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('wage_source_radio_manual_mix')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('wage_source_radio_manual_mix')),
          findsOneWidget,
        );

        // Step — switch dinner covers source to manual; manual entry
        // sub-card appears.
        await tester.ensureVisible(
          find.byKey(const Key('covers_source_chip_dinner_manual')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('covers_source_chip_dinner_manual')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('data_accuracy_covers_manual_entry_card')),
          findsOneWidget,
        );

        // Step — type today's dinner covers and submit.
        await tester.ensureVisible(
          find.byKey(const Key('covers_manual_entry_field_dinner')),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('covers_manual_entry_field_dinner')),
          '187',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();

        // Step — scroll polling card into view and tap "Request tier
        // change" → the change-request dialog appears.
        await tester.ensureVisible(
          find.byKey(const Key('polling_tier_request_change_button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('polling_tier_request_change_button')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('polling_tier_change_request_dialog')),
          findsOneWidget,
        );
      },
    );
  });

  group('DataAccuracyScreen wage vendor applicability binding', () {
    testWidgets(
      'enabled current wage rows make vendor selectable and persist through save',
      (tester) async {
        await sizeViewport(tester, const Size(1280, 1200));
        final saves = <DataAccuracySettings>[];
        final applicabilityGateway = _FakeWebVendorApplicabilityGateway()
          ..rows = <WebVendorApplicabilityRow>[
            _vendorApplicabilityRow(
              id: 'toast-current',
              vendorSlug: 'toast',
              enabled: true,
            ),
          ];

        await tester.pumpWidget(
          wrap(
            DataAccuracyScreen(
              session: ownerSession,
              locationId: ownerSession.primaryLocationId ?? '',
              gateway: InMemoryVendorConnectionsGateway(),
              initialSettings: _settingsWithWage(WageSource.manualMix),
              vendorApplicabilityGateway: applicabilityGateway,
              onSaveSettings: saves.add,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(applicabilityGateway.calls, equals(<String>['wage']));
        expect(
          find.byKey(const Key('wage_source_vendor_applicability_status')),
          findsOneWidget,
        );
        expect(
          find.textContaining('Enabled wage vendors: toast'),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('wage_source_radio_vendor')));
        await tester.pumpAndSettle();

        expect(saves.last.wageSource, WageSource.vendor);
      },
    );

    testWidgets(
      'disabled and ended wage rows are not selectable as vendor source',
      (tester) async {
        await sizeViewport(tester, const Size(1280, 1200));
        final saves = <DataAccuracySettings>[];
        final applicabilityGateway = _FakeWebVendorApplicabilityGateway()
          ..rows = <WebVendorApplicabilityRow>[
            _vendorApplicabilityRow(
              id: 'toast-disabled',
              vendorSlug: 'toast',
              enabled: false,
            ),
            _vendorApplicabilityRow(
              id: 'qbt-ended',
              vendorSlug: 'quickbooks_time',
              enabled: true,
              effectiveUntil: DateTime.utc(2026, 5, 14),
            ),
          ];

        await tester.pumpWidget(
          wrap(
            DataAccuracyScreen(
              session: ownerSession,
              locationId: ownerSession.primaryLocationId ?? '',
              gateway: InMemoryVendorConnectionsGateway(),
              initialSettings: _settingsWithWage(WageSource.manualMix),
              vendorApplicabilityGateway: applicabilityGateway,
              onSaveSettings: saves.add,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.textContaining('No enabled wage vendor is current'),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('wage_source_radio_vendor')));
        await tester.pumpAndSettle();

        expect(saves, isEmpty);
      },
    );

    testWidgets('empty wage applicability rows keep manual mix available', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1200));
      final applicabilityGateway = _FakeWebVendorApplicabilityGateway();

      await tester.pumpWidget(
        wrap(
          DataAccuracyScreen(
            session: ownerSession,
            locationId: ownerSession.primaryLocationId ?? '',
            gateway: InMemoryVendorConnectionsGateway(),
            initialSettings: _settingsWithWage(WageSource.manualMix),
            vendorApplicabilityGateway: applicabilityGateway,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Manual mix stays available'), findsOneWidget);
      expect(
        find.byKey(const Key('wage_source_radio_manual_mix')),
        findsOneWidget,
      );
    });

    testWidgets(
      'wage applicability load error is shown without saving vendor',
      (tester) async {
        await sizeViewport(tester, const Size(1280, 1200));
        final saves = <DataAccuracySettings>[];
        final applicabilityGateway = _FakeWebVendorApplicabilityGateway()
          ..throwsOnList = true;

        await tester.pumpWidget(
          wrap(
            DataAccuracyScreen(
              session: ownerSession,
              locationId: ownerSession.primaryLocationId ?? '',
              gateway: InMemoryVendorConnectionsGateway(),
              initialSettings: _settingsWithWage(WageSource.manualMix),
              vendorApplicabilityGateway: applicabilityGateway,
              onSaveSettings: saves.add,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.textContaining('Could not load wage vendor applicability'),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('wage_source_radio_vendor')));
        await tester.pumpAndSettle();

        expect(saves, isEmpty);
      },
    );
  });

  // Doc 1 keyed-data-accuracy-write — operator-web screen wires the
  // keyed service-period card to OperatorWebDataAccuracyGateway. The
  // dialog round-trips a draft into saveServicePeriodSetting on the
  // injected gateway.
  group('DataAccuracyScreen keyed service-period card', () {
    testWidgets(
      'card renders existing rows when a data-accuracy gateway is wired',
      (tester) async {
        await sizeViewport(tester, const Size(1280, 1400));

        final gateway = _RecordingDataAccuracyGateway()
          ..seedServicePeriodRows = <DataAccuracyServicePeriodSetting>[
            DataAccuracyServicePeriodSetting(
              id: 'period-1',
              operatorId: ownerSession.operatorId,
              locationId: ownerSession.primaryLocationId ?? '',
              servicePeriodKey: 'breakfast',
              coversSource: ServicePeriodCoversSource.reservationPlusWalkin,
              wageSource: ServicePeriodWageSource.targetSubstitution,
              effectiveAtBusinessDate: '2026-05-07',
              createdAt: DateTime.utc(2026, 5, 7),
              updatedAt: DateTime.utc(2026, 5, 7),
            ),
          ];

        await tester.pumpWidget(
          wrap(
            DataAccuracyScreen(
              session: ownerSession,
              locationId: ownerSession.primaryLocationId ?? '',
              gateway: InMemoryVendorConnectionsGateway(),
              dataAccuracyGateway: gateway,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(kKeyedServicePeriodAccuracyCardKey), findsOneWidget);
        expect(
          find.byKey(
            const Key(
              'data_accuracy_keyed_service_period_row_breakfast_2026-05-07',
            ),
          ),
          findsOneWidget,
        );
        expect(gateway.servicePeriodLoadCalls, equals(1));
      },
    );

    testWidgets(
      'add affordance round-trips a draft into saveServicePeriodSetting',
      (tester) async {
        await sizeViewport(tester, const Size(1280, 1400));

        final gateway = _RecordingDataAccuracyGateway();

        await tester.pumpWidget(
          wrap(
            DataAccuracyScreen(
              session: ownerSession,
              locationId: ownerSession.primaryLocationId ?? '',
              gateway: InMemoryVendorConnectionsGateway(),
              dataAccuracyGateway: gateway,
              businessDateIso: '2026-05-08',
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Open the add-or-edit dialog.
        final addButton = find.byKey(kKeyedServicePeriodAccuracyAddButtonKey);
        await tester.ensureVisible(addButton);
        await tester.pumpAndSettle();
        await tester.tap(addButton, warnIfMissed: false);
        await tester.pumpAndSettle();

        expect(
          find.byKey(kKeyedServicePeriodAccuracyDialogKey),
          findsOneWidget,
        );

        // The dialog pre-fills the effective business date with the
        // screen's `businessDateIso` so the operator does not have to
        // type it for "from today" overrides.
        final dateField = tester.widget<TextField>(
          find.byKey(kKeyedServicePeriodAccuracyEffectiveDateFieldKey),
        );
        expect(dateField.controller!.text, '2026-05-08');

        await tester.enterText(
          find.byKey(kKeyedServicePeriodAccuracyKeyFieldKey),
          'breakfast',
        );

        // Pick covers source = reservation_plus_walkin.
        await tester.tap(find.byKey(kKeyedServicePeriodAccuracyCoversFieldKey));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Reservations + walk-ins').last);
        await tester.pumpAndSettle();

        // Pick wage source = target_substitution.
        await tester.tap(find.byKey(kKeyedServicePeriodAccuracyWageFieldKey));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Target substitution').last);
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(kKeyedServicePeriodAccuracySubmitKey));
        await tester.pumpAndSettle();

        expect(gateway.servicePeriodSaveCalls, hasLength(1));
        final call = gateway.servicePeriodSaveCalls.single;
        expect(call.servicePeriodKey, 'breakfast');
        expect(
          call.coversSource,
          ServicePeriodCoversSource.reservationPlusWalkin,
        );
        expect(call.wageSource, ServicePeriodWageSource.targetSubstitution);
        expect(call.effectiveAtBusinessDateIso, '2026-05-08');
        expect(call.operatorId, ownerSession.operatorId);
        expect(call.locationId, ownerSession.primaryLocationId);
      },
    );

    testWidgets(
      'invalid service period key surfaces inline error and skips save',
      (tester) async {
        await sizeViewport(tester, const Size(1280, 1400));

        final gateway = _RecordingDataAccuracyGateway();

        await tester.pumpWidget(
          wrap(
            DataAccuracyScreen(
              session: ownerSession,
              locationId: ownerSession.primaryLocationId ?? '',
              gateway: InMemoryVendorConnectionsGateway(),
              dataAccuracyGateway: gateway,
              businessDateIso: '2026-05-08',
            ),
          ),
        );
        await tester.pumpAndSettle();

        final addButton = find.byKey(kKeyedServicePeriodAccuracyAddButtonKey);
        await tester.ensureVisible(addButton);
        await tester.pumpAndSettle();
        await tester.tap(addButton, warnIfMissed: false);
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(kKeyedServicePeriodAccuracyKeyFieldKey),
          'Brunch Special',
        );
        await tester.tap(find.byKey(kKeyedServicePeriodAccuracySubmitKey));
        await tester.pumpAndSettle();

        expect(
          find.byKey(
            const Key('data_accuracy_keyed_service_period_dialog_error'),
          ),
          findsOneWidget,
        );
        expect(gateway.servicePeriodSaveCalls, isEmpty);
      },
    );
  });

  // Wave 2 S-2 (`debug.md:220`, OW-13c) — Wage Authority folded under
  // the Data Accuracy page. The section embeds inside the screen with
  // every S-1 affordance intact (blended-wage summary card, FOH/BOH/
  // Management bands, hierarchy-scope notice). Full unit coverage for
  // the calculator + label widgets still lives next to those files; the
  // screen test only asserts the embed is mounted + wires through to
  // the gateway.
  group('DataAccuracyScreen embedded wage authority section', () {
    testWidgets(
      'wage authority section mounts inside the Data accuracy page',
      (tester) async {
        await sizeViewport(tester, const Size(1280, 2400));
        final wageGateway = _FakeWageAuthorityGateway()
          ..seed(<WageRoleRowRecord>[
            _wageRowFor(
              id: 'row-foh',
              roleName: 'Server',
              laborBucket: 'foh',
            ),
            _wageRowFor(
              id: 'row-mgr',
              roleName: 'GM',
              laborBucket: 'manager',
              hourlyRate: 30.0,
            ),
          ]);

        await tester.pumpWidget(
          wrap(
            DataAccuracyScreen(
              session: ownerSession,
              locationId: ownerSession.primaryLocationId ?? '',
              gateway: InMemoryVendorConnectionsGateway(),
              wageAuthorityGateway: wageGateway,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // The embedded wage section is mounted under Data accuracy.
        expect(
          find.byKey(
            const Key('operator_web_data_accuracy_wage_authority_section'),
          ),
          findsOneWidget,
        );
        // S-1 blended-wage summary card renders inside the embed.
        expect(
          find.byKey(const Key('wage_authority_blended_summary_card')),
          findsOneWidget,
        );
        // Three labor bands present.
        expect(
          find.byKey(const Key('wage_authority_bucket_foh')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('wage_authority_bucket_boh')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('wage_authority_bucket_manager')),
          findsOneWidget,
        );
        // Seeded rows render in the right bands.
        expect(
          find.byKey(const Key('wage_authority_row_display_row-foh')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('wage_authority_row_display_row-mgr')),
          findsOneWidget,
        );
        // S-1 hierarchy-scope notice (HP #11) renders at the top of
        // the embedded section.
        expect(
          find.byKey(const Key('wage_authority_hierarchy_scope')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'wage authority embed saves through the supplied gateway',
      (tester) async {
        await sizeViewport(tester, const Size(1280, 2400));
        final wageGateway = _FakeWageAuthorityGateway();
        var idemSeq = 0;

        await tester.pumpWidget(
          wrap(
            DataAccuracyScreen(
              session: ownerSession,
              locationId: ownerSession.primaryLocationId ?? '',
              gateway: InMemoryVendorConnectionsGateway(),
              wageAuthorityGateway: wageGateway,
              wageAuthorityIdempotencyKeyFactory: () {
                idemSeq += 1;
                return 'test-idem-$idemSeq';
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Open the FOH add-row form inside the embedded section.
        await tester.ensureVisible(
          find.byKey(const Key('wage_authority_add_button_foh')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('wage_authority_add_button_foh')),
        );
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('wage_authority_form_role_name_add')),
          'Server',
        );
        await tester.enterText(
          find.byKey(const Key('wage_authority_form_hourly_rate_add')),
          '18.50',
        );
        await tester.enterText(
          find.byKey(const Key('wage_authority_form_weighted_hours_add')),
          '32',
        );
        await tester.ensureVisible(
          find.byKey(const Key('wage_authority_form_save_add')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('wage_authority_form_save_add')));
        await tester.pumpAndSettle();

        // Save round-tripped through the gateway with the embed's
        // idempotency-key factory.
        expect(wageGateway.upsertCalls, hasLength(1));
        final call = wageGateway.upsertCalls.single;
        expect(call.request.roleName, 'Server');
        expect(call.request.laborBucket, 'foh');
        expect(call.request.hourlyRate, 18.5);
        expect(call.idempotencyKey, 'test-idem-1');
      },
    );
  });
}

class _UpsertCallFixture {
  const _UpsertCallFixture({
    required this.request,
    required this.idempotencyKey,
  });

  final WageRoleRowUpsert request;
  final String idempotencyKey;
}

class _FakeWageAuthorityGateway implements OperatorWebWageAuthorityGateway {
  final List<WageRoleRowRecord> _rows = <WageRoleRowRecord>[];
  final List<_UpsertCallFixture> upsertCalls = <_UpsertCallFixture>[];

  void seed(Iterable<WageRoleRowRecord> rows) {
    _rows
      ..clear()
      ..addAll(rows);
  }

  @override
  Future<List<WageRoleRowRecord>> list({
    required String operatorId,
    required String locationId,
  }) async {
    return List<WageRoleRowRecord>.unmodifiable(
      _rows.where((r) => r.isActive),
    );
  }

  @override
  Future<WageRoleRowRecord> upsert({
    required WageRoleRowUpsert request,
    required String idempotencyKey,
  }) async {
    upsertCalls.add(
      _UpsertCallFixture(request: request, idempotencyKey: idempotencyKey),
    );
    final now = DateTime.utc(2026, 5, 14, 12);
    final record = WageRoleRowRecord(
      wageRoleRowId: 'fake-${upsertCalls.length}',
      operatorId: 'brio-operator',
      locationId: 'brio-chicago-loop',
      restaurantId: request.restaurantId,
      roleName: request.roleName,
      laborBucket: request.laborBucket,
      hourlyRate: request.hourlyRate,
      weightedHours: request.weightedHours,
      jobCode: request.jobCode,
      vendorId: request.vendorId,
      vendorRoleId: request.vendorRoleId,
      source: request.source ?? WageRoleRowSource.operatorManual,
      isActive: true,
      effectiveAt: now,
      metadata: request.metadata,
      createdAt: now,
      updatedAt: now,
    );
    _rows.add(record);
    return record;
  }

  @override
  Future<bool> delete({
    required String wageRoleRowId,
    required String idempotencyKey,
  }) async {
    _rows.removeWhere((r) => r.wageRoleRowId == wageRoleRowId);
    return true;
  }
}

WageRoleRowRecord _wageRowFor({
  required String id,
  required String roleName,
  required String laborBucket,
  double hourlyRate = 18.50,
  double weightedHours = 32.0,
  String operatorId = 'brio-operator',
  String locationId = 'brio-chicago-loop',
}) {
  final now = DateTime.utc(2026, 5, 14, 12);
  return WageRoleRowRecord(
    wageRoleRowId: id,
    operatorId: operatorId,
    locationId: locationId,
    restaurantId: locationId,
    roleName: roleName,
    laborBucket: laborBucket,
    hourlyRate: hourlyRate,
    weightedHours: weightedHours,
    source: WageRoleRowSource.operatorManual,
    isActive: true,
    effectiveAt: now,
    metadata: const <String, Object?>{},
    createdAt: now,
    updatedAt: now,
  );
}

class _ServicePeriodSaveCall {
  const _ServicePeriodSaveCall({
    required this.operatorId,
    required this.locationId,
    required this.servicePeriodKey,
    required this.coversSource,
    required this.wageSource,
    required this.effectiveAtBusinessDateIso,
  });

  final String operatorId;
  final String locationId;
  final String servicePeriodKey;
  final ServicePeriodCoversSource coversSource;
  final ServicePeriodWageSource wageSource;
  final String effectiveAtBusinessDateIso;
}

DataAccuracySettings _settingsWithWage(WageSource wageSource) {
  return DataAccuracySettings(
    settingId: 'settings-wage-$wageSource',
    operatorId: 'brio-operator',
    locationId: 'brio-chicago-loop',
    coversSourcePerServicePeriod: const <String, CoversSource>{},
    coversManualEntries: const <String, Map<String, int>>{},
    wageSource: wageSource,
    walkInHandlingMode: DataAccuracyWalkInHandlingMode.reservationsOnly,
    walkInManualEntries: const <String, int>{},
    createdAt: DateTime.utc(2026, 5, 13),
    updatedAt: DateTime.utc(2026, 5, 13),
  );
}

WebVendorApplicabilityRow _vendorApplicabilityRow({
  required String id,
  required String vendorSlug,
  required bool enabled,
  DateTime? effectiveUntil,
  String settingKind = 'wage',
}) {
  final now = DateTime.utc(2026, 5, 13, 15);
  return WebVendorApplicabilityRow(
    id: id,
    settingKind: settingKind,
    settingKey: 'default',
    vendorSlug: vendorSlug,
    enabled: enabled,
    metadata: const <String, Object?>{'authority_basis': 'job_code'},
    effectiveFrom: now,
    effectiveUntil: effectiveUntil,
    operatorId: 'brio-operator',
    createdAt: now,
    createdBy: 'admin-user',
  );
}

class _FakeWebVendorApplicabilityGateway
    implements WebVendorApplicabilityGateway {
  List<WebVendorApplicabilityRow> rows = const <WebVendorApplicabilityRow>[];
  final List<String> calls = <String>[];
  bool throwsOnList = false;

  @override
  Future<List<WebVendorApplicabilityRow>> list({
    required String settingKind,
    String? settingKey,
  }) async {
    calls.add(settingKind);
    if (throwsOnList) {
      throw const WebVendorApplicabilityGatewayError(
        code: 'simulated_failure',
        message: 'fake failure',
      );
    }
    return rows
        .where(
          (row) =>
              row.settingKind == settingKind &&
              (settingKey == null || row.settingKey == settingKey),
        )
        .toList(growable: false);
  }
}

/// Minimal in-memory test double for the operator-web data accuracy
/// gateway. The screen test only exercises the keyed
/// service-period surface; the legacy load/save methods round-trip a
/// canned response so the screen's hydrate sequence is happy.
class _RecordingDataAccuracyGateway implements OperatorWebDataAccuracyGateway {
  List<DataAccuracyServicePeriodSetting> seedServicePeriodRows =
      const <DataAccuracyServicePeriodSetting>[];

  int servicePeriodLoadCalls = 0;
  final List<_ServicePeriodSaveCall> servicePeriodSaveCalls =
      <_ServicePeriodSaveCall>[];

  @override
  Future<DataAccuracySettings?> loadSettings({
    required String operatorId,
    required String locationId,
  }) async {
    return DataAccuracySettings(
      settingId: 'setting-1',
      operatorId: operatorId,
      locationId: locationId,
      coversSourcePerServicePeriod: const <String, CoversSource>{},
      coversManualEntries: const <String, Map<String, int>>{},
      wageSource: WageSource.vendor,
      walkInHandlingMode: DataAccuracyWalkInHandlingMode.reservationsOnly,
      walkInManualEntries: const <String, int>{},
      createdAt: DateTime.utc(2026, 5, 8),
      updatedAt: DateTime.utc(2026, 5, 8),
    );
  }

  @override
  Future<DataAccuracySettings> saveSettings(
    DataAccuracySettings settings,
  ) async => settings;

  @override
  Future<List<DataAccuracyServicePeriodSetting>> loadServicePeriodSettings({
    required String operatorId,
    required String locationId,
  }) async {
    servicePeriodLoadCalls += 1;
    return List<DataAccuracyServicePeriodSetting>.unmodifiable(
      seedServicePeriodRows,
    );
  }

  @override
  Future<DataAccuracyServicePeriodSetting> saveServicePeriodSetting({
    required String operatorId,
    required String locationId,
    required String servicePeriodKey,
    required ServicePeriodCoversSource coversSource,
    required ServicePeriodWageSource wageSource,
    required String effectiveAtBusinessDateIso,
  }) async {
    servicePeriodSaveCalls.add(
      _ServicePeriodSaveCall(
        operatorId: operatorId,
        locationId: locationId,
        servicePeriodKey: servicePeriodKey,
        coversSource: coversSource,
        wageSource: wageSource,
        effectiveAtBusinessDateIso: effectiveAtBusinessDateIso,
      ),
    );
    final saved = DataAccuracyServicePeriodSetting(
      id: 'period-${servicePeriodSaveCalls.length}',
      operatorId: operatorId,
      locationId: locationId,
      servicePeriodKey: servicePeriodKey,
      coversSource: coversSource,
      wageSource: wageSource,
      effectiveAtBusinessDate: effectiveAtBusinessDateIso,
      createdAt: DateTime.utc(2026, 5, 8),
      updatedAt: DateTime.utc(2026, 5, 8),
    );
    seedServicePeriodRows = <DataAccuracyServicePeriodSetting>[
      ...seedServicePeriodRows.where(
        (r) =>
            !(r.servicePeriodKey == servicePeriodKey &&
                r.effectiveAtBusinessDate == effectiveAtBusinessDateIso),
      ),
      saved,
    ];
    return saved;
  }
}
