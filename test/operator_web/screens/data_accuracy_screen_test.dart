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

import 'package:forge_and_flow/integrations/ui/vendor_connections/in_memory_vendor_connections_gateway.dart';
import 'package:forge_and_flow/integrations/ui/vendor_connections/vendor_connections_models.dart';
import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/screens/data_accuracy_screen.dart';
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
      locationId: session.primaryLocationId,
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
  }) =>
      VendorConnectionRow(
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
              locationId: ownerSession.primaryLocationId,
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
            locationId: ownerSession.primaryLocationId,
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
        subtitle.data!.contains('Brio - Chicago Loop (primary location)'),
        isTrue,
        reason: 'Subtitle should name the primary location explicitly.',
      );
    });
  });

  group('DataAccuracyScreen permission gate', () {
    testWidgets('forbidden surface for location_manager session',
        (tester) async {
      await sizeViewport(tester, const Size(1280, 800));

      await tester.pumpWidget(
        wrap(
          DataAccuracyScreen(
            session: locationManagerSession,
            locationId: locationManagerSession.primaryLocationId,
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
              locationId: ownerSession.primaryLocationId,
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
              locationId: ownerSession.primaryLocationId,
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

    testWidgets('historical seed card surfaces for non-covers-exposing POS',
        (tester) async {
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
            locationId: ownerSession.primaryLocationId,
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

    testWidgets(
      'switching dinner to manual reveals manual entry sub-card',
      (tester) async {
        await sizeViewport(tester, const Size(1280, 1600));

        await tester.pumpWidget(
          wrap(
            DataAccuracyScreen(
              session: ownerSession,
              locationId: ownerSession.primaryLocationId,
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
      },
    );
  });

  group('DataAccuracyScreen polling tier interaction', () {
    testWidgets('request tier change opens the ticket dialog', (tester) async {
      await sizeViewport(tester, const Size(1280, 1600));

      await tester.pumpWidget(
        wrap(
          DataAccuracyScreen(
            session: ownerSession,
            locationId: ownerSession.primaryLocationId,
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
  });

  // ─── Acceptance item I — UX writing audit ────────────────────────

  group('DataAccuracyScreen UX writing audit', () {
    testWidgets(
      'subtitle and screen body avoid engineering jargon',
      (tester) async {
        await sizeViewport(tester, const Size(1280, 1600));

        await tester.pumpWidget(
          wrap(
            DataAccuracyScreen(
              session: ownerSession,
              locationId: ownerSession.primaryLocationId,
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
              reason:
                  'Rendered Text leaked banned substring "$banned": "$data"',
            );
          }
        }
      },
    );
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
              locationId: ownerSession.primaryLocationId,
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
        await tester.tap(
          find.byKey(const Key('wage_source_radio_manual_mix')),
        );
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
}
