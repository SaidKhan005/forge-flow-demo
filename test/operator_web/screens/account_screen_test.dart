// Phase 11W.7 / Wave A2 - Business-identity AccountScreen widget tests.
//
// The screen is the business-identity editor (sibling to MyAccountScreen,
// which owns Profile/MFA/Password/T&Cs). Tests cover:
//   * renders the three sections + Save button
//   * unavailable banner when no gateway is wired
//   * read-only banner for non-edit roles
//   * happy-path save round-trips through the gateway
//   * gateway error surfaces in the inline error banner

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/screens/account_screen.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_proxy_client.dart';
import 'package:forge_and_flow/operator_web/services/web_account_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

class _FakeAccountGateway implements WebAccountGateway {
  _FakeAccountGateway({this.failWith});

  final OperatorWebProxyException? failWith;
  final List<AccountIdentityPatch> calls = <AccountIdentityPatch>[];

  @override
  Future<AccountIdentity> patchAccount(AccountIdentityPatch patch) async {
    calls.add(patch);
    if (failWith != null) throw failWith!;
    return AccountIdentity(
      operatorId: 'op-1',
      businessName: patch.businessName ?? 'Brio Restaurants',
      logoUrl: patch.logoUrl,
      currencyCode: patch.currencyCode ?? 'USD',
      localeTag: patch.localeTag ?? 'en-US',
      weekStartDay: patch.weekStartDay ?? 'monday',
      rolloverHour: patch.rolloverHour ?? 4,
      updatedAt: DateTime.utc(2026, 5, 6, 18),
    );
  }
}

OperatorWebSession sessionWithRole(String role) => OperatorWebSession(
      uid: 'uid-$role',
      email: 'alex@brio-restaurants.com',
      displayName: 'Alex Morrison',
      operatorId: 'op-1',
      businessName: 'Brio Restaurants',
      primaryLocationId: 'loc-1',
      primaryLocationName: 'Brio Main',
      roles: <String>[role],
      currencyCode: 'USD',
      localeTag: 'en-US',
      weekStartDay: 'monday',
      rolloverHour: 4,
    );

Widget wrap(Widget child) => MaterialApp(
      theme: AppTheme.themeData,
      home: Scaffold(body: child),
    );

Future<void> _sizeViewport(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

void main() {
  testWidgets('renders the three identity sections + Save', (tester) async {
    await _sizeViewport(tester);
    final session = sessionWithRole('operator_owner');
    await tester.pumpWidget(wrap(AccountScreen(session: session)));
    expect(
      find.byKey(const Key('operator_web_account_screen')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('operator_web_account_section_identity')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('operator_web_account_section_region')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('operator_web_account_section_business_day')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('operator_web_account_save')),
      findsOneWidget,
    );
  });

  testWidgets('unavailable banner shows when gateway absent', (tester) async {
    await _sizeViewport(tester);
    final session = sessionWithRole('operator_owner');
    await tester.pumpWidget(wrap(AccountScreen(session: session)));
    expect(
      find.byKey(const Key('operator_web_account_unavailable')),
      findsOneWidget,
    );
    final saveButton = tester.widget<ButtonStyleButton>(
      find.byKey(const Key('operator_web_account_save')),
    );
    expect(saveButton.onPressed, isNull);
  });

  testWidgets('read-only banner for non-edit role', (tester) async {
    await _sizeViewport(tester);
    final session = sessionWithRole('location_manager');
    await tester.pumpWidget(
      wrap(
        AccountScreen(
          session: session,
          gateway: _FakeAccountGateway(),
        ),
      ),
    );
    expect(
      find.byKey(const Key('operator_web_account_readonly')),
      findsOneWidget,
    );
    final saveButton = tester.widget<ButtonStyleButton>(
      find.byKey(const Key('operator_web_account_save')),
    );
    expect(saveButton.onPressed, isNull);
  });

  testWidgets('happy-path save calls gateway with patch fields',
      (tester) async {
    await _sizeViewport(tester);
    final gateway = _FakeAccountGateway();
    final session = sessionWithRole('operator_owner');
    await tester.pumpWidget(
      wrap(AccountScreen(session: session, gateway: gateway)),
    );

    await tester.enterText(
      find.byKey(const Key('operator_web_account_business_name')),
      'Brio Restaurants',
    );
    await tester.tap(find.byKey(const Key('operator_web_account_save')));
    await tester.pumpAndSettle();

    expect(gateway.calls, hasLength(1));
    expect(gateway.calls.single.businessName, 'Brio Restaurants');
    expect(
      find.byKey(const Key('operator_web_account_success')),
      findsOneWidget,
    );
  });

  testWidgets('gateway error surfaces in the inline error banner',
      (tester) async {
    await _sizeViewport(tester);
    final gateway = _FakeAccountGateway(
      failWith: const OperatorWebProxyException(
        code: 'invalid_currency_code',
        message: 'Currency code must be three uppercase letters.',
      ),
    );
    final session = sessionWithRole('operator_owner');
    await tester.pumpWidget(
      wrap(AccountScreen(session: session, gateway: gateway)),
    );
    await tester.tap(find.byKey(const Key('operator_web_account_save')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('operator_web_account_error')),
      findsOneWidget,
    );
    expect(
      find.text('Currency code must be three uppercase letters.'),
      findsOneWidget,
    );
  });
}
