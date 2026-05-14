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
import 'package:forge_and_flow/operator_web/widgets/web_app_shell.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

class _FakeAccountGateway implements WebAccountGateway {
  _FakeAccountGateway({this.failWith, this.timezoneFailWith});

  final OperatorWebProxyException? failWith;
  final OperatorWebProxyException? timezoneFailWith;
  final List<AccountIdentityPatch> calls = <AccountIdentityPatch>[];
  final List<AccountLocationTimezonePatch> timezoneCalls =
      <AccountLocationTimezonePatch>[];
  int getCalls = 0;

  @override
  Future<AccountIdentity> getAccount() async {
    getCalls += 1;
    if (failWith != null) throw failWith!;
    return AccountIdentity(
      operatorId: 'op-1',
      businessName: 'Brio Restaurants',
      logoUrl: null,
      currencyCode: 'USD',
      localeTag: 'en-US',
      weekStartDay: 'monday',
      rolloverHour: 4,
      updatedAt: DateTime.utc(2026, 5, 6, 18),
    );
  }

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

  @override
  Future<AccountLocationTimezone> patchLocationTimezone(
    AccountLocationTimezonePatch patch,
  ) async {
    timezoneCalls.add(patch);
    if (timezoneFailWith != null) throw timezoneFailWith!;
    return AccountLocationTimezone(
      operatorId: 'op-1',
      locationId: 'loc-1',
      ianaTimezone: patch.ianaTimezone,
      updatedAt: DateTime.utc(2026, 5, 14, 12),
    );
  }

  @override
  Future<SelfProfilePatchResult> patchSelfProfile(
    SelfProfilePatchPayload patch,
  ) async {
    // Test default — the account screen test doesn't exercise the
    // self-profile path. The W-3 dedicated test
    // (`my_account_screen_test.dart`) drives a real fake.
    if (failWith != null) throw failWith!;
    return SelfProfilePatchResult(
      userId: 'uid-1',
      email: patch.email ?? 'alex@brio-restaurants.com',
      displayName: patch.displayName ?? 'Alex Morrison',
      emailChanged: patch.email != null,
      displayNameChanged: patch.displayName != null,
    );
  }
}

