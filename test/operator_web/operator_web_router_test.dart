// Phase 11W.0 — Operator Web Console router widget tests.
//
// Verifies the router renders the right surface for each
// `OperatorWebAuthState` and that the post-onboarding shell hosts
// the operator-web route bodies behind the side
// nav. Keeps the demo source as the driver so the click path runs
// without Firebase.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/auth/operator_web_handoff_redeem_gateway.dart';
import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/router/operator_web_router.dart';
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

  group('OperatorWebRouter onboarding stages', () {
    testWidgets(
      'signed-out state lands on the welcome screen with token field',
      (tester) async {
        await sizeViewport(tester);
        final source = DemoOperatorWebAuthSource.signedOut();
        addTearDown(source.dispose);

        await tester.pumpWidget(
          wrap(OperatorWebRouter(source: source, initialMagicLinkToken: 'abc')),
        );

        expect(
          find.byKey(const Key('operator_web_welcome_token_field')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('operator_web_welcome_submit')),
          findsOneWidget,
        );
        // Step pill confirms we're on the welcome stage.
        expect(find.text('Step 1 of 4 — Welcome'), findsOneWidget);
        // Welcome explainer rendered.
        expect(
          find.byKey(const Key('operator_web_welcome_explainer')),
          findsOneWidget,
        );
      },
    );

    testWidgets('settingPassword state renders the password screen', (
      tester,
    ) async {
      await sizeViewport(tester);
      final source = DemoOperatorWebAuthSource.atWelcome();
      addTearDown(source.dispose);
      source.emitForTesting(
        const OperatorWebSettingPassword(session: kDemoOperatorWebSession),
      );

      await tester.pumpWidget(wrap(OperatorWebRouter(source: source)));

      expect(
        find.byKey(const Key('operator_web_password_field')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_password_confirm_field')),
        findsOneWidget,
      );
      expect(find.text('Step 2 of 4 — Password'), findsOneWidget);
    });

    testWidgets('enrollingMfa state renders the MFA factor picker', (
      tester,
    ) async {
      await sizeViewport(tester);
      final source = DemoOperatorWebAuthSource.atWelcome();
      addTearDown(source.dispose);
      source.emitForTesting(
        const OperatorWebEnrollingMfa(session: kDemoOperatorWebSession),
      );

      await tester.pumpWidget(wrap(OperatorWebRouter(source: source)));

      expect(
        find.byKey(const Key('operator_web_mfa_factor_picker')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_mfa_option_totp')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_mfa_option_sms')),
        findsOneWidget,
      );
      expect(find.text('Step 3 of 4 — Two-factor sign-in'), findsOneWidget);
    });

    testWidgets('acceptingTos state renders the T&Cs click-through', (
      tester,
    ) async {
      await sizeViewport(tester);
      final source = DemoOperatorWebAuthSource.atWelcome();
      addTearDown(source.dispose);
      source.emitForTesting(
        OperatorWebAcceptingTos(
          session: kDemoOperatorWebSession,
          tosVersion: DemoOperatorWebAuthSource.kDemoTosVersion.version,
          tosBodyMarkdown:
              DemoOperatorWebAuthSource.kDemoTosVersion.bodyMarkdown,
        ),
      );

      await tester.pumpWidget(wrap(OperatorWebRouter(source: source)));

      expect(find.byKey(const Key('operator_web_tos_summary')), findsOneWidget);
      expect(
        find.byKey(const Key('operator_web_tos_body_panel')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_tos_agreement_checkbox')),
        findsOneWidget,
      );
      expect(find.text('Step 4 of 4 — Authorize data access'), findsOneWidget);
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
        final navOrder = [
          'account',
          'business_setup',
          'locations',
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
      await tester.pumpAndSettle();
      await tester.tap(find.text('Downtown').last);
      await tester.pumpAndSettle();

      expect(
        find.text('Manage the services connected to Downtown.'),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const Key('operator_web_management_scope_picker')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('All locations').last);
      await tester.pumpAndSettle();

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
      // After sign-out the welcome screen reappears.
      expect(
        find.byKey(const Key('operator_web_welcome_token_field')),
        findsOneWidget,
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
