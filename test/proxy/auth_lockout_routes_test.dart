// HARD-B - Auth lockout / retry route tests.
//
// Covers the contract envelopes from
// `docs/contracts/hardening_auth_protection_contract.md` "Lockout
// Behavior":
//
//   1. Login route: 5 failures within 15 minutes for the same
//      `(email_hash, ip_hash)` -> 6th returns 423 + emits
//      `auth.account_locked`.
//   2. Login route: success path with email + lockout enforcer
//      records the success row + does NOT 423 a fresh email.
//   3. MFA TOTP confirm: 3 rejected guesses per challenge -> 4th
//      returns 429 with `Retry-After: 30` + emits
//      `auth.mfa_retry_exceeded`.
//   4. Password-reset request: 10 requests within 24h per email -> 11th
//      returns 429 with `Retry-After: 86400` + emits
//      `auth.password_reset_throttled`.
//   5. Audit-payload sensitive-field redaction: no raw email / IP /
//      TOTP secret appears in any audit row written by these routes.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/services/auth/auth_session_ledger_writer.dart';
import 'package:forge_and_flow/services/auth/password_reset_request_gateway.dart';
import 'package:forge_and_flow/services/mfa/mfa_enrollment_service.dart';
import 'package:forge_and_flow/services/mfa/mfa_operations_gateway.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

