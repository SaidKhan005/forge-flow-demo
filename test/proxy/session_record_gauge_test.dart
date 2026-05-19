// Slice A11.1 — Production session-record gauge tests.
//
// Covers the gauge emission contract from
// `docs/archive/_execution/lane_a_code_health/03_execution_slices.md`
// "Slice A11.1 — Production Session-Record Gauge" + R3 §2 stretch goal:
//
//   1. Happy path — a tenant-scoped sign-in that returns a complete
//      session record (session_id + user_id + operator_id + location_id
//      all non-empty) does NOT increment the gauge.
//   2. Happy path — a global-admin sign-in (ff_support / super_admin)
//      that returns the contract-correct shape (session_id + user_id
//      non-empty, operator_id + location_id empty) does NOT increment
//      the gauge.
//   3. Predicate-only contract — feeding the gauge a body with a
//      missing field produces the right per-(route, missing_field)
//      increment WITHOUT touching the route at all.
//   4. Discipline — gauge.observe never throws on a malformed body and
//      never alters the assertion's `complete` field for the route's
//      response (the 2xx already shipped).
//
// The integration cases (1 + 2) drive the proxy's
// /v1/auth/session/login route end-to-end through `routeRequest` so the
// in-route emission point is exercised. Cases (3 + 4) exercise the
// gauge directly because the proxy never produces a missing-field
// response in normal operation — the gauge surfaces a contract break
// the route handler did not catch, so a unit test is the right shape
// for that branch (the route would have to be intentionally broken to
// produce the missing-field response, which is out of scope for this
// slice).
//
// The /v1/admin/auth/sessions list route returns `{sessions: [...]}`
// (a per-session listing, not a session record) and is therefore NOT
// a session-finalizing route — it is intentionally not wired into the
// gauge. Future slices may add additional finalizing routes; the
// gauge's per-route bucketing supports them with no schema change.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/services/auth/auth_session_ledger_writer.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';
import '../../tool/advisor_proxy/session_record_predicate.dart'
    show SessionRecordAssertion;

