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
  _FakeAccountGateway({
    this.failWith,
    this.timezoneFailWith,
    this.initialOverrides,
  });

  final OperatorWebProxyException? failWith;
  final OperatorWebProxyException? timezoneFailWith;
  OperatorWebProxyException? overridesFailWith;

  /// Wave 2 U-FU-hp11-account — when non-null, `getLocationAccountOverrides`
  /// returns this envelope; otherwise the fake returns a synthetic "no
  /// override on file" envelope (every override field NULL, business
  /// defaults filled in).
  final LocationAccountOverridesEnvelope? initialOverrides;

  final List<AccountIdentityPatch> calls = <AccountIdentityPatch>[];
  final List<AccountLocationTimezonePatch> timezoneCalls =
      <AccountLocationTimezonePatch>[];
  final List<({String locationId, LocationAccountOverridesPatchPayload patch})>
  overridesPatchCalls =
      <({String locationId, LocationAccountOverridesPatchPayload patch})>[];
  final List<String> overridesGetCalls = <String>[];
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

  // Wave 2 U-FU-hp11-account — synthetic in-memory implementation of
  // the per-location override gateway methods. Sufficient for widget
  // tests: getLocationAccountOverrides returns the seeded envelope (or
  // a "no override" default); patchLocationAccountOverrides records the
  // call and reflects the patch in the returned envelope so the screen
  // sees the new override state.
  LocationAccountOverridesEnvelope _defaultOverridesEnvelope() {
    return LocationAccountOverridesEnvelope(
      operatorId: 'op-1',
      locationId: 'loc-1',
      effective: const LocationAccountOverridesFieldSet(
        ianaTimezone: 'America/Toronto',
        localeCode: 'en-US',
        currencyCode: 'USD',
        businessDayRolloverHour: 4,
      ),
      override: const LocationAccountOverridesFieldSet(),
      businessDefault: const LocationAccountOverridesFieldSet(
        ianaTimezone: 'America/Toronto',
        localeCode: 'en-US',
        currencyCode: 'USD',
        businessDayRolloverHour: 4,
      ),
      updatedAt: DateTime.utc(2026, 5, 14, 12),
    );
  }

  @override
  Future<LocationAccountOverridesEnvelope> getLocationAccountOverrides({
    required String locationId,
  }) async {
    overridesGetCalls.add(locationId);
    if (overridesFailWith != null) throw overridesFailWith!;
    return initialOverrides ?? _defaultOverridesEnvelope();
  }

  @override
  Future<LocationAccountOverridesEnvelope> patchLocationAccountOverrides({
    required String locationId,
    required LocationAccountOverridesPatchPayload patch,
  }) async {
    overridesPatchCalls.add((locationId: locationId, patch: patch));
    if (overridesFailWith != null) throw overridesFailWith!;
    final businessDefault =
        (initialOverrides ?? _defaultOverridesEnvelope()).businessDefault;
    return LocationAccountOverridesEnvelope(
      operatorId: 'op-1',
      locationId: locationId,
      effective: LocationAccountOverridesFieldSet(
        ianaTimezone: patch.ianaTimezone ?? businessDefault.ianaTimezone,
        localeCode: patch.localeCode ?? businessDefault.localeCode,
        currencyCode: patch.currencyCode ?? businessDefault.currencyCode,
        businessDayRolloverHour:
            patch.businessDayRolloverHour ??
            businessDefault.businessDayRolloverHour,
        contactEmail: patch.contactEmail,
        contactPhone: patch.contactPhone,
      ),
      override: LocationAccountOverridesFieldSet(
        ianaTimezone: patch.ianaTimezone,
        localeCode: patch.localeCode,
        currencyCode: patch.currencyCode,
        businessDayRolloverHour: patch.businessDayRolloverHour,
        contactEmail: patch.contactEmail,
        contactPhone: patch.contactPhone,
      ),
      businessDefault: businessDefault,
      updatedAt: DateTime.utc(2026, 5, 14, 12),
    );
  }
}

