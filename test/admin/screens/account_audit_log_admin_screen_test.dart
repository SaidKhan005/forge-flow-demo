// Widget tests for the full-page admin Audit log
// (AccountAuditLogAdminScreen): it renders the signed-in admin's own
// account events from the self-scoped gateway, the time-window filter
// narrows the list, CSV export hands the rendered rows to the clipboard
// seam, and a null gateway degrades to the honest disconnected state.
// Also pins the admin-shell nav wiring so the "Audit log" row mounts
// the screen.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_auth_gate.dart';
import 'package:forge_and_flow/admin/admin_routes.dart';
import 'package:forge_and_flow/admin/admin_shell.dart';
import 'package:forge_and_flow/admin/screens/account_audit_log_admin_screen.dart';
import 'package:forge_and_flow/admin/services/admin_security_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: Scaffold(body: child),
      );

  void wideViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1440, 1024);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  DateTime fixedNow() => DateTime.utc(2026, 5, 14, 12, 30, 0);

  group('AccountAuditLogAdminScreen', () {
    testWidgets('renders the account event rows from the gateway', (
      tester,
    ) async {
      wideViewport(tester);
      await tester.pumpWidget(
        wrap(
          AccountAuditLogAdminScreen(
            gateway: InMemoryAdminSecurityGateway(now: fixedNow),
            now: fixedNow,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_account_audit_log_screen')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_account_audit_log_list')),
        findsOneWidget,
      );
      // Seeded events render within the default 90-day window.
      expect(find.text('Signed in'), findsWidgets);
      expect(find.text('Password changed'), findsWidgets);
    });

    testWidgets('time-window filter narrows the list', (tester) async {
      wideViewport(tester);
      await tester.pumpWidget(
        wrap(
          AccountAuditLogAdminScreen(
            gateway: InMemoryAdminSecurityGateway(now: fixedNow),
            now: fixedNow,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Default 90 days shows the 6-day-old password change.
      expect(find.text('Password changed'), findsWidgets);

      // Narrow to the last 24 hours: only the 2-hour-old sign-in stays.
      final last24h = find.byKey(
        const Key('admin_account_audit_log_filter_last_24h'),
      );
      await tester.ensureVisible(last24h);
      await tester.tap(last24h);
      await tester.pumpAndSettle();

      expect(find.text('Signed in'), findsWidgets);
      expect(find.text('Password changed'), findsNothing);
    });

    testWidgets('Export copies the rendered rows to the clipboard seam', (
      tester,
    ) async {
      wideViewport(tester);
      String? captured;
      await tester.pumpWidget(
        wrap(
          AccountAuditLogAdminScreen(
            gateway: InMemoryAdminSecurityGateway(now: fixedNow),
            now: fixedNow,
            copyToClipboard: (csv) async => captured = csv,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final exportBtn = find.byKey(
        const Key('admin_account_audit_log_export'),
      );
      await tester.ensureVisible(exportBtn);
      await tester.tap(exportBtn);
      await tester.pump();
      await tester.pump();

      expect(captured, isNotNull);
      expect(captured!, contains('When (UTC),Event,Type,Device,Location'));
      expect(captured!, contains('Signed in'));
      expect(
        find.byKey(const Key('admin_account_audit_log_export_toast')),
        findsOneWidget,
      );
    });

    testWidgets('null gateway shows the disconnected state, export disabled', (
      tester,
    ) async {
      wideViewport(tester);
      await tester.pumpWidget(
        wrap(const AccountAuditLogAdminScreen(gateway: null)),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_account_audit_log_disconnected')),
        findsOneWidget,
      );
      final exportBtn = tester.widget<OutlinedButton>(
        find.byKey(const Key('admin_account_audit_log_export')),
      );
      expect(exportBtn.onPressed, isNull);
    });
  });

  group('Admin shell nav wiring', () {
    testWidgets('Audit log route mounts via the side nav', (tester) async {
      wideViewport(tester);
      final source = DemoAdminAuthSource.signedInAsSuperAdmin();
      addTearDown(source.dispose);
      final session = (source.current as AdminAuthAuthenticated).session;

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.themeData,
          home: AdminConsoleServicesScope(
            adminAuthSource: source,
            child: AdminShell(session: session, authSource: source),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final navItem = find.byKey(
        Key('admin_nav_item_$kAdminAuditLogRouteId'),
      );
      expect(navItem, findsOneWidget);
      await tester.ensureVisible(navItem);
      await tester.tap(navItem);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_account_audit_log_screen')),
        findsOneWidget,
      );
    });
  });
}