void main() {
  group('SessionRecordIncompleteGauge — predicate observability', () {
    test(
      'tenant-scoped complete record does NOT increment the gauge',
      () {
        final gauge = SessionRecordIncompleteGauge();
        final assertion = gauge.observe(
          route: authSessionLoginPath,
          body: <String, Object?>{
            'session_id': 'sid-1',
            'user_id': 'uid-1',
            'operator_id': 'op-1',
            'location_id': 'loc-1',
          },
          roles: <String>{'operator_owner'},
        );
        expect(assertion.complete, isTrue);
        expect(gauge.snapshot(), isEmpty);
        expect(gauge.totalIncrements(), equals(0));
      },
    );

    test(
      'global-admin complete record (empty scope by contract) does NOT '
      'increment the gauge',
      () {
        final gauge = SessionRecordIncompleteGauge();
        final assertion = gauge.observe(
          route: authSessionLoginPath,
          body: <String, Object?>{
            'session_id': 'sid-1',
            'user_id': 'uid-1',
            'operator_id': '',
            'location_id': '',
          },
          roles: <String>{'ff_support'},
        );
        expect(assertion.complete, isTrue);
        expect(gauge.snapshot(), isEmpty);
        expect(gauge.totalIncrements(), equals(0));
      },
    );

    test(
      'tenant-scoped record missing operator_id increments the per-(route,'
      ' missing_field) bucket',
      () {
        final gauge = SessionRecordIncompleteGauge();
        gauge.observe(
          route: authSessionLoginPath,
          body: <String, Object?>{
            'session_id': 'sid-1',
            'user_id': 'uid-1',
            'operator_id': '',
            'location_id': 'loc-1',
          },
          roles: <String>{'operator_owner'},
        );
        expect(gauge.snapshot(), <String, Map<String, int>>{
          authSessionLoginPath: <String, int>{'operator_id': 1},
        });
        expect(gauge.totalIncrements(), equals(1));
      },
    );

    test(
      'tenant-scoped record missing session_id AND user_id increments both '
      'buckets independently',
      () {
        final gauge = SessionRecordIncompleteGauge();
        gauge.observe(
          route: authSessionLoginPath,
          body: <String, Object?>{
            'session_id': '',
            'user_id': '',
            'operator_id': 'op-1',
            'location_id': 'loc-1',
          },
          roles: <String>{'operator_owner'},
        );
        final snapshot = gauge.snapshot();
        expect(snapshot[authSessionLoginPath]?['session_id'], equals(1));
        expect(snapshot[authSessionLoginPath]?['user_id'], equals(1));
        expect(gauge.totalIncrements(), equals(2));
      },
    );

    test(
      'global-admin record with non-empty operator_id increments the '
      'unexpected_operator_id bucket (contract violation)',
      () {
        final gauge = SessionRecordIncompleteGauge();
        gauge.observe(
          route: authSessionLoginPath,
          body: <String, Object?>{
            'session_id': 'sid-1',
            'user_id': 'uid-1',
            'operator_id': 'op-1',
            'location_id': '',
          },
          roles: <String>{'super_admin'},
        );
        expect(gauge.snapshot(), <String, Map<String, int>>{
          authSessionLoginPath: <String, int>{'unexpected_operator_id': 1},
        });
      },
    );

    test(
      'snapshot() returns a deep copy so callers cannot mutate gauge state',
      () {
        final gauge = SessionRecordIncompleteGauge();
        gauge.observe(
          route: authSessionLoginPath,
          body: <String, Object?>{
            'session_id': 'sid-1',
            'user_id': '',
            'operator_id': 'op-1',
            'location_id': 'loc-1',
          },
          roles: <String>{'operator_owner'},
        );
        final snap = gauge.snapshot();
        snap[authSessionLoginPath]!['user_id'] = 99;
        snap[authSessionLoginPath]!['injected'] = 1;
        // Re-snapshot must not see the caller's mutations.
        final fresh = gauge.snapshot();
        expect(fresh[authSessionLoginPath]?['user_id'], equals(1));
        expect(fresh[authSessionLoginPath]?['injected'], isNull);
      },
    );

    test(
      'reset() clears all per-route counts so a process restart starts '
      'observability from zero',
      () {
        final gauge = SessionRecordIncompleteGauge();
        gauge.observe(
          route: authSessionLoginPath,
          body: <String, Object?>{
            'session_id': '',
            'user_id': 'uid-1',
            'operator_id': 'op-1',
            'location_id': 'loc-1',
          },
          roles: <String>{'operator_owner'},
        );
        expect(gauge.totalIncrements(), equals(1));
        gauge.reset();
        expect(gauge.snapshot(), isEmpty);
        expect(gauge.totalIncrements(), equals(0));
      },
    );

    test(
      'observe never throws on a malformed body (defensive: gauge cannot '
      'crash the response path)',
      () {
        final gauge = SessionRecordIncompleteGauge();
        // Body has unexpected types — predicate coerces via toString(),
        // but the gauge's defensive try/catch is the belt + suspenders.
        final assertion = gauge.observe(
          route: authSessionLoginPath,
          body: <String, Object?>{
            'session_id': 12345,
            'user_id': null,
            'operator_id': 'op-1',
            'location_id': 'loc-1',
          },
          roles: <String>{'operator_owner'},
        );
        // Either the predicate reads it as complete (ints stringify) or it
        // counts user_id missing — both are non-throwing paths. The assertion
        // value is informational; the route handler never branches on it.
        expect(assertion, isA<SessionRecordAssertion>());
      },
    );
  });

  group(
    'POST /v1/auth/session/login — gauge emission integration',
    () {
      test(
        'tenant-scoped 2xx sign-in does NOT increment the gauge (happy path)',
        () async {
          await _withScaffold((scaffold) async {
            scaffold.verifier.claims = const ProxyJwtClaims(
              userId: 'uid-1',
              operatorId: 'op-1',
              locationId: 'loc-1',
              roles: <String>['operator_owner'],
              firebaseUid: 'firebase-uid',
            );
            final response = await scaffold.post(
              authSessionLoginPath,
              body: <String, Object?>{
                // Non-blank token_hash satisfies the success-path body
                // check (see authSessionLoginPath handler in
                // advisor_proxy.dart). The hash value is opaque to the
                // route — it just records the row in the session ledger.
                'token_hash': 'th-test',
              },
              authorization: 'Bearer placeholder.id.token',
            );
            expect(response.statusCode, equals(200));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            // Sanity: the response is the SessionRecord shape the predicate
            // checks; if this ever stops being true, the gauge starts firing
            // and the test catches it.
            expect(body['session_id'], isNotEmpty);
            expect(body['user_id'], equals('uid-1'));
            expect(body['operator_id'], equals('op-1'));
            expect(body['location_id'], equals('loc-1'));
            // The predicate-passing 2xx does NOT increment the gauge.
            expect(scaffold.gauge.snapshot(), isEmpty);
            expect(scaffold.gauge.totalIncrements(), equals(0));
          });
        },
      );

      test(
        'global-admin 2xx sign-in (empty scope by contract) does NOT '
        'increment the gauge',
        () async {
          await _withScaffold((scaffold) async {
            // ff_support / super_admin tokens skip the per-tenant scope
            // check (B1 sign-in contract); the proxy returns empty
            // operator_id + location_id strings. The predicate enforces
            // exactly this shape.
            scaffold.verifier.claims = const ProxyJwtClaims(
              userId: 'uid-1',
              operatorId: '',
              locationId: '',
              roles: <String>['ff_support'],
              firebaseUid: 'firebase-uid',
            );
            final response = await scaffold.post(
              authSessionLoginPath,
              body: <String, Object?>{
                // Non-blank token_hash satisfies the success-path body
                // check (see authSessionLoginPath handler in
                // advisor_proxy.dart). The hash value is opaque to the
                // route — it just records the row in the session ledger.
                'token_hash': 'th-test',
              },
              authorization: 'Bearer placeholder.id.token',
            );
            expect(response.statusCode, equals(200));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['session_id'], isNotEmpty);
            expect(body['user_id'], equals('uid-1'));
            expect(body['operator_id'], equals(''));
            expect(body['location_id'], equals(''));
            expect(scaffold.gauge.snapshot(), isEmpty);
          });
        },
      );

      test(
        'route runs without a gauge wired (back-compat: null gauge = no-op)',
        () async {
          // Same scaffold but with sessionRecordIncompleteGauge: null.
          await _withScaffold(
            (scaffold) async {
              scaffold.verifier.claims = const ProxyJwtClaims(
                userId: 'uid-1',
                operatorId: 'op-1',
                locationId: 'loc-1',
                roles: <String>['operator_owner'],
                firebaseUid: 'firebase-uid',
              );
              final response = await scaffold.post(
                authSessionLoginPath,
                body: <String, Object?>{'token_hash': 'th-test'},
                authorization: 'Bearer placeholder.id.token',
              );
              // Route succeeds whether or not the gauge is wired. This
              // is the back-compat guarantee for existing tests +
              // scaffolds that don't plumb the gauge through every
              // routeRequest call site.
              expect(response.statusCode, equals(200));
            },
            wireGauge: false,
          );
        },
      );
    },
  );
}

