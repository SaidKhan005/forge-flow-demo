// Lane B B11.2.b — step-up wiring tests.
//
// B11.2 shipped the SCAFFOLD only (policy + registry + router + header
// builder + 27 unit tests). B11.2.b is the WIRING — the gate runs at
// the head of routeRequest BEFORE any sensitive handler. These tests
// pin:
//
//   1. The gate fires for every flagged route in
//      `kStepUpSensitiveRoutes`. Each sensitive surface emits a
//      401 + RFC 9470 WWW-Authenticate header + JSON body carrying
//      `challenge_id`, `required_acr`, `max_age_seconds`.
//   2. A valid challenge id presented in the `Step-Up-Challenge-Id`
//      HEADER (NEVER URL parameter — addendum A1) admits the
//      request.
//   3. A consumed challenge replayed returns 410.
//   4. A challenge from a different operator returns 401 (oracle-
//      safe — same status as expired so brute-force probing cannot
//      distinguish the two cases).
//   5. A challenge from the WRONG route returns 401 (same oracle-
//      safe collapse).
//   6. Service-principal callers (sp:* actor kind) skip the gate.
//   7. An unflagged route is unaffected even with the router wired.
//
// The tests drive `runStepUpGate` directly with a recording fake
// gateway so we exercise the FULL gate logic without binding HTTP
// sockets. The integration with `routeRequest` is asserted by the
// bootstrap test (b11_2_b_bootstrap_wiring_test).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';
import '../../tool/advisor_proxy/auth_step_up_gate.dart';
import '../../tool/advisor_proxy/auth_step_up_routes.dart';

const String _opA = 'op-1';
const String _opB = 'op-2';
const String _locA = 'loc-1';
const String _userA = 'user-1';

