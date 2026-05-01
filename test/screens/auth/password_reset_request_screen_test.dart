// Phase 9.UX.7 - PasswordResetRequestScreen widget tests.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/screens/auth/password_reset_request_screen.dart';
import 'package:forge_and_flow/services/auth/password_reset_gateway.dart';

void main() {
  group('PasswordResetRequestScreen', () {
    Widget wrap(PasswordResetRequestScreen screen) {
      return MaterialApp(home: screen);
    }

    testWidgets('blocks submit on invalid email with client-side validation',
        (tester) async {
      final gateway = _RecordingPasswordResetGateway();

      await tester.pumpWidget(wrap(PasswordResetRequestScreen(gateway: gateway)));
      await tester.enterText(
        find.byKey(const Key('password_reset_request_email_field')),
        'not-an-email',
      );
      await tester
          .tap(find.byKey(const Key('password_reset_request_submit_button')));
      await tester.pumpAndSettle();

      expect(gateway.requestCalls, equals(0));
      expect(
        find.byKey(const Key('password_reset_request_error_banner')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('password_reset_request_confirmation_banner')),
        findsNothing,
      );
    });

    testWidgets('shows privacy-preserving copy on success', (tester) async {
      final gateway = _RecordingPasswordResetGateway();

      await tester.pumpWidget(wrap(PasswordResetRequestScreen(gateway: gateway)));
      await tester.enterText(
        find.byKey(const Key('password_reset_request_email_field')),
        'demo@forgeflow.test',
      );
      await tester
          .tap(find.byKey(const Key('password_reset_request_submit_button')));
      await tester.pumpAndSettle();

      expect(gateway.requestCalls, equals(1));
      expect(gateway.lastRequestEmail, equals('demo@forgeflow.test'));
      expect(
        find.byKey(const Key('password_reset_request_confirmation_banner')),
        findsOneWidget,
      );
      expect(
        find.text(
          "If an account exists for this email, you'll receive a reset link.",
        ),
        findsOneWidget,
      );
    });

    testWidgets('shows same privacy-preserving copy for unknown email',
        (tester) async {
      // The proxy contract says request always succeeds from the client's
      // perspective regardless of whether the email exists. Confirm the UI
      // does not branch on the email parameter — same banner copy fires.
      final gateway =
          _RecordingPasswordResetGateway(accept: (_) => true);

      await tester.pumpWidget(wrap(PasswordResetRequestScreen(gateway: gateway)));
      await tester.enterText(
        find.byKey(const Key('password_reset_request_email_field')),
        'unknown@forgeflow.test',
      );
      await tester
          .tap(find.byKey(const Key('password_reset_request_submit_button')));
      await tester.pumpAndSettle();

      expect(
        find.text(
          "If an account exists for this email, you'll receive a reset link.",
        ),
        findsOneWidget,
      );
    });

    testWidgets('renders rate-limited error copy on 429', (tester) async {
      final gateway = _RecordingPasswordResetGateway(
        rejection: const PasswordResetRejected(
          code: 'rate_limited',
          message: 'too many',
          statusCode: 429,
        ),
      );

      await tester.pumpWidget(wrap(PasswordResetRequestScreen(gateway: gateway)));
      await tester.enterText(
        find.byKey(const Key('password_reset_request_email_field')),
        'demo@forgeflow.test',
      );
      await tester
          .tap(find.byKey(const Key('password_reset_request_submit_button')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('password_reset_request_error_banner')),
        findsOneWidget,
      );
      expect(
        find.textContaining('Too many reset requests'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('password_reset_request_confirmation_banner')),
        findsNothing,
      );
    });

    testWidgets('network failure surfaces retry copy', (tester) async {
      final gateway = _RecordingPasswordResetGateway(
        throwGeneric: () => StateError('boom'),
      );

      await tester.pumpWidget(wrap(PasswordResetRequestScreen(gateway: gateway)));
      await tester.enterText(
        find.byKey(const Key('password_reset_request_email_field')),
        'demo@forgeflow.test',
      );
      await tester
          .tap(find.byKey(const Key('password_reset_request_submit_button')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('password_reset_request_error_banner')),
        findsOneWidget,
      );
      expect(
        find.textContaining('temporarily unavailable'),
        findsOneWidget,
      );
    });

    testWidgets(
      'reuses the same Idempotency-Key when the operator retries the same '
      'email after a transient failure, then rotates when the email changes',
      (tester) async {
        // First call fails with a transient error so the screen
        // surfaces an error and the operator can tap submit again.
        // Subsequent calls succeed.
        final gateway = _CountingFailureThenSuccessGateway(failOnce: true);
        var keyCounter = 0;
        await tester.pumpWidget(
          wrap(
            PasswordResetRequestScreen(
              gateway: gateway,
              idempotencyKeyFactory: () =>
                  'idem-${++keyCounter}',
            ),
          ),
        );

        // First submit (transient failure).
        await tester.enterText(
          find.byKey(const Key('password_reset_request_email_field')),
          'demo@forgeflow.test',
        );
        await tester
            .tap(find.byKey(const Key('password_reset_request_submit_button')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('password_reset_request_error_banner')),
          findsOneWidget,
        );

        // Operator taps submit again with the same email — same key.
        await tester
            .tap(find.byKey(const Key('password_reset_request_submit_button')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('password_reset_request_confirmation_banner')),
          findsOneWidget,
        );

        // First two calls share the same key; the second call would
        // hit the proxy's idempotency cache and replay the earlier
        // result instead of re-issuing the email.
        expect(gateway.recordedKeys, hasLength(2));
        expect(gateway.recordedKeys[0], equals('idem-1'));
        expect(gateway.recordedKeys[1], equals('idem-1'));

        // Now operator changes email and submits — fresh key.
        await tester.enterText(
          find.byKey(const Key('password_reset_request_email_field')),
          'someone.else@forgeflow.test',
        );
        await tester
            .tap(find.byKey(const Key('password_reset_request_submit_button')));
        await tester.pumpAndSettle();
        expect(gateway.recordedKeys, hasLength(3));
        expect(gateway.recordedKeys[2], equals('idem-2'));
      },
    );

    testWidgets(
      'rotates the Idempotency-Key on 429 so the next retry is not '
      'pinned to the cached rate-limit response',
      (tester) async {
        // First call returns 429 (rate-limited). The screen MUST
        // retire the key so when the operator waits and taps submit
        // again, we send a fresh key — otherwise the proxy cache
        // would replay 429 forever.
        final gateway = _RateLimitedThenSuccessGateway();
        var keyCounter = 0;
        await tester.pumpWidget(
          wrap(
            PasswordResetRequestScreen(
              gateway: gateway,
              idempotencyKeyFactory: () => 'idem-${++keyCounter}',
            ),
          ),
        );

        await tester.enterText(
          find.byKey(const Key('password_reset_request_email_field')),
          'demo@forgeflow.test',
        );
        await tester
            .tap(find.byKey(const Key('password_reset_request_submit_button')));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Too many reset requests'),
          findsOneWidget,
        );
        expect(gateway.recordedKeys, equals(<String>['idem-1']));

        // Operator retries SAME email after waiting — key must
        // rotate because rate_limited is conceptually transient.
        await tester
            .tap(find.byKey(const Key('password_reset_request_submit_button')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('password_reset_request_confirmation_banner')),
          findsOneWidget,
        );
        expect(gateway.recordedKeys, equals(<String>['idem-1', 'idem-2']));
      },
    );
  });
}