void main() {
  group('POST /v1/auth/session/login - lockout enforcement', () {
    test(
      '5 failures within 15 minutes -> 6th returns 423 account_locked',
      () async {
        await _withScaffold((scaffold) async {
          // Send 5 failure reports - each returns 401 + emits one
          // auth.login_failed audit row. Only ON the 6th failure is
          // the lockout tripped.
          for (var i = 0; i < 5; i++) {
            final response = await scaffold.post(
              authSessionLoginPath,
              body: <String, Object?>{
                'email': 'attacker@e.test',
                'failure_outcome': AuthLoginFailureOutcomes.badPassword,
              },
            );
            expect(response.statusCode, equals(401),
                reason: 'attempt #${i + 1} should be 401 below threshold');
          }

          // 6th attempt trips the threshold inline: the 5th was
          // counted, so the next call sees count >= 5 and returns 423.
          // Implementation detail: count >= 5 BEFORE the 6th insert
          // means the 6th flow lands in the "already locked" branch
          // (priorEval.locked is true).
          final tripped = await scaffold.post(
            authSessionLoginPath,
            body: <String, Object?>{
              'email': 'attacker@e.test',
              'failure_outcome': AuthLoginFailureOutcomes.badPassword,
            },
          );
          expect(tripped.statusCode, equals(423));
          final body = jsonDecode(tripped.body) as Map<String, Object?>;
          expect(body['error'], equals('account_locked'));
          expect(body['retry_after_seconds'], equals(900));
          expect(tripped.retryAfter, equals('900'));

          // Audit sink received: 5 auth.login_failed events + 1
          // auth.account_locked event.
          final loginFailed = scaffold.audit.events
              .where((e) => e['event_type'] == 'auth.login_failed')
              .toList();
          expect(loginFailed, hasLength(5),
              reason: '5 below-threshold failures emit auth.login_failed');

          final accountLocked = scaffold.audit.events
              .where((e) => e['event_type'] == 'auth.account_locked')
              .toList();
          expect(accountLocked, hasLength(1),
              reason: 'only the 6th attempt emits auth.account_locked');
          // Audit payload contains the email + ip hash, NOT the raw
          // email/IP. SHA-256 hex is 64 chars.
          final lockedRow = accountLocked.single;
          expect(lockedRow['email_hash'], isA<String>());
          expect((lockedRow['email_hash'] as String).length, equals(64));
          expect(lockedRow['ip_hash'], isA<String>());
          expect((lockedRow['ip_hash'] as String).length, equals(64));
          // Sensitive-field redaction: the audit payload must not
          // contain the raw email anywhere.
          final auditJson = jsonEncode(scaffold.audit.events);
          expect(auditJson.contains('attacker@e.test'), isFalse,
              reason:
                  'raw email must not appear in any auth.* audit row payload');
        });
      },
    );

    test(
      '5 failures from one (email, ip) do NOT lock a different email',
      () async {
        await _withScaffold((scaffold) async {
          for (var i = 0; i < 5; i++) {
            await scaffold.post(
              authSessionLoginPath,
              body: <String, Object?>{
                'email': 'attacker@e.test',
                'failure_outcome': AuthLoginFailureOutcomes.badPassword,
              },
            );
          }
          // Different email - lockout slot is per (email_hash, ip_hash)
          // so a different email keys a fresh slot even from the same IP.
          final fresh = await scaffold.post(
            authSessionLoginPath,
            body: <String, Object?>{
              'email': 'innocent@e.test',
              'failure_outcome': AuthLoginFailureOutcomes.badPassword,
            },
          );
          expect(fresh.statusCode, equals(401),
              reason:
                  'a different email should not inherit the locked slot');
        });
      },
    );

    test(
      'failure-report path rejects unknown outcome with 400',
      () async {
        await _withScaffold((scaffold) async {
          final response = await scaffold.post(
            authSessionLoginPath,
            body: <String, Object?>{
              'email': 'foo@e.test',
              'failure_outcome': 'phishing_attack',
            },
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('invalid_failure_outcome'));
        });
      },
    );

    test(
      'failure-report path rejects when email is missing with 400',
      () async {
        await _withScaffold((scaffold) async {
          final response = await scaffold.post(
            authSessionLoginPath,
            body: <String, Object?>{
              'failure_outcome': AuthLoginFailureOutcomes.badPassword,
            },
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('missing_email'));
        });
      },
    );

    test(
      'a successful login within the window resets the failure count '
      '(4 fails -> success -> 1 fail = NOT locked on the next attempt)',
      () async {
        await _withScaffold((scaffold) async {
          // 4 failures - each lands a row in the lockout ledger.
          for (var i = 0; i < 4; i++) {
            final response = await scaffold.post(
              authSessionLoginPath,
              body: <String, Object?>{
                'email': 'alice@e.test',
                'failure_outcome': AuthLoginFailureOutcomes.badPassword,
              },
            );
            expect(response.statusCode, equals(401));
          }
          // Successful login (with a verified bearer token + email).
          // The success-path lockout pre-check sees 4 failures (still
          // below threshold), the session is recorded, and recordSuccess
          // writes a `success` row that the next countFailuresIn must
          // treat as a reset cutoff.
          scaffold.verifier.claims = const ProxyJwtClaims(
            userId: 'user-uuid',
            operatorId: 'op-uuid',
            locationId: 'loc-uuid',
            roles: <String>[],
          );
          final success = await scaffold.post(
            authSessionLoginPath,
            authorization: 'Bearer placeholder.id.token',
            body: <String, Object?>{
              'email': 'alice@e.test',
              'token_hash': 'sha256-hex-hash',
            },
          );
          expect(success.statusCode, equals(200));
          // 1 more failure AFTER the success - the count predicate
          // should treat this as the FIRST failure in the new
          // post-success window, so the next attempt is NOT locked.
          final fifth = await scaffold.post(
            authSessionLoginPath,
            body: <String, Object?>{
              'email': 'alice@e.test',
              'failure_outcome': AuthLoginFailureOutcomes.badPassword,
            },
          );
          expect(fifth.statusCode, equals(401),
              reason:
                  'success row should reset the counter so this single '
                  'post-success failure is not the threshold');
          // ANOTHER attempt (so total post-success = 2) - still 401.
          final sixth = await scaffold.post(
            authSessionLoginPath,
            body: <String, Object?>{
              'email': 'alice@e.test',
              'failure_outcome': AuthLoginFailureOutcomes.badPassword,
            },
          );
          expect(sixth.statusCode, equals(401),
              reason:
                  'with the success reset honored, the second post-success '
                  'failure is still well below the 5-fail threshold');
          // Audit: the account_locked event must NOT have been emitted
          // anywhere in this sequence. The 4 pre-success failures + the
          // 2 post-success failures all stayed below the (post-reset)
          // threshold.
          final lockedEvents = scaffold.audit.events
              .where((e) => e['event_type'] == 'auth.account_locked')
              .toList();
          expect(lockedEvents, isEmpty,
              reason:
                  'no account_locked event should fire when a success '
                  'between failures resets the counter below threshold');
        });
      },
    );

    test(
      'success-path account_locked emission carries operator + actor for '
      'audit_logs fan-out',
      () async {
        await _withScaffold((scaffold) async {
          // Burn enough failures to trip the lockout.
          for (var i = 0; i < 5; i++) {
            await scaffold.post(
              authSessionLoginPath,
              body: <String, Object?>{
                'email': 'alice@e.test',
                'failure_outcome': AuthLoginFailureOutcomes.badPassword,
              },
            );
          }
          // Now Alice's session-ledger write arrives (verified bearer
          // token). The success-path pre-check sees the threshold and
          // 423s -- and the account_locked audit row carries the
          // resolved operator/location/actor so the production sink
          // fans the row out into the per-tenant audit_logs chain.
          scaffold.verifier.claims = const ProxyJwtClaims(
            userId: 'user-uuid',
            operatorId: 'op-uuid',
            locationId: 'loc-uuid',
            roles: <String>[],
          );
          final tripped = await scaffold.post(
            authSessionLoginPath,
            authorization: 'Bearer placeholder.id.token',
            body: <String, Object?>{
              'email': 'alice@e.test',
              'token_hash': 'sha256-hex-hash',
            },
          );
          expect(tripped.statusCode, equals(423));
          final lockedEvents = scaffold.audit.events
              .where((e) => e['event_type'] == 'auth.account_locked')
              .toList();
          expect(lockedEvents, isNotEmpty,
              reason: 'success-path lock must emit account_locked');
          final last = lockedEvents.last;
          expect(last['operator_id'], equals('op-uuid'),
              reason:
                  'success-path account_locked must carry operator_id so '
                  'the production sink can fan out into audit_logs');
          expect(last['location_id'], equals('loc-uuid'));
          expect(last['actor_user_id'], equals('user-uuid'),
              reason:
                  'success-path account_locked must carry actor_user_id '
                  '(verified bearer token) so the audit_logs row passes the '
                  'actor-shape CHECK constraint');
        });
      },
    );
  });

  group('POST /v1/auth/mfa/totp/confirm - retry cap', () {
    test(
      '3 rejected guesses per challenge -> 4th returns 429 with Retry-After',
      () async {
        await _withScaffold((scaffold) async {
          scaffold.verifier.claims = const ProxyJwtClaims(
            userId: '11111111-2222-3333-4444-555555555555',
            operatorId: 'op-uuid',
            locationId: 'loc-uuid',
            roles: <String>[],
            firebaseUid: 'firebase-uid',
          );
          // Three rejections - each surfaces the gateway's 422 reject.
          scaffold.mfaGateway.rejectNextNTimes = 3;
          for (var i = 0; i < 3; i++) {
            final response = await scaffold.post(
              authMfaTotpConfirmPath,
              body: <String, Object?>{
                'factor_id': 'factor-A',
                'one_time_code': '000000',
              },
              authorization: 'Bearer placeholder.id.token',
            );
            expect(response.statusCode, equals(422),
                reason: 'attempt #${i + 1} surfaces gateway rejection');
          }
          // 4th attempt - the counter has 3 entries; threshold is 3,
          // so this attempt 429s before the gateway is even called.
          final tripped = await scaffold.post(
            authMfaTotpConfirmPath,
            body: <String, Object?>{
              'factor_id': 'factor-A',
              'one_time_code': '000000',
            },
            authorization: 'Bearer placeholder.id.token',
          );
          expect(tripped.statusCode, equals(429));
          final body = jsonDecode(tripped.body) as Map<String, Object?>;
          expect(body['error'], equals('mfa_retry_limit'));
          expect(body['retry_after_seconds'], equals(30));
          expect(tripped.retryAfter, equals('30'));

          // Audit emitted exactly one auth.mfa_retry_exceeded; the
          // payload uses the SHA-256 challenge hash, not the raw
          // factor_id or one_time_code.
          final retryAudit = scaffold.audit.events
              .where((e) => e['event_type'] == 'auth.mfa_retry_exceeded')
              .toList();
          expect(retryAudit, hasLength(1));
          final challengeHash = retryAudit.single['challenge_id_hash'];
          expect(challengeHash, isA<String>());
          expect((challengeHash as String).length, equals(64));
          // Sensitive-field redaction: TOTP code must not appear.
          final auditJson = jsonEncode(scaffold.audit.events);
          expect(auditJson.contains('000000'), isFalse,
              reason: 'TOTP one-time code must not appear in audit rows');
          expect(auditJson.contains('factor-A'), isFalse,
              reason: 'raw factor_id must not appear in audit rows');
        });
      },
    );

    test(
      'fresh challenge id on a new factor uses a separate counter slot',
      () async {
        await _withScaffold((scaffold) async {
          scaffold.verifier.claims = const ProxyJwtClaims(
            userId: '11111111-2222-3333-4444-555555555555',
            operatorId: 'op-uuid',
            locationId: 'loc-uuid',
            roles: <String>[],
            firebaseUid: 'firebase-uid',
          );
          scaffold.mfaGateway.rejectNextNTimes = 3;
          for (var i = 0; i < 3; i++) {
            await scaffold.post(
              authMfaTotpConfirmPath,
              body: <String, Object?>{
                'factor_id': 'factor-A',
                'one_time_code': '000000',
              },
              authorization: 'Bearer placeholder.id.token',
            );
          }
          // Switch to a different factor - the counter key includes
          // factor_id so the new factor starts fresh.
          scaffold.mfaGateway.rejectNextNTimes = 1;
          final fresh = await scaffold.post(
            authMfaTotpConfirmPath,
            body: <String, Object?>{
              'factor_id': 'factor-B',
              'one_time_code': '111111',
            },
            authorization: 'Bearer placeholder.id.token',
          );
          expect(fresh.statusCode, equals(422),
              reason: 'a different challenge should not inherit retry slots');
        });
      },
    );
  });

  group('POST /v1/auth/password/reset/request - 24h cap', () {
    test(
      '10 requests within 24h per email -> 11th returns 429',
      () async {
        await _withScaffold((scaffold) async {
          // Burn all 10 slots successfully.
          for (var i = 0; i < 10; i++) {
            final response = await scaffold.post(
              authPasswordResetRequestPath,
              body: <String, Object?>{'email': 'alice@e.test'},
              headers: <String, String>{'Idempotency-Key': 'idem-$i'},
            );
            expect(response.statusCode, equals(200),
                reason: 'request #${i + 1} within window should succeed');
          }
          final tripped = await scaffold.post(
            authPasswordResetRequestPath,
            body: <String, Object?>{'email': 'alice@e.test'},
            headers: <String, String>{'Idempotency-Key': 'idem-11'},
          );
          expect(tripped.statusCode, equals(429));
          final body = jsonDecode(tripped.body) as Map<String, Object?>;
          expect(body['error'], equals('reset_request_throttled'));
          expect(body['retry_after_seconds'], equals(86400));
          expect(tripped.retryAfter, equals('86400'));

          final throttledAudit = scaffold.audit.events
              .where(
                (e) => e['event_type'] == 'auth.password_reset_throttled',
              )
              .toList();
          expect(throttledAudit, hasLength(1));
          // Audit payload carries email_hash, never the raw email.
          final emailHash = throttledAudit.single['email_hash'];
          expect(emailHash, isA<String>());
          expect((emailHash as String).length, equals(64));
          final auditJson = jsonEncode(scaffold.audit.events);
          expect(auditJson.contains('alice@e.test'), isFalse,
              reason:
                  'raw email must not appear in any reset-throttle audit row');
        });
      },
    );

    test(
      'different email keys a fresh window slot',
      () async {
        await _withScaffold((scaffold) async {
          for (var i = 0; i < 10; i++) {
            await scaffold.post(
              authPasswordResetRequestPath,
              body: <String, Object?>{'email': 'alice@e.test'},
              headers: <String, String>{'Idempotency-Key': 'idem-a$i'},
            );
          }
          final fresh = await scaffold.post(
            authPasswordResetRequestPath,
            body: <String, Object?>{'email': 'bob@e.test'},
            headers: <String, String>{'Idempotency-Key': 'idem-b'},
          );
          expect(fresh.statusCode, equals(200),
              reason: 'a different email should not inherit the limit');
        });
      },
    );

    test(
      'idempotent retry of the same request does not double-count the slot',
      () async {
        await _withScaffold((scaffold) async {
          // Two requests with the SAME idempotency key collapse to one
          // gateway call - the counter only increments inside the
          // compute body, so the second call replays without
          // increment.
          for (var i = 0; i < 2; i++) {
            final response = await scaffold.post(
              authPasswordResetRequestPath,
              body: <String, Object?>{'email': 'alice@e.test'},
              headers: <String, String>{'Idempotency-Key': 'idem-A'},
            );
            expect(response.statusCode, equals(200));
          }
          // Burn 9 more slots with fresh keys.
          for (var i = 0; i < 9; i++) {
            final response = await scaffold.post(
              authPasswordResetRequestPath,
              body: <String, Object?>{'email': 'alice@e.test'},
              headers: <String, String>{'Idempotency-Key': 'idem-fresh-$i'},
            );
            expect(response.statusCode, equals(200),
                reason:
                    'idempotent retry must NOT have double-counted; the 10th '
                    'fresh request should still succeed');
          }
        });
      },
    );
  });
}