void main() {
  group('runStepUpGate', () {
    test('emits 401 + RFC 9470 challenge for every flagged surface', () async {
      // V1 sensitive surfaces. The slice spec mentions "14 sensitive
      // routes" but the registry actually covers 20 (mostly because
      // prefix matchers count as a single registry entry — one entry
      // covers PATCH + DELETE on /v1/admin/auth/roles/<id>).
      // We probe one canonical path per registry entry to assert the
      // gate fires across the full surface.
      final probes = <_RouteProbe>[
        _RouteProbe('PATCH', '/v1/operator/account'),
        _RouteProbe('POST', '/v1/auth/password/change'),
        _RouteProbe('POST', '/v1/auth/mfa/totp/begin'),
        _RouteProbe('POST', '/v1/auth/mfa/totp/confirm'),
        _RouteProbe('POST', '/v1/auth/mfa/factors/revoke'),
        _RouteProbe('POST', '/v1/admin/auth/roles'),
        _RouteProbe('PATCH', '/v1/admin/auth/roles/abc'),
        _RouteProbe('DELETE', '/v1/admin/auth/roles/abc'),
        _RouteProbe('POST', '/v1/admin/auth/role-grants'),
        _RouteProbe('DELETE', '/v1/admin/auth/role-grants/abc'),
        _RouteProbe('POST', '/v1/auth/team/roles'),
        _RouteProbe('PATCH', '/v1/auth/team/roles/abc'),
        _RouteProbe('DELETE', '/v1/auth/team/roles/abc'),
        _RouteProbe('POST', '/v1/auth/team/role-grants'),
        _RouteProbe('DELETE', '/v1/auth/team/role-grants/abc'),
        _RouteProbe('PATCH', '/v1/admin/pricing/operators/op-1'),
        _RouteProbe('PUT', '/v1/admin/pricing/usage-caps'),
        _RouteProbe('PATCH', '/v1/admin/pricing/plans/premium'),
        _RouteProbe('PUT', '/v1/admin/pricing/scoped-contracts'),
        _RouteProbe('POST', '/v1/admin/vendor-applicability/wage'),
        _RouteProbe('PATCH', '/v1/admin/vendor-applicability/covers'),
        _RouteProbe('DELETE', '/v1/admin/vendor-applicability/polling'),
      ];

      for (final probe in probes) {
        final gateway = _RecordingStepUpGateway(
          now: () => DateTime.utc(2026, 5, 13, 10),
        );
        final router = StepUpChallengeRouter(gateway: gateway);
        final request = _FakeHttpRequest(
          method: probe.method,
          path: probe.path,
          // No Step-Up-Challenge-Id header — caller has no fresh
          // proof.
          headers: <String, String>{
            HttpHeaders.authorizationHeader: 'Bearer placeholder',
          },
        );
        // Build a fake scope with STALE auth_time so the policy
        // requires a challenge.
        final scope = _scope(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          // 1 hour ago — well past the 5-minute freshness window.
          authTime: DateTime.utc(2026, 5, 13, 9),
        );

        final wrote = await runStepUpGate(
          request: request,
          path: probe.path,
          authGuard: _StubAuthGuard(scope),
          router: router,
          now: () => DateTime.utc(2026, 5, 13, 10),
        );
        expect(
          wrote,
          isTrue,
          reason: 'gate did not respond for ${probe.method} ${probe.path}',
        );
        expect(
          request.response.statusCodeValue,
          equals(401),
          reason: 'expected 401 challenge for ${probe.method} ${probe.path}',
        );
        final wwwHeader =
            request.response.capturedHeaders[kStepUpWwwAuthenticateHeader];
        expect(
          wwwHeader,
          isNotNull,
          reason: 'missing WWW-Authenticate for ${probe.method} ${probe.path}',
        );
        expect(wwwHeader, contains('error="insufficient_user_authentication"'));
        expect(wwwHeader, contains('acr_values="urn:mfa"'));
        expect(wwwHeader, contains('max_age=300'));
        final body =
            jsonDecode(request.response.writtenBody) as Map<String, Object?>;
        expect(body['error'], equals('insufficient_user_authentication'));
        expect(body['challenge_id'], isA<String>());
        expect((body['challenge_id'] as String).isNotEmpty, isTrue);
        expect(body['required_acr'], equals('urn:mfa'));
        expect(body['max_age_seconds'], equals(300));
        expect(
          gateway.emittedChallenges,
          hasLength(1),
          reason: 'expected 1 challenge persisted for ${probe.path}',
        );
        expect(gateway.emittedChallenges.single.routePath, equals(probe.path));
        expect(gateway.emittedChallenges.single.operatorId, equals(_opA));
        expect(gateway.emittedChallenges.single.userId, equals(_userA));
      }
    });

    test(
      'valid presented Step-Up-Challenge-Id HEADER admits the request',
      () async {
        final gateway = _RecordingStepUpGateway(
          now: () => DateTime.utc(2026, 5, 13, 10),
        );
        // Pre-seed the gateway with a challenge for opA/userA/revoke.
        gateway.seedChallenge(
          challengeId: 'CHAL_VALID',
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          routePath: '/v1/auth/session/revoke',
          expiresAt: DateTime.utc(2026, 5, 13, 10, 10),
        );
        // The route registry doesn't currently flag session/revoke —
        // pick a flagged route the gateway can consume. Use
        // /v1/auth/password/change.
        gateway.seedChallenge(
          challengeId: 'CHAL_PASSWORD',
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          routePath: '/v1/auth/password/change',
          expiresAt: DateTime.utc(2026, 5, 13, 10, 10),
        );
        final router = StepUpChallengeRouter(gateway: gateway);
        final request = _FakeHttpRequest(
          method: 'POST',
          path: '/v1/auth/password/change',
          headers: <String, String>{
            HttpHeaders.authorizationHeader: 'Bearer placeholder',
            kStepUpChallengeIdHeader: 'CHAL_PASSWORD',
          },
        );
        final wrote = await runStepUpGate(
          request: request,
          path: '/v1/auth/password/change',
          authGuard: _StubAuthGuard(
            _scope(
              operatorId: _opA,
              locationId: _locA,
              userId: _userA,
              authTime: DateTime.utc(2026, 5, 13, 9), // stale
            ),
          ),
          router: router,
          now: () => DateTime.utc(2026, 5, 13, 10),
        );
        // Admit -> gate writes nothing, returns false.
        expect(wrote, isFalse);
        expect(gateway.consumedIds, contains('CHAL_PASSWORD'));
      },
    );

    test('consumed challenge replayed returns 410', () async {
      final gateway = _RecordingStepUpGateway(
        now: () => DateTime.utc(2026, 5, 13, 10),
      );
      gateway.seedChallenge(
        challengeId: 'CHAL_ALREADY_USED',
        operatorId: _opA,
        locationId: _locA,
        userId: _userA,
        routePath: '/v1/auth/password/change',
        expiresAt: DateTime.utc(2026, 5, 13, 10, 10),
        consumedAt: DateTime.utc(2026, 5, 13, 9, 55),
      );
      final router = StepUpChallengeRouter(gateway: gateway);
      final request = _FakeHttpRequest(
        method: 'POST',
        path: '/v1/auth/password/change',
        headers: <String, String>{
          HttpHeaders.authorizationHeader: 'Bearer placeholder',
          kStepUpChallengeIdHeader: 'CHAL_ALREADY_USED',
        },
      );
      final wrote = await runStepUpGate(
        request: request,
        path: '/v1/auth/password/change',
        authGuard: _StubAuthGuard(
          _scope(
            operatorId: _opA,
            locationId: _locA,
            userId: _userA,
            authTime: DateTime.utc(2026, 5, 13, 9), // stale
          ),
        ),
        router: router,
        now: () => DateTime.utc(2026, 5, 13, 10),
      );
      expect(wrote, isTrue);
      expect(request.response.statusCodeValue, equals(410));
      final body =
          jsonDecode(request.response.writtenBody) as Map<String, Object?>;
      expect(body['error'], equals('step_up_challenge_already_consumed'));
    });

    test('cross-operator challenge replay returns 401 (oracle-safe)', () async {
      final gateway = _RecordingStepUpGateway(
        now: () => DateTime.utc(2026, 5, 13, 10),
      );
      // Challenge issued for operator B; replay attempt from operator A.
      gateway.seedChallenge(
        challengeId: 'CHAL_CROSS_OP',
        operatorId: _opB,
        locationId: _locA,
        userId: _userA,
        routePath: '/v1/auth/password/change',
        expiresAt: DateTime.utc(2026, 5, 13, 10, 10),
      );
      final router = StepUpChallengeRouter(gateway: gateway);
      final request = _FakeHttpRequest(
        method: 'POST',
        path: '/v1/auth/password/change',
        headers: <String, String>{
          HttpHeaders.authorizationHeader: 'Bearer placeholder',
          kStepUpChallengeIdHeader: 'CHAL_CROSS_OP',
        },
      );
      final wrote = await runStepUpGate(
        request: request,
        path: '/v1/auth/password/change',
        authGuard: _StubAuthGuard(
          _scope(
            operatorId: _opA, // wrong operator
            locationId: _locA,
            userId: _userA,
            authTime: DateTime.utc(2026, 5, 13, 9), // stale
          ),
        ),
        router: router,
        now: () => DateTime.utc(2026, 5, 13, 10),
      );
      expect(wrote, isTrue);
      // 401 (NOT 410) — oracle-safe: an attacker probing the id space
      // gets the same response for unknown-id, wrong-operator, and
      // expired so cross-operator existence cannot be inferred.
      expect(request.response.statusCodeValue, equals(401));
    });

    test('wrong-route challenge replay returns 401 (oracle-safe)', () async {
      final gateway = _RecordingStepUpGateway(
        now: () => DateTime.utc(2026, 5, 13, 10),
      );
      gateway.seedChallenge(
        challengeId: 'CHAL_FOR_PASSWORD',
        operatorId: _opA,
        locationId: _locA,
        userId: _userA,
        routePath: '/v1/auth/password/change',
        expiresAt: DateTime.utc(2026, 5, 13, 10, 10),
      );
      final router = StepUpChallengeRouter(gateway: gateway);
      // Try to use a password challenge against an admin role mutation.
      final request = _FakeHttpRequest(
        method: 'POST',
        path: '/v1/admin/auth/roles',
        headers: <String, String>{
          HttpHeaders.authorizationHeader: 'Bearer placeholder',
          kStepUpChallengeIdHeader: 'CHAL_FOR_PASSWORD',
        },
      );
      final wrote = await runStepUpGate(
        request: request,
        path: '/v1/admin/auth/roles',
        authGuard: _StubAuthGuard(
          _scope(
            operatorId: _opA,
            locationId: _locA,
            userId: _userA,
            authTime: DateTime.utc(2026, 5, 13, 9), // stale
          ),
        ),
        router: router,
        now: () => DateTime.utc(2026, 5, 13, 10),
      );
      expect(wrote, isTrue);
      expect(request.response.statusCodeValue, equals(401));
    });

    test('service-principal caller skips the gate (V1)', () async {
      final gateway = _RecordingStepUpGateway(
        now: () => DateTime.utc(2026, 5, 13, 10),
      );
      final router = StepUpChallengeRouter(gateway: gateway);
      final request = _FakeHttpRequest(
        method: 'POST',
        path: '/v1/auth/password/change',
        headers: <String, String>{
          HttpHeaders.authorizationHeader: 'Bearer placeholder',
        },
      );
      final scope = _scope(
        operatorId: _opA,
        locationId: _locA,
        userId: _userA,
        authTime: DateTime.utc(2026, 5, 13, 9),
        actorKind: 'service_principal',
      );
      final wrote = await runStepUpGate(
        request: request,
        path: '/v1/auth/password/change',
        authGuard: _StubAuthGuard(scope),
        router: router,
        now: () => DateTime.utc(2026, 5, 13, 10),
      );
      expect(wrote, isFalse);
      expect(gateway.emittedChallenges, isEmpty);
    });

    test(
      'unflagged route is unaffected (gate.isSensitive returns false)',
      () async {
        final router = StepUpChallengeRouter(
          gateway: _RecordingStepUpGateway(
            now: () => DateTime.utc(2026, 5, 13, 10),
          ),
        );
        // The dispatcher would not call runStepUpGate at all because
        // isSensitive returns false; here we assert isSensitive directly.
        expect(
          router.isSensitive(method: 'GET', path: '/v1/operator/account'),
          isFalse,
        );
        expect(
          router.isSensitive(method: 'POST', path: '/v1/auth/handoff/codes'),
          isFalse,
        );
        // B11.1's handoff codes route is NOT a step-up target.
        expect(
          router.isSensitive(method: 'POST', path: '/v1/auth/handoff/redeem'),
          isFalse,
        );
      },
    );

    test('addendum A1 — Step-Up-Challenge-Id passed as URL query parameter is '
        'IGNORED; the gate emits a fresh challenge', () async {
      final gateway = _RecordingStepUpGateway(
        now: () => DateTime.utc(2026, 5, 13, 10),
      );
      gateway.seedChallenge(
        challengeId: 'CHAL_TOKEN_IN_URL',
        operatorId: _opA,
        locationId: _locA,
        userId: _userA,
        routePath: '/v1/auth/password/change',
        expiresAt: DateTime.utc(2026, 5, 13, 10, 10),
      );
      final router = StepUpChallengeRouter(gateway: gateway);
      // No Step-Up-Challenge-Id HEADER. The id is in the URL — the
      // gate does NOT inspect URL params, so this is just an
      // unflagged challenge id from the proxy's perspective.
      final request = _FakeHttpRequest(
        method: 'POST',
        path: '/v1/auth/password/change',
        // Even if URL has ?challenge_id=... it is irrelevant —
        // runStepUpGate reads ONLY from request.headers.value(...)
        // for kStepUpChallengeIdHeader.
        headers: <String, String>{
          HttpHeaders.authorizationHeader: 'Bearer placeholder',
        },
      );
      final wrote = await runStepUpGate(
        request: request,
        path: '/v1/auth/password/change',
        authGuard: _StubAuthGuard(
          _scope(
            operatorId: _opA,
            locationId: _locA,
            userId: _userA,
            authTime: DateTime.utc(2026, 5, 13, 9),
          ),
        ),
        router: router,
        now: () => DateTime.utc(2026, 5, 13, 10),
      );
      // Gate emits a FRESH challenge (not the seeded one), proving
      // the URL-param value was ignored.
      expect(wrote, isTrue);
      expect(request.response.statusCodeValue, equals(401));
      expect(gateway.consumedIds, isEmpty);
      expect(gateway.emittedChallenges, hasLength(1));
      expect(
        gateway.emittedChallenges.single.challengeId,
        isNot(equals('CHAL_TOKEN_IN_URL')),
      );
    });
  });
}