class _RateLimitedThenSuccessGateway implements PasswordResetGateway {
  final recordedKeys = <String>[];
  bool _rateLimited = false;

  @override
  Future<PasswordResetRequested> requestReset(
    PasswordResetRequestCommand command,
  ) async {
    recordedKeys.add(command.idempotencyKey ?? '<missing>');
    if (!_rateLimited) {
      _rateLimited = true;
      throw const PasswordResetRejected(
        code: 'rate_limited',
        message: 'too many',
        statusCode: 429,
      );
    }
    return const PasswordResetRequested();
  }

  @override
  Future<PasswordResetConfirmed> confirmReset(
    PasswordResetConfirmRequest request,
  ) async {
    throw UnimplementedError();
  }
}

class _CountingFailureThenSuccessGateway implements PasswordResetGateway {
  _CountingFailureThenSuccessGateway({required this.failOnce});

  final bool failOnce;
  final recordedKeys = <String>[];
  bool _failed = false;

  @override
  Future<PasswordResetRequested> requestReset(
    PasswordResetRequestCommand command,
  ) async {
    recordedKeys.add(command.idempotencyKey ?? '<missing>');
    if (failOnce && !_failed) {
      _failed = true;
      throw const PasswordResetRejected(
        code: 'transient',
        message: 'transient',
      );
    }
    return const PasswordResetRequested();
  }

  @override
  Future<PasswordResetConfirmed> confirmReset(
    PasswordResetConfirmRequest request,
  ) async {
    throw UnimplementedError();
  }
}

class _RecordingPasswordResetGateway implements PasswordResetGateway {
  _RecordingPasswordResetGateway({
    this.rejection,
    this.throwGeneric,
    bool Function(String email)? accept,
  }) : _accept = accept;

  final PasswordResetRejected? rejection;
  final Object Function()? throwGeneric;
  final bool Function(String email)? _accept;

  int requestCalls = 0;
  String? lastRequestEmail;

  @override
  Future<PasswordResetRequested> requestReset(
    PasswordResetRequestCommand command,
  ) async {
    requestCalls += 1;
    lastRequestEmail = command.email;
    if (throwGeneric != null) {
      throw throwGeneric!();
    }
    if (rejection != null) {
      throw rejection!;
    }
    if (_accept != null && !_accept(command.email)) {
      throw const PasswordResetRejected(
        code: 'invalid',
        message: 'no',
      );
    }
    return const PasswordResetRequested();
  }

  @override
  Future<PasswordResetConfirmed> confirmReset(
    PasswordResetConfirmRequest request,
  ) async {
    throw UnimplementedError();
  }
}