OperatorWebSession sessionWithRole(
  String role, {
  String? primaryLocationTimezone = 'America/Toronto',
}) => OperatorWebSession(
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

Future<void> _openScopeDetails(WidgetTester tester) async {
  await tester.ensureVisible(
    find.byKey(const Key('operator_web_account_scope_details_toggle')),
  );
  await tester.tap(
    find.byKey(const Key('operator_web_account_scope_details_toggle')),
  );
  await tester.pumpAndSettle();
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
      find.byKey(const Key('operator_web_account_rollover_hour')),
      findsNothing,
    );
    expect(
      find.byKey(
        const Key('operator_web_account_business_day_rollover_readonly'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const Key('operator_web_account_rollover_business_timing_link'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('operator_web_account_save')), findsOneWidget);
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
      wrap(AccountScreen(session: session, gateway: _FakeAccountGateway())),
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

  testWidgets('happy-path save calls gateway with patch fields', (
    tester,
  ) async {
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
    // The Account screen is long enough that Save may sit below the
    // 1600px viewport; scroll it into view before tapping.
    await tester.ensureVisible(
      find.byKey(const Key('operator_web_account_save')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('operator_web_account_save')));
    await tester.pumpAndSettle();

    expect(gateway.calls, hasLength(1));
    expect(gateway.calls.single.businessName, 'Brio Restaurants');
    expect(gateway.calls.single.weekStartDay, isNull);
    expect(gateway.calls.single.rolloverHour, isNull);
    expect(
      find.byKey(const Key('operator_web_account_success')),
      findsOneWidget,
    );
  });

  testWidgets('gateway error surfaces in the inline error banner', (
    tester,
  ) async {
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
    // The Account screen is long enough that Save may sit below the
    // default viewport; scroll first.
    await tester.ensureVisible(
      find.byKey(const Key('operator_web_account_save')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('operator_web_account_save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('operator_web_account_error')), findsOneWidget);
    expect(
      find.text('Currency code must be three uppercase letters.'),
      findsOneWidget,
    );
  });

  // Wave 2 W-6 — timezone section coverage.

  testWidgets(
    'timezone section renders with account scope summary + current value',
    (tester) async {
      await _sizeViewport(tester);
      final session = sessionWithRole('operator_owner');
      await tester.pumpWidget(
        wrap(AccountScreen(session: session, gateway: _FakeAccountGateway())),
      );
      expect(
        find.byKey(const Key('operator_web_account_section_location_timezone')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_account_scope_summary')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_account_scope_pill')),
        findsOneWidget,
      );
      await _openScopeDetails(tester);
      expect(
        find.byKey(const Key('operator_web_account_timezone_scope_summary')),
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
      expect(find.textContaining('America/Toronto'), findsWidgets);
    },
  );

  testWidgets('timezone save refreshes the summary source wording', (
    tester,
  ) async {
    await _sizeViewport(tester);
    final gateway = _FakeAccountGateway();
    final session = sessionWithRole(
      'operator_owner',
      primaryLocationTimezone: 'America/Toronto',
    );
    const savedSourceLabel = 'Set here. Does not inherit from a higher scope.';
    const unsavedSourceLabel =
        'Unsaved change here. Save timezone to set it at Location: '
        'Brio Main.';
    await tester.pumpWidget(
      wrap(AccountScreen(session: session, gateway: gateway)),
    );
    await _openScopeDetails(tester);
    expect(
      find.descendant(
        of: find.byKey(
          const Key('operator_web_account_timezone_scope_summary'),
        ),
        matching: find.text(savedSourceLabel, findRichText: true),
      ),
      findsOneWidget,
    );
    // The Account screen is long enough that the timezone shortlist
    // may sit below the viewport; scroll it into view first.
    await tester.ensureVisible(
      find.byKey(const Key('operator_web_account_timezone_shortlist')),
    );
    await tester.pumpAndSettle();

    // Open the dropdown and pick a different shortlist option.
    await tester.tap(
      find.byKey(const Key('operator_web_account_timezone_shortlist')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('London / Dublin').last);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(
          const Key('operator_web_account_timezone_scope_summary'),
        ),
        matching: find.text(unsavedSourceLabel, findRichText: true),
      ),
      findsOneWidget,
    );

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
    expect(
      find.descendant(
        of: find.byKey(
          const Key('operator_web_account_timezone_scope_summary'),
        ),
        matching: find.text(unsavedSourceLabel, findRichText: true),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(
          const Key('operator_web_account_timezone_scope_summary'),
        ),
        matching: find.text(savedSourceLabel, findRichText: true),
      ),
      findsOneWidget,
    );
  });

  testWidgets('timezone gateway error surfaces in the inline timezone banner', (
    tester,
  ) async {
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
    // The Account screen is long enough that the timezone save button
    // may sit below the viewport; scroll it into view before tapping.
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
  });

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
      await _openScopeDetails(tester);
      expect(
        find.text('No timezone is on file. Set one to lock daily timing.'),
        findsOneWidget,
      );
    },
  );

  // Wave 2 U-FU-hp11-account: HP #11 selected scope, source, and
  // current value coverage for the Account screen summary panel.

  group('HP #11 scope summary', () {
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

    testWidgets('Business scope renders summary rows without inheritance', (
      tester,
    ) async {
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
        find.byKey(const Key('operator_web_account_scope_summary')),
        findsOneWidget,
      );
      await _openScopeDetails(tester);
      expect(
        find.byKey(const Key('operator_web_account_identity_scope_summary')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_account_region_scope_summary')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('operator_web_account_business_day_scope_summary'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_account_timezone_scope_summary')),
        findsOneWidget,
      );
      expect(
        find.text(
          'Set here. Does not inherit from a higher scope.',
          findRichText: true,
        ),
        findsNWidgets(4),
      );
      // Save stays enabled at Business scope when the gateway is
      // wired + the operator has edit permission.
      final saveButton = tester.widget<ButtonStyleButton>(
        find.byKey(const Key('operator_web_account_save')),
      );
      expect(saveButton.onPressed, isNotNull);
    });

    testWidgets(
      'Location scope with no override renders the inheritance line + '
      'enables Save (U-FU-hp11-account-schema)',
      (tester) async {
        await _sizeViewport(tester);
        final session = sessionWithRole('operator_owner');
        final gateway = _FakeAccountGateway();
        await tester.pumpWidget(
          wrap(
            AccountScreen(
              session: session,
              gateway: gateway,
              selectedScope: locationScope,
            ),
          ),
        );
        // Let the post-frame loadLocationOverrides round-trip settle.
        await tester.pumpAndSettle();
        await _openScopeDetails(tester);
        // The summary rows show inheritance copy carrying the business default.
        expect(
          find.textContaining(
            'Inherits the business default from Business:',
            findRichText: true,
          ),
          findsNWidgets(3),
        );
        // The backend-only explainer is NO LONGER rendered at Location
        // scope — the slice replaces the PUNT-mode copy with a real
        // override surface.
        expect(
          find.textContaining(
            'Per-location overrides for this field are not on file yet.',
          ),
          findsNothing,
        );
        // The screen called the override-load gateway.
        expect(gateway.overridesGetCalls, contains('loc-1'));
        // Save is ENABLED at Location scope because the per-location
        // override route is the new write target.
        final saveButton = tester.widget<ButtonStyleButton>(
          find.byKey(const Key('operator_web_account_save')),
        );
        expect(saveButton.onPressed, isNotNull);
        // The business-name field stays disabled (single business
        // name doctrine).
        final businessNameField = tester.widget<TextField>(
          find.byKey(const Key('operator_web_account_business_name')),
        );
        expect(businessNameField.enabled, isFalse);
        // The new contact email + phone fields render and are
        // editable at Location scope.
        final contactEmailField = tester.widget<TextField>(
          find.byKey(const Key('operator_web_account_contact_email')),
        );
        expect(contactEmailField.enabled, isTrue);
      },
    );

    testWidgets('Location scope region source changes while draft is unsaved', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final session = sessionWithRole('operator_owner');
      final gateway = _FakeAccountGateway();
      await tester.pumpWidget(
        wrap(
          AccountScreen(
            session: session,
            gateway: gateway,
            selectedScope: locationScope,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const Key('operator_web_account_currency')),
      );
      await tester.tap(find.byKey(const Key('operator_web_account_currency')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Euro (EUR)').last);
      await tester.pumpAndSettle();

      await _openScopeDetails(tester);
      expect(
        find.text(
          'Unsaved change here. Save to set these region settings at '
          'Location: Brio Main.',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_account_region_scope_summary')),
        findsOneWidget,
      );

      await tester.ensureVisible(
        find.byKey(const Key('operator_web_account_save')),
      );
      await tester.tap(find.byKey(const Key('operator_web_account_save')));
      await tester.pumpAndSettle();

      expect(gateway.overridesPatchCalls, hasLength(1));
      expect(gateway.overridesPatchCalls.single.patch.currencyCode, 'EUR');
      expect(
        find.descendant(
          of: find.byKey(
            const Key('operator_web_account_region_scope_summary'),
          ),
          matching: find.textContaining(
            'Set here at Brio Main.',
            findRichText: true,
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'Location scope contact source updates while draft is unsaved',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        final session = sessionWithRole('operator_owner');
        final gateway = _FakeAccountGateway();
        await tester.pumpWidget(
          wrap(
            AccountScreen(
              session: session,
              gateway: gateway,
              selectedScope: locationScope,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _openScopeDetails(tester);

        await tester.ensureVisible(
          find.byKey(const Key('operator_web_account_contact_email')),
        );
        await tester.enterText(
          find.byKey(const Key('operator_web_account_contact_email')),
          'ops@brio-main.com',
        );
        await tester.pumpAndSettle();

        expect(
          find.descendant(
            of: find.byKey(
              const Key('operator_web_account_identity_scope_summary'),
            ),
            matching: find.text(
              'Unsaved change here. Save to set these contact details at '
              'Location: Brio Main.',
              findRichText: true,
            ),
          ),
          findsOneWidget,
        );

        await tester.ensureVisible(
          find.byKey(const Key('operator_web_account_save')),
        );
        await tester.tap(find.byKey(const Key('operator_web_account_save')));
        await tester.pumpAndSettle();

        expect(gateway.overridesPatchCalls, hasLength(1));
        expect(
          find.descendant(
            of: find.byKey(
              const Key('operator_web_account_identity_scope_summary'),
            ),
            matching: find.textContaining(
              'Set here at Brio Main.',
              findRichText: true,
            ),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('Location scope save round-trips an override patch through the '
        'gateway', (tester) async {
      // U-FU-hp11-account adds the contact-email + contact-phone
      // fields at the bottom of the Identity card, plus the
      // location-overrides banner; the default 1600px viewport
      // pushes Save below the fold. Use a taller viewport so the
      // tap hits.
      tester.view.physicalSize = const Size(1280, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final session = sessionWithRole('operator_owner');
      final gateway = _FakeAccountGateway();
      await tester.pumpWidget(
        wrap(
          AccountScreen(
            session: session,
            gateway: gateway,
            selectedScope: locationScope,
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Type a new contact email so the patch carries it.
      await tester.ensureVisible(
        find.byKey(const Key('operator_web_account_contact_email')),
      );
      await tester.enterText(
        find.byKey(const Key('operator_web_account_contact_email')),
        'ops@brio-main.com',
      );
      await tester.ensureVisible(
        find.byKey(const Key('operator_web_account_save')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('operator_web_account_save')));
      await tester.pumpAndSettle();
      // The override gateway must have been called; the operator-
      // level patchAccount path must NOT have been touched.
      expect(gateway.overridesPatchCalls.length, equals(1));
      final call = gateway.overridesPatchCalls.single;
      expect(call.locationId, equals('loc-1'));
      expect(call.patch.contactEmail, equals('ops@brio-main.com'));
      expect(call.patch.businessDayRolloverHour, isNull);
      expect(gateway.calls, isEmpty);
      // Success banner renders.
      expect(
        find.byKey(const Key('operator_web_account_success')),
        findsOneWidget,
      );
    });

    testWidgets('Location scope with an existing override renders the '
        '"Set here" inheritance line carrying the business default', (
      tester,
    ) async {
      await _sizeViewport(tester);
      final session = sessionWithRole('operator_owner');
      final gateway = _FakeAccountGateway(
        initialOverrides: LocationAccountOverridesEnvelope(
          operatorId: 'op-1',
          locationId: 'loc-1',
          effective: const LocationAccountOverridesFieldSet(
            ianaTimezone: 'Europe/London',
            localeCode: 'en-GB',
            currencyCode: 'GBP',
            businessDayRolloverHour: 4,
            contactEmail: 'ops@example.com',
          ),
          override: const LocationAccountOverridesFieldSet(
            currencyCode: 'GBP',
            localeCode: 'en-GB',
            contactEmail: 'ops@example.com',
          ),
          businessDefault: const LocationAccountOverridesFieldSet(
            ianaTimezone: 'America/Toronto',
            localeCode: 'en-US',
            currencyCode: 'USD',
            businessDayRolloverHour: 4,
          ),
          updatedAt: DateTime.utc(2026, 5, 14, 12),
        ),
      );
      await tester.pumpWidget(
        wrap(
          AccountScreen(
            session: session,
            gateway: gateway,
            selectedScope: locationScope,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _openScopeDetails(tester);
      // The region summary carries the "Set here at <location>. Business
      // default: <value>." copy because the override row is on file.
      expect(
        find.textContaining('Set here at Brio Main.', findRichText: true),
        findsWidgets,
      );
      // At least one summary row surfaces the business default value
      // alongside the override.
      expect(
        find.textContaining(
          'Business default: USD / en-US',
          findRichText: true,
        ),
        findsWidgets,
      );
    });

    testWidgets('Region scope row carries the current value summary', (
      tester,
    ) async {
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
      await _openScopeDetails(tester);
      expect(find.textContaining('Currency is USD'), findsWidgets);
      expect(find.textContaining('locale is en-US'), findsWidgets);
    });

    testWidgets('Business day scope row carries the current value summary', (
      tester,
    ) async {
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
      await _openScopeDetails(tester);
      expect(find.textContaining('Week starts Monday'), findsWidgets);
      expect(
        find.byKey(
          const Key('operator_web_account_week_start_business_timing_link'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Business day rollover is'), findsWidgets);
      expect(find.textContaining('04:00 local'), findsWidgets);
      expect(
        find.textContaining('Sales before that time count'),
        findsOneWidget,
      );
    });

    testWidgets('Business Timing links call back to the router', (
      tester,
    ) async {
      await _sizeViewport(tester);
      final session = sessionWithRole('operator_owner');
      var opened = 0;
      await tester.pumpWidget(
        wrap(
          AccountScreen(
            session: session,
            gateway: _FakeAccountGateway(),
            selectedScope: businessScope,
            onOpenBusinessTiming: () => opened += 1,
          ),
        ),
      );

      await tester.ensureVisible(
        find.byKey(
          const Key('operator_web_account_rollover_business_timing_link'),
        ),
      );
      await tester.tap(
        find.byKey(
          const Key('operator_web_account_rollover_business_timing_link'),
        ),
      );

      expect(opened, 1);
    });
  });
}