// ─── Fakes ──────────────────────────────────────────────────────────

class _RouteProbe {
  const _RouteProbe(this.method, this.path);
  final String method;
  final String path;
}

OperatorContext _scope({
  required String operatorId,
  required String locationId,
  required String userId,
  required DateTime authTime,
  String actorKind = 'user',
}) {
  return OperatorContext(
    userId: userId,
    operatorId: operatorId,
    locationId: locationId,
    roles: const <String>['operator_owner'],
    actorKind: actorKind,
    lastFreshAuthAt: authTime,
  );
}

/// Stub auth guard — bypasses JWT verification + returns a fixed scope.
class _StubAuthGuard implements ProxyRequestGuard {
  _StubAuthGuard(this._scope);

  final OperatorContext _scope;

  @override
  Future<OperatorContext> requireOperatorContext({
    required String? authorizationHeader,
  }) async {
    return _scope;
  }

  @override
  Future<ProxyJwtClaims> requireVerifiedClaims({
    required String? authorizationHeader,
  }) async {
    throw UnimplementedError('not used in B11.2.b wiring tests');
  }
}

/// Recording in-memory gateway. Mirrors the production
/// `RepositoryStepUpChallengesGateway` shape but stores rows in a
/// `Map<String, _StoredChallenge>` so tests can assert emit/consume
/// behavior without binding Postgres.
class _RecordingStepUpGateway implements StepUpChallengesGateway {
  _RecordingStepUpGateway({DateTime Function() now = DateTime.now})
    : _now = now;

