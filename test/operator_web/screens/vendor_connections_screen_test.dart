// Phase 11W.8 — Vendor Connections screen widget tests.
//
// Covers what 11W.8 ships under the operator-web shell: the screen
// mount, permission gate (operator_owner allow — G7d folded the
// phantom operator_admin into operator_owner; location_manager 403),
// responsive breakpoints, and the standalone
// Notify-me dialog (open / submit / cancel / pre-fill / duplicate
// resubmit).
//
// The shared picker now renders the implemented 17-adapter catalog
// and gates lifecycle states so documented and sandbox-verified
// vendors stay visible but cannot start a connect flow.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/integrations/ui/vendor_connections/in_memory_vendor_connections_gateway.dart';
import 'package:forge_and_flow/integrations/ui/vendor_connections/vendor_connections_gateway.dart';
import 'package:forge_and_flow/integrations/ui/vendor_connections/vendor_connections_models.dart';
import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/screens/vendor_connections_screen.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_proxy_client.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_vendor_connections_gateway.dart';
import 'package:forge_and_flow/operator_web/widgets/vendor_lifecycle_notify_me_dialog.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  // ─── Test fixtures ───────────────────────────────────────────────

  // G7d (spec §3): the phantom `operator_admin` folds into
  // `operator_owner` (never seeded in v1/v2). This fixture now drives
  // the fold target — the elevated tier that, post-v2, the Vendor
  // Connections admit set (`{roleOperatorOwner}`) recognizes.
  const adminSession = OperatorWebSession(
    uid: 'brio-admin',
    email: 'alex@brio-restaurants.com',
    displayName: 'Alex Reyes',
    operatorId: 'brio-operator',
    businessName: 'Brio Restaurants',
    primaryLocationId: 'brio-chicago-loop',
    primaryLocationName: 'Brio - Chicago Loop',
    roles: <String>['operator_owner'],
  );

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

  Widget wrap(Widget child, {Size size = const Size(1280, 800)}) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeData,
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: Scaffold(backgroundColor: AppColors.backgroundDeep, body: child),
      ),
    );
  }

  Future<void> sizeViewport(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  // ─── Permission gate ─────────────────────────────────────────────

  group('VendorConnectionsScreen permission gate', () {
    testWidgets('operator_admin fold target (owner) renders the screen '
        'body', (tester) async {
      await sizeViewport(tester, const Size(1280, 800));
      await tester.pumpWidget(
        wrap(
          VendorConnectionsScreen(
            session: adminSession,
            locationId: adminSession.primaryLocationId ?? '',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('operator_web_vendor_connections_screen')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_vendor_connections_forbidden')),
        findsNothing,
      );
      // The screen chrome (display20 title + subtitle) renders. The
      // shared widget under the screen also has its own internal
      // header that says "Vendor integrations", so a bare text find
      // for that string would match both — the screen Key + the
      // unique subtitle Key together pin the chrome.
      expect(
        find.byKey(const Key('operator_web_vendor_connections_subtitle')),
        findsOneWidget,
      );
      expect(
        find.text('Manage the services connected to Brio - Chicago Loop.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('does not push changes back to vendor systems'),
        findsNothing,
      );
    });

    testWidgets('operator_owner renders the screen body', (tester) async {
      await sizeViewport(tester, const Size(1280, 800));
      await tester.pumpWidget(
        wrap(
          VendorConnectionsScreen(
            session: ownerSession,
            locationId: ownerSession.primaryLocationId ?? '',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('operator_web_vendor_connections_screen')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_vendor_connections_forbidden')),
        findsNothing,
      );
    });

    testWidgets('location_manager hits the friendly 403 surface', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 800));
      await tester.pumpWidget(
        wrap(
          VendorConnectionsScreen(
            session: locationManagerSession,
            locationId: locationManagerSession.primaryLocationId ?? '',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('operator_web_vendor_connections_screen')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('operator_web_vendor_connections_forbidden')),
        findsOneWidget,
      );
      // Friendly copy reads as training (per UX writing standard).
      expect(
        find.byKey(const Key('operator_web_vendor_connections_forbidden_body')),
        findsOneWidget,
      );
      expect(
        find.text(
          'Your operator admin or owner can set up integrations for '
          'this location.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('empty roles list also hits the 403 surface', (tester) async {
      await sizeViewport(tester, const Size(1280, 800));
      const noRoleSession = OperatorWebSession(
        uid: 'brio-norole',
        email: 'norole@brio-restaurants.com',
        displayName: 'No Role',
        operatorId: 'brio-operator',
        businessName: 'Brio Restaurants',
        primaryLocationId: 'brio-chicago-loop',
        primaryLocationName: 'Brio - Chicago Loop',
      );
      await tester.pumpWidget(
        wrap(
          VendorConnectionsScreen(
            session: noRoleSession,
            locationId: noRoleSession.primaryLocationId ?? '',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('operator_web_vendor_connections_forbidden')),
        findsOneWidget,
      );
    });
  });

  // ─── Screen mount + responsive ──────────────────────────────────

  group('VendorConnectionsScreen mount', () {
    testWidgets('hosts the shared VendorConnectionsWidget', (tester) async {
      await sizeViewport(tester, const Size(1280, 800));
      await tester.pumpWidget(
        wrap(
          VendorConnectionsScreen(
            session: adminSession,
            locationId: adminSession.primaryLocationId ?? '',
            gateway: InMemoryVendorConnectionsGateway(
              seed: <String, VendorConnectionsBundle>{
                'brio-operator/brio-chicago-loop':
                    InMemoryVendorConnectionsGateway.demoFirstBackfillBundle(
                      operatorId: adminSession.operatorId,
                      locationId: adminSession.primaryLocationId ?? '',
                      locationName: adminSession.primaryLocationName,
                    ),
              },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // The screen Key wraps the title + the shared-widget host.
      expect(
        find.byKey(const Key('operator_web_vendor_connections_screen')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_vendor_connections_widget_host')),
        findsOneWidget,
      );
      // The shared widget renders its category sections after the
      // gateway resolves.
      expect(
        find.byKey(const Key('vendor_connections_section_pos')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('vendor_connections_section_reservation')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('vendor_connections_section_labor')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('operator_web_vendor_connections_backfill_progress'),
        ),
        findsNothing,
      );
      expect(find.text('60 day benchmark data'), findsNothing);
      expect(
        find.byKey(
          const Key('vendor_connections_first_backfill_toast_running'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('non-primary location id uses plain location copy', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 800));
      await tester.pumpWidget(
        wrap(
          VendorConnectionsScreen(
            session: adminSession,
            locationId: 'brio-other-location',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Manage the services connected to this location.'),
        findsOneWidget,
      );
    });

    testWidgets('renders cleanly at tablet 768x1024 viewport', (tester) async {
      await sizeViewport(tester, const Size(768, 1024));
      await tester.pumpWidget(
        wrap(
          VendorConnectionsScreen(
            session: adminSession,
            locationId: adminSession.primaryLocationId ?? '',
          ),
          size: const Size(768, 1024),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('operator_web_vendor_connections_screen')),
        findsOneWidget,
      );
      // No layout overflow recorded by the framework.
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders cleanly at desktop 1024x768 viewport', (tester) async {
      await sizeViewport(tester, const Size(1024, 768));
      await tester.pumpWidget(
        wrap(
          VendorConnectionsScreen(
            session: adminSession,
            locationId: adminSession.primaryLocationId ?? '',
          ),
          size: const Size(1024, 768),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('operator_web_vendor_connections_screen')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'plumbs session.operatorId + locationId through to the gateway',
      (tester) async {
        await sizeViewport(tester, const Size(1280, 800));
        final captureGateway = _CaptureGateway();
        await tester.pumpWidget(
          wrap(
            VendorConnectionsScreen(
              session: adminSession,
              locationId: 'brio-other-location',
              gateway: captureGateway,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // The gateway saw exactly one loadBundle call carrying the
        // operator_id from the session and the location_id passed
        // by the router. RLS-Ready Schema rule (CLAUDE.md) requires
        // operator-scoped reads carry the right tenant tuple at the
        // gateway boundary; this test pins that contract.
        expect(captureGateway.loadBundleCalls, hasLength(1));
        expect(
          captureGateway.loadBundleCalls.single.operatorId,
          equals('brio-operator'),
        );
        expect(
          captureGateway.loadBundleCalls.single.locationId,
          equals('brio-other-location'),
        );
      },
    );

    testWidgets(
      'route changes refresh the shared widget with the new location',
      (tester) async {
        await sizeViewport(tester, const Size(1280, 800));
        final captureGateway = _CaptureGateway();
        await tester.pumpWidget(
          wrap(
            VendorConnectionsScreen(
              session: adminSession,
              locationId: adminSession.primaryLocationId ?? '',
              gateway: captureGateway,
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.pumpWidget(
          wrap(
            VendorConnectionsScreen(
              session: adminSession,
              locationId: 'brio-other-location',
              gateway: captureGateway,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(captureGateway.loadBundleCalls, hasLength(2));
        expect(
          captureGateway.loadBundleCalls.map((call) => call.locationId),
          equals(<String>['brio-chicago-loop', 'brio-other-location']),
        );
        expect(
          find.text('Manage the services connected to this location.'),
          findsOneWidget,
        );
      },
    );

    test('in-memory catalog exposes all implemented adapter rows', () async {
      final gateway = InMemoryVendorConnectionsGateway();
      final pos = await gateway.listAvailableVendors(
        category: VendorCategory.pos,
      );
      final reservations = await gateway.listAvailableVendors(
        category: VendorCategory.reservation,
      );
      final labor = await gateway.listAvailableVendors(
        category: VendorCategory.labor,
      );

      expect(pos, hasLength(7));
      expect(reservations, hasLength(4));
      expect(labor, hasLength(6));
      expect(
        <String>{
          ...pos.map((entry) => entry.vendorId),
          ...reservations.map((entry) => entry.vendorId),
          ...labor.map((entry) => entry.vendorId),
        },
        containsAll(<String>[
          'aloha_ncr_voyix',
          'clover',
          'lightspeed_lsk',
          'oracle_micros_simphony',
          'revel',
          'square',
          'toast',
          'libro',
          'opentable',
          'sevenrooms',
          'tock',
          'adp',
          'agendrix',
          'humanity',
          'push_operations',
          'quickbooks_time',
          'seven_shifts',
        ]),
      );
    });

    test(
      'live operator-web catalog keeps documented lifecycle truth',
      () async {
        final gateway = OperatorWebHttpVendorConnectionsGateway(
          proxyClient: OperatorWebProxyClient(
            baseUri: Uri.parse('https://proxy.example.test'),
          ),
          idTokenProvider: () async => 'token',
        );
        final pos = await gateway.listAvailableVendors(
          category: VendorCategory.pos,
        );
        final reservations = await gateway.listAvailableVendors(
          category: VendorCategory.reservation,
        );
        final labor = await gateway.listAvailableVendors(
          category: VendorCategory.labor,
        );

        expect(pos, hasLength(7));
        expect(reservations, hasLength(4));
        expect(labor, hasLength(6));
        expect(
          [...pos, ...reservations, ...labor].map((entry) => entry.lifecycle),
          everyElement(VendorLifecycle.documented),
        );
      },
    );

    testWidgets('documented vendors are visible but cannot continue', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 800));
      await tester.pumpWidget(
        wrap(
          VendorConnectionsScreen(
            session: adminSession,
            locationId: adminSession.primaryLocationId ?? '',
            gateway: InMemoryVendorConnectionsGateway(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('vendor_connections_connect_pos')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('vendor_connections_picker_grid')),
        findsOneWidget,
      );
      expect(find.text('7 available vendor options'), findsOneWidget);
      expect(
        find.byTooltip('Official Aloha (NCR Voyix) icon from ncrvoyix.com'),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('vendor_connections_picker_choice_aloha_ncr_voyix'),
        ),
        findsOneWidget,
      );
      expect(find.text('Aloha (NCR Voyix)'), findsOneWidget);
      expect(find.text('API pending'), findsWidgets);

      await tester.tap(
        find.byKey(
          const Key('vendor_connections_picker_choice_aloha_ncr_voyix'),
        ),
      );
      await tester.pumpAndSettle();

      final continueButton = tester.widget<FilledButton>(
        find.byKey(const Key('vendor_connections_picker_continue')),
      );
      expect(continueButton.onPressed, isNull);
      expect(find.text('API access pending'), findsOneWidget);
      expect(
        find.byKey(const Key('vendor_connections_picker_selected_panel')),
        findsOneWidget,
      );
    });

    testWidgets('Libro Reserve uses checked initials mark, not a favicon', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 800));
      await tester.pumpWidget(
        wrap(
          VendorConnectionsScreen(
            session: adminSession,
            locationId: adminSession.primaryLocationId ?? '',
            gateway: InMemoryVendorConnectionsGateway(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final reservationButton = find.byKey(
        const Key('vendor_connections_connect_reservation'),
      );
      await tester.ensureVisible(reservationButton);
      await tester.pumpAndSettle();
      await tester.tap(reservationButton);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('vendor_connections_picker_choice_libro')),
        findsOneWidget,
      );
      expect(find.byTooltip('Libro Reserve logo'), findsOneWidget);
      expect(
        find.byTooltip('Official Libro Reserve icon from libroreserve.com'),
        findsNothing,
      );
    });

    testWidgets('vendor picker card grid renders cleanly at tablet width', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(768, 1024));
      await tester.pumpWidget(
        wrap(
          VendorConnectionsScreen(
            session: adminSession,
            locationId: adminSession.primaryLocationId ?? '',
            gateway: InMemoryVendorConnectionsGateway(),
          ),
          size: const Size(768, 1024),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('vendor_connections_connect_pos')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('vendor_connections_picker_dialog')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('vendor_connections_picker_grid')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  // ─── Notify-me dialog (standalone) ───────────────────────────────

  group('VendorLifecycleNotifyMeDialog', () {
    testWidgets('opens with email pre-filled from defaultEmail', (
      tester,
    ) async {
      final repo = _FakeNotificationRepository();
      VendorLifecycleNotifyMeResult? result;

      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                key: const Key('test_open_dialog'),
                onPressed: () async {
                  result = await showVendorLifecycleNotifyMeDialog(
                    context,
                    operatorId: adminSession.operatorId,
                    vendorId: 'toast',
                    vendorDisplayName: 'Toast',
                    lifecycle: VendorLifecycle.documented,
                    defaultEmail: adminSession.email,
                    repository: repo,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('test_open_dialog')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('vendor_lifecycle_notify_me_dialog')),
        findsOneWidget,
      );
      expect(
        find.text("We'll email you the moment Toast goes live for connecting."),
        findsOneWidget,
      );
      // Email pre-filled.
      final field = tester.widget<TextField>(
        find.byKey(const Key('vendor_lifecycle_notify_me_email_field')),
      );
      expect(field.controller!.text, equals('alex@brio-restaurants.com'));
      // Result stays null until submit.
      expect(result, isNull);
    });

    testWidgets('submit inserts via repository and returns inserted outcome', (
      tester,
    ) async {
      final repo = _FakeNotificationRepository();
      VendorLifecycleNotifyMeResult? result;

      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                key: const Key('test_open_dialog'),
                onPressed: () async {
                  result = await showVendorLifecycleNotifyMeDialog(
                    context,
                    operatorId: adminSession.operatorId,
                    vendorId: 'toast',
                    vendorDisplayName: 'Toast',
                    lifecycle: VendorLifecycle.documented,
                    defaultEmail: adminSession.email,
                    repository: repo,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('test_open_dialog')));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('vendor_lifecycle_notify_me_submit')),
      );
      await tester.pumpAndSettle();

      expect(repo.insertCalls, hasLength(1));
      expect(repo.insertCalls.single.operatorId, equals('brio-operator'));
      expect(repo.insertCalls.single.vendorId, equals('toast'));
      expect(
        repo.insertCalls.single.email,
        equals('alex@brio-restaurants.com'),
      );
      expect(result, isNotNull);
      expect(result!.email, equals('alex@brio-restaurants.com'));
      expect(
        result!.outcome,
        equals(VendorLifecycleNotificationOutcome.inserted),
      );
    });

    testWidgets('duplicate submit returns alreadySubscribed', (tester) async {
      final repo = _FakeNotificationRepository(
        outcomes: <VendorLifecycleNotificationOutcome>[
          VendorLifecycleNotificationOutcome.inserted,
          VendorLifecycleNotificationOutcome.alreadySubscribed,
        ],
      );
      final results = <VendorLifecycleNotifyMeResult?>[];

      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                key: const Key('test_open_dialog'),
                onPressed: () async {
                  final r = await showVendorLifecycleNotifyMeDialog(
                    context,
                    operatorId: adminSession.operatorId,
                    vendorId: 'toast',
                    vendorDisplayName: 'Toast',
                    lifecycle: VendorLifecycle.documented,
                    defaultEmail: adminSession.email,
                    repository: repo,
                  );
                  results.add(r);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      // First open + submit.
      await tester.tap(find.byKey(const Key('test_open_dialog')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('vendor_lifecycle_notify_me_submit')),
      );
      await tester.pumpAndSettle();
      // Second open + submit.
      await tester.tap(find.byKey(const Key('test_open_dialog')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('vendor_lifecycle_notify_me_submit')),
      );
      await tester.pumpAndSettle();

      expect(repo.insertCalls, hasLength(2));
      expect(results, hasLength(2));
      expect(
        results[0]!.outcome,
        equals(VendorLifecycleNotificationOutcome.inserted),
      );
      expect(
        results[1]!.outcome,
        equals(VendorLifecycleNotificationOutcome.alreadySubscribed),
      );
    });

    testWidgets('cancel returns null and does not insert', (tester) async {
      final repo = _FakeNotificationRepository();
      VendorLifecycleNotifyMeResult? result =
          const VendorLifecycleNotifyMeResult(
            email: 'sentinel@example.com',
            outcome: VendorLifecycleNotificationOutcome.inserted,
          );

      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                key: const Key('test_open_dialog'),
                onPressed: () async {
                  result = await showVendorLifecycleNotifyMeDialog(
                    context,
                    operatorId: adminSession.operatorId,
                    vendorId: 'toast',
                    vendorDisplayName: 'Toast',
                    lifecycle: VendorLifecycle.documented,
                    defaultEmail: adminSession.email,
                    repository: repo,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('test_open_dialog')));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('vendor_lifecycle_notify_me_cancel')),
      );
      await tester.pumpAndSettle();

      expect(repo.insertCalls, isEmpty);
      expect(result, isNull);
    });

    testWidgets('invalid email surfaces inline error and does not insert', (
      tester,
    ) async {
      final repo = _FakeNotificationRepository();
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                key: const Key('test_open_dialog'),
                onPressed: () => showVendorLifecycleNotifyMeDialog(
                  context,
                  operatorId: adminSession.operatorId,
                  vendorId: 'toast',
                  vendorDisplayName: 'Toast',
                  lifecycle: VendorLifecycle.documented,
                  defaultEmail: 'invalid-no-at-sign',
                  repository: repo,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('test_open_dialog')));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('vendor_lifecycle_notify_me_submit')),
      );
      await tester.pumpAndSettle();

      expect(repo.insertCalls, isEmpty);
      // Inline error rendered (use textContaining to be tolerant of
      // wrapping at different widths).
      expect(find.textContaining('valid email address'), findsOneWidget);
    });

    test(
      'repository.cancelNotification contract is reachable on the seam',
      () async {
        // The post-submit row chrome (blocked upstream — see
        // walkthrough) calls cancelNotification when the operator
        // taps the [Cancel] button on a "We'll email you when X is
        // ready" row. This test pins the contract method on the
        // abstract repository seam: signature + parameters match
        // the surface doc + migration column shape exactly.
        final repo = _FakeNotificationRepository();
        await repo.cancelNotification(
          operatorId: 'brio-operator',
          vendorId: 'toast',
          email: 'alex@brio-restaurants.com',
        );
        expect(repo.cancelCalls, hasLength(1));
        expect(repo.cancelCalls.single.operatorId, equals('brio-operator'));
        expect(repo.cancelCalls.single.vendorId, equals('toast'));
        expect(
          repo.cancelCalls.single.email,
          equals('alex@brio-restaurants.com'),
        );
      },
    );

    testWidgets('sandbox_verified lifecycle renders distinct subline', (
      tester,
    ) async {
      final repo = _FakeNotificationRepository();
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                key: const Key('test_open_dialog'),
                onPressed: () => showVendorLifecycleNotifyMeDialog(
                  context,
                  operatorId: adminSession.operatorId,
                  vendorId: 'opentable',
                  vendorDisplayName: 'OpenTable',
                  lifecycle: VendorLifecycle.sandboxVerified,
                  defaultEmail: adminSession.email,
                  repository: repo,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('test_open_dialog')));
      await tester.pumpAndSettle();

      expect(
        find.textContaining(
          "verified the integration end-to-end against OpenTable's sandbox",
        ),
        findsOneWidget,
      );
    });
  });
}

// ─── Test fakes ──────────────────────────────────────────────────

class _FakeInsertCall {
  _FakeInsertCall({
    required this.operatorId,
    required this.vendorId,
    required this.email,
  });

  final String operatorId;
  final String vendorId;
  final String email;
}

class _FakeNotificationRepository
    implements VendorLifecycleNotificationRepository {
  _FakeNotificationRepository({
    List<VendorLifecycleNotificationOutcome>? outcomes,
  }) : _outcomes =
           outcomes ??
           <VendorLifecycleNotificationOutcome>[
             VendorLifecycleNotificationOutcome.inserted,
           ];

  final List<VendorLifecycleNotificationOutcome> _outcomes;
  final List<_FakeInsertCall> insertCalls = <_FakeInsertCall>[];
  final List<_FakeInsertCall> cancelCalls = <_FakeInsertCall>[];
  int _cursor = 0;

  @override
  Future<VendorLifecycleNotificationOutcome> insertNotification({
    required String operatorId,
    required String vendorId,
    required String email,
  }) async {
    insertCalls.add(
      _FakeInsertCall(operatorId: operatorId, vendorId: vendorId, email: email),
    );
    final outcome = _outcomes[_cursor.clamp(0, _outcomes.length - 1)];
    _cursor += 1;
    return outcome;
  }

  @override
  Future<void> cancelNotification({
    required String operatorId,
    required String vendorId,
    required String email,
  }) async {
    cancelCalls.add(
      _FakeInsertCall(operatorId: operatorId, vendorId: vendorId, email: email),
    );
  }
}

class _CaptureLoadBundleCall {
  _CaptureLoadBundleCall({required this.operatorId, required this.locationId});
  final String operatorId;
  final String locationId;
}

/// Test-only gateway that captures the operator_id + location_id the
/// screen plumbs through to `loadBundle()` and returns an empty
/// bundle so the widget renders its empty-state cards. Lives in the
/// test file so we can prove the screen → widget plumbing without
/// forking any production gateway under
/// `lib/integrations/ui/vendor_connections/`.
class _CaptureGateway implements VendorConnectionsGateway {
  final List<_CaptureLoadBundleCall> loadBundleCalls =
      <_CaptureLoadBundleCall>[];

  @override
  Future<VendorConnectionsBundle> loadBundle({
    required String operatorId,
    required String locationId,
  }) async {
    loadBundleCalls.add(
      _CaptureLoadBundleCall(operatorId: operatorId, locationId: locationId),
    );
    return VendorConnectionsBundle(
      operatorId: operatorId,
      locationId: locationId,
      locationName: 'Capture Location',
      posConnection: null,
      laborConnection: null,
      reservationConnection: null,
      demoFlags: const <VendorCategory, bool>{
        VendorCategory.pos: true,
        VendorCategory.labor: true,
        VendorCategory.reservation: true,
      },
    );
  }

  @override
  Future<List<VendorPickerEntry>> listAvailableVendors({
    required VendorCategory category,
  }) async => const <VendorPickerEntry>[];

  @override
  Future<VendorConnectFlowStart> startConnect({
    required String operatorId,
    required String locationId,
    required String vendorId,
    String? module,
  }) async => const VendorConnectFlowStart(
    redirectUrl: 'about:blank',
    flowKind: VendorConnectFlowKind.oauthRedirect,
  );

  @override
  Future<VendorTestConnectionResult> testConnection({
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) async => const VendorTestConnectionResult(
    authValid: true,
    elapsedMs: 0,
    sampleSummary: '',
    fieldMapping: <String, String>{},
  );

  @override
  Future<void> disconnect({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String reason,
  }) async {}

  @override
  Future<List<VendorSyncLogEntry>> loadLogs({
    required String operatorId,
    required String locationId,
    required String vendorId,
    int limit = 100,
  }) async => const <VendorSyncLogEntry>[];

  @override
  Future<VendorApiKeyConnectResult> connectWithApiKey({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String apiKey,
    String? apiSecret,
    String? module,
  }) async => VendorApiKeyConnectResult(
    connectionId: 'capture-conn-$vendorId',
    connectedAt: DateTime.now().toUtc(),
    firstBackfillStarted: true,
  );
}
