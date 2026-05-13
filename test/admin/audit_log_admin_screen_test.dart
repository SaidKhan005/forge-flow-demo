// Lane B B8 — AuditLogAdminScreen widget tests.
//
// Drives the screen against an InMemoryAuditLogAdminGateway so the
// click path runs end-to-end without the proxy. Coverage:
//
//   * Initial render shows the filter chrome (scope dropdown, time
//     range fields, admin_reason field).
//   * Run filter sends a command through the gateway and renders the
//     returned rows.
//   * Missing admin_reason surfaces an inline error and does not call
//     the gateway.
//   * Scope=location populates the location_filter via the tree tap
//     callback (when a rootNode is supplied).
//   * Gateway error message renders in the error banner.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/screens/audit_log_admin_screen.dart';
import 'package:forge_and_flow/admin/services/audit_log_admin_gateway.dart';
import 'package:forge_and_flow/domain/models/inheritance_tree_node.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _locB = '33333333-3333-3333-3333-333333333333';

void main() {
  // Resize the surface for every test so the dense filter row +
  // results list have room to lay out without RenderFlex overflow
  // (the production screen is rendered inside the admin app shell at
  // 1280+ widths). Reset in tearDown so the next test starts clean.
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dispatcher = TestWidgetsFlutterBinding.instance.platformDispatcher;
    dispatcher.views.first.physicalSize = const Size(1600, 1200);
    dispatcher.views.first.devicePixelRatio = 1.0;
  });

  tearDown(() {
    final dispatcher = TestWidgetsFlutterBinding.instance.platformDispatcher;
    dispatcher.views.first.resetPhysicalSize();
    dispatcher.views.first.resetDevicePixelRatio();
  });

  Widget wrap(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: Scaffold(body: child),
      );

  AuditLogAdminRow seedRow({required String id, String? locationId}) {
    return AuditLogAdminRow(
      id: id,
      operatorId: _opA,
      locationId: locationId,
      occurredAt: DateTime.utc(2026, 5, 13, 12),
      actorKind: 'user',
      action: 'auth.password_changed',
    );
  }

  testWidgets('renders header + scope dropdown + reason field + time '
      'range inputs on initial mount',
      (tester) async {
    final gateway = InMemoryAuditLogAdminGateway();
    await tester.pumpWidget(
      wrap(AuditLogAdminScreen(gateway: gateway)),
    );
    expect(find.text('Audit log'), findsOneWidget);
    expect(
      find.byKey(const Key('admin_audit_log_admin_reason')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_audit_log_scope_type')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_audit_log_from')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_audit_log_to')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_audit_log_run_button')),
      findsOneWidget,
    );
  });

  testWidgets('Run filter without an admin_reason shows the inline '
      'error banner and never calls the gateway',
      (tester) async {
    final gateway = InMemoryAuditLogAdminGateway();
    await tester.pumpWidget(
      wrap(AuditLogAdminScreen(gateway: gateway)),
    );
    await tester.tap(find.byKey(const Key('admin_audit_log_run_button')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('admin_audit_log_error_banner')),
      findsOneWidget,
    );
    expect(gateway.calls, isEmpty);
  });

  testWidgets('Run filter with an admin_reason sends the command and '
      'renders the result rows',
      (tester) async {
    final gateway = InMemoryAuditLogAdminGateway(
      rows: <AuditLogAdminRow>[
        seedRow(id: '1', locationId: _locA),
        seedRow(id: '2', locationId: _locB),
      ],
    );
    await tester.pumpWidget(
      wrap(AuditLogAdminScreen(gateway: gateway)),
    );
    await tester.enterText(
      find.byKey(const Key('admin_audit_log_admin_reason')),
      'Support ticket #5125',
    );
    await tester.tap(find.byKey(const Key('admin_audit_log_run_button')));
    await tester.pumpAndSettle();
    expect(gateway.calls, hasLength(1));
    expect(gateway.calls.first.adminReason, 'Support ticket #5125');
    expect(find.byKey(const Key('admin_audit_log_row_1')), findsOneWidget);
    expect(find.byKey(const Key('admin_audit_log_row_2')), findsOneWidget);
  });

  testWidgets('Gateway error surface renders in the error banner', (
    tester,
  ) async {
    final gateway = InMemoryAuditLogAdminGateway(
      failWith: const AuditLogAdminGatewayError(
        'something failed',
        statusCode: 503,
      ),
    );
    await tester.pumpWidget(
      wrap(AuditLogAdminScreen(gateway: gateway)),
    );
    await tester.enterText(
      find.byKey(const Key('admin_audit_log_admin_reason')),
      'tick-1',
    );
    await tester.tap(find.byKey(const Key('admin_audit_log_run_button')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('admin_audit_log_error_banner')),
      findsOneWidget,
    );
    expect(find.text('something failed'), findsOneWidget);
  });

  testWidgets('Switching the scope dropdown to "Region / district" '
      'reveals the org_unit_id field', (tester) async {
    final gateway = InMemoryAuditLogAdminGateway();
    await tester.pumpWidget(
      wrap(AuditLogAdminScreen(gateway: gateway)),
    );
    // Initially the org_unit_id field is not rendered (scope is
    // operator_wide by default).
    expect(find.byKey(const Key('admin_audit_log_org_unit_id')), findsNothing);
    // Open the dropdown and pick "Region / district".
    await tester.tap(find.byKey(const Key('admin_audit_log_scope_type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Region / district').last);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('admin_audit_log_org_unit_id')),
      findsOneWidget,
    );
  });

  testWidgets('Tapping a location node in the InheritanceTree '
      'auto-fills the location_filter and switches the scope dropdown',
      (tester) async {
    final gateway = InMemoryAuditLogAdminGateway();
    final tree = InheritanceTreeNode(
      scopeKind: InheritanceTreeScopeKind.business,
      scopeId: 'business-1',
      displayName: 'Acme Restaurants',
      children: <InheritanceTreeNode>[
        InheritanceTreeNode(
          scopeKind: InheritanceTreeScopeKind.location,
          scopeId: _locA,
          displayName: 'Downtown',
          parentScopeId: 'business-1',
          depth: 1,
        ),
      ],
    );
    await tester.pumpWidget(
      wrap(AuditLogAdminScreen(gateway: gateway, rootNode: tree)),
    );
    await tester.tap(find.byKey(Key('inheritance_tree_tap_$_locA')));
    await tester.pumpAndSettle();
    // After tap the location_filter field is visible (scope is now
    // "Single location") and carries the tapped location id.
    final locField = find.byKey(
      const Key('admin_audit_log_location_filter'),
    );
    expect(locField, findsOneWidget);
    final controller = (tester.widget(locField) as TextField).controller!;
    expect(controller.text, _locA);
  });

  testWidgets('Empty rows render the friendly empty-state copy', (
    tester,
  ) async {
    final gateway = InMemoryAuditLogAdminGateway();
    await tester.pumpWidget(
      wrap(AuditLogAdminScreen(gateway: gateway)),
    );
    await tester.enterText(
      find.byKey(const Key('admin_audit_log_admin_reason')),
      'support-ticket-2',
    );
    await tester.tap(find.byKey(const Key('admin_audit_log_run_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('admin_audit_log_empty')), findsOneWidget);
  });
}