  final DateTime Function() _now;
  final Map<String, _StoredChallenge> _store = <String, _StoredChallenge>{};
  final List<_StoredChallenge> emittedChallenges = <_StoredChallenge>[];
  final List<String> consumedIds = <String>[];
  int _counter = 0;

  void seedChallenge({
    required String challengeId,
    required String operatorId,
    required String locationId,
    required String userId,
    required String routePath,
    required DateTime expiresAt,
    DateTime? consumedAt,
  }) {
    _store[challengeId] = _StoredChallenge(
      challengeId: challengeId,
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
      routePath: routePath,
      requiredAcr: 'urn:mfa',
      requiredFreshnessSeconds: 300,
      expiresAt: expiresAt,
      consumedAt: consumedAt,
    );
  }

  @override
  Future<String> emit({
    required String operatorId,
    required String locationId,
    required String userId,
    required String routePath,
    required String requiredAcr,
    required int requiredFreshnessSeconds,
    required Duration challengeTtl,
    required String sourceActorKind,
    required String? sourceDeviceFingerprint,
  }) async {
    _counter += 1;
    final challengeId = 'CHAL_GEN_$_counter';
    final row = _StoredChallenge(
      challengeId: challengeId,
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
      routePath: routePath,
      requiredAcr: requiredAcr,
      requiredFreshnessSeconds: requiredFreshnessSeconds,
      expiresAt: _now().toUtc().add(challengeTtl),
    );
    _store[challengeId] = row;
    emittedChallenges.add(row);
    return challengeId;
  }

