// L5 — FirebaseMfaEnrollmentService unit coverage.
//
// The live-binding test covers the happy path end-to-end. This file
// pins the boundary contract that the service layer is a pure pass-
// through over the [FirebaseMfaClient] adapter:
//
//   * `beginTotpEnrollment` forwards arguments verbatim and projects
//     the adapter payload (factorId, secretBase32, otpAuthUrl) into
//     `TotpEnrollmentSetup` without mutation.
//   * `confirmTotpEnrollment` resolves the factor identity to use:
//     prefer a non-empty string `firebase_factor_uid` from metadata,
//     otherwise fall back to the session factorId. Non-string and
//     blank metadata values fall back, never throw.
//   * Failures are surfaced verbatim — the service never invents
//     codes/messages of its own.
//   * Adapter errors propagate; the service does not swallow them.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/services/mfa/firebase_mfa_client.dart';
import 'package:forge_and_flow/services/mfa/firebase_mfa_enrollment_service.dart';
import 'package:forge_and_flow/services/mfa/mfa_enrollment_service.dart';

void main() {
  group('FirebaseMfaEnrollmentService.beginTotpEnrollment', () {
    test('forwards every argument to the adapter verbatim', () async {
      final client = _FakeMfaClient(
        beginPayload: const FirebaseMfaTotpBeginPayload(
          factorId: 'fb-session-factor-1',
          secretBase32: 'JBSWY3DPEHPK3PXP',
          otpAuthUrl: 'otpauth://totp/Forge%20%26%20Flow:u@example.test'
              '?secret=JBSWY3DPEHPK3PXP&issuer=Forge%20%26%20Flow',
        ),
      );
      final service = FirebaseMfaEnrollmentService(client: client);

      await service.beginTotpEnrollment(
        authorizationIdToken: 'id-token-abc',
        userId: 'user-1',
        userEmail: 'u@example.test',
        issuerName: 'Forge & Flow',
      );

      final call = client.beginCalls.single;
      expect(call.authorizationIdToken, equals('id-token-abc'));
      expect(call.userId, equals('user-1'));
      expect(call.userEmail, equals('u@example.test'));
      expect(call.issuerName, equals('Forge & Flow'));
    });

    test('projects the adapter payload into TotpEnrollmentSetup verbatim',
        () async {
      final service = FirebaseMfaEnrollmentService(
        client: _FakeMfaClient(
          beginPayload: const FirebaseMfaTotpBeginPayload(
            factorId: 'fb-factor-α',
            secretBase32: 'JBSWY3DPEHPK3PXP2',
            otpAuthUrl: 'otpauth://totp/X?secret=ABC',
          ),
        ),
      );
      final setup = await service.beginTotpEnrollment(
        userId: 'u',
        userEmail: 'u@example.test',
        issuerName: 'X',
      );
      expect(setup, isA<TotpEnrollmentSetup>());
      expect(setup.factorId, equals('fb-factor-α'));
      expect(setup.secretBase32, equals('JBSWY3DPEHPK3PXP2'));
      expect(setup.otpAuthUrl, equals('otpauth://totp/X?secret=ABC'));
    });

    test('default empty authorizationIdToken still forwards through',
        () async {
      final client = _FakeMfaClient(beginPayload: _placeholderBegin);
      final service = FirebaseMfaEnrollmentService(client: client);
      await service.beginTotpEnrollment(
        userId: 'u',
        userEmail: 'u@example.test',
        issuerName: 'X',
      );
      expect(client.beginCalls.single.authorizationIdToken, isEmpty);
    });

    test('successive begin calls increment the adapter call count', () async {
      final client = _FakeMfaClient(beginPayload: _placeholderBegin);
      final service = FirebaseMfaEnrollmentService(client: client);
      for (var i = 0; i < 3; i++) {
        await service.beginTotpEnrollment(
          userId: 'u-$i',
          userEmail: 'u$i@example.test',
          issuerName: 'X',
        );
      }
      expect(client.beginCalls, hasLength(3));
      expect(
        client.beginCalls.map((call) => call.userId).toList(),
        equals(<String>['u-0', 'u-1', 'u-2']),
      );
    });

    test('rethrows adapter errors instead of swallowing them', () async {
      final service = FirebaseMfaEnrollmentService(
        client: _FakeMfaClient(
          beginThrows: StateError('adapter not bound'),
        ),
      );
      await expectLater(
        service.beginTotpEnrollment(
          userId: 'u',
          userEmail: 'u@example.test',
          issuerName: 'X',
        ),
        throwsStateError,
      );
    });
  });

  group('FirebaseMfaEnrollmentService.confirmTotpEnrollment', () {
    test('Succeeded with non-empty firebase_factor_uid wins over session id',
        () async {
      final service = FirebaseMfaEnrollmentService(
        client: _FakeMfaClient(
          confirmOutcome: const FirebaseMfaConfirmSucceeded(
            factorMetadata: <String, Object?>{
              'firebase_factor_uid': 'fb-uid-prod-1',
              'issuer': 'Forge & Flow',
            },
          ),
        ),
      );
      final result = await service.confirmTotpEnrollment(
        factorId: 'session-only-factor',
        oneTimeCode: '123456',
      );
      expect(result, isA<MfaEnrollmentConfirmSuccess>());
      expect(
        (result as MfaEnrollmentConfirmSuccess).payload.factorId,
        equals('fb-uid-prod-1'),
      );
    });

    test(
      'Succeeded with EMPTY / non-string / missing firebase_factor_uid '
      'falls back to the session factorId',
      () async {
        final cases = <Map<String, Object?>>[
          // Empty string.
          <String, Object?>{
            'firebase_factor_uid': '',
            'issuer': 'Forge & Flow',
          },
          // Non-string (a regression on the wire) must not crash.
          <String, Object?>{
            'firebase_factor_uid': 42,
            'issuer': 'Forge & Flow',
          },
          // Completely missing key.
          <String, Object?>{},
        ];
        for (var i = 0; i < cases.length; i++) {
          final service = FirebaseMfaEnrollmentService(
            client: _FakeMfaClient(
              confirmOutcome: FirebaseMfaConfirmSucceeded(
                factorMetadata: cases[i],
              ),
            ),
          );
          final result = await service.confirmTotpEnrollment(
            factorId: 'session-fallback-$i',
            oneTimeCode: '000000',
          );
          expect(
            (result as MfaEnrollmentConfirmSuccess).payload.factorId,
            equals('session-fallback-$i'),
            reason: 'case $i (${cases[i]}) should fall back',
          );
        }
      },
    );

    test('Failed outcome preserves the wire-protocol code + message', () async {
      const failure = FirebaseMfaConfirmFailed(
        code: 'totp_otp_mismatch',
        message: 'The verification code was incorrect.',
      );
      final service = FirebaseMfaEnrollmentService(
        client: _FakeMfaClient(confirmOutcome: failure),
      );
      final result = await service.confirmTotpEnrollment(
        factorId: 'f',
        oneTimeCode: '999999',
      );
      expect(result, isA<MfaEnrollmentConfirmFailure>());
      final f = result as MfaEnrollmentConfirmFailure;
      expect(f.code, equals(failure.code));
      expect(f.message, equals(failure.message));
    });

    test(
      'malformed-looking codes are forwarded verbatim — shape validation '
      'belongs to Firebase, not the service',
      () async {
        final client = _FakeMfaClient(
          confirmOutcome: const FirebaseMfaConfirmFailed(
            code: 'totp_otp_invalid',
            message: 'Code format invalid.',
          ),
        );
        final service = FirebaseMfaEnrollmentService(client: client);
        const cases = <String>['', '   ', '12', 'abcdef', '1234567', '000000'];
        for (final code in cases) {
          await service.confirmTotpEnrollment(
            factorId: 'fb-factor',
            oneTimeCode: code,
          );
        }
        expect(
          client.confirmCalls.map((c) => c.oneTimeCode).toList(),
          equals(cases),
        );
      },
    );

    test('forwards authorizationIdToken + factorId + issuerName verbatim',
        () async {
      final client = _FakeMfaClient(
        confirmOutcome: const FirebaseMfaConfirmSucceeded(
          factorMetadata: <String, Object?>{},
        ),
      );
      final service = FirebaseMfaEnrollmentService(client: client);
      await service.confirmTotpEnrollment(
        authorizationIdToken: 'my-id-token',
        factorId: 'f-1',
        oneTimeCode: '654321',
        issuerName: 'Different Issuer',
      );
      final call = client.confirmCalls.single;
      expect(call.authorizationIdToken, equals('my-id-token'));
      expect(call.factorId, equals('f-1'));
      expect(call.oneTimeCode, equals('654321'));
      expect(call.issuerName, equals('Different Issuer'));
    });

    test(
      'replay rejection surfaces verbatim — service does not track state',
      () async {
        // The service has no idempotency layer; if Firebase returns a
        // replay/used code error after a prior success, the service
        // surfaces it unchanged.
        final client = _FakeMfaClient(confirmScript: <FirebaseMfaConfirmOutcome>[
          const FirebaseMfaConfirmSucceeded(
            factorMetadata: <String, Object?>{
              'firebase_factor_uid': 'fb-once',
            },
          ),
          const FirebaseMfaConfirmFailed(
            code: 'totp_otp_replayed',
            message: 'This code was already used.',
          ),
        ]);
        final service = FirebaseMfaEnrollmentService(client: client);

        final first = await service.confirmTotpEnrollment(
          factorId: 'fb-session',
          oneTimeCode: '123456',
        );
        expect(first, isA<MfaEnrollmentConfirmSuccess>());

        final second = await service.confirmTotpEnrollment(
          factorId: 'fb-session',
          oneTimeCode: '123456',
        );
        expect(
          (second as MfaEnrollmentConfirmFailure).code,
          equals('totp_otp_replayed'),
        );
      },
    );

    test('rethrows adapter errors during confirm', () async {
      final service = FirebaseMfaEnrollmentService(
        client: _FakeMfaClient(
          confirmThrows: StateError('adapter offline'),
        ),
      );
      await expectLater(
        service.confirmTotpEnrollment(
          factorId: 'f',
          oneTimeCode: '123456',
        ),
        throwsStateError,
      );
    });
  });
}