// ---- Test scaffold ---------------------------------------------------------

class _Scaffold {
  _Scaffold({
    required this.server,
    required this.client,
    required this.baseUri,
    required this.verifier,
    required this.audit,
    required this.mfaGateway,
    required this.passwordResetGateway,
  });

  final HttpServer server;
  final HttpClient client;
  final Uri baseUri;
  final _SettableVerifier verifier;
  final InMemoryAuthLockoutAuditSink audit;
  final _CountingMfaOperationsGateway mfaGateway;
  final _CountingPasswordResetGateway passwordResetGateway;

  Future<_HttpResponse> post(
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? headers,
    String? authorization,
  }) async {
    final request = await client.postUrl(baseUri.resolve(path));
    request.persistentConnection = false;
    request.headers.contentType = ContentType.json;
    if (authorization != null) {
      request.headers.set(HttpHeaders.authorizationHeader, authorization);
    }
    headers?.forEach(request.headers.set);
    if (body != null) {
      final encoded = utf8.encode(jsonEncode(body));
      request.contentLength = encoded.length;
      request.add(encoded);
    } else {
      request.contentLength = 0;
    }
    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();
    return _HttpResponse(
      statusCode: response.statusCode,
      body: responseBody,
      retryAfter: response.headers.value(HttpHeaders.retryAfterHeader),
    );
  }
}