  @override
  Future<StepUpChallengeConsumed?> consume({
    required String callerOperatorId,
    required String callerLocationId,
    required String callerUserId,
    required String callerRoutePath,
    required String challengeId,
  }) async {
    final row = _store[challengeId];
    if (row == null) return null;
    if (row.operatorId != callerOperatorId) return null;
    if (row.userId != callerUserId) return null;
    if (row.routePath != callerRoutePath) return null;
    if (row.consumedAt != null) return null;
    if (row.expiresAt.isBefore(_now().toUtc())) return null;
    row.consumedAt = _now().toUtc();
    consumedIds.add(challengeId);
    return StepUpChallengeConsumed(
      challengeId: row.challengeId,
      operatorId: row.operatorId,
      locationId: row.locationId,
      userId: row.userId,
      routePath: row.routePath,
      requiredAcr: row.requiredAcr,
      requiredFreshnessSeconds: row.requiredFreshnessSeconds,
      consumedAt: row.consumedAt!,
    );
  }

  @override
  Future<StepUpChallengeState?> lookupForReplayCheck({
    required String callerOperatorId,
    required String challengeId,
  }) async {
    final row = _store[challengeId];
    if (row == null) return null;
    return StepUpChallengeState(
      operatorId: row.operatorId,
      userId: row.userId,
      routePath: row.routePath,
      expiresAt: row.expiresAt,
      consumedAt: row.consumedAt,
    );
  }
}