const FirebaseMfaTotpBeginPayload _placeholderBegin =
    FirebaseMfaTotpBeginPayload(
  factorId: 'placeholder',
  secretBase32: 'JBSWY3DPEHPK3PXP',
  otpAuthUrl: 'otpauth://totp/X?secret=JBSWY3DPEHPK3PXP',
);

class _BeginCall {
  const _BeginCall({
    required this.authorizationIdToken,
    required this.userId,
    required this.userEmail,
    required this.issuerName,
  });

  final String authorizationIdToken;
  final String userId;
  final String userEmail;
  final String issuerName;
}

class _ConfirmCall {
  const _ConfirmCall({
    required this.authorizationIdToken,
    required this.factorId,
    required this.oneTimeCode,
    required this.issuerName,
  });

  final String authorizationIdToken;
  final String factorId;
  final String oneTimeCode;
  final String issuerName;
}

/// Single configurable fake. Test cases set whichever knob matches what
/// they exercise: a fixed begin payload, a fixed confirm outcome, a
/// scripted sequence of confirm outcomes, or a thrown error on either
/// side.
class _FakeMfaClient implements FirebaseMfaClient {
  _FakeMfaClient({
    FirebaseMfaTotpBeginPayload? beginPayload,
    this.confirmOutcome,
    List<FirebaseMfaConfirmOutcome>? confirmScript,
    this.beginThrows,
    this.confirmThrows,
  })  : _beginPayload = beginPayload ?? _placeholderBegin,
        _confirmScript = confirmScript == null
            ? null
            : List<FirebaseMfaConfirmOutcome>.from(confirmScript);

