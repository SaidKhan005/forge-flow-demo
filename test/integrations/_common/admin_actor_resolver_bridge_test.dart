// Phase 8 framework — admin actor resolver bridge tests.
//
// Covers the four behaviours the slice promises:
//   1. Missing Authorization header → null.
//   2. Invalid JWT (verifier throws) → null.
//   3. Valid JWT + known user → AdminActorContext with the right
//      operator/location/user ids.
//   4. Valid JWT + unknown user (lookup returns null) → null.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/_common/admin_actor_resolver_bridge.dart';

const String _opId = '11111111-2222-3333-4444-555555555555';
const String _locId = '66666666-7777-8888-9999-aaaaaaaaaaaa';
const String _userId = 'bbbbbbbb-cccc-dddd-eeee-ffffffffffff';
const String _firebaseUid = 'firebase-uid-001';

void main() {
  test('missing Authorization header returns null', () async {
    final request = _FakeRequest();
    final actor = await resolveAdminActorFromHttpRequest(
      request,
      jwtVerifier: _AlwaysOkVerifier(),
      lookupResolver: _StaticLookupResolver(uid: _userId),
    );
    expect(actor, isNull);
  });

  test('invalid bearer prefix returns null', () async {
    final request = _FakeRequest(authorization: 'Token abc');
    final actor = await resolveAdminActorFromHttpRequest(
      request,
      jwtVerifier: _AlwaysOkVerifier(),
      lookupResolver: _StaticLookupResolver(uid: _userId),
    );
    expect(actor, isNull);
  });

  test('verifier throw surfaces as null', () async {
    final request = _FakeRequest(authorization: 'Bearer xyz');
    final actor = await resolveAdminActorFromHttpRequest(
      request,
      jwtVerifier: _ThrowingVerifier(),
      lookupResolver: _StaticLookupResolver(uid: _userId),
    );
    expect(actor, isNull);
  });

  test(
      'valid token with known user produces an AdminActorContext '
      'carrying the verified operator/location/user ids', () async {
    final request = _FakeRequest(authorization: 'Bearer good-token');
    final lookup = _RecordingLookupResolver(uid: _userId);
    final actor = await resolveAdminActorFromHttpRequest(
      request,
      jwtVerifier: _AlwaysOkVerifier(),
      lookupResolver: lookup,
    );
    expect(actor, isNotNull);
    expect(actor!.operatorId, equals(_opId));
    expect(actor.locationId, equals(_locId));
    expect(actor.userId, equals(_userId));
    // Lookup ran with the canonical reason string.
    expect(lookup.lastFirebaseUid, equals(_firebaseUid));
    expect(lookup.lastReason, equals(kAdminActorIntegrationsReason));
  });

  test('valid token with unknown user returns null', () async {
    final request = _FakeRequest(authorization: 'Bearer good-token');
    final actor = await resolveAdminActorFromHttpRequest(
      request,
      jwtVerifier: _AlwaysOkVerifier(),
      lookupResolver: _StaticLookupResolver(uid: null),
    );
    expect(actor, isNull);
  });

  test('valid token missing operator scope returns null', () async {
    final request = _FakeRequest(authorization: 'Bearer good-token');
    final actor = await resolveAdminActorFromHttpRequest(
      request,
      jwtVerifier:
          _StaticVerifier(claims: const AdminActorJwtClaims(
        firebaseUid: _firebaseUid,
        operatorId: null,
        locationId: _locId,
      )),
      lookupResolver: _StaticLookupResolver(uid: _userId),
    );
    expect(actor, isNull);
  });

  test('valid token missing firebase uid returns null', () async {
    final request = _FakeRequest(authorization: 'Bearer good-token');
    final actor = await resolveAdminActorFromHttpRequest(
      request,
      jwtVerifier:
          _StaticVerifier(claims: const AdminActorJwtClaims(
        firebaseUid: null,
        operatorId: _opId,
        locationId: _locId,
      )),
      lookupResolver: _StaticLookupResolver(uid: _userId),
    );
    expect(actor, isNull);
  });
}

// ── Fakes ───────────────────────────────────────────────────────────

class _FakeRequest implements HttpRequest {
  _FakeRequest({String? authorization}) {
    _headers = _FakeHeaders(authorization: authorization);
  }

  late final _FakeHeaders _headers;

  @override
  HttpHeaders get headers => _headers;

  // Other HttpRequest members are not exercised — leave them as
  // noSuchMethod throws.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeHeaders implements HttpHeaders {
  _FakeHeaders({String? authorization}) : _authorization = authorization;
  final String? _authorization;

  @override
  String? value(String name) {
    if (name.toLowerCase() == 'authorization') return _authorization;
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _AlwaysOkVerifier implements AdminActorJwtVerifier {
  @override
  Future<AdminActorJwtClaims> verify(String bearerToken) async {
    return const AdminActorJwtClaims(
      firebaseUid: _firebaseUid,
      operatorId: _opId,
      locationId: _locId,
    );
  }
}

class _ThrowingVerifier implements AdminActorJwtVerifier {
  @override
  Future<AdminActorJwtClaims> verify(String bearerToken) async {
    throw const FormatException('invalid token');
  }
}

class _StaticVerifier implements AdminActorJwtVerifier {
  _StaticVerifier({required this.claims});
  final AdminActorJwtClaims claims;

  @override
  Future<AdminActorJwtClaims> verify(String bearerToken) async => claims;
}

class _StaticLookupResolver implements AdminActorUserResolver {
  _StaticLookupResolver({required this.uid});
  final String? uid;

  @override
  Future<String?> resolveActorUserId({
    required String firebaseUid,
    required String adminReason,
  }) async {
    return uid;
  }
}

class _RecordingLookupResolver implements AdminActorUserResolver {
  _RecordingLookupResolver({required this.uid});
  final String? uid;
  String? lastFirebaseUid;
  String? lastReason;

  @override
  Future<String?> resolveActorUserId({
    required String firebaseUid,
    required String adminReason,
  }) async {
    lastFirebaseUid = firebaseUid;
    lastReason = adminReason;
    return uid;
  }
}