class _HttpResponse {
  _HttpResponse({
    required this.statusCode,
    required this.body,
    required this.retryAfter,
  });

  final int statusCode;
  final String body;
  final String? retryAfter;
}

Future<void> _withScaffold(Future<void> Function(_Scaffold) body) async {
  final saved = HttpOverrides.current;
  HttpOverrides.global = null;
  try {
    final verifier = _SettableVerifier();
    final guard = ProxyRequestGuard(verifier: verifier);
    final audit = InMemoryAuthLockoutAuditSink();
    final enforcer = InMemoryAuthLockoutEnforcer();
    final mfaTotp = RollingWindowAttemptCounter(
      window: kAuthMfaTotpRetryAfter * 60,
    );
    final passwordReset = RollingWindowAttemptCounter(
      window: kAuthPasswordResetWindow,
    );
    final mfaGateway = _CountingMfaOperationsGateway();
    final passwordResetGateway = _CountingPasswordResetGateway();
    final ledger = _RecordingAuthSessionLedger();

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // ignore: unawaited_futures
    server.listen((request) async {
      try {
        await routeRequest(
          request,
          guard,
          authSessionLedgerWriter: ledger,
          passwordResetRequestGateway: passwordResetGateway,
          mfaOperationsGateway: mfaGateway,
          authLockoutEnforcer: enforcer,
          authLockoutAuditSink: audit,
          mfaTotpRetryCounter: mfaTotp,
          passwordResetThrottleCounter: passwordReset,
          // Trust forwarded IP so the test scaffold can simulate
          // distinct client IPs and the lockout enforcer keys on a
          // stable address.
          trustProxyAuditHeaders: false,
        );
      } catch (_) {
        try {
          request.response.statusCode = 500;
          await request.response.close();
        } catch (_) {
          /* ignore */
        }
      }
    });
    final client = HttpClient();
    final baseUri = Uri.parse('http://${server.address.host}:${server.port}');

    final scaffold = _Scaffold(
      server: server,
      client: client,
      baseUri: baseUri,
      verifier: verifier,
      audit: audit,
      mfaGateway: mfaGateway,
      passwordResetGateway: passwordResetGateway,
    );
    try {
      await body(scaffold);
    } finally {
      client.close(force: true);
      await server.close(force: true);
    }
  } finally {
    HttpOverrides.global = saved;
  }
}