  final FirebaseMfaTotpBeginPayload _beginPayload;
  final FirebaseMfaConfirmOutcome? confirmOutcome;
  final List<FirebaseMfaConfirmOutcome>? _confirmScript;
  final Object? beginThrows;
  final Object? confirmThrows;

  final beginCalls = <_BeginCall>[];
  final confirmCalls = <_ConfirmCall>[];
  int _scriptIndex = 0;

  @override
  Future<FirebaseMfaTotpBeginPayload> beginTotpEnrollment({
    String authorizationIdToken = '',
    required String userId,
    required String userEmail,
    required String issuerName,
  }) async {
    beginCalls.add(_BeginCall(
      authorizationIdToken: authorizationIdToken,
      userId: userId,
      userEmail: userEmail,
      issuerName: issuerName,
    ));
    final err = beginThrows;
    if (err != null) throw err;
    return _beginPayload;
  }

  @override
  Future<FirebaseMfaConfirmOutcome> confirmTotpEnrollment({
    String authorizationIdToken = '',
    required String factorId,
    required String oneTimeCode,
    String issuerName = 'Forge & Flow',
  }) async {
    confirmCalls.add(_ConfirmCall(
      authorizationIdToken: authorizationIdToken,
      factorId: factorId,
      oneTimeCode: oneTimeCode,
      issuerName: issuerName,
    ));
    final err = confirmThrows;
    if (err != null) throw err;
    final script = _confirmScript;
    if (script != null) {
      if (_scriptIndex >= script.length) {
        throw StateError('scripted client exhausted');
      }
      return script[_scriptIndex++];
    }
    return confirmOutcome ??
        const FirebaseMfaConfirmFailed(
          code: 'unconfigured',
          message: 'fake client default',
        );
  }

  @override
  Future<List<FirebaseMfaTotpFactor>> listTotpFactors({
    String authorizationIdToken = '',
    required String userId,
  }) async {
    return const <FirebaseMfaTotpFactor>[];
  }

  @override
  Future<void> unenrollFactor({
    String authorizationIdToken = '',
    required String userId,
    required String factorId,
  }) async {}
}
