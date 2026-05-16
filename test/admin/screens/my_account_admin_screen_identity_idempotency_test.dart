// Audit finding G70 — admin "My Account" identity-edit idempotency
// regression cover. Extends the #855/G60 stable-key pattern that the
// sibling password / recovery / MFA-confirm dialogs already honor.
//
// Before the fix, `_AdminEditIdentityDialog._handleSave` re-minted a
// FRESH idempotency key on every submit attempt. The failure path keeps
// the dialog open, so a timeout/5xx-then-retap re-ran `_handleSave`
// with a NEW key — the proxy `proxy_requests` UNIQUE guard could no
// longer collapse the duplicate, so the same identity PATCH (email
// change forces sign-out) could apply twice. These tests pin:
//
//  1. A retried identity save reuses the SAME Idempotency-Key (the
//     proxy collapses the retry).
//  2. A distinct edit (dialog reopened for a new logical save) uses a
//     DISTINCT key.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_auth_gate.dart';
import 'package:forge_and_flow/admin/screens/my_account_admin_screen.dart';
import 'package:forge_and_flow/admin/services/admin_account_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

/// Recording account gateway. Captures every idempotency key handed to
/// `patchSelfProfile` and lets the test script per-call success/failure
/// so the dialog's retryable failure path can be exercised.
class _RecordingAdminAccountGateway implements AdminAccountGateway {
  _RecordingAdminAccountGateway({this.failuresBeforeSuccess = 0});

  /// How many leading calls throw a retryable gateway error before the
  /// gateway starts succeeding. Models a proxy timeout / 5xx.
  int failuresBeforeSuccess;

  final List<String> idempotencyKeys = <String>[];
  int _calls = 0;

  @override
  Future<AdminAccountProfilePatched> patchSelfProfile({
    String? displayName,
    String? email,
    required String idempotencyKey,
  }) async {
    idempotencyKeys.add(idempotencyKey);
    _calls += 1;
    if (_calls <= failuresBeforeSuccess) {
      throw const AdminAccountGatewayError(
        statusCode: 504,
        errorCode: 'upstream_timeout',
        message: 'The admin console timed out reaching the account service.',
      );
    }
    return AdminAccountProfilePatched(
      userId: 'demo-super-admin',
      email: email ?? 'super.admin@forgeflow.test',
      displayName: displayName ?? 'Demo Super Admin',
      emailChanged: email != null,
      displayNameChanged: displayName != null,
    );
  }
}

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

  AdminAuthSession session() => AdminAuthSession(
        uid: 'demo-super-admin',
        email: 'super.admin@forgeflow.test',
        displayName: 'Demo Super Admin',
        roles: const <String>['super_admin'],
        lastFreshAuthAt: DateTime.utc(2026, 5, 14, 12, 0, 0),
      );

  testWidgets(
      'G70: a retried identity save reuses the SAME Idempotency-Key',
      (tester) async {
    wideViewport(tester);
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);
    // First submit fails (timeout) — the dialog stays open so the
    // admin re-taps Save. The second submit must reuse the key.
    final gateway = _RecordingAdminAccountGateway(failuresBeforeSuccess: 1);

    await tester.pumpWidget(
      wrap(
        MyAccountAdminScreen(
          session: session(),
          authSource: source,
          accountGateway: gateway,
          now: () => DateTime.utc(2026, 5, 14, 12, 30, 0),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('admin_my_account_identity_edit')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('admin_edit_identity_dialog')),
      findsOneWidget,
    );

    // Change the display name only (no email-confirm gate needed).
    await tester.enterText(
      find.byKey(const Key('admin_edit_identity_display_name_field')),
      'Demo Super Admin Renamed',
    );
    await tester.pump();

    // First attempt → gateway throws, dialog stays open with an error.
    await tester.tap(find.byKey(const Key('admin_edit_identity_save')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('admin_edit_identity_dialog')),
      findsOneWidget,
      reason: 'A retryable failure must keep the dialog open.',
    );
    expect(
      find.byKey(const Key('admin_edit_identity_error')),
      findsOneWidget,
    );

    // Re-tap Save (the retry). This succeeds and closes the dialog.
    await tester.tap(find.byKey(const Key('admin_edit_identity_save')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('admin_edit_identity_dialog')),
      findsNothing,
    );

    // The retry rode the SAME key — the proxy UNIQUE guard collapses
    // it. Two calls, one distinct key (no G70 fresh-mint regression).
    expect(gateway.idempotencyKeys, hasLength(2));
    expect(
      gateway.idempotencyKeys.toSet(),
      hasLength(1),
      reason: 'A retried identity save must reuse one caller-stable key.',
    );
    expect(
      gateway.idempotencyKeys.first,
      startsWith('admin-self-profile-'),
    );
  });

  testWidgets(
      'G70: a distinct identity edit uses a DISTINCT Idempotency-Key',
      (tester) async {
    wideViewport(tester);
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);
    final gateway = _RecordingAdminAccountGateway();

    await tester.pumpWidget(
      wrap(
        MyAccountAdminScreen(
          session: session(),
          authSource: source,
          accountGateway: gateway,
          now: () => DateTime.utc(2026, 5, 14, 12, 30, 0),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // First logical save.
    await tester.tap(
      find.byKey(const Key('admin_my_account_identity_edit')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('admin_edit_identity_display_name_field')),
      'First Rename',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('admin_edit_identity_save')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('admin_edit_identity_dialog')),
      findsNothing,
    );

    // Second, separate logical save — reopen the dialog and edit again.
    await tester.tap(
      find.byKey(const Key('admin_my_account_identity_edit')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('admin_edit_identity_display_name_field')),
      'Second Rename',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('admin_edit_identity_save')));
    await tester.pumpAndSettle();

    expect(gateway.idempotencyKeys, hasLength(2));
    expect(
      gateway.idempotencyKeys.toSet(),
      hasLength(2),
      reason: 'Two distinct logical saves must use two distinct keys.',
    );
    for (final key in gateway.idempotencyKeys) {
      expect(key, startsWith('admin-self-profile-'));
    }
  });
}
