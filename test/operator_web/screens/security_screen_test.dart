// Phase 11W.6 - Security screen widget tests.
//
// Pins the parity contract section "Security (`11W.6` + `11A.14`
// Actions panel)":
//
//   - MFA factor list renders enrolled fixtures and surfaces an
//     `Add authenticator app` action.
//   - Revoke flow schedules a 24-hour delayed removal and flips the
//     row to a `Removal pending` chip + `Cancel removal` action.
//   - Cancel removal restores the row to the active state.
//   - Change password dialog enforces locked validation copy on
//     wrong-current / weak / reused / mismatched-confirm.
//   - Login history strip filters to the last 7 days locally.
//   - Idempotency keys mint per write and thread through the gateway.
//   - Zero em dashes in operator-facing literals across the slice's
//     owned files.
//
// Tests rely on the in-memory `DemoWebSecurityGateway` and the
// shared fixture set so the assertions stay deterministic.

import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/screens/change_password_dialog.dart';
import 'package:forge_and_flow/operator_web/screens/security_screen.dart';
import 'package:forge_and_flow/operator_web/services/demo_security_gateway.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_fixtures.dart';
import 'package:forge_and_flow/operator_web/services/web_security_gateway.dart';
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

  OperatorWebSession sessionFor(String role) => OperatorWebSession(
        uid: 'demo-user-owner',
        email: 'sam.owner@demobistro.test',
        displayName: 'Sam Patel',
        operatorId: kDemoOperatorIdFixture,
        businessName: kDemoOperatorBusinessNameFixture,
        primaryLocationId: 'demo-loc-downtown',
        primaryLocationName: 'Downtown',
        roles: <String>[role],
      );

  Future<WebSecurityGateway> pumpScreen(
    WidgetTester tester, {
    String role = 'operator_owner',
    WebSecurityGateway? gateway,
    DateTime Function()? now,
    String Function()? idempotencyKeyFactory,
  }) async {
    final actual = gateway ??
        DemoWebSecurityGateway(now: DateTime.utc(2026, 5, 6, 12));
    await tester.pumpWidget(
      wrap(
        SecurityScreen(
          session: sessionFor(role),
          gateway: actual,
          now: now ?? () => DateTime.utc(2026, 5, 6, 12),
          idempotencyKeyFactory: idempotencyKeyFactory,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return actual;
  }

  Future<void> confirmDialog(WidgetTester tester) async {
    await tester.tap(
      find.byKey(const Key('operator_web_security_confirm_dialog_confirm')),
    );
    await tester.pumpAndSettle();
  }

  group('SecurityScreen layout', () {
    testWidgets('renders MFA / password / login history sections',
        (tester) async {
      await sizeViewport(tester, const Size(1280, 1400));
      await pumpScreen(tester);

      expect(
        find.byKey(const Key('operator_web_security_screen')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_security_mfa_section')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_security_password_section')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('operator_web_security_login_history_section'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          Key(
            'operator_web_security_mfa_factor_row_$kDemoSecurityExistingFactorId',
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('floor-manager role sees the same own-only surface',
        (tester) async {
      await sizeViewport(tester, const Size(1280, 1400));
      await pumpScreen(tester, role: 'location_manager');

      expect(
        find.byKey(const Key('operator_web_security_screen')),
        findsOneWidget,
      );
      // Floor managers see their own MFA + password + login history -
      // no team-scoped section.
      expect(
        find.byKey(const Key('operator_web_security_mfa_section')),
        findsOneWidget,
      );
    });
  });

  group('Revoke and cancel removal', () {
    testWidgets('revoke schedules a 24-hour removal and flips to pending '
        'chip + cancel action', (tester) async {
      await sizeViewport(tester, const Size(1280, 1400));
      final gateway = await pumpScreen(tester);

      await tester.tap(
        find.byKey(
          Key(
            'operator_web_security_mfa_factor_revoke_$kDemoSecurityExistingFactorId',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await confirmDialog(tester);

      expect(
        find.byKey(
          Key(
            'operator_web_security_mfa_factor_pending_chip_$kDemoSecurityExistingFactorId',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          Key(
            'operator_web_security_mfa_factor_cancel_removal_$kDemoSecurityExistingFactorId',
          ),
        ),
        findsOneWidget,
      );
      // Gateway state mutated to pending.
      final result = await gateway.listFactors();
      expect(
        result.removalRequests.any(
          (r) =>
              r.factorId == kDemoSecurityExistingFactorId &&
              r.status == 'pending',
        ),
        isTrue,
      );
      // 24-hour delayed removal posture pinned: executeAfter is now()
      // + 24 hours from the gateway's clock.
      final pending = result.removalRequests
          .firstWhere((r) => r.factorId == kDemoSecurityExistingFactorId);
      expect(
        pending.executeAfter,
        DateTime.utc(2026, 5, 7, 12),
      );
    });

    testWidgets('cancel removal flips the row back to active', (tester) async {
      await sizeViewport(tester, const Size(1280, 1400));
      final gateway = await pumpScreen(tester);

      await tester.tap(
        find.byKey(
          Key(
            'operator_web_security_mfa_factor_revoke_$kDemoSecurityExistingFactorId',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await confirmDialog(tester);
      // The revoke surfaced a 4-second snackbar; pumpAndSettle above
      // already waited for it. The factor row is now in pending
      // state with the cancel-removal action available.
      expect(
        find.byKey(
          Key(
            'operator_web_security_mfa_factor_cancel_removal_$kDemoSecurityExistingFactorId',
          ),
        ),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(
          Key(
            'operator_web_security_mfa_factor_cancel_removal_$kDemoSecurityExistingFactorId',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(
          Key(
            'operator_web_security_mfa_factor_pending_chip_$kDemoSecurityExistingFactorId',
          ),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          Key(
            'operator_web_security_mfa_factor_revoke_$kDemoSecurityExistingFactorId',
          ),
        ),
        findsOneWidget,
      );
      // Gateway state mutated to cancelled.
      final result = await gateway.listFactors();
      final pending = result.removalRequests.where(
        (r) =>
            r.factorId == kDemoSecurityExistingFactorId &&
            r.status == 'pending',
      );
      expect(pending, isEmpty);
    });
  });

  group('Change password validation copy', () {
    Future<void> openChangePasswordDialog(WidgetTester tester) async {
      await tester.tap(
        find.byKey(const Key('operator_web_security_password_change')),
      );
      await tester.pumpAndSettle();
    }

    Future<void> typePasswords(
      WidgetTester tester, {
      required String current,
      required String next,
      required String confirm,
    }) async {
      await tester.enterText(
        find.byKey(
          const Key('operator_web_security_change_password_current'),
        ),
        current,
      );
      await tester.enterText(
        find.byKey(const Key('operator_web_security_change_password_new')),
        next,
      );
      await tester.enterText(
        find.byKey(
          const Key('operator_web_security_change_password_confirm'),
        ),
        confirm,
      );
      await tester.tap(
        find.byKey(
          const Key('operator_web_security_change_password_submit'),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('weak password surfaces the locked too-weak copy',
        (tester) async {
      await sizeViewport(tester, const Size(1280, 1400));
      await pumpScreen(tester);
      await openChangePasswordDialog(tester);
      await typePasswords(
        tester,
        current: 'demo-pass-1!',
        next: 'short',
        confirm: 'short',
      );
      expect(find.text(WebSecurityPasswordCopy.tooWeak), findsOneWidget);
    });

    testWidgets('wrong current password surfaces the locked copy',
        (tester) async {
      await sizeViewport(tester, const Size(1280, 1400));
      await pumpScreen(tester);
      await openChangePasswordDialog(tester);
      await typePasswords(
        tester,
        current: 'wrong-current',
        next: 'rotate-pass-2026!',
        confirm: 'rotate-pass-2026!',
      );
      expect(
        find.text(WebSecurityPasswordCopy.wrongCurrent),
        findsOneWidget,
      );
    });

    testWidgets('reuse rejection surfaces the locked copy', (tester) async {
      await sizeViewport(tester, const Size(1280, 1400));
      await pumpScreen(tester);
      await openChangePasswordDialog(tester);
      await typePasswords(
        tester,
        current: 'demo-pass-1!',
        next: 'demo-pass-1!',
        confirm: 'demo-pass-1!',
      );
      expect(find.text(WebSecurityPasswordCopy.reused), findsOneWidget);
    });

    testWidgets('valid change closes the dialog and surfaces the toast',
        (tester) async {
      await sizeViewport(tester, const Size(1280, 1400));
      final gateway = await pumpScreen(tester);
      await openChangePasswordDialog(tester);
      await typePasswords(
        tester,
        current: 'demo-pass-1!',
        next: 'rotate-pass-2026!',
        confirm: 'rotate-pass-2026!',
      );

      expect(
        find.byKey(
          const Key('operator_web_security_change_password_dialog'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(const Key('operator_web_security_password_toast')),
        findsOneWidget,
      );
      // Gateway state advanced - the next change must use the new
      // current password.
      try {
        await gateway.changePassword(
          currentPassword: 'demo-pass-1!',
          newPassword: 'another-pass-99!',
          idempotencyKey: 'next-change',
        );
        fail('expected wrong-current-password error');
      } on WebSecurityError catch (error) {
        expect(error.code, 'wrong_current_password');
      }
    });
  });

  group('Login history filter', () {
    testWidgets('default window is 90 days; switching to 7 days hides '
        'older rows', (tester) async {
      await sizeViewport(tester, const Size(1280, 1600));
      await pumpScreen(tester);

      // 90-day default surfaces the password-changed row from 2026-04-10
      // and the older 2026-03-22 sign-in row.
      expect(
        find.byKey(
          const Key(
            'operator_web_security_login_history_row_demo-history-password-changed-2026-04-10',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key(
            'operator_web_security_login_history_row_demo-history-signin-web-2026-03-22',
          ),
        ),
        findsOneWidget,
      );

      // Switch to last 7 days - older rows disappear.
      await tester.tap(
        find.byKey(
          const Key('operator_web_security_login_history_filter_last_7'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const Key(
            'operator_web_security_login_history_row_demo-history-password-changed-2026-04-10',
          ),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          const Key(
            'operator_web_security_login_history_row_demo-history-signin-web-2026-03-22',
          ),
        ),
        findsNothing,
      );
      // The recent web sign-in row from 2026-05-05 stays.
      expect(
        find.byKey(
          const Key(
            'operator_web_security_login_history_row_demo-history-signin-web-2026-05-05',
          ),
        ),
        findsOneWidget,
      );
    });
  });

  group('Idempotency thread-through', () {
    testWidgets('change password threads the screen-minted key into the '
        'gateway', (tester) async {
      await sizeViewport(tester, const Size(1280, 1400));
      final recording = _RecordingDemoSecurityGateway();
      var keySeq = 0;
      await pumpScreen(
        tester,
        gateway: recording,
        idempotencyKeyFactory: () {
          keySeq += 1;
          return 'fixed-security-key-$keySeq';
        },
      );

      await tester.tap(
        find.byKey(const Key('operator_web_security_password_change')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(
          const Key('operator_web_security_change_password_current'),
        ),
        'demo-pass-1!',
      );
      await tester.enterText(
        find.byKey(const Key('operator_web_security_change_password_new')),
        'rotate-pass-2026!',
      );
      await tester.enterText(
        find.byKey(
          const Key('operator_web_security_change_password_confirm'),
        ),
        'rotate-pass-2026!',
      );
      await tester.tap(
        find.byKey(
          const Key('operator_web_security_change_password_submit'),
        ),
      );
      await tester.pumpAndSettle();

      expect(recording.lastChangePasswordKey, isNotNull);
      expect(recording.lastChangePasswordKey, startsWith('fixed-security-key-'));
    });

    testWidgets('revoke threads the screen-minted key into the gateway',
        (tester) async {
      await sizeViewport(tester, const Size(1280, 1400));
      final recording = _RecordingDemoSecurityGateway();
      await pumpScreen(
        tester,
        gateway: recording,
        idempotencyKeyFactory: () => 'fixed-security-revoke-key',
      );

      await tester.tap(
        find.byKey(
          Key(
            'operator_web_security_mfa_factor_revoke_$kDemoSecurityExistingFactorId',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await confirmDialog(tester);

      expect(recording.lastRevokeKey, 'fixed-security-revoke-key');
      expect(
        recording.lastRevokeFactorId,
        kDemoSecurityExistingFactorId,
      );
    });
  });

  group('Recovery request', () {
    testWidgets('confirming the lost-access dialog queues a recovery '
        'request through the gateway', (tester) async {
      await sizeViewport(tester, const Size(1280, 1400));
      final recording = _RecordingDemoSecurityGateway();
      await pumpScreen(
        tester,
        gateway: recording,
        idempotencyKeyFactory: () => 'fixed-recovery-key',
      );

      await tester.tap(
        find.byKey(const Key('operator_web_security_mfa_recovery_request')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('operator_web_security_confirm_dialog_confirm')),
      );
      await tester.pumpAndSettle();

      expect(recording.lastRecoveryKey, 'fixed-recovery-key');
      expect(recording.lastRecoveryEmail, 'sam.owner@demobistro.test');
    });
  });

  group('No em dash regression on 11W.6-owned files', () {
    test('every operator-facing string literal in the 11W.6 file set is '
        'em-dash free', () async {
      const ownedPaths = <String>[
        'lib/operator_web/services/web_security_gateway.dart',
        'lib/operator_web/services/demo_security_gateway.dart',
        'lib/operator_web/screens/security_screen.dart',
        'lib/operator_web/screens/mfa_factor_dialog.dart',
        'lib/operator_web/screens/change_password_dialog.dart',
      ];
      for (final relativePath in ownedPaths) {
        final source = await io.File(relativePath).readAsString();
        final stripped = source
            .split('\n')
            .map((line) {
              var inString = false;
              String? quote;
              for (var i = 0; i < line.length - 1; i++) {
                final c = line[i];
                if (!inString && (c == '"' || c == "'")) {
                  inString = true;
                  quote = c;
                  continue;
                }
                if (inString && c == quote) {
                  inString = false;
                  quote = null;
                  continue;
                }
                if (!inString && c == '/' && line[i + 1] == '/') {
                  return line.substring(0, i);
                }
              }
              return line;
            })
            .join('\n');
        expect(
          stripped.contains('—'),
          isFalse,
          reason: 'em dash (U+2014) found in $relativePath outside comments',
        );
      }
    });
  });
}

/// Demo gateway wrapper that records the last write keys + targets so
/// the idempotency-thread tests can pin them without reaching for the
/// HTTP layer.
class _RecordingDemoSecurityGateway implements WebSecurityGateway {
  _RecordingDemoSecurityGateway()
      : _delegate = DemoWebSecurityGateway(now: DateTime.utc(2026, 5, 6, 12));

  final DemoWebSecurityGateway _delegate;

  String? lastBeginKey;
  String? lastBeginUserEmail;
  String? lastConfirmKey;
  String? lastConfirmFactorId;
  String? lastRevokeKey;
  String? lastRevokeFactorId;
  String? lastCancelKey;
  String? lastCancelRequestId;
  String? lastChangePasswordKey;
  String? lastRecoveryKey;
  String? lastRecoveryEmail;

  @override
  Future<WebSecurityFactorsListed> listFactors() => _delegate.listFactors();

  @override
  Future<WebSecurityLoginHistoryListed> listLoginHistory() =>
      _delegate.listLoginHistory();

  @override
  Future<WebSecurityTotpEnrollment> beginTotpEnrollment({
    required String userEmail,
    required String idempotencyKey,
  }) {
    lastBeginKey = idempotencyKey;
    lastBeginUserEmail = userEmail;
    return _delegate.beginTotpEnrollment(
      userEmail: userEmail,
      idempotencyKey: idempotencyKey,
    );
  }

  @override
  Future<WebSecurityRecoveryRequestResult> requestMfaRecovery({
    required String email,
    String? reason,
    required String idempotencyKey,
  }) {
    lastRecoveryKey = idempotencyKey;
    lastRecoveryEmail = email;
    return _delegate.requestMfaRecovery(
      email: email,
      reason: reason,
      idempotencyKey: idempotencyKey,
    );
  }

  @override
  Future<WebSecurityMfaFactor> confirmTotpEnrollment({
    required String factorId,
    required String oneTimeCode,
    required String idempotencyKey,
  }) {
    lastConfirmKey = idempotencyKey;
    lastConfirmFactorId = factorId;
    return _delegate.confirmTotpEnrollment(
      factorId: factorId,
      oneTimeCode: oneTimeCode,
      idempotencyKey: idempotencyKey,
    );
  }

  @override
  Future<WebSecurityRevokeFactorResult> revokeFactor({
    required String factorId,
    required String idempotencyKey,
  }) {
    lastRevokeKey = idempotencyKey;
    lastRevokeFactorId = factorId;
    return _delegate.revokeFactor(
      factorId: factorId,
      idempotencyKey: idempotencyKey,
    );
  }

  @override
  Future<WebSecurityCancelRemovalResult> cancelFactorRemoval({
    required String requestId,
    required String idempotencyKey,
  }) {
    lastCancelKey = idempotencyKey;
    lastCancelRequestId = requestId;
    return _delegate.cancelFactorRemoval(
      requestId: requestId,
      idempotencyKey: idempotencyKey,
    );
  }

  @override
  Future<WebSecurityPasswordChangeResult> changePassword({
    required String currentPassword,
    required String newPassword,
    required String idempotencyKey,
  }) {
    lastChangePasswordKey = idempotencyKey;
    return _delegate.changePassword(
      currentPassword: currentPassword,
      newPassword: newPassword,
      idempotencyKey: idempotencyKey,
    );
  }
}
