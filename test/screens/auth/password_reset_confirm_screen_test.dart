// Phase 9.UX.7 - PasswordResetConfirmScreen widget tests.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/auth/password_policy.dart';
import 'package:forge_and_flow/screens/auth/password_reset_confirm_screen.dart';
import 'package:forge_and_flow/services/auth/password_reset_gateway.dart';

void main() {
  group('PasswordResetConfirmScreen', () {
    test('default minimum aligns with PasswordPolicy.minLength', () {
      const screen = PasswordResetConfirmScreen(
        gateway: DemoPasswordResetGateway(),
        oobCode: 'oob',
      );
      expect(screen.minPasswordLength, equals(PasswordPolicy.minLength));
    });

    Widget wrap(PasswordResetConfirmScreen screen) {
      return MaterialApp(home: screen);
    }

    testWidgets('shows the Forge & Flow logo above the confirm form', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          PasswordResetConfirmScreen(
            gateway: _RecordingConfirmGateway(),
            oobCode: 'demo-oob',
          ),
        ),
      );

      expect(
        find.byKey(const Key('password_reset_confirm_logo')),
        findsOneWidget,
      );
    });

    testWidgets('blocks submit when password shorter than minimum length', (
      tester,
    ) async {
      final gateway = _RecordingConfirmGateway();
      await tester.pumpWidget(
        wrap(
          PasswordResetConfirmScreen(
            gateway: gateway,
            oobCode: 'demo-oob',
            minPasswordLength: 12,
          ),
        ),
      );

      await tester.enterText(
        find.byKey(const Key('password_reset_confirm_password_field')),
        'short',
      );
      await tester.enterText(
        find.byKey(const Key('password_reset_confirm_password_repeat_field')),
        'short',
      );
      await tester.tap(
        find.byKey(const Key('password_reset_confirm_submit_button')),
      );
      await tester.pumpAndSettle();

      expect(gateway.confirmCalls, equals(0));
      expect(
        find.byKey(const Key('password_reset_confirm_validation_banner')),
        findsOneWidget,
      );
    });

    testWidgets('blocks submit when passwords do not match', (tester) async {
      final gateway = _RecordingConfirmGateway();
      await tester.pumpWidget(
        wrap(
          PasswordResetConfirmScreen(
            gateway: gateway,
            oobCode: 'demo-oob',
            minPasswordLength: 12,
          ),
        ),
      );

      await tester.enterText(
        find.byKey(const Key('password_reset_confirm_password_field')),
        'fresh-secret-2026',
      );
      await tester.enterText(
        find.byKey(const Key('password_reset_confirm_password_repeat_field')),
        'fresh-secret-2027',
      );
      await tester.tap(
        find.byKey(const Key('password_reset_confirm_submit_button')),
      );
      await tester.pumpAndSettle();

      expect(gateway.confirmCalls, equals(0));
      expect(find.text('Passwords do not match.'), findsOneWidget);
    });

    testWidgets('on success invokes redirect callback (no auto-sign-in)', (
      tester,
    ) async {
      final gateway = _RecordingConfirmGateway();
      var redirected = false;
      await tester.pumpWidget(
        wrap(
          PasswordResetConfirmScreen(
            gateway: gateway,
            oobCode: 'demo-oob',
            minPasswordLength: 12,
            onResetCompleted: (_) => redirected = true,
          ),
        ),
      );

      await tester.enterText(
        find.byKey(const Key('password_reset_confirm_password_field')),
        'fresh-secret-2026',
      );
      await tester.enterText(
        find.byKey(const Key('password_reset_confirm_password_repeat_field')),
        'fresh-secret-2026',
      );
      await tester.tap(
        find.byKey(const Key('password_reset_confirm_submit_button')),
      );
      await tester.pumpAndSettle();

      expect(gateway.confirmCalls, equals(1));
      expect(gateway.lastOobCode, equals('demo-oob'));
      expect(gateway.lastNewPassword, equals('fresh-secret-2026'));
      expect(redirected, isTrue);
    });

    testWidgets('renders HIBP rejection copy without redirecting', (
      tester,
    ) async {
      final gateway = _RecordingConfirmGateway(
        rejection: const PasswordResetRejected(
          code: 'password_pwned',
          message: 'pwned',
          rejections: <String>['pwned_in_breach'],
        ),
      );
      var redirected = false;

      await tester.pumpWidget(
        wrap(
          PasswordResetConfirmScreen(
            gateway: gateway,
            oobCode: 'demo-oob',
            minPasswordLength: 12,
            onResetCompleted: (_) => redirected = true,
          ),
        ),
      );

      await tester.enterText(
        find.byKey(const Key('password_reset_confirm_password_field')),
        'leaked-password-2026',
      );
      await tester.enterText(
        find.byKey(const Key('password_reset_confirm_password_repeat_field')),
        'leaked-password-2026',
      );
      await tester.tap(
        find.byKey(const Key('password_reset_confirm_submit_button')),
      );
      await tester.pumpAndSettle();

      expect(redirected, isFalse);
      expect(
        find.byKey(const Key('password_reset_confirm_error_banner')),
        findsOneWidget,
      );
      expect(find.textContaining('known data breach'), findsOneWidget);
    });

    testWidgets('renders history-reuse rejection copy', (tester) async {
      final gateway = _RecordingConfirmGateway(
        rejection: const PasswordResetRejected(
          code: 'password_reused',
          message: 'reused',
          rejections: <String>['reused_from_history'],
        ),
      );

      await tester.pumpWidget(
        wrap(
          PasswordResetConfirmScreen(
            gateway: gateway,
            oobCode: 'demo-oob',
            minPasswordLength: 12,
            onResetCompleted: (_) {},
          ),
        ),
      );

      await tester.enterText(
        find.byKey(const Key('password_reset_confirm_password_field')),
        'fresh-secret-2026',
      );
      await tester.enterText(
        find.byKey(const Key('password_reset_confirm_password_repeat_field')),
        'fresh-secret-2026',
      );
      await tester.tap(
        find.byKey(const Key('password_reset_confirm_submit_button')),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('used this password recently'),
        findsOneWidget,
      );
    });

    testWidgets(
      'reuses Idempotency-Key on transient retry, rotates when the operator '
      'picks a new password after a policy rejection',
      (tester) async {
        final gateway = _ConfirmKeyTrackingGateway();
        var keyCounter = 0;
        await tester.pumpWidget(
          wrap(
            PasswordResetConfirmScreen(
              gateway: gateway,
              oobCode: 'demo-oob',
              minPasswordLength: 8,
              onResetCompleted: (_) {},
              idempotencyKeyFactory: () => 'idem-${++keyCounter}',
            ),
          ),
        );

        // Submit a leaked password — terminal 422 rejection. The key
        // gets retired so a new password attempt rotates the key.
        gateway.nextRejection = const PasswordResetRejected(
          code: 'password_pwned',
          message: 'pwned',
          rejections: <String>['pwned_in_breach'],
          statusCode: 422,
        );
        await tester.enterText(
          find.byKey(const Key('password_reset_confirm_password_field')),
          'leaked-pw',
        );
        await tester.enterText(
          find.byKey(const Key('password_reset_confirm_password_repeat_field')),
          'leaked-pw',
        );
        final submit = find.byKey(
          const Key('password_reset_confirm_submit_button'),
        );
        await tester.ensureVisible(submit);
        await tester.tap(submit);
        await tester.pumpAndSettle();
        expect(gateway.recordedKeys, equals(<String>['idem-1']));

        // Operator picks a new password — key MUST rotate so the
        // proxy treats this as a fresh attempt (otherwise the
        // cached 422 would replay forever).
        gateway.nextRejection = null;
        await tester.enterText(
          find.byKey(const Key('password_reset_confirm_password_field')),
          'fresh-secret',
        );
        await tester.enterText(
          find.byKey(const Key('password_reset_confirm_password_repeat_field')),
          'fresh-secret',
        );
        await tester.ensureVisible(submit);
        await tester.tap(submit);
        await tester.pumpAndSettle();
        expect(gateway.recordedKeys, equals(<String>['idem-1', 'idem-2']));
      },
    );

    testWidgets(
      'reuses the Idempotency-Key on a transient 5xx retry of the same '
      '(oobCode, password) so a confirm retry replays instead of burning '
      'the single-use oobCode into password_reset_expired',
      (tester) async {
        final gateway = _ConfirmKeyTrackingGateway();
        var keyCounter = 0;
        await tester.pumpWidget(
          wrap(
            PasswordResetConfirmScreen(
              gateway: gateway,
              oobCode: 'demo-oob',
              minPasswordLength: 8,
              onResetCompleted: (_) {},
              idempotencyKeyFactory: () => 'idem-${++keyCounter}',
            ),
          ),
        );

        // First submit fails with a transient 5xx. Key MUST stay
        // pinned so the next tap reuses it (proxy will replay, or
        // recover, without burning the oobCode).
        gateway.nextRejection = const PasswordResetRejected(
          code: 'password_reset_confirm_unavailable',
          message: 'try again',
          statusCode: 503,
        );
        await tester.enterText(
          find.byKey(const Key('password_reset_confirm_password_field')),
          'fresh-secret',
        );
        await tester.enterText(
          find.byKey(const Key('password_reset_confirm_password_repeat_field')),
          'fresh-secret',
        );
        final submit = find.byKey(
          const Key('password_reset_confirm_submit_button'),
        );
        await tester.ensureVisible(submit);
        await tester.tap(submit);
        await tester.pumpAndSettle();
        expect(gateway.recordedKeys, equals(<String>['idem-1']));

        // Operator taps submit again with the SAME password — same key.
        gateway.nextRejection = null;
        await tester.ensureVisible(submit);
        await tester.tap(submit);
        await tester.pumpAndSettle();
        expect(gateway.recordedKeys, equals(<String>['idem-1', 'idem-1']));
      },
    );

    testWidgets('renders friendly copy for expired oobCode', (tester) async {
      final gateway = _RecordingConfirmGateway(
        rejection: const PasswordResetRejected(
          code: 'password_reset_expired',
          message: 'expired',
        ),
      );

      await tester.pumpWidget(
        wrap(
          PasswordResetConfirmScreen(
            gateway: gateway,
            oobCode: 'demo-oob',
            minPasswordLength: 12,
            onResetCompleted: (_) {},
          ),
        ),
      );

      await tester.enterText(
        find.byKey(const Key('password_reset_confirm_password_field')),
        'fresh-secret-2026',
      );
      await tester.enterText(
        find.byKey(const Key('password_reset_confirm_password_repeat_field')),
        'fresh-secret-2026',
      );
      await tester.tap(
        find.byKey(const Key('password_reset_confirm_submit_button')),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('reset link is no longer valid'),
        findsOneWidget,
      );
    });

    testWidgets('renders deploy-specific copy for route-missing 404', (
      tester,
    ) async {
      final gateway = _RecordingConfirmGateway(
        rejection: const PasswordResetRejected(
          code: 'not found',
          message: 'not found',
          statusCode: 404,
        ),
      );

      await tester.pumpWidget(
        wrap(
          PasswordResetConfirmScreen(
            gateway: gateway,
            oobCode: 'demo-oob',
            minPasswordLength: 8,
            onResetCompleted: (_) {},
          ),
        ),
      );

      await tester.enterText(
        find.byKey(const Key('password_reset_confirm_password_field')),
        'fresh-secret',
      );
      await tester.enterText(
        find.byKey(const Key('password_reset_confirm_password_repeat_field')),
        'fresh-secret',
      );
      await tester.tap(
        find.byKey(const Key('password_reset_confirm_submit_button')),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('route is not deployed'), findsOneWidget);
    });

    testWidgets('renders timeout copy without redirecting', (tester) async {
      final gateway = _RecordingConfirmGateway(
        throwGeneric: () => TimeoutException('slow proxy'),
      );
      var redirected = false;

      await tester.pumpWidget(
        wrap(
          PasswordResetConfirmScreen(
            gateway: gateway,
            oobCode: 'demo-oob',
            minPasswordLength: 8,
            onResetCompleted: (_) => redirected = true,
          ),
        ),
      );

      await tester.enterText(
        find.byKey(const Key('password_reset_confirm_password_field')),
        'fresh-secret',
      );
      await tester.enterText(
        find.byKey(const Key('password_reset_confirm_password_repeat_field')),
        'fresh-secret',
      );
      await tester.tap(
        find.byKey(const Key('password_reset_confirm_submit_button')),
      );
      await tester.pumpAndSettle();

      expect(redirected, isFalse);
      expect(find.textContaining('timed out'), findsOneWidget);
    });
  });
}