// ---- Test scaffold ---------------------------------------------------------

class _Scaffold {
  _Scaffold({
    required this.server,
    required this.client,
    required this.baseUri,
    required this.verifier,
    required this.gauge,
  });

  final HttpServer server;
  final HttpClient client;
  final Uri baseUri;
  final _SettableVerifier verifier;
  final SessionRecordIncompleteGauge gauge;

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
    );
  }
}

class _HttpResponse {
  _HttpResponse({required this.statusCode, required this.body});
  final int statusCode;
  final String body;
}

Future<void> _withScaffold(
  Future<void> Function(_Scaffold) body, {
  bool wireGauge = true,
}) async {
  final saved = HttpOverrides.current;
  HttpOverrides.global = null;
  try {
    final verifier = _SettableVerifier();
    final guard = ProxyRequestGuard(verifier: verifier);
    final ledger = _RecordingAuthSessionLedger();
    final gauge = SessionRecordIncompleteGauge();

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // ignore: unawaited_futures
    server.listen((request) async {
      try {
        await routeRequest(
          request,
          guard,
          authSessionLedgerWriter: ledger,
          // Trust forwarded IP so the lockout enforcer (when wired) can
          // resolve a stable IP. The login path used in this test does
          // not need the enforcer, but the scaffold mirrors the lockout
          // test's posture for parity.
          trustProxyAuditHeaders: false,
          sessionRecordIncompleteGauge: wireGauge ? gauge : null,
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
      gauge: gauge,
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

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    final value = claims;
    if (value != null) return value;
    throw ProxyJwtVerificationError('test verifier not configured');
  }
}

class _RecordingAuthSessionLedger implements AuthSessionLedgerWriter {
  int _seq = 0;

  @override
  Future<String> recordLogin(AuthSessionLedgerLogin login) async {
    _seq += 1;
    return 'session-$_seq';
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