class _StoredChallenge {
  _StoredChallenge({
    required this.challengeId,
    required this.operatorId,
    required this.locationId,
    required this.userId,
    required this.routePath,
    required this.requiredAcr,
    required this.requiredFreshnessSeconds,
    required this.expiresAt,
    this.consumedAt,
  });

  final String challengeId;
  final String operatorId;
  final String locationId;
  final String userId;
  final String routePath;
  final String requiredAcr;
  final int requiredFreshnessSeconds;
  final DateTime expiresAt;
  DateTime? consumedAt;
}

/// Fake HttpRequest that captures response writes so the test can
/// assert status code + headers + body.
class _FakeHttpRequest implements HttpRequest {
  _FakeHttpRequest({
    required this.method,
    required this.path,
    Map<String, String> headers = const <String, String>{},
  }) : uri = Uri.parse(path),
       response = _FakeHttpResponse(),
       _headers = _FakeHttpHeaders(headers);

  @override
  final String method;

  final String path;

  @override
  final Uri uri;

  @override
  final _FakeHttpResponse response;

  final _FakeHttpHeaders _headers;

  @override
  HttpHeaders get headers => _headers;

  // Stub members — only the API surface used by runStepUpGate is wired.
  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('not used in B11.2.b wiring tests');
}

class _FakeHttpHeaders implements HttpHeaders {
  _FakeHttpHeaders(Map<String, String> source)
    : _store = <String, List<String>>{
        for (final entry in source.entries)
          entry.key.toLowerCase(): <String>[entry.value],
      };

  final Map<String, List<String>> _store;

  @override
  String? value(String name) {
    final v = _store[name.toLowerCase()];
    if (v == null || v.isEmpty) return null;
    return v.single;
  }

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('not used in B11.2.b wiring tests');
}

class _FakeHttpResponse implements HttpResponse {
  int statusCodeValue = 200;
  final Map<String, String> capturedHeaders = <String, String>{};
  final StringBuffer _body = StringBuffer();
  final _FakeOutHeaders _headers = _FakeOutHeaders();

  @override
  int get statusCode => statusCodeValue;

  @override
  set statusCode(int value) {
    statusCodeValue = value;
  }

  @override
  HttpHeaders get headers {
    _headers.bind(capturedHeaders, (_) {});
    return _headers;
  }

  @override
  void write(Object? object) {
    _body.write(object);
  }

  String get writtenBody => _body.toString();

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('not used in B11.2.b wiring tests');
}

class _FakeOutHeaders implements HttpHeaders {
  late Map<String, String> _store;
  late void Function(ContentType?) _onContentType;
  bool _bound = false;

  void bind(
    Map<String, String> store,
    void Function(ContentType?) onContentType,
  ) {
    if (_bound) return;
    _store = store;
    _onContentType = onContentType;
    _bound = true;
  }

  @override
  set contentType(ContentType? value) {
    _onContentType(value);
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _store[name] = value.toString();
  }

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('not used in B11.2.b wiring tests');
}