class _RecordingConfirmGateway implements PasswordResetGateway {
  _RecordingConfirmGateway({this.rejection, this.throwGeneric});

  final PasswordResetRejected? rejection;
  final Object Function()? throwGeneric;

  int confirmCalls = 0;
  String? lastOobCode;
  String? lastNewPassword;

  @override
  Future<PasswordResetRequested> requestReset(
    PasswordResetRequestCommand command,
  ) async {
    throw UnimplementedError();
  }

  @override
  Future<PasswordResetConfirmed> confirmReset(
    PasswordResetConfirmRequest request,
  ) async {
    confirmCalls += 1;
    lastOobCode = request.oobCode;
    lastNewPassword = request.newPassword;
    if (throwGeneric != null) {
      throw throwGeneric!();
    }
    if (rejection != null) {
      throw rejection!;
    }
    return const PasswordResetConfirmed();
  }
}

/// Gateway that records each call's `idempotencyKey` and lets the
/// test mutate the next-call rejection in flight.
class _ConfirmKeyTrackingGateway implements PasswordResetGateway {
  PasswordResetRejected? nextRejection;
  final recordedKeys = <String>[];

  @override
  Future<PasswordResetRequested> requestReset(
    PasswordResetRequestCommand command,
  ) async {
    throw UnimplementedError();
  }

  @override
  Future<PasswordResetConfirmed> confirmReset(
    PasswordResetConfirmRequest request,
  ) async {
    recordedKeys.add(request.idempotencyKey ?? '<missing>');
    final rejection = nextRejection;
    if (rejection != null) {
      throw rejection;
    }
    return const PasswordResetConfirmed();
  }
}
