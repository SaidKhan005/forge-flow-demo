// Phase 11W.7 / Wave A2 - My account screen widget tests.
//
// Covers the four sections (Profile, MFA, Password, T&Cs), the
// desktop (1024x768) + tablet (768x1024) breakpoints (including the
// Profile two-column to single-column flip), the role-based
// permission gate (`operator_owner` / `operator_admin` to full
// surface; `location_manager` to read-only with disabled CTAs), and
// the demo-mode mutation surfaces (MFA enroll, password change,
// auto-clearing toast).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/screens/my_account_screen.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
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

  OperatorWebSession sessionWithRole(
    String role, {
    bool mfaEnrolled = false,
    String? phone,
  }) =>
      OperatorWebSession(
        uid: 'demo-uid-$role',
        email: 'alex@brio-restaurants.com',
        displayName: 'Alex Morrison',
        operatorId: 'demo-operator',
        businessName: 'Brio Restaurants',
        primaryLocationId: 'demo-location',
        primaryLocationName: 'Brio Main Street',
        roles: <String>[role],
        mfaEnrolled: mfaEnrolled,
        phone: phone,
      );

  group('MyAccountScreen layout', () {
    testWidgets('renders all four sections at desktop 1024×768', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1024, 768));
      final session = sessionWithRole('operator_owner');

      await tester.pumpWidget(wrap(MyAccountScreen(session: session)));

      expect(find.byKey(const Key('operator_web_account_screen')),
          findsOneWidget);
      expect(find.byKey(const Key('account_section_profile')),
          findsOneWidget);
      expect(find.byKey(const Key('account_section_mfa')), findsOneWidget);
      expect(find.byKey(const Key('account_section_password')),
          findsOneWidget);
      expect(find.byKey(const Key('account_section_tos')), findsOneWidget);
    });

    testWidgets('renders all four sections at tablet 768×1024', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(768, 1024));
      final session = sessionWithRole('operator_owner');

      await tester.pumpWidget(wrap(MyAccountScreen(session: session)));

      expect(find.byKey(const Key('operator_web_account_screen')),
          findsOneWidget);
      expect(find.byKey(const Key('account_section_profile')),
          findsOneWidget);
      expect(find.byKey(const Key('account_section_mfa')), findsOneWidget);
      expect(find.byKey(const Key('account_section_password')),
          findsOneWidget);
      expect(find.byKey(const Key('account_section_tos')), findsOneWidget);
    });

    testWidgets('Profile two-column flips to single-column at tablet width', (
      tester,
    ) async {
      // Desktop 1024 — two-column Wrap renders.
      await sizeViewport(tester, const Size(1024, 768));
      final session = sessionWithRole('operator_owner');

      await tester.pumpWidget(wrap(MyAccountScreen(session: session)));

      expect(
        find.byKey(const Key('account_section_profile_two_column')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('account_section_profile_single_column')),
        findsNothing,
      );

      // Tablet 768 — fields stack into a single column.
      await sizeViewport(tester, const Size(768, 1024));
      await tester.pumpWidget(wrap(MyAccountScreen(session: session)));

      expect(
        find.byKey(const Key('account_section_profile_single_column')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('account_section_profile_two_column')),
        findsNothing,
      );
    });

    testWidgets('Profile section renders identity values from the session', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1024, 768));
      final session =
          sessionWithRole('operator_owner', phone: '+1 (555) 010-2580');

      await tester.pumpWidget(wrap(MyAccountScreen(session: session)));

      expect(find.text('Alex Morrison'), findsOneWidget);
      expect(find.text('alex@brio-restaurants.com'), findsOneWidget);
      expect(find.text('Brio Restaurants'), findsOneWidget);
      // When the session has a phone on file, that is what renders.
      expect(find.text('+1 (555) 010-2580'), findsOneWidget);
    });

    testWidgets('Profile section falls back to "Not on file" when phone absent',
        (tester) async {
      await sizeViewport(tester, const Size(1024, 768));
      final session = sessionWithRole('operator_owner');

      await tester.pumpWidget(wrap(MyAccountScreen(session: session)));

      expect(find.text('Not on file'), findsOneWidget);
    });

    testWidgets('Profile section is read-only (no editable fields)', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1024, 768));
      final session = sessionWithRole('operator_owner');

      await tester.pumpWidget(wrap(MyAccountScreen(session: session)));

      // No TextField inside the profile section — read-only at V1.
      expect(
        find.descendant(
          of: find.byKey(const Key('account_section_profile')),
          matching: find.byType(TextField),
        ),
        findsNothing,
      );
    });
  });

  group('MyAccountScreen MFA section', () {
    testWidgets('starts on Not enrolled with the Enroll CTA visible', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1024, 768));
      final session = sessionWithRole('operator_owner');

      await tester.pumpWidget(wrap(MyAccountScreen(session: session)));

      expect(find.text('MFA: Not enrolled'), findsOneWidget);
      expect(find.byKey(const Key('account_section_mfa_enroll')),
          findsOneWidget);
      expect(
        find.byKey(const Key('account_section_mfa_view_backup_codes')),
        findsNothing,
      );
    });

    testWidgets(
      'session.mfaEnrolled=true initial state shows backup-codes CTA',
      (tester) async {
        await sizeViewport(tester, const Size(1024, 768));
        final session = sessionWithRole('operator_owner', mfaEnrolled: true);

        await tester.pumpWidget(wrap(MyAccountScreen(session: session)));

        expect(find.text('MFA: Enrolled'), findsOneWidget);
        expect(
          find.byKey(const Key('account_section_mfa_view_backup_codes')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('account_section_mfa_enroll')),
            findsNothing);
      },
    );

    testWidgets('Enroll → confirm 123456 → badge flips to Enrolled (green)', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1024, 768));
      final session = sessionWithRole('operator_owner');

      await tester.pumpWidget(wrap(MyAccountScreen(session: session)));

      await tester.tap(find.byKey(const Key('account_section_mfa_enroll')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('mfa_enroll_dialog')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('mfa_enroll_dialog_code_field')),
        '123456',
      );
      await tester.tap(find.byKey(const Key('mfa_enroll_dialog_confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('mfa_enroll_dialog')), findsNothing);
      expect(find.text('MFA: Enrolled'), findsOneWidget);
      expect(
        find.byKey(const Key('account_section_mfa_view_backup_codes')),
        findsOneWidget,
      );
    });

    testWidgets('Wrong code surfaces remediation copy without flipping badge',
        (tester) async {
      await sizeViewport(tester, const Size(1024, 768));
      final session = sessionWithRole('operator_owner');

      await tester.pumpWidget(wrap(MyAccountScreen(session: session)));

      await tester.tap(find.byKey(const Key('account_section_mfa_enroll')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('mfa_enroll_dialog_code_field')),
        '000000',
      );
      await tester.tap(find.byKey(const Key('mfa_enroll_dialog_confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('mfa_enroll_dialog')), findsOneWidget);
      expect(find.textContaining('did not match'), findsOneWidget);
      // Badge stays in the not-enrolled state until the dialog is
      // dismissed via Cancel or a successful confirm.
      await tester.tap(find.byKey(const Key('mfa_enroll_dialog_cancel')));
      await tester.pumpAndSettle();
      expect(find.text('MFA: Not enrolled'), findsOneWidget);
    });

    testWidgets('Backup codes dialog lists 10 codes scoped to its panel', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1024, 768));
      final session = sessionWithRole('operator_owner', mfaEnrolled: true);

      await tester.pumpWidget(wrap(MyAccountScreen(session: session)));

      await tester.tap(
        find.byKey(const Key('account_section_mfa_view_backup_codes')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('mfa_backup_codes_dialog')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('mfa_backup_codes_dialog_list')),
          matching: find.byType(SelectableText),
        ),
        findsNWidgets(10),
      );
    });

    testWidgets(
      'View backup codes is reachable for an already-enrolled location_manager',
      (tester) async {
        await sizeViewport(tester, const Size(1024, 768));
        // location_manager who somehow already has MFA enrolled (e.g.
        // mobile-first onboarding) should still be able to view their
        // own recovery codes — viewing is not an admin-write action.
        final session =
            sessionWithRole('location_manager', mfaEnrolled: true);

        await tester.pumpWidget(wrap(MyAccountScreen(session: session)));

        final viewButton = tester.widget<OutlinedButton>(
          find.byKey(const Key('account_section_mfa_view_backup_codes')),
        );
        expect(viewButton.onPressed, isNotNull);
      },
    );
  });

  group('MyAccountScreen Password section', () {
    testWidgets('Change password opens a 3-field modal', (tester) async {
      await sizeViewport(tester, const Size(1024, 768));
      final session = sessionWithRole('operator_owner');

      await tester.pumpWidget(wrap(MyAccountScreen(session: session)));

      await tester.ensureVisible(
        find.byKey(const Key('account_section_password_change')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('account_section_password_change')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('change_password_dialog')), findsOneWidget);
      expect(find.byKey(const Key('change_password_dialog_current')),
          findsOneWidget);
      expect(find.byKey(const Key('change_password_dialog_new')),
          findsOneWidget);
      expect(find.byKey(const Key('change_password_dialog_confirm')),
          findsOneWidget);
    });

    testWidgets('Submitting a valid password closes the modal + shows toast', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1024, 768));
      final session = sessionWithRole('operator_owner');

      await tester.pumpWidget(wrap(MyAccountScreen(session: session)));

      await tester.ensureVisible(
        find.byKey(const Key('account_section_password_change')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('account_section_password_change')),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('change_password_dialog_current')),
        'old-password-123',
      );
      await tester.enterText(
        find.byKey(const Key('change_password_dialog_new')),
        'new-password-12345',
      );
      await tester.enterText(
        find.byKey(const Key('change_password_dialog_confirm')),
        'new-password-12345',
      );
      await tester.tap(
        find.byKey(const Key('change_password_dialog_submit')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('change_password_dialog')), findsNothing);
      expect(find.byKey(const Key('account_section_password_toast')),
          findsOneWidget);
      expect(find.text('Password updated'), findsOneWidget);
    });

    testWidgets('Toast auto-dismisses after the configured duration', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1024, 768));
      final session = sessionWithRole('operator_owner');

      await tester.pumpWidget(wrap(MyAccountScreen(session: session)));

      await tester.ensureVisible(
        find.byKey(const Key('account_section_password_change')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('account_section_password_change')),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('change_password_dialog_current')),
        'old-password-123',
      );
      await tester.enterText(
        find.byKey(const Key('change_password_dialog_new')),
        'new-password-12345',
      );
      await tester.enterText(
        find.byKey(const Key('change_password_dialog_confirm')),
        'new-password-12345',
      );
      await tester.tap(
        find.byKey(const Key('change_password_dialog_submit')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('account_section_password_toast')),
          findsOneWidget);

      // Advance beyond the 4s visibility window.
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();

      expect(find.byKey(const Key('account_section_password_toast')),
          findsNothing);
    });
  });

  group('MyAccountScreen T&Cs section', () {
    testWidgets('shows accepted version and date', (tester) async {
      await sizeViewport(tester, const Size(1024, 768));
      final session = sessionWithRole('operator_owner');

      await tester.pumpWidget(wrap(MyAccountScreen(session: session)));

      expect(
        find.byKey(const Key('account_section_tos_accepted_line')),
        findsOneWidget,
      );
      expect(find.text('Accepted v1.0 on 2026-04-15'), findsOneWidget);
      expect(find.byKey(const Key('account_section_tos_view')),
          findsOneWidget);
    });

    testWidgets('View current T&Cs opens a read-only scrollable dialog', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1024, 768));
      final session = sessionWithRole('operator_owner');

      await tester.pumpWidget(wrap(MyAccountScreen(session: session)));

      await tester.ensureVisible(
        find.byKey(const Key('account_section_tos_view')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('account_section_tos_view')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('view_tos_dialog')), findsOneWidget);
      expect(find.byKey(const Key('view_tos_dialog_scroll')), findsOneWidget);
      expect(find.byKey(const Key('view_tos_dialog_close')), findsOneWidget);
    });
  });

  group('MyAccountScreen permission gate', () {
    testWidgets('operator_owner sees enabled MFA + Password CTAs', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1024, 768));
      final session = sessionWithRole('operator_owner');

      await tester.pumpWidget(wrap(MyAccountScreen(session: session)));

      final enroll = tester.widget<OutlinedButton>(
        find.byKey(const Key('account_section_mfa_enroll')),
      );
      final pwd = tester.widget<OutlinedButton>(
        find.byKey(const Key('account_section_password_change')),
      );
      expect(enroll.onPressed, isNotNull);
      expect(pwd.onPressed, isNotNull);
    });

    testWidgets('operator_admin sees enabled MFA + Password CTAs', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1024, 768));
      final session = sessionWithRole('operator_admin');

      await tester.pumpWidget(wrap(MyAccountScreen(session: session)));

      final enroll = tester.widget<OutlinedButton>(
        find.byKey(const Key('account_section_mfa_enroll')),
      );
      final pwd = tester.widget<OutlinedButton>(
        find.byKey(const Key('account_section_password_change')),
      );
      expect(enroll.onPressed, isNotNull);
      expect(pwd.onPressed, isNotNull);
    });

    testWidgets(
      'location_manager sees Profile + T&Cs but MFA + Password disabled',
      (tester) async {
        await sizeViewport(tester, const Size(1024, 768));
        final session = sessionWithRole('location_manager');

        await tester.pumpWidget(wrap(MyAccountScreen(session: session)));

        // Profile + T&Cs still render for read-only access.
        expect(find.byKey(const Key('account_section_profile')),
            findsOneWidget);
        expect(find.byKey(const Key('account_section_tos')), findsOneWidget);

        // MFA + Password CTAs are disabled.
        final enroll = tester.widget<OutlinedButton>(
          find.byKey(const Key('account_section_mfa_enroll')),
        );
        final pwd = tester.widget<OutlinedButton>(
          find.byKey(const Key('account_section_password_change')),
        );
        expect(enroll.onPressed, isNull);
        expect(pwd.onPressed, isNull);

        // Tooltip copy explains why — UX writing standard friendly-error
        // surface for the role gate.
        final tooltips = find
            .byType(Tooltip)
            .evaluate()
            .map((e) => (e.widget as Tooltip).message ?? '')
            .toList();
        expect(
          tooltips.any((t) => t.contains('Only operator admins can change MFA')),
          isTrue,
        );
        expect(
          tooltips.any(
            (t) =>
                t.contains('Only operator admins can change account passwords'),
          ),
          isTrue,
        );
      },
    );

    testWidgets('demo location_manager factory lands on the read-only branch',
        (tester) async {
      await sizeViewport(tester, const Size(1024, 768));
      final source = DemoOperatorWebAuthSource.completedAsLocationManager();
      addTearDown(source.dispose);
      final completed = source.current as OperatorWebCompleted;

      await tester.pumpWidget(
        wrap(MyAccountScreen(session: completed.session)),
      );

      final enroll = tester.widget<OutlinedButton>(
        find.byKey(const Key('account_section_mfa_enroll')),
      );
      expect(enroll.onPressed, isNull);
      expect(completed.session.roles, contains('location_manager'));
    });
  });
}