OperatorWebSession sessionWithRole(
  String role, {
  String? primaryLocationTimezone = 'America/Toronto',
}) =>
    OperatorWebSession(
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
      primaryLocationTimezone: primaryLocationTimezone,
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
    // Wave 2 U-FU-hp11-account — three new HP #11 scope notices
    // pushed the Save button below the 1600px viewport; scroll it
    // into view before tapping.
    await tester.ensureVisible(
      find.byKey(const Key('operator_web_account_save')),
    );
    await tester.pumpAndSettle();
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
    // Wave 2 U-FU-hp11-account — scope notices pushed Save out of
    // the default viewport; scroll first.
    await tester.ensureVisible(
      find.byKey(const Key('operator_web_account_save')),
    );
    await tester.pumpAndSettle();
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

  // Wave 2 W-6 — timezone section coverage.

  testWidgets(
    'timezone section renders with HP #11 scope notice + effective value',
    (tester) async {
      await _sizeViewport(tester);
      final session = sessionWithRole('operator_owner');
      await tester.pumpWidget(
        wrap(AccountScreen(session: session, gateway: _FakeAccountGateway())),
      );
      expect(
        find.byKey(
          const Key('operator_web_account_section_location_timezone'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_account_timezone_scope')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('operator_web_account_timezone_scope_scope_pill'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_account_timezone_shortlist')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_account_timezone_save')),
        findsOneWidget,
      );
      // HP #11 effective row carries the seeded America/Toronto value.
      expect(
        find.textContaining('America/Toronto'),
        findsWidgets,
      );
    },
  );

  testWidgets(
    'timezone save round-trips the picked value through the gateway',
    (tester) async {
      await _sizeViewport(tester);
      final gateway = _FakeAccountGateway();
      final session = sessionWithRole(
        'operator_owner',
        primaryLocationTimezone: 'America/Toronto',
      );
      await tester.pumpWidget(
        wrap(AccountScreen(session: session, gateway: gateway)),
      );
      // Wave 2 U-FU-hp11-account — three new HP #11 notices pushed
      // the timezone shortlist below the 1600px viewport; scroll it
      // into view before driving the dropdown.
      await tester.ensureVisible(
        find.byKey(const Key('operator_web_account_timezone_shortlist')),
      );
      await tester.pumpAndSettle();

      // Open the dropdown and pick a different shortlist option.
      await tester.tap(
        find.byKey(const Key('operator_web_account_timezone_shortlist')),
      );
      await tester.pumpAndSettle();
      await tester
          .tap(find.text('London / Dublin').last);
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const Key('operator_web_account_timezone_save')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('operator_web_account_timezone_save')),
      );
      await tester.pumpAndSettle();

      expect(gateway.timezoneCalls, hasLength(1));
      expect(gateway.timezoneCalls.single.ianaTimezone, 'Europe/London');
      expect(
        find.byKey(const Key('operator_web_account_timezone_success')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'timezone gateway error surfaces in the inline timezone banner',
    (tester) async {
      await _sizeViewport(tester);
      final gateway = _FakeAccountGateway(
        timezoneFailWith: const OperatorWebProxyException(
          code: 'invalid_iana_timezone',
          message: 'That timezone is not in the IANA database.',
        ),
      );
      final session = sessionWithRole('operator_owner');
      await tester.pumpWidget(
        wrap(AccountScreen(session: session, gateway: gateway)),
      );
      // Wave 2 U-FU-hp11-account — three new HP #11 scope notices
      // pushed the timezone save button below the 1600px viewport.
      // Scroll it into view before tapping.
      await tester.ensureVisible(
        find.byKey(const Key('operator_web_account_timezone_save')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('operator_web_account_timezone_save')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('operator_web_account_timezone_error')),
        findsOneWidget,
      );
      expect(
        find.text('That timezone is not in the IANA database.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'session with no primary location timezone shows the empty-state copy',
    (tester) async {
      await _sizeViewport(tester);
      final session = sessionWithRole(
        'operator_owner',
        primaryLocationTimezone: null,
      );
      await tester.pumpWidget(
        wrap(AccountScreen(session: session, gateway: _FakeAccountGateway())),
      );
      expect(
        find.text('No timezone is on file. Set one to lock daily timing.'),
        findsOneWidget,
      );
    },
  );

  // Wave 2 U-FU-hp11-account — HP #11 (Selected scope / Inherited
  // from / Effective value) coverage for the three operator-set
  // sections: Business identity, Region, Business day.

  group('HP #11 scope notices', () {
    const businessScope = OperatorWebManagementScopeOption(
      key: 'operator:op-1',
      kind: OperatorWebManagementScopeKind.operator,
      id: 'op-1',
      label: 'Brio Restaurants',
      helper: 'All locations',
    );
    const locationScope = OperatorWebManagementScopeOption(
      key: 'location:loc-1',
      kind: OperatorWebManagementScopeKind.location,
      id: 'loc-1',
      label: 'Brio Main',
      helper: 'Location',
    );

    testWidgets(
      'Business scope renders Selected/Inherited/Effective without inheritance',
      (tester) async {
        await _sizeViewport(tester);
        final session = sessionWithRole('operator_owner');
        await tester.pumpWidget(
          wrap(
            AccountScreen(
              session: session,
              gateway: _FakeAccountGateway(),
              selectedScope: businessScope,
            ),
          ),
        );
        // All three operator-set cards expose the scope notice.
        expect(
          find.byKey(const Key('operator_web_account_identity_scope')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('operator_web_account_region_scope')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('operator_web_account_business_day_scope')),
          findsOneWidget,
        );
        // "Set here" (no inheritance) is rendered for every card at
        // Business scope (Business identity + Region + Business day),
        // plus the pre-existing Location-scoped timezone card (Wave 2
        // W-6) that always renders the same "Set here" copy because
        // timezone lives on `locations.timezone` natively.
        expect(
          find.text('Set here. Does not inherit from a higher scope.'),
          findsNWidgets(4),
        );
        // Save stays enabled at Business scope when the gateway is
        // wired + the operator has edit permission.
        final saveButton = tester.widget<ButtonStyleButton>(
          find.byKey(const Key('operator_web_account_save')),
        );
        expect(saveButton.onPressed, isNotNull);
      },
    );

    testWidgets(
      'Location scope with no override renders the inheritance line + disables edit',
      (tester) async {
        await _sizeViewport(tester);
        final session = sessionWithRole('operator_owner');
        await tester.pumpWidget(
          wrap(
            AccountScreen(
              session: session,
              gateway: _FakeAccountGateway(),
              selectedScope: locationScope,
            ),
          ),
        );
        // The three cards show the inheritance copy.
        expect(
          find.text('Inherits the business default from Business.'),
          findsNWidgets(3),
        );
        // Backend-only explainer surfaces the schema gap in plain
        // English.
        expect(
          find.textContaining(
            'Per-location overrides for this field are not on file yet.',
          ),
          findsNWidgets(3),
        );
        // Save is disabled at non-business scope because the schema
        // has no override path yet.
        final saveButton = tester.widget<ButtonStyleButton>(
          find.byKey(const Key('operator_web_account_save')),
        );
        expect(saveButton.onPressed, isNull);
        // The editable fields disable their input handlers.
        final businessNameField = tester.widget<TextField>(
          find.byKey(const Key('operator_web_account_business_name')),
        );
        expect(businessNameField.enabled, isFalse);
      },
    );

    testWidgets('Region card carries the effective value summary',
        (tester) async {
      await _sizeViewport(tester);
      final session = sessionWithRole('operator_owner');
      await tester.pumpWidget(
        wrap(
          AccountScreen(
            session: session,
            gateway: _FakeAccountGateway(),
            selectedScope: businessScope,
          ),
        ),
      );
      expect(
        find.textContaining('Currency is USD'),
        findsWidgets,
      );
      expect(
        find.textContaining('locale is en-US'),
        findsWidgets,
      );
    });

    testWidgets('Business day card carries the effective value summary',
        (tester) async {
      await _sizeViewport(tester);
      final session = sessionWithRole('operator_owner');
      await tester.pumpWidget(
        wrap(
          AccountScreen(
            session: session,
            gateway: _FakeAccountGateway(),
            selectedScope: businessScope,
          ),
        ),
      );
      expect(
        find.textContaining('Week starts Monday'),
        findsWidgets,
      );
      expect(
        find.textContaining('04:00 local'),
        findsWidgets,
      );
    });
  });
}