class _SettableVerifier implements ProxyJwtVerifier {
  ProxyJwtClaims? claims;
  String? errorMessage;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    final error = errorMessage;
    if (error != null) {
      throw ProxyJwtVerificationError(error);
    }
    final value = claims;
    if (value != null) return value;
    throw ProxyJwtVerificationError('test verifier not configured');
  }
}

class _RecordingAuthSessionLedger implements AuthSessionLedgerWriter {
  final List<AuthSessionLedgerLogin> logins = <AuthSessionLedgerLogin>[];

  @override
  Future<String> recordLogin(AuthSessionLedgerLogin login) async {
    logins.add(login);
    return 'session-${logins.length}';
  }

  @override
  Future<void> recordRefresh({
    required String sessionId,
    required String userId,
    required String operatorId,
    required String locationId,
  }) async {}

  @override
  Future<void> revokeSession({
    required String sessionId,
    required String userId,
    required String operatorId,
    required String locationId,
    required String reason,
  }) async {}

  @override
  Future<int> revokeAllSessionsForUser({
    required String userId,
    required String operatorId,
    required String locationId,
    required String reason,
  }) async {
    return 0;
  }
}

class _CountingMfaOperationsGateway implements MfaOperationsGateway {
  int rejectNextNTimes = 0;
  int confirmCalls = 0;

