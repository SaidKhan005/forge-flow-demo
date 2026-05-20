// Phase 11W.0 — Operator Web Console router widget tests.
//
// Verifies the router renders the right surface for each
// `OperatorWebAuthState` and that the post-onboarding shell hosts
// the operator-web route bodies behind the side
// nav. Keeps the demo source as the driver so the click path runs
// without Firebase.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/models/data_accuracy_service_period_setting.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_settings.dart';
import 'package:forge_and_flow/operator_web/auth/operator_web_handoff_redeem_gateway.dart';
import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/router/operator_web_router.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_audit_log_gateway.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_hierarchy_gateway.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_users_gateway.dart';
import 'package:forge_and_flow/operator_web/services/demo_vendor_connections_fixtures.dart';
import 'package:forge_and_flow/operator_web/services/business_timing_gateway.dart';
import 'package:forge_and_flow/operator_web/services/demo_operator_web_write_gateways.dart';
import 'package:forge_and_flow/operator_web/services/http_business_timing_read_gateway.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_data_accuracy_gateway.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_team_gateway_providers.dart';
import 'package:forge_and_flow/operator_web/services/web_business_timing_gateway.dart';
import 'package:forge_and_flow/operator_web/widgets/keyed_service_period_accuracy_card.dart';
import 'package:forge_and_flow/integrations/ui/vendor_connections/vendor_connections_gateway.dart';
import 'package:forge_and_flow/operator_web/services/web_team_audit_log_gateway.dart';
import 'package:forge_and_flow/operator_web/services/web_team_hierarchy_gateway.dart';
import 'package:forge_and_flow/operator_web/services/web_team_users_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: child,
  );

  // Operator-web shell is desktop-first (≥1024 breakpoint per the
  // 11W plan acceptance criteria). The default 800×600 test viewport
  // would push the side nav + header off-screen.
  Future<void> sizeViewport(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  group('OperatorWebRouter auth stages', () {
    testWidgets(
      'signed-out state lands on the sign-in screen (no onboarding click '
      'path); G24/G3 S3′ — invitee onboarding is the Firebase reset email',
      (tester) async {
        await sizeViewport(tester);
        final source = DemoOperatorWebAuthSource.signedOut();
        addTearDown(source.dispose);

        await tester.pumpWidget(wrap(OperatorWebRouter(source: source)));

        // Sign-in surface, not a welcome/token screen.
        expect(
          find.byKey(const Key('operator_web_signin_email_field')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('operator_web_signin_password_field')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('operator_web_signin_submit')),
          findsOneWidget,
        );
        // Invitee guidance points at the reset email, not a magic link.
        expect(
          find.byKey(const Key('operator_web_signin_invite_hint')),
          findsOneWidget,
        );
        // No magic-link / onboarding-step affordances remain.
        expect(
          find.byKey(const Key('operator_web_welcome_token_field')),
          findsNothing,
        );
      },
    );

    testWidgets('email/password sign-in reaches the completed shell with no '
        'magic-link / ToS step in between (invited-operator path)', (
      tester,
    ) async {
      await sizeViewport(tester);
      final source = DemoOperatorWebAuthSource.signedOut();
      addTearDown(source.dispose);

      await tester.pumpWidget(wrap(OperatorWebRouter(source: source)));

      await tester.enterText(
        find.byKey(const Key('operator_web_signin_email_field')),
        'invited.operator@forgeflow.test',
      );
      await tester.enterText(
        find.byKey(const Key('operator_web_signin_password_field')),
        'set-via-firebase-reset-email',
      );
      await tester.tap(find.byKey(const Key('operator_web_signin_submit')));
      await tester.pumpAndSettle();

      // Lands directly on the post-sign-in shell — no welcome, no
      // set-password, no onboarding-MFA, no ToS surface.
      expect(
        find.byKey(const Key('operator_web_shell_scaffold')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_welcome_token_field')),
        findsNothing,
      );
    });

    testWidgets(
      'completed state renders the post-onboarding shell with Account body',
      (tester) async {
        await sizeViewport(tester);
        final source = DemoOperatorWebAuthSource.completed();
        addTearDown(source.dispose);

        await tester.pumpWidget(wrap(OperatorWebRouter(source: source)));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('operator_web_shell_scaffold')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('operator_web_header_bar')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('operator_web_management_scope_picker')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('operator_web_side_nav')), findsOneWidget);
        expect(
          find.byKey(const Key('operator_web_nav_item_account')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('operator_web_nav_item_schedule')),
            matching: find.text('Plan'),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('operator_web_nav_item_business_setup')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('operator_web_nav_item_vendor_connections')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('operator_web_nav_group_business')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('operator_web_nav_group_people')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('operator_web_nav_group_access')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('operator_web_nav_group_data_integrations')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('operator_web_nav_item_roles')),
            matching: find.byIcon(Icons.admin_panel_settings_outlined),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('operator_web_nav_item_security')),
          findsNothing,
        );
        // Wave 2 OW-4 — the default management scope is the operator's
        // primary location, so the Locations CRUD nav row is hidden on
        // first paint. The next test in this group flips the picker to
        // "All locations" and asserts the row reappears.
        expect(
          find.byKey(const Key('operator_web_nav_item_locations')),
          findsNothing,
        );
        final navOrder = [
          'account',
          'business_setup',
          'my_account',
          'members',
          'roles',
          'sessions',
          'audit_log',
          'vendor_connections',
          'data_accuracy',
        ];
        var previousY = -1.0;
        for (final navId in navOrder) {
          final y = tester
              .getTopLeft(find.byKey(Key('operator_web_nav_item_$navId')))
              .dy;
          expect(
            y,
            greaterThan(previousY),
            reason: '$navId should follow the UX task-based nav order',
          );
          previousY = y;
        }
        // Default body is the real Account screen (11W.7).
        expect(
          find.byKey(const Key('operator_web_account_screen')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('operator_web_vendor_connections_screen')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'Wave 2 OW-4 — Locations nav row is hidden at location scope and '
      'reappears at business scope',
      (tester) async {
        await sizeViewport(tester);
        final source = DemoOperatorWebAuthSource.completed();
        addTearDown(source.dispose);

        await tester.pumpWidget(wrap(OperatorWebRouter(source: source)));
        await tester.pumpAndSettle();

        // Default scope is the operator's primary location: the
        // Locations CRUD row is hidden so the side nav doesn't offer
        // an admin-of-the-tree affordance from inside a single leaf.
        expect(
          find.byKey(const Key('operator_web_nav_item_locations')),
          findsNothing,
        );

        // Flip the management scope to "All locations" (business scope).
        await tester.tap(
          find.byKey(const Key('operator_web_management_scope_picker')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('All locations').last);
        await tester.pumpAndSettle();

        // The Locations CRUD row is now mounted under the Business group.
        expect(
          find.byKey(const Key('operator_web_nav_item_locations')),
          findsOneWidget,
        );

        // Flip back to a specific location; the row hides again.
        await tester.tap(
          find.byKey(const Key('operator_web_management_scope_picker')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Downtown').last);
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('operator_web_nav_item_locations')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'Wave 2 OW-4 — selecting Locations then narrowing to location scope '
      'snaps the body back to the default nav',
      (tester) async {
        await sizeViewport(tester);
        final source = DemoOperatorWebAuthSource.completed();
        addTearDown(source.dispose);

        await tester.pumpWidget(wrap(OperatorWebRouter(source: source)));
        await tester.pumpAndSettle();

        // Widen scope to business so the Locations row is mounted.
        await tester.tap(
          find.byKey(const Key('operator_web_management_scope_picker')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('All locations').last);
        await tester.pumpAndSettle();

        // Tap into the Locations CRUD body.
        await tester.tap(
          find.byKey(const Key('operator_web_nav_item_locations')),
        );
        await tester.pumpAndSettle();

        // Now narrow back to a location. The nav row vanishes and the
        // body must snap to the default (Account) so the operator is
        // never stranded on an orphaned route.
        await tester.tap(
          find.byKey(const Key('operator_web_management_scope_picker')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Downtown').last);
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('operator_web_nav_item_locations')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('operator_web_account_screen')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Wave 2 OW-4 — deep-linking to /locations at location scope renders '
      'the Switch-to-business fail-soft surface',
      (tester) async {
        await sizeViewport(tester);
        final source = DemoOperatorWebAuthSource.completed();
        addTearDown(source.dispose);

        await tester.pumpWidget(
          wrap(
            OperatorWebRouter(
              source: source,
              initialNavId: kOperatorWebNavLocations,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Default scope is location, so the deep link lands on the
        // fail-soft surface rather than the CRUD tree.
        expect(
          find.byKey(const Key('operator_web_locations_requires_business')),
          findsOneWidget,
        );

        // Widen scope to business: the CRUD body mounts.
        await tester.tap(
          find.byKey(const Key('operator_web_management_scope_picker')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('All locations').last);
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('operator_web_locations_requires_business')),
          findsNothing,
        );
      },
    );

    testWidgets('/security deep link opens My account security section', (
      tester,
    ) async {
      await sizeViewport(tester);
      final source = DemoOperatorWebAuthSource.completed();
      addTearDown(source.dispose);

      await tester.pumpWidget(
        wrap(
          OperatorWebRouter(
            source: source,
            initialUri: Uri.parse('https://app.forgeflow.app/security'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('operator_web_account_screen')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('account_section_security')), findsOneWidget);
      expect(
        find.byKey(const Key('operator_web_security_login_history_section')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_nav_item_security')),
        findsNothing,
      );
    });

    testWidgets(
      '/sign-in-security deep link opens My account security section',
      (tester) async {
        await sizeViewport(tester);
        final source = DemoOperatorWebAuthSource.completed();
        addTearDown(source.dispose);

        await tester.pumpWidget(
          wrap(
            OperatorWebRouter(
              source: source,
              initialUri: Uri.parse(
                'https://app.forgeflow.app/sign-in-security?mode=continue',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('operator_web_account_screen')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('account_section_security')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('operator_web_security_login_history_section')),
          findsOneWidget,
        );
      },
    );

    testWidgets('prior /operator-web/sign-in-security alias opens My account', (
      tester,
    ) async {
      await sizeViewport(tester);
      final source = DemoOperatorWebAuthSource.completed();
      addTearDown(source.dispose);

      await tester.pumpWidget(
        wrap(
          OperatorWebRouter(
            source: source,
            initialUri: Uri.parse(
              'https://app.forgeflow.app/operator-web/sign-in-security',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('operator_web_account_screen')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('account_section_security')), findsOneWidget);
    });

    testWidgets('/my-account#security opens My account security section', (
      tester,
    ) async {
      await sizeViewport(tester);
      final source = DemoOperatorWebAuthSource.completed();
      addTearDown(source.dispose);

      await tester.pumpWidget(
        wrap(
          OperatorWebRouter(
            source: source,
            initialUri: Uri.parse(
              'https://app.forgeflow.app/my-account#security',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('operator_web_account_screen')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('account_section_security')), findsOneWidget);
    });

    testWidgets('/audit-log deep link opens Audit log instead of Account', (
      tester,
    ) async {
      await sizeViewport(tester);
      final source = DemoOperatorWebAuthSource.completed();
      addTearDown(source.dispose);

      await tester.pumpWidget(
        wrap(
          OperatorWebRouter(
            source: source,
            initialUri: Uri.parse('https://app.forgeflow.app/audit-log'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('operator_web_audit_log_screen')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_account_screen')),
        findsNothing,
      );
    });

    testWidgets('My account audit link opens Audit log in-place', (
      tester,
    ) async {
      await sizeViewport(tester);
      final source = DemoOperatorWebAuthSource.completed();
      addTearDown(source.dispose);

      await tester.pumpWidget(wrap(OperatorWebRouter(source: source)));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('operator_web_nav_item_my_account')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('account_section_profile_audit_log_link')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('operator_web_audit_log_screen')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_account_screen')),
        findsNothing,
      );
    });

    testWidgets('/handoff redeems code and routes to returned target', (
      tester,
    ) async {
      await sizeViewport(tester);
      final gateway = _FakeOperatorWebHandoffGateway(
        result: const OperatorWebHandoffRedeemResult(
          userId: 'user-1',
          operatorId: 'operator-1',
          locationId: 'location-1',
          targetPath: '/wage-authority',
        ),
      );
      final source = _HandoffDemoOperatorWebSource(gateway);
      addTearDown(source.dispose);

      await tester.pumpWidget(
        wrap(
          OperatorWebRouter(
            source: source,
            initialUri: Uri.parse(
              'https://app.forgeflow.app/handoff?code=CODE123&nav=my_account',
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(gateway.codes, <String>['CODE123']);
      // Wave 2 S-2 (`debug.md:220`, OW-13c) folded Wage authority under
      // Data accuracy. Legacy `/wage-authority` handoff targets now
      // resolve to the Data accuracy page, and the wage section mounts
      // inside it (key
      // `operator_web_data_accuracy_wage_authority_section`).
      expect(
        find.byKey(const Key('operator_web_data_accuracy_screen')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('operator_web_data_accuracy_wage_authority_section'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_account_screen')),
        findsNothing,
      );
    });

    testWidgets('/handoff missing code fails closed before routing', (
      tester,
    ) async {
      await sizeViewport(tester);
      final gateway = _FakeOperatorWebHandoffGateway(
        result: const OperatorWebHandoffRedeemResult(
          userId: 'user-1',
          operatorId: 'operator-1',
          locationId: 'location-1',
          targetPath: '/wage-authority',
        ),
      );
      final source = _HandoffDemoOperatorWebSource(gateway);
      addTearDown(source.dispose);

      await tester.pumpWidget(
        wrap(
          OperatorWebRouter(
            source: source,
            initialUri: Uri.parse(
              'https://app.forgeflow.app/handoff?nav=roles',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(gateway.codes, isEmpty);
      expect(
        find.byKey(const Key('operator_web_handoff_landing_surface')),
        findsOneWidget,
      );
      expect(
        find.text('This handoff link is missing its code.'),
        findsOneWidget,
      );
    });

    testWidgets('side nav switches body to vendor-connections screen', (
      tester,
    ) async {
      await sizeViewport(tester);
      final source = DemoOperatorWebAuthSource.completed();
      addTearDown(source.dispose);

      await tester.pumpWidget(wrap(OperatorWebRouter(source: source)));

      await tester.tap(
        find.byKey(const Key('operator_web_nav_item_vendor_connections')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('operator_web_vendor_connections_screen')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_account_screen')),
        findsNothing,
      );
    });

    testWidgets('management picker drives location-scoped vendor route', (
      tester,
    ) async {
      await sizeViewport(tester);
      final source = DemoOperatorWebAuthSource.completed();
      addTearDown(source.dispose);

      await tester.pumpWidget(
        wrap(
          OperatorWebRouter(
            source: source,
            initialNavId: kOperatorWebNavVendorConnections,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('operator_web_management_scope_picker')),
      );
      await tester.pump();
      await tester.tap(find.text('Downtown').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(
        find.text('Manage the services connected to Downtown.'),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const Key('operator_web_management_scope_picker')),
      );
      await tester.pump();
      await tester.tap(find.text('All locations').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(
        find.byKey(
          const Key('operator_web_vendor_connections_requires_location'),
        ),
        findsOneWidget,
      );
      expect(find.text('Currently managing: All locations'), findsOneWidget);
    });

    testWidgets('side nav switches body to business setup screen', (
      tester,
    ) async {
      await sizeViewport(tester);
      final source = DemoOperatorWebAuthSource.completed();
      addTearDown(source.dispose);

      await tester.pumpWidget(wrap(OperatorWebRouter(source: source)));

      await tester.tap(
        find.byKey(const Key('operator_web_nav_item_business_setup')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('operator_web_business_setup_screen')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_account_screen')),
        findsNothing,
      );
    });

    testWidgets('initialNavId opens the vendor-connections route directly', (
      tester,
    ) async {
      await sizeViewport(tester);
      final source = DemoOperatorWebAuthSource.completed();
      addTearDown(source.dispose);

      await tester.pumpWidget(
        wrap(
          OperatorWebRouter(
            source: source,
            initialNavId: kOperatorWebNavVendorConnections,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('operator_web_vendor_connections_screen')),
        findsOneWidget,
      );
    });

    testWidgets('initialNavId opens the business setup route directly', (
      tester,
    ) async {
      await sizeViewport(tester);
      final source = DemoOperatorWebAuthSource.completed();
      addTearDown(source.dispose);

      await tester.pumpWidget(
        wrap(
          OperatorWebRouter(
            source: source,
            initialNavId: kOperatorWebNavBusinessSetup,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('operator_web_business_setup_screen')),
        findsOneWidget,
      );
    });

    testWidgets('standard demo Business setup edit opens the timing editor', (
      tester,
    ) async {
      await sizeViewport(tester);
      final writeGateway = DemoOperatorWebBusinessTimingWriteGateway();
      final source = _BusinessTimingHierarchyOperatorWebSource(writeGateway);
      addTearDown(source.dispose);

      await tester.pumpWidget(
        wrap(
          OperatorWebRouter(
            source: source,
            initialNavId: kOperatorWebNavBusinessSetup,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('operator_web_business_setup_screen')),
        findsOneWidget,
      );
      expect(find.text('Live editor'), findsOneWidget);
      expect(
        find.byKey(const Key('operator_web_business_timing_safe_dialog')),
        findsNothing,
      );

      await tester.ensureVisible(
        find.byKey(const Key('operator_web_business_timing_edit_button')),
      );
      await tester.tap(
        find.byKey(const Key('operator_web_business_timing_edit_button')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('operator_web_business_timing_editor_screen')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_business_timing_safe_dialog')),
        findsNothing,
      );
    });

    testWidgets('standard demo Schedule timing opens schedule mode editor', (
      tester,
    ) async {
      await sizeViewport(tester);
      final writeGateway = DemoOperatorWebBusinessTimingWriteGateway();
      final source = _BusinessTimingHierarchyOperatorWebSource(writeGateway);
      addTearDown(source.dispose);

      await tester.pumpWidget(
        wrap(
          OperatorWebRouter(
            source: source,
            initialNavId: kOperatorWebNavBusinessSetup,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const Key('operator_web_business_timing_schedule_button')),
      );
      await tester.tap(
        find.byKey(const Key('operator_web_business_timing_schedule_button')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('operator_web_business_timing_editor_screen')),
        findsOneWidget,
      );
      expect(find.text('Schedule timing change'), findsNWidgets(2));
      expect(
        find.byKey(const Key('operator_web_business_timing_safe_dialog')),
        findsNothing,
      );
    });

    testWidgets('org-unit management scope opens editor and writes org_unit', (
      tester,
    ) async {
      await sizeViewport(tester);
      final writeGateway = _CapturingBusinessTimingGateway();
      final source = _BusinessTimingHierarchyOperatorWebSource(writeGateway);
      addTearDown(source.dispose);

      await tester.pumpWidget(
        wrap(
          OperatorWebRouter(
            source: source,
            initialNavId: kOperatorWebNavBusinessSetup,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('operator_web_management_scope_picker')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('East Region').last);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('operator_web_business_timing_editor_screen')),
        findsOneWidget,
      );
      expect(find.textContaining('East Region'), findsWidgets);

      await tester.ensureVisible(
        find.byKey(const Key('operator_web_business_timing_editor_save')),
      );
      await tester.tap(
        find.byKey(const Key('operator_web_business_timing_editor_save')),
      );
      await tester.pumpAndSettle();

      expect(writeGateway.creates, hasLength(1));
      expect(writeGateway.creates.single.scopeKind, 'org_unit');
      expect(writeGateway.creates.single.scopeId, 'demo-org-east');
    });

    testWidgets('forbidden state renders the fail-closed surface', (
      tester,
    ) async {
      await sizeViewport(tester);
      final source = DemoOperatorWebAuthSource.forbidden();
      addTearDown(source.dispose);

      await tester.pumpWidget(wrap(OperatorWebRouter(source: source)));

      expect(
        find.byKey(const Key('operator_web_forbidden_card')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_forbidden_signout')),
        findsOneWidget,
      );
    });

    testWidgets('header sign-out routes through the auth source', (
      tester,
    ) async {
      await sizeViewport(tester);
      final source = DemoOperatorWebAuthSource.completed();
      addTearDown(source.dispose);

      await tester.pumpWidget(wrap(OperatorWebRouter(source: source)));

      expect(source.current, isA<OperatorWebCompleted>());

      await tester.tap(find.byKey(const Key('operator_web_header_signout')));
      await tester.pumpAndSettle();

      expect(source.current, isA<OperatorWebSignedOut>());
      // G24/G3 S3′: after sign-out the sign-in screen reappears
      // (no welcome / magic-link screen).
      expect(
        find.byKey(const Key('operator_web_signin_email_field')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_welcome_token_field')),
        findsNothing,
      );
    });

    testWidgets('forbidden surface sign-out also routes through the source', (
      tester,
    ) async {
      await sizeViewport(tester);
      final source = DemoOperatorWebAuthSource.forbidden();
      addTearDown(source.dispose);

      await tester.pumpWidget(wrap(OperatorWebRouter(source: source)));

      await tester.tap(find.byKey(const Key('operator_web_forbidden_signout')));
      await tester.pumpAndSettle();

      expect(source.current, isA<OperatorWebSignedOut>());
    });
  });

  // G62 + G19 — a live source missing a gateway mixin must fail loud
  // (honest "unavailable — wiring error" surface) instead of silently
  // serving in-memory fixtures; the demo source must show a persistent
  // demo banner; a fully-wired live source must render normally with
  // no banner.
  group('OperatorWebRouter G62 fail-loud + G19 demo banner', () {
    testWidgets(
      'demo source: persistent demo banner shown + fixtures still served',
      (tester) async {
        await sizeViewport(tester);
        final source = DemoOperatorWebAuthSource.completed();
        addTearDown(source.dispose);

        await tester.pumpWidget(wrap(OperatorWebRouter(source: source)));
        await tester.pumpAndSettle();

        // G19 — demo banner present in the shell.
        expect(
          find.byKey(const Key('operator_web_demo_banner')),
          findsOneWidget,
        );

        // Navigate to Members (a fixture-substituting surface).
        await tester.tap(
          find.byKey(const Key('operator_web_nav_item_members')),
        );
        await tester.pumpAndSettle();

        // Fixtures still served — the demo Members screen renders, NOT
        // the wiring-error surface.
        expect(
          find.byKey(const Key('operator_web_members_screen')),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const Key('operator_web_surface_wiring_error_team_members'),
          ),
          findsNothing,
        );
        // Banner persists across navigation.
        expect(
          find.byKey(const Key('operator_web_demo_banner')),
          findsOneWidget,
        );

        // OW-G70 — the 4 newly-guarded commerce-critical routes must
        // STILL serve their demo fixtures for the demo source (the
        // `_isDemoAuthSource` short-circuit inside
        // `_liveSurfaceMissingGateway` keeps the demo path
        // byte-unchanged: no false fail-loud for demo). The demo
        // session pins `demo-location`, so each route lands directly
        // in location scope and renders its screen body.
        await tester.tap(
          find.byKey(const Key('operator_web_nav_item_vendor_connections')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('operator_web_vendor_connections_screen')),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const Key('operator_web_surface_wiring_error_vendor_connections'),
          ),
          findsNothing,
        );

        await tester.tap(
          find.byKey(const Key('operator_web_nav_item_data_accuracy')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('operator_web_data_accuracy_screen')),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const Key('operator_web_surface_wiring_error_data_accuracy'),
          ),
          findsNothing,
        );

        await tester.tap(
          find.byKey(const Key('operator_web_nav_item_schedule')),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('schedule_screen')), findsOneWidget);
        expect(
          find.byKey(const Key('operator_web_surface_wiring_error_schedule')),
          findsNothing,
        );

        // Wage authority has no nav row (folded under Data accuracy,
        // Wave 2 S-2); drive it via the deep-link nav id.
        expect(
          find.byKey(const Key('operator_web_demo_banner')),
          findsOneWidget,
        );
      },
    );

    // OW-G73 — removed three OW-G70 tests that injected the deleted
    // `kOperatorWebNavWageAuthority` constant directly to exercise the
    // standalone Wage authority router case. That case + constant were
    // dead (Wave 2 S-2 folded Wage authority under Data accuracy;
    // `_navIdFromRaw` redirects `wage_authority` deep links to Data
    // accuracy, so no production entry point could select it). The
    // legacy `/wage-authority` handoff redirect is covered by the
    // "/handoff ... Wave 2 S-2" test above (Data accuracy mounts with
    // the embedded `operator_web_data_accuracy_wage_authority_section`),
    // and the live fail-loud guard is covered by the Data accuracy
    // wiring-error tests below.

    testWidgets('live source missing the team-users mixin: honest wiring-error '
        'surface, NOT fixtures, NO demo banner', (tester) async {
      await sizeViewport(tester);
      final source = _LiveUnwiredOperatorWebSource();
      addTearDown(source.dispose);

      await tester.pumpWidget(wrap(OperatorWebRouter(source: source)));
      await tester.pumpAndSettle();

      // G19 — no demo banner for a live source.
      expect(find.byKey(const Key('operator_web_demo_banner')), findsNothing);

      await tester.tap(find.byKey(const Key('operator_web_nav_item_members')));
      await tester.pumpAndSettle();

      // G62 — fail loud: the honest wiring-error surface, NOT the
      // in-memory demo fixtures.
      expect(
        find.byKey(const Key('operator_web_surface_wiring_error_team_members')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_members_screen')),
        findsNothing,
      );
      expect(find.byKey(const Key('operator_web_demo_banner')), findsNothing);
    });

    testWidgets(
      'fully-wired live source: real gateway renders Members, NO banner, '
      'NO wiring-error surface',
      (tester) async {
        await sizeViewport(tester);
        final source = _LiveWiredOperatorWebSource(DemoWebTeamUsersGateway());
        addTearDown(source.dispose);

        await tester.pumpWidget(wrap(OperatorWebRouter(source: source)));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('operator_web_demo_banner')), findsNothing);

        await tester.tap(
          find.byKey(const Key('operator_web_nav_item_members')),
        );
        await tester.pumpAndSettle();

        // Live provider present → normal screen, no fail-loud surface.
        expect(
          find.byKey(
            const Key('operator_web_surface_wiring_error_team_members'),
          ),
          findsNothing,
        );
        expect(
          find.byKey(const Key('operator_web_members_screen')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('operator_web_demo_banner')), findsNothing);
      },
    );

    // BLOCKER fix (PR #857 re-audit) — the Audit-Log fail-loud guard
    // must NOT require `OperatorWebAuditLogHierarchyGatewayProvider`.
    // That provider is a sanctioned deferred follow-up: the production
    // `FirebaseOperatorWebAuthSource` mixes the team audit-log + team
    // hierarchy gateways but intentionally does NOT yet mix the
    // hierarchy-FILTER gateway provider (router :1386-1401 +
    // `operator_web_team_gateway_providers.dart:52-54` document the
    // in-memory fallback). A live source shaped like production must
    // therefore render the real Audit Log screen — not a false
    // positive wiring error and not the demo banner.
    testWidgets(
      'live source with team audit-log + team hierarchy mixins but NOT '
      'the hierarchy-filter provider: real Audit Log screen renders, '
      'NOT the wiring-error surface, NO demo banner',
      (tester) async {
        await sizeViewport(tester);
        final source = _LiveAuditLogWiredOperatorWebSource(
          teamAuditLogGateway: DemoWebTeamAuditLogGateway(),
          teamHierarchyGateway: DemoWebTeamHierarchyGateway(),
        );
        addTearDown(source.dispose);

        await tester.pumpWidget(wrap(OperatorWebRouter(source: source)));
        await tester.pumpAndSettle();

        // G19 — no demo banner for a live source.
        expect(find.byKey(const Key('operator_web_demo_banner')), findsNothing);

        await tester.tap(
          find.byKey(const Key('operator_web_nav_item_audit_log')),
        );
        await tester.pumpAndSettle();

        // The real Audit Log screen renders (hierarchy-filter gateway
        // falls back to InMemoryWebAuditLogHierarchyGateway — sanctioned
        // deferred follow-up, NOT a wiring regression).
        expect(
          find.byKey(const Key('operator_web_audit_log_screen')),
          findsOneWidget,
        );
        // NOT the fail-loud wiring-error surface.
        expect(
          find.byKey(const Key('operator_web_surface_wiring_error_audit_log')),
          findsNothing,
        );
        // Still no demo banner — this is a live source.
        expect(find.byKey(const Key('operator_web_demo_banner')), findsNothing);
      },
    );

    // OW-G70 — extend the #857 G62 fail-loud guard to the 4
    // commerce-critical routes that #857 left uncovered (Vendor
    // connections, Data accuracy, Wage authority, Schedule). For each:
    //   (a) live source missing the genuinely-live provider ⇒ honest
    //       wiring-error surface, NOT silent fixtures, NO demo banner;
    //   (b) fully-wired live source ⇒ real screen, no wiring error,
    //       no demo banner.
    // The demo-source "fixtures still served" assertions live in the
    // demo-banner tests above.

    testWidgets('OW-G70 — live source missing the vendor-connections mixin: '
        'honest wiring-error surface, NOT fixtures, NO demo banner', (
      tester,
    ) async {
      await sizeViewport(tester);
      final source = _LiveUnwiredOperatorWebSource();
      addTearDown(source.dispose);

      await tester.pumpWidget(
        wrap(
          OperatorWebRouter(
            source: source,
            initialNavId: kOperatorWebNavVendorConnections,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(
          const Key('operator_web_surface_wiring_error_vendor_connections'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_vendor_connections_screen')),
        findsNothing,
      );
      expect(find.byKey(const Key('operator_web_demo_banner')), findsNothing);
    });

    testWidgets('OW-G70 — fully-wired live source: real Vendor connections '
        'screen renders, NO wiring error, NO demo banner', (tester) async {
      await sizeViewport(tester);
      final source = _LiveVendorConnectionsWiredOperatorWebSource(
        OperatorWebDemoVendorConnectionsFixture.gateway(),
      );
      addTearDown(source.dispose);

      await tester.pumpWidget(
        wrap(
          OperatorWebRouter(
            source: source,
            initialNavId: kOperatorWebNavVendorConnections,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('operator_web_vendor_connections_screen')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('operator_web_surface_wiring_error_vendor_connections'),
        ),
        findsNothing,
      );
      expect(find.byKey(const Key('operator_web_demo_banner')), findsNothing);
    });

    testWidgets('OW-G70 — live source missing the data-accuracy mixin: honest '
        'wiring-error surface, NOT fixtures, NO demo banner', (tester) async {
      await sizeViewport(tester);
      final source = _LiveUnwiredOperatorWebSource();
      addTearDown(source.dispose);

      await tester.pumpWidget(
        wrap(
          OperatorWebRouter(
            source: source,
            initialNavId: kOperatorWebNavDataAccuracy,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(
          const Key('operator_web_surface_wiring_error_data_accuracy'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_data_accuracy_screen')),
        findsNothing,
      );
      expect(find.byKey(const Key('operator_web_demo_banner')), findsNothing);
    });

    testWidgets(
      'OW-G70 — live source with data-accuracy gateway but MISSING the '
      'vendor-applicability mixin: still fails loud (both genuinely-'
      'live providers required)',
      (tester) async {
        await sizeViewport(tester);
        // Only the data-accuracy provider is mixed in; the production
        // source genuinely mixes BOTH, so a half-wired live source is
        // still a wiring regression.
        final source = _LiveDataAccuracyOnlyOperatorWebSource(
          _StubDataAccuracyGateway(),
        );
        addTearDown(source.dispose);

        await tester.pumpWidget(
          wrap(
            OperatorWebRouter(
              source: source,
              initialNavId: kOperatorWebNavDataAccuracy,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(
            const Key('operator_web_surface_wiring_error_data_accuracy'),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('operator_web_data_accuracy_screen')),
          findsNothing,
        );
      },
    );

    testWidgets('OW-G70 - live source missing the business-timing mixin: still '
        'fails loud because Data accuracy needs the current business date', (
      tester,
    ) async {
      await sizeViewport(tester);
      final source = _LiveDataAccuracyNoTimingOperatorWebSource(
        dataAccuracyGateway: _StubDataAccuracyGateway(),
        vendorApplicabilityGateway: _StubVendorApplicabilityGateway(),
      );
      addTearDown(source.dispose);

      await tester.pumpWidget(
        wrap(
          OperatorWebRouter(
            source: source,
            initialNavId: kOperatorWebNavDataAccuracy,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(
          const Key('operator_web_surface_wiring_error_data_accuracy'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_data_accuracy_screen')),
        findsNothing,
      );
    });

    testWidgets(
      'Data accuracy uses Business Timing for default business date',
      (tester) async {
        await sizeViewport(tester);
        final source = _LiveDataAccuracyWiredOperatorWebSource(
          dataAccuracyGateway: _StubDataAccuracyGateway(),
          vendorApplicabilityGateway: _StubVendorApplicabilityGateway(),
        );
        addTearDown(source.dispose);

        await tester.pumpWidget(
          wrap(
            OperatorWebRouter(
              source: source,
              initialNavId: kOperatorWebNavDataAccuracy,
              nowUtc: () => DateTime.utc(2026, 5, 13, 8, 15),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final addButton = find.byKey(kKeyedServicePeriodAccuracyAddButtonKey);
        await tester.ensureVisible(addButton);
        await tester.pumpAndSettle();
        await tester.tap(addButton, warnIfMissed: false);
        await tester.pumpAndSettle();

        final dateField = tester.widget<TextField>(
          find.byKey(kKeyedServicePeriodAccuracyEffectiveDateFieldKey),
        );
        expect(dateField.controller!.text, '2026-05-12');
        expect(find.text('Breakfast (breakfast)'), findsOneWidget);
      },
    );

    testWidgets('OW-G70 — fully-wired live source (data-accuracy + vendor-'
        'applicability): real Data accuracy screen, NO wiring error, '
        'NO demo banner', (tester) async {
      await sizeViewport(tester);
      final source = _LiveDataAccuracyWiredOperatorWebSource(
        dataAccuracyGateway: _StubDataAccuracyGateway(),
        vendorApplicabilityGateway: _StubVendorApplicabilityGateway(),
      );
      addTearDown(source.dispose);

      await tester.pumpWidget(
        wrap(
          OperatorWebRouter(
            source: source,
            initialNavId: kOperatorWebNavDataAccuracy,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('operator_web_data_accuracy_screen')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('operator_web_surface_wiring_error_data_accuracy'),
        ),
        findsNothing,
      );
      expect(find.byKey(const Key('operator_web_demo_banner')), findsNothing);
    });

    // OW-G73 — removed the two remaining OW-G70 tests that injected the
    // deleted `kOperatorWebNavWageAuthority` constant to exercise the
    // standalone Wage authority router case (live-unwired wiring error
    // and fully-wired screen mount). The case + constant were dead;
    // the live fail-loud guard now lives on the Data accuracy case and
    // is covered by the Data accuracy wiring-error tests above. The
    // now-unused `_LiveWageAuthorityWiredOperatorWebSource` helper was
    // removed with them.

    testWidgets('OW-G70 — live source missing the schedule mixin: honest '
        'wiring-error surface, NOT fixtures, NO demo banner', (tester) async {
      await sizeViewport(tester);
      final source = _LiveUnwiredOperatorWebSource();
      addTearDown(source.dispose);

      await tester.pumpWidget(
        wrap(
          OperatorWebRouter(
            source: source,
            initialNavId: kOperatorWebNavSchedule,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('operator_web_surface_wiring_error_schedule')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('schedule_screen')), findsNothing);
      expect(find.byKey(const Key('operator_web_demo_banner')), findsNothing);
    });

    testWidgets('OW-G70 — fully-wired live source: real Schedule screen, NO '
        'wiring error, NO demo banner', (tester) async {
      await sizeViewport(tester);
      final source = _LiveScheduleWiredOperatorWebSource(
        OperatorWebDemoScheduleGateway(),
      );
      addTearDown(source.dispose);

      await tester.pumpWidget(
        wrap(
          OperatorWebRouter(
            source: source,
            initialNavId: kOperatorWebNavSchedule,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('schedule_screen')), findsOneWidget);
      expect(
        find.byKey(const Key('operator_web_surface_wiring_error_schedule')),
        findsNothing,
      );
      expect(find.byKey(const Key('operator_web_demo_banner')), findsNothing);
    });
  });
}

/// G62 test double — a *live* auth source (does NOT extend
/// [DemoOperatorWebAuthSource]) that completed sign-in but mixes in NO
/// gateway providers. Models a live wiring regression where a provider
/// mixin was dropped from [FirebaseOperatorWebAuthSource]. The router
/// must fail loud here, not substitute fixtures.
class _LiveUnwiredOperatorWebSource extends OperatorWebAuthSource {
  _LiveUnwiredOperatorWebSource() {
    _controller.add(_state);
  }

  final _controller = StreamController<OperatorWebAuthState>.broadcast();
  final OperatorWebAuthState _state = const OperatorWebCompleted(
    session: kDemoOperatorWebSession,
  );

  @override
  Stream<OperatorWebAuthState> get stream => _controller.stream;

  @override
  OperatorWebAuthState get current => _state;

  @override
  Future<void> signOut() async {}

  @override
  void dispose() {
    _controller.close();
  }
}

/// G62 test double — a *live* auth source with the team-users gateway
/// provider correctly mixed in. Models the fully-wired live path; the
/// router must render the real screen with no demo banner and no
/// fail-loud surface.
class _LiveWiredOperatorWebSource extends OperatorWebAuthSource
    implements OperatorWebTeamUsersGatewayProvider {
  _LiveWiredOperatorWebSource(this.teamUsersGateway) {
    _controller.add(_state);
  }

  final _controller = StreamController<OperatorWebAuthState>.broadcast();
  final OperatorWebAuthState _state = const OperatorWebCompleted(
    session: kDemoOperatorWebSession,
  );

  @override
  final WebTeamUsersGateway teamUsersGateway;

  @override
  Stream<OperatorWebAuthState> get stream => _controller.stream;

  @override
  OperatorWebAuthState get current => _state;

  @override
  Future<void> signOut() async {}

  @override
  void dispose() {
    _controller.close();
  }
}

/// BLOCKER-fix test double (PR #857) — a *live* auth source shaped
/// like the production `FirebaseOperatorWebAuthSource`: it mixes the
/// two genuinely-live-wired Audit-Log providers (team audit-log + team
/// hierarchy) but intentionally does NOT mix
/// `OperatorWebAuditLogHierarchyGatewayProvider` (the hierarchy-FILTER
/// gateway is a sanctioned deferred follow-up that falls back to the
/// in-memory gateway). The router must render the real Audit Log
/// screen here — fail-loud must NOT trigger on the deferred provider.
class _LiveAuditLogWiredOperatorWebSource extends OperatorWebAuthSource
    implements
        OperatorWebTeamAuditLogGatewayProvider,
        OperatorWebTeamHierarchyGatewayProvider {
  _LiveAuditLogWiredOperatorWebSource({
    required this.teamAuditLogGateway,
    required this.teamHierarchyGateway,
  }) {
    _controller.add(_state);
  }

  final _controller = StreamController<OperatorWebAuthState>.broadcast();
  final OperatorWebAuthState _state = const OperatorWebCompleted(
    session: kDemoOperatorWebSession,
  );

  @override
  final WebTeamAuditLogGateway teamAuditLogGateway;

  @override
  final WebTeamHierarchyGateway teamHierarchyGateway;

  @override
  Stream<OperatorWebAuthState> get stream => _controller.stream;

  @override
  OperatorWebAuthState get current => _state;

  @override
  Future<void> signOut() async {}

  @override
  void dispose() {
    _controller.close();
  }
}

class _HandoffDemoOperatorWebSource extends DemoOperatorWebAuthSource
    implements OperatorWebHandoffRedeemGatewayProvider {
  _HandoffDemoOperatorWebSource(this.handoffRedeemGateway)
    : super(initial: OperatorWebCompleted(session: kDemoOperatorWebSession));

  @override
  final OperatorWebHandoffRedeemGateway handoffRedeemGateway;
}

class _FakeOperatorWebHandoffGateway
    implements OperatorWebHandoffRedeemGateway {
  _FakeOperatorWebHandoffGateway({required this.result});

  final OperatorWebHandoffRedeemResult result;
  final List<String> codes = <String>[];

  @override
  Future<OperatorWebHandoffRedeemResult> redeemHandoffCode({
    required String code,
  }) async {
    codes.add(code);
    return result;
  }
}

// ---------------------------------------------------------------------------
// OW-G70 test doubles — *live* auth sources (do NOT extend
// `DemoOperatorWebAuthSource`) shaped like production
// `FirebaseOperatorWebAuthSource` for the 4 commerce-critical routes.
// `_LiveUnwiredOperatorWebSource` (defined above) models the wiring
// regression (no provider mixin) → the router must fail loud. The
// `*Wired*` doubles below mix the genuinely-live provider(s) the
// production source carries → the router must render the real screen.
// ---------------------------------------------------------------------------

/// Fully-wired live source for the Vendor connections route — mixes
/// `OperatorWebVendorConnectionsGatewayProvider`, exactly as the
/// production `FirebaseOperatorWebAuthSource` does.
class _LiveVendorConnectionsWiredOperatorWebSource extends OperatorWebAuthSource
    implements OperatorWebVendorConnectionsGatewayProvider {
  _LiveVendorConnectionsWiredOperatorWebSource(this.vendorConnectionsGateway) {
    _controller.add(_state);
  }

  final _controller = StreamController<OperatorWebAuthState>.broadcast();
  final OperatorWebAuthState _state = const OperatorWebCompleted(
    session: kDemoOperatorWebSession,
  );

  @override
  final VendorConnectionsGateway? vendorConnectionsGateway;

  @override
  Stream<OperatorWebAuthState> get stream => _controller.stream;

  @override
  OperatorWebAuthState get current => _state;

  @override
  Future<void> signOut() async {}

  @override
  void dispose() {
    _controller.close();
  }
}

/// Live source for the Data accuracy route that mixes ONLY
/// `OperatorWebDataAccuracyGatewayProvider` — NOT
/// `OperatorWebVendorApplicabilityGatewayProvider`. The production
/// source genuinely mixes BOTH, so this half-wired shape is still a
/// wiring regression and must fail loud.
class _LiveDataAccuracyOnlyOperatorWebSource extends OperatorWebAuthSource
    implements OperatorWebDataAccuracyGatewayProvider {
  _LiveDataAccuracyOnlyOperatorWebSource(this.dataAccuracyGateway) {
    _controller.add(_state);
  }

  final _controller = StreamController<OperatorWebAuthState>.broadcast();
  final OperatorWebAuthState _state = const OperatorWebCompleted(
    session: kDemoOperatorWebSession,
  );

  @override
  final OperatorWebDataAccuracyGateway dataAccuracyGateway;

  @override
  Stream<OperatorWebAuthState> get stream => _controller.stream;

  @override
  OperatorWebAuthState get current => _state;

  @override
  Future<void> signOut() async {}

  @override
  void dispose() {
    _controller.close();
  }
}

/// Fully-wired live source for the Data accuracy route — mixes BOTH
/// `OperatorWebDataAccuracyGatewayProvider` and
/// `OperatorWebVendorApplicabilityGatewayProvider`, exactly the two
/// genuinely-live providers the production source carries for this
/// surface. The embedded Wage Authority section is deliberately NOT
/// gated here (it has a sanctioned demo fallback), so this fully-wired
/// shape renders the real screen.
class _LiveDataAccuracyNoTimingOperatorWebSource extends OperatorWebAuthSource
    implements
        OperatorWebDataAccuracyGatewayProvider,
        OperatorWebVendorApplicabilityGatewayProvider {
  _LiveDataAccuracyNoTimingOperatorWebSource({
    required this.dataAccuracyGateway,
    required this.vendorApplicabilityGateway,
  }) {
    _controller.add(_state);
  }

  final _controller = StreamController<OperatorWebAuthState>.broadcast();
  final OperatorWebAuthState _state = const OperatorWebCompleted(
    session: kDemoOperatorWebSession,
  );

  @override
  final OperatorWebDataAccuracyGateway dataAccuracyGateway;

  @override
  final WebVendorApplicabilityGateway vendorApplicabilityGateway;

  @override
  Stream<OperatorWebAuthState> get stream => _controller.stream;

  @override
  OperatorWebAuthState get current => _state;

  @override
  Future<void> signOut() async {}

  @override
  void dispose() {
    _controller.close();
  }
}

class _LiveDataAccuracyWiredOperatorWebSource extends OperatorWebAuthSource
    implements
        OperatorWebDataAccuracyGatewayProvider,
        OperatorWebVendorApplicabilityGatewayProvider,
        OperatorWebBusinessTimingWriteGatewayProvider {
  _LiveDataAccuracyWiredOperatorWebSource({
    required this.dataAccuracyGateway,
    required this.vendorApplicabilityGateway,
    WebBusinessTimingGateway? businessTimingWriteGateway,
  }) : businessTimingWriteGateway =
           businessTimingWriteGateway ?? const _StubBusinessTimingGateway() {
    _controller.add(_state);
  }

  final _controller = StreamController<OperatorWebAuthState>.broadcast();
  final OperatorWebAuthState _state = const OperatorWebCompleted(
    session: kDemoOperatorWebSession,
  );

  @override
  final OperatorWebDataAccuracyGateway dataAccuracyGateway;

  @override
  final WebVendorApplicabilityGateway vendorApplicabilityGateway;

  @override
  final WebBusinessTimingGateway businessTimingWriteGateway;

  @override
  Stream<OperatorWebAuthState> get stream => _controller.stream;

  @override
  OperatorWebAuthState get current => _state;

  @override
  Future<void> signOut() async {}

  @override
  void dispose() {
    _controller.close();
  }
}

/// Fully-wired source for Business Timing plus hierarchy context.
class _BusinessTimingHierarchyOperatorWebSource extends OperatorWebAuthSource
    implements
        OperatorWebBusinessTimingGatewayProvider,
        OperatorWebBusinessTimingWriteGatewayProvider,
        OperatorWebTeamHierarchyGatewayProvider {
  _BusinessTimingHierarchyOperatorWebSource(
    this.businessTimingWriteGateway, {
    BusinessTimingGateway? businessTimingGateway,
  }) : businessTimingGateway =
           businessTimingGateway ??
           HttpBusinessTimingReadGateway(gateway: businessTimingWriteGateway) {
    _controller.add(_state);
  }

  final _controller = StreamController<OperatorWebAuthState>.broadcast();
  final OperatorWebAuthState _state = const OperatorWebCompleted(
    session: kDemoOperatorWebSession,
  );

  @override
  final BusinessTimingGateway businessTimingGateway;

  @override
  final WebBusinessTimingGateway businessTimingWriteGateway;

  @override
  final WebTeamHierarchyGateway teamHierarchyGateway =
      DemoWebTeamHierarchyGateway();

  @override
  Stream<OperatorWebAuthState> get stream => _controller.stream;

  @override
  OperatorWebAuthState get current => _state;

  @override
  Future<void> signOut() async {}

  @override
  void dispose() {
    _controller.close();
  }
}

/// Fully-wired live source for the Schedule route — mixes
/// `OperatorWebScheduleGatewayProvider`, exactly as the production
/// `FirebaseOperatorWebAuthSource` does.
class _LiveScheduleWiredOperatorWebSource extends OperatorWebAuthSource
    implements OperatorWebScheduleGatewayProvider {
  _LiveScheduleWiredOperatorWebSource(this.scheduleGateway) {
    _controller.add(_state);
  }

  final _controller = StreamController<OperatorWebAuthState>.broadcast();
  final OperatorWebAuthState _state = const OperatorWebCompleted(
    session: kDemoOperatorWebSession,
  );

  @override
  final OperatorWebScheduleGateway? scheduleGateway;

  @override
  Stream<OperatorWebAuthState> get stream => _controller.stream;

  @override
  OperatorWebAuthState get current => _state;

  @override
  Future<void> signOut() async {}

  @override
  void dispose() {
    _controller.close();
  }
}

/// Minimal stub for the data-accuracy gateway: unconfigured location
/// (null settings, empty keyed rows). The screen renders honest
/// "not configured yet" state — enough for the router to mount the
/// real `operator_web_data_accuracy_screen`.
class _StubDataAccuracyGateway implements OperatorWebDataAccuracyGateway {
  @override
  Future<DataAccuracySettings?> loadSettings({
    required String operatorId,
    required String locationId,
  }) async => null;

  @override
  Future<DataAccuracySettings> saveSettings(
    DataAccuracySettings settings,
  ) async => settings;

  @override
  Future<DataAccuracySettings> saveManualCovers({
    required String operatorId,
    required String locationId,
    required String businessDateIso,
    required String servicePeriodKey,
    required int covers,
  }) async => DataAccuracySettings(
    settingId: 'stub-setting',
    operatorId: operatorId,
    locationId: locationId,
    coversSourcePerServicePeriod: const <String, CoversSource>{},
    coversManualEntries: <String, Map<String, int>>{
      businessDateIso: <String, int>{servicePeriodKey: covers},
    },
    wageSource: WageSource.vendor,
    createdAt: DateTime.utc(2026, 5, 16),
    updatedAt: DateTime.utc(2026, 5, 16),
  );

  @override
  Future<DataAccuracySettings> clearManualCovers({
    required String operatorId,
    required String locationId,
    required String businessDateIso,
    required String servicePeriodKey,
  }) async => DataAccuracySettings(
    settingId: 'stub-setting',
    operatorId: operatorId,
    locationId: locationId,
    coversSourcePerServicePeriod: const <String, CoversSource>{},
    coversManualEntries: const <String, Map<String, int>>{},
    wageSource: WageSource.vendor,
    createdAt: DateTime.utc(2026, 5, 16),
    updatedAt: DateTime.utc(2026, 5, 16),
  );

  @override
  Future<List<DataAccuracyServicePeriodSetting>> loadServicePeriodSettings({
    required String operatorId,
    required String locationId,
  }) async => const <DataAccuracyServicePeriodSetting>[];

  @override
  Future<OperatorWebPollingTierSnapshot?> loadPollingTierAssignment({
    required String operatorId,
    required String locationId,
  }) async => null;

  @override
  Future<DataAccuracyServicePeriodSetting> saveServicePeriodSetting({
    required String operatorId,
    required String locationId,
    required String servicePeriodKey,
    required ServicePeriodCoversSource coversSource,
    required ServicePeriodWageSource wageSource,
    required String effectiveAtBusinessDateIso,
  }) async => DataAccuracyServicePeriodSetting(
    id: 'stub-period',
    operatorId: operatorId,
    locationId: locationId,
    servicePeriodKey: servicePeriodKey,
    coversSource: coversSource,
    wageSource: wageSource,
    effectiveAtBusinessDate: effectiveAtBusinessDateIso,
    createdAt: DateTime.utc(2026, 5, 16),
    updatedAt: DateTime.utc(2026, 5, 16),
  );

  @override
  Future<void> resetServicePeriodSetting({
    required String operatorId,
    required String locationId,
    required String servicePeriodKey,
  }) async {}
}

/// Minimal stub for the vendor-applicability gateway — empty rows.
class _StubVendorApplicabilityGateway implements WebVendorApplicabilityGateway {
  @override
  Future<List<WebVendorApplicabilityRow>> list({
    required String settingKind,
    String? settingKey,
  }) async => const <WebVendorApplicabilityRow>[];
}

class _CapturingBusinessTimingGateway implements WebBusinessTimingGateway {
  final List<BusinessTimingProfileCreate> creates =
      <BusinessTimingProfileCreate>[];

  @override
  Future<List<BusinessTimingProfileWriteResult>> listProfiles() async =>
      const <BusinessTimingProfileWriteResult>[];

  @override
  Future<BusinessTimingResolutionResult> resolveForLocation({
    required String locationId,
    String? businessDate,
  }) async => BusinessTimingResolutionResult(
    operatorId: 'demo-operator',
    locationId: locationId,
    businessDate: businessDate ?? '2026-05-13',
    ianaTimezone: 'America/Toronto',
    candidates: const <BusinessTimingResolutionCandidate>[],
  );

  @override
  Future<BusinessTimingProfileWriteResult> createProfile(
    BusinessTimingProfileCreate request,
  ) async {
    creates.add(request);
    return BusinessTimingProfileWriteResult(
      profileId: 'profile-new',
      versionId: 'profile-new',
      scopeKind: request.scopeKind,
      scopeId: request.scopeId,
      effectiveAtBusinessDate: request.effectiveAtBusinessDate,
      ianaTimezone: request.ianaTimezone,
      weekStartDay: request.weekStartDay,
      businessDayStartLocal: request.businessDayStartLocal,
      servicePeriods: const <ServicePeriod>[],
      createdAt: DateTime.utc(2026, 5, 19),
      updatedAt: DateTime.utc(2026, 5, 19),
    );
  }

  @override
  Future<BusinessTimingProfileWriteResult> updateProfile({
    required String profileId,
    required BusinessTimingProfilePatch patch,
  }) async => throw UnimplementedError();

  @override
  Future<BusinessTimingProfileWriteResult> addServicePeriod({
    required String profileId,
    required ServicePeriodCreate period,
  }) async => throw UnimplementedError();

  @override
  Future<BusinessTimingProfileWriteResult> updateServicePeriod({
    required String profileId,
    required String key,
    required ServicePeriodPatch patch,
  }) async => throw UnimplementedError();
}

class _StubBusinessTimingGateway implements WebBusinessTimingGateway {
  const _StubBusinessTimingGateway();

  @override
  Future<List<BusinessTimingProfileWriteResult>> listProfiles() async =>
      const <BusinessTimingProfileWriteResult>[];

  @override
  Future<BusinessTimingResolutionResult> resolveForLocation({
    required String locationId,
    String? businessDate,
  }) async => BusinessTimingResolutionResult(
    operatorId: 'demo-operator',
    locationId: locationId,
    businessDate: businessDate ?? '2026-05-13',
    ianaTimezone: 'America/Toronto',
    candidates: <BusinessTimingResolutionCandidate>[
      BusinessTimingResolutionCandidate(
        profileId: 'timing-demo',
        scopeType: 'operator',
        scopeId: 'demo-operator',
        scopeLabel: 'Demo Restaurant Group',
        scopeDepthRank: 0,
        ianaTimezone: 'America/Toronto',
        effectiveAtBusinessDate: '2026-05-01',
        weekStartDay: 'monday',
        businessDayStartLocal: '04:30',
        servicePeriods: _servicePeriods,
      ),
    ],
  );

  static const List<ServicePeriod> _servicePeriods = <ServicePeriod>[
    ServicePeriod(
      key: 'breakfast',
      label: 'Breakfast',
      shortLabel: 'B',
      sortOrder: 1,
      startLocal: '05:00',
      endLocal: '11:00',
      rollsPastMidnight: false,
    ),
    ServicePeriod(
      key: 'lunch',
      label: 'Lunch',
      shortLabel: 'L',
      sortOrder: 2,
      startLocal: '11:00',
      endLocal: '17:00',
      rollsPastMidnight: false,
    ),
    ServicePeriod(
      key: 'dinner',
      label: 'Dinner',
      shortLabel: 'D',
      sortOrder: 3,
      startLocal: '17:00',
      endLocal: '01:00',
      rollsPastMidnight: true,
    ),
  ];

  @override
  Future<BusinessTimingProfileWriteResult> createProfile(
    BusinessTimingProfileCreate request,
  ) async => throw UnimplementedError();

  @override
  Future<BusinessTimingProfileWriteResult> updateProfile({
    required String profileId,
    required BusinessTimingProfilePatch patch,
  }) async => throw UnimplementedError();

  @override
  Future<BusinessTimingProfileWriteResult> addServicePeriod({
    required String profileId,
    required ServicePeriodCreate period,
  }) async => throw UnimplementedError();

  @override
  Future<BusinessTimingProfileWriteResult> updateServicePeriod({
    required String profileId,
    required String key,
    required ServicePeriodPatch patch,
  }) async => throw UnimplementedError();
}