  @override
  Future<MfaTotpConfirmCompleted> confirmTotpEnrollment(
    MfaTotpConfirmCommand command,
  ) async {
    confirmCalls += 1;
    if (rejectNextNTimes > 0) {
      rejectNextNTimes -= 1;
      throw const MfaOperationRejected(
        code: 'invalid_totp',
        message: 'invalid TOTP one-time code',
        statusCode: 422,
      );
    }
    return MfaTotpConfirmCompleted(factorId: command.factorId);
  }

  @override
  Future<TotpEnrollmentSetup> beginTotpEnrollment(
    MfaTotpBeginCommand command,
  ) async {
    throw UnimplementedError();
  }

  @override
  Future<MfaListFactorsCompleted> listFactors(
    MfaListFactorsCommand command,
  ) async {
    throw UnimplementedError();
  }

  @override
  Future<MfaRevokeFactorCompleted> revokeFactor(
    MfaRevokeFactorCommand command,
  ) async {
    throw UnimplementedError();
  }

  @override
  Future<MfaMarkRecoveryCodesViewedCompleted> markRecoveryCodesViewed(
    MfaMarkRecoveryCodesViewedCommand command,
  ) async {
    throw UnimplementedError();
  }

  @override
  Future<MfaCancelFactorRemovalCompleted> cancelFactorRemoval(
    MfaCancelFactorRemovalCommand command,
  ) async {
    throw UnimplementedError();
  }

  @override
  Future<MfaRevokeUserFactorsCompleted> revokeUserFactors(
    MfaRevokeUserFactorsCommand command,
  ) async {
    throw UnimplementedError();
  }
}

class _CountingPasswordResetGateway implements PasswordResetRequestGateway {
  int requestCalls = 0;

  @override
  Future<PasswordResetRequestAccepted> requestReset(
    PasswordResetRequestCommand command,
  ) async {
    requestCalls += 1;
    return const PasswordResetRequestAccepted();
  }
}
