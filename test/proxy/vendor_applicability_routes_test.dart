import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

const String _adminPostgresUserId = '11111111-1111-4111-8111-111111111111';
const String _operatorId = '22222222-2222-4222-8222-222222222222';
const String _locationId = '33333333-3333-4333-8333-333333333333';

void main() {
  group('vendor applicability proxy routes', () {
    test('admin GET returns gateway rows for super_admin callers', () async {
      final gateway = _FakeVendorApplicabilityGateway();
      final ctx = await _serve(
        claims: const ProxyJwtClaims(
          userId: 'firebase-admin',
          operatorId: null,
          locationId: null,
          roles: <String>['super_admin'],
        ),
        gateway: gateway,
      );
      addTearDown(ctx.close);

      final response = await _httpGet(
        ctx.uri(
          '/v1/admin/vendor-applicability?setting_kind=wage&current_only=false',
        ),
      );

      expect(response.statusCode, 200);
      final body = jsonDecode(response.body) as Map<String, Object?>;
      expect(body['rows'], isA<List<Object?>>());
      expect(gateway.listAdminCalls, hasLength(1));
      expect(gateway.listAdminCalls.single.settingKind, 'wage');
      expect(gateway.listAdminCalls.single.currentOnly, isFalse);
    });

    test('ff_support can read the admin route without write access', () async {
      final gateway = _FakeVendorApplicabilityGateway();
      final ctx = await _serve(
        claims: const ProxyJwtClaims(
          userId: 'support-user',
          operatorId: null,
          locationId: null,
          roles: <String>['ff_support'],
        ),
        gateway: gateway,
      );
      addTearDown(ctx.close);

      final response = await _httpGet(
        ctx.uri('/v1/admin/vendor-applicability'),
      );

      expect(response.statusCode, 200);
      expect(gateway.listAdminCalls, hasLength(1));
    });

    test(
      'admin writes require Idempotency-Key before gateway execution',
      () async {
        final gateway = _FakeVendorApplicabilityGateway();
        final ctx = await _serve(
          claims: const ProxyJwtClaims(
            userId: 'firebase-admin',
            firebaseUid: 'firebase-admin',
            operatorId: null,
            locationId: null,
            roles: <String>['super_admin'],
          ),
          gateway: gateway,
          resolver: _FakeIntegrationAdminActorResolver(_adminPostgresUserId),
        );
        addTearDown(ctx.close);

        final response = await _httpJson(
          'POST',
          ctx.uri('/v1/admin/vendor-applicability'),
          body: _upsertBody(),
        );

        expect(response.statusCode, 400);
        final body = jsonDecode(response.body) as Map<String, Object?>;
        expect(body['error'], 'idempotency_key_missing');
        expect(gateway.upsertCalls, isEmpty);
      },
    );

    test('admin POST resolves actor and replays idempotent writes', () async {
      final gateway = _FakeVendorApplicabilityGateway();
      final store = _MemoryAdminIdempotencyStore();
      final resolver = _FakeIntegrationAdminActorResolver(_adminPostgresUserId);
      final ctx = await _serve(
        claims: const ProxyJwtClaims(
          userId: 'firebase-admin',
          firebaseUid: 'firebase-admin',
          operatorId: null,
          locationId: null,
          roles: <String>['super_admin'],
        ),
        gateway: gateway,
        resolver: resolver,
        idempotencyStore: store,
      );
      addTearDown(ctx.close);

      final first = await _httpJson(
        'POST',
        ctx.uri('/v1/admin/vendor-applicability'),
        idempotencyKey: 'idem-upsert',
        body: _upsertBody(),
      );
      final second = await _httpJson(
        'POST',
        ctx.uri('/v1/admin/vendor-applicability'),
        idempotencyKey: 'idem-upsert',
        body: _upsertBody(),
      );

      expect(first.statusCode, 200);
      expect(second.statusCode, 200);
      expect(gateway.upsertCalls, hasLength(1));
      expect(gateway.upsertCalls.single.actorUserId, _adminPostgresUserId);
      expect(gateway.upsertCalls.single.settingKind, 'wage');
      expect(
        gateway.upsertCalls.single.adminReason,
        'Ticket VA-123 launch wage defaults',
      );
      expect(
        gateway.upsertCalls.single.metadata['authority_basis'],
        'job_code',
      );
      expect(resolver.firebaseUids, <String>[
        'firebase-admin',
        'firebase-admin',
      ]);
      expect(store.completedKeys, <String>['idem-upsert']);
    });

    test(
      'admin POST rejects missing admin_reason before gateway write',
      () async {
        final gateway = _FakeVendorApplicabilityGateway();
        final ctx = await _serve(
          claims: const ProxyJwtClaims(
            userId: 'firebase-admin',
            firebaseUid: 'firebase-admin',
            operatorId: null,
            locationId: null,
            roles: <String>['super_admin'],
          ),
          gateway: gateway,
          resolver: _FakeIntegrationAdminActorResolver(_adminPostgresUserId),
          idempotencyStore: _MemoryAdminIdempotencyStore(),
        );
        addTearDown(ctx.close);
        final body = Map<String, Object?>.from(_upsertBody())
          ..remove('admin_reason');

        final response = await _httpJson(
          'POST',
          ctx.uri('/v1/admin/vendor-applicability'),
          idempotencyKey: 'idem-missing-reason',
          body: body,
        );

        expect(response.statusCode, 400);
        final decoded = jsonDecode(response.body) as Map<String, Object?>;
        expect(decoded['error'], 'missing_admin_reason');
        expect(gateway.upsertCalls, isEmpty);
      },
    );

    test(
      'admin PATCH end delegates through the idempotent write path',
      () async {
        final gateway = _FakeVendorApplicabilityGateway();
        final ctx = await _serve(
          claims: const ProxyJwtClaims(
            userId: 'firebase-admin',
            firebaseUid: 'firebase-admin',
            operatorId: null,
            locationId: null,
            roles: <String>['super_admin'],
          ),
          gateway: gateway,
          resolver: _FakeIntegrationAdminActorResolver(_adminPostgresUserId),
          idempotencyStore: _MemoryAdminIdempotencyStore(),
        );
        addTearDown(ctx.close);

        final response = await _httpJson(
          'PATCH',
          ctx.uri('/v1/admin/vendor-applicability'),
          idempotencyKey: 'idem-end',
          body: const <String, Object?>{
            'action': 'end',
            'setting_kind': 'wage',
            'setting_key': 'tip_credit',
            'vendor_slug': 'toast',
            'admin_reason': 'Ticket VA-124 retire stale default',
            'reason_note': 'retired',
          },
        );

        expect(response.statusCode, 200);
        expect(gateway.endCalls, hasLength(1));
        expect(gateway.endCalls.single.actorUserId, _adminPostgresUserId);
        expect(
          gateway.endCalls.single.adminReason,
          'Ticket VA-124 retire stale default',
        );
        expect(gateway.endCalls.single.reasonNote, 'retired');
      },
    );

    test(
      'admin PATCH rejects blank admin_reason before gateway write',
      () async {
        final gateway = _FakeVendorApplicabilityGateway();
        final ctx = await _serve(
          claims: const ProxyJwtClaims(
            userId: 'firebase-admin',
            firebaseUid: 'firebase-admin',
            operatorId: null,
            locationId: null,
            roles: <String>['super_admin'],
          ),
          gateway: gateway,
          resolver: _FakeIntegrationAdminActorResolver(_adminPostgresUserId),
          idempotencyStore: _MemoryAdminIdempotencyStore(),
        );
        addTearDown(ctx.close);

        final response = await _httpJson(
          'PATCH',
          ctx.uri('/v1/admin/vendor-applicability'),
          idempotencyKey: 'idem-blank-reason',
          body: const <String, Object?>{
            'action': 'end',
            'setting_kind': 'wage',
            'setting_key': 'tip_credit',
            'vendor_slug': 'toast',
            'admin_reason': '   ',
          },
        );

        expect(response.statusCode, 400);
        final decoded = jsonDecode(response.body) as Map<String, Object?>;
        expect(decoded['error'], 'missing_admin_reason');
        expect(gateway.endCalls, isEmpty);
      },
    );

    test('admin POST threads location_id through to the gateway', () async {
      final gateway = _FakeVendorApplicabilityGateway();
      final ctx = await _serve(
        claims: const ProxyJwtClaims(
          userId: 'firebase-admin',
          firebaseUid: 'firebase-admin',
          operatorId: null,
          locationId: null,
          roles: <String>['super_admin'],
        ),
        gateway: gateway,
        resolver: _FakeIntegrationAdminActorResolver(_adminPostgresUserId),
        idempotencyStore: _MemoryAdminIdempotencyStore(),
      );
      addTearDown(ctx.close);

      final body = Map<String, Object?>.from(_upsertBody())
        ..['operator_id'] = _operatorId
        ..['location_id'] = _locationId;

      final response = await _httpJson(
        'POST',
        ctx.uri('/v1/admin/vendor-applicability'),
        idempotencyKey: 'idem-location-upsert',
        body: body,
      );

      expect(response.statusCode, 200);
      expect(gateway.upsertCalls, hasLength(1));
      expect(gateway.upsertCalls.single.operatorId, _operatorId);
      expect(gateway.upsertCalls.single.locationId, _locationId);
    });

    test(
      'admin POST rejects location_id without operator_id before the gateway',
      () async {
        final gateway = _FakeVendorApplicabilityGateway();
        final ctx = await _serve(
          claims: const ProxyJwtClaims(
            userId: 'firebase-admin',
            firebaseUid: 'firebase-admin',
            operatorId: null,
            locationId: null,
            roles: <String>['super_admin'],
          ),
          gateway: gateway,
          resolver: _FakeIntegrationAdminActorResolver(_adminPostgresUserId),
          idempotencyStore: _MemoryAdminIdempotencyStore(),
        );
        addTearDown(ctx.close);

        final body = Map<String, Object?>.from(_upsertBody())
          ..['location_id'] = _locationId;

        final response = await _httpJson(
          'POST',
          ctx.uri('/v1/admin/vendor-applicability'),
          idempotencyKey: 'idem-location-no-operator',
          body: body,
        );

        expect(response.statusCode, 400);
        final decoded = jsonDecode(response.body) as Map<String, Object?>;
        expect(decoded['error'], 'location_requires_operator');
        expect(gateway.upsertCalls, isEmpty);
      },
    );

    test('admin PATCH end threads location_id through to the gateway', () async {
      final gateway = _FakeVendorApplicabilityGateway();
      final ctx = await _serve(
        claims: const ProxyJwtClaims(
          userId: 'firebase-admin',
          firebaseUid: 'firebase-admin',
          operatorId: null,
          locationId: null,
          roles: <String>['super_admin'],
        ),
        gateway: gateway,
        resolver: _FakeIntegrationAdminActorResolver(_adminPostgresUserId),
        idempotencyStore: _MemoryAdminIdempotencyStore(),
      );
      addTearDown(ctx.close);

      final response = await _httpJson(
        'PATCH',
        ctx.uri('/v1/admin/vendor-applicability'),
        idempotencyKey: 'idem-location-end',
        body: <String, Object?>{
          'action': 'end',
          'operator_id': _operatorId,
          'location_id': _locationId,
          'setting_kind': 'wage',
          'setting_key': 'tip_credit',
          'vendor_slug': 'toast',
          'admin_reason': 'Ticket VA-130 retire location override',
        },
      );

      expect(response.statusCode, 200);
      expect(gateway.endCalls, hasLength(1));
      expect(gateway.endCalls.single.operatorId, _operatorId);
      expect(gateway.endCalls.single.locationId, _locationId);
    });

    test(
      'admin PATCH end rejects location_id without operator_id',
      () async {
        final gateway = _FakeVendorApplicabilityGateway();
        final ctx = await _serve(
          claims: const ProxyJwtClaims(
            userId: 'firebase-admin',
            firebaseUid: 'firebase-admin',
            operatorId: null,
            locationId: null,
            roles: <String>['super_admin'],
          ),
          gateway: gateway,
          resolver: _FakeIntegrationAdminActorResolver(_adminPostgresUserId),
          idempotencyStore: _MemoryAdminIdempotencyStore(),
        );
        addTearDown(ctx.close);

        final response = await _httpJson(
          'PATCH',
          ctx.uri('/v1/admin/vendor-applicability'),
          idempotencyKey: 'idem-end-location-no-operator',
          body: <String, Object?>{
            'action': 'end',
            'location_id': _locationId,
            'setting_kind': 'wage',
            'setting_key': 'tip_credit',
            'vendor_slug': 'toast',
            'admin_reason': 'Ticket VA-131 bad scope',
          },
        );

        expect(response.statusCode, 400);
        final decoded = jsonDecode(response.body) as Map<String, Object?>;
        expect(decoded['error'], 'location_requires_operator');
        expect(gateway.endCalls, isEmpty);
      },
    );

    test('admin GET passes operator + location filters through', () async {
      final gateway = _FakeVendorApplicabilityGateway();
      final ctx = await _serve(
        claims: const ProxyJwtClaims(
          userId: 'firebase-admin',
          operatorId: null,
          locationId: null,
          roles: <String>['super_admin'],
        ),
        gateway: gateway,
      );
      addTearDown(ctx.close);

      final response = await _httpGet(
        ctx.uri(
          '/v1/admin/vendor-applicability?setting_kind=wage'
          '&operator_id=$_operatorId&location_id=$_locationId',
        ),
      );

      expect(response.statusCode, 200);
      expect(gateway.listAdminCalls, hasLength(1));
      expect(gateway.listAdminCalls.single.operatorId, _operatorId);
      expect(gateway.listAdminCalls.single.locationId, _locationId);
    });

    test('admin GET rejects location filter without operator filter', () async {
      final gateway = _FakeVendorApplicabilityGateway();
      final ctx = await _serve(
        claims: const ProxyJwtClaims(
          userId: 'firebase-admin',
          operatorId: null,
          locationId: null,
          roles: <String>['super_admin'],
        ),
        gateway: gateway,
      );
      addTearDown(ctx.close);

      final response = await _httpGet(
        ctx.uri(
          '/v1/admin/vendor-applicability?location_id=$_locationId',
        ),
      );

      expect(response.statusCode, 400);
      final decoded = jsonDecode(response.body) as Map<String, Object?>;
      expect(decoded['error'], 'location_requires_operator');
      expect(gateway.listAdminCalls, isEmpty);
    });

    test('operator GET requires setting_kind and tenant scope', () async {
      final gateway = _FakeVendorApplicabilityGateway();
      final ctx = await _serve(
        claims: const ProxyJwtClaims(
          userId: 'operator-user',
          operatorId: _operatorId,
          locationId: _locationId,
          roles: <String>['operator_owner'],
        ),
        gateway: gateway,
      );
      addTearDown(ctx.close);

      final missing = await _httpGet(
        ctx.uri('/v1/operator/vendor-applicability'),
      );
      final found = await _httpGet(
        ctx.uri(
          '/v1/operator/vendor-applicability?setting_kind=wage&setting_key=tip_credit',
        ),
      );

      expect(missing.statusCode, 400);
      expect(found.statusCode, 200);
      expect(gateway.operatorCalls, hasLength(1));
      expect(gateway.operatorCalls.single.scope.operatorId, _operatorId);
      expect(gateway.operatorCalls.single.scope.locationId, _locationId);
      expect(gateway.operatorCalls.single.settingKind, 'wage');
      expect(gateway.operatorCalls.single.settingKey, 'tip_credit');
    });
  });
}

Map<String, Object?> _upsertBody() => const <String, Object?>{
  'setting_kind': 'wage',
  'setting_key': 'tip_credit',
  'vendor_slug': 'toast',
  'enabled': true,
  'metadata': <String, Object?>{'authority_basis': 'job_code'},
  'admin_reason': 'Ticket VA-123 launch wage defaults',
  'reason_note': 'launch',
};

Future<_ServerContext> _serve({
  required ProxyJwtClaims claims,
  required _FakeVendorApplicabilityGateway gateway,
  IntegrationAdminActorResolver? resolver,
  AdminRequestIdempotencyStore? idempotencyStore,
}) async {
  final verifier = _FixedClaimsVerifier(claims);
  final guard = ProxyRequestGuard(verifier: verifier);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    await routeRequest(
      request,
      guard,
      vendorApplicabilityGateway: gateway,
      integrationAdminActorResolver: resolver,
      adminRequestIdempotencyStore: idempotencyStore,
    );
  });
  return _ServerContext(server);
}

Future<_HttpResponseSnapshot> _httpGet(Uri uri) async {
  return _rawHttp(
    method: 'GET',
    uri: uri,
    headers: const <String, String>{'Authorization': 'Bearer test-token'},
  );
}

Future<_HttpResponseSnapshot> _httpJson(
  String method,
  Uri uri, {
  String? idempotencyKey,
  Map<String, Object?>? body,
}) async {
  final encoded = jsonEncode(body ?? const <String, Object?>{});
  return _rawHttp(
    method: method,
    uri: uri,
    headers: <String, String>{
      'Authorization': 'Bearer test-token',
      'Content-Type': 'application/json',
      if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
    },
    body: encoded,
  );
}

Future<_HttpResponseSnapshot> _rawHttp({
  required String method,
  required Uri uri,
  required Map<String, String> headers,
  String? body,
}) async {
  final socket = await Socket.connect(uri.host, uri.port);
  final target = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
  final payload = body == null ? <int>[] : utf8.encode(body);
  final buffer = StringBuffer()
    ..write('$method $target HTTP/1.1\r\n')
    ..write('Host: ${uri.host}:${uri.port}\r\n')
    ..write('Connection: close\r\n');
  for (final entry in headers.entries) {
    buffer.write('${entry.key}: ${entry.value}\r\n');
  }
  if (payload.isNotEmpty) {
    buffer.write('Content-Length: ${payload.length}\r\n');
  }
  buffer.write('\r\n');
  socket.add(utf8.encode(buffer.toString()));
  if (payload.isNotEmpty) socket.add(payload);
  await socket.flush();
  final raw = await utf8.decoder.bind(socket).join();
  return _parseRawHttp(raw);
}

_HttpResponseSnapshot _parseRawHttp(String raw) {
  final headerEnd = raw.indexOf('\r\n\r\n');
  if (headerEnd < 0) {
    return _HttpResponseSnapshot(statusCode: 0, body: raw);
  }
  final headerLines = raw.substring(0, headerEnd).split('\r\n');
  final statusCode = int.parse(headerLines.first.split(' ')[1]);
  var body = raw.substring(headerEnd + 4);
  final isChunked = headerLines.any(
    (line) => line.toLowerCase() == 'transfer-encoding: chunked',
  );
  if (isChunked) {
    body = _decodeChunkedBody(body);
  }
  return _HttpResponseSnapshot(statusCode: statusCode, body: body);
}

String _decodeChunkedBody(String raw) {
  final chunks = StringBuffer();
  var cursor = 0;
  while (cursor < raw.length) {
    final sizeEnd = raw.indexOf('\r\n', cursor);
    if (sizeEnd < 0) break;
    final size = int.parse(raw.substring(cursor, sizeEnd), radix: 16);
    if (size == 0) break;
    final start = sizeEnd + 2;
    chunks.write(raw.substring(start, start + size));
    cursor = start + size + 2;
  }
  return chunks.toString();
}

class _ServerContext {
  const _ServerContext(this.server);

  final HttpServer server;

  Uri uri(String pathAndQuery) {
    return Uri.parse('http://127.0.0.1:${server.port}$pathAndQuery');
  }

  Future<void> close() => server.close(force: true);
}

class _HttpResponseSnapshot {
  const _HttpResponseSnapshot({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

class _FixedClaimsVerifier implements ProxyJwtVerifier {
  const _FixedClaimsVerifier(this.claims);

  final ProxyJwtClaims claims;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async => claims;
}

class _FakeIntegrationAdminActorResolver
    implements IntegrationAdminActorResolver {
  _FakeIntegrationAdminActorResolver(this.actorUserId);

  final String actorUserId;
  final List<String> firebaseUids = <String>[];

  @override
  Future<String?> resolveActorUserId({
    required String firebaseUid,
    required String adminReason,
  }) async {
    firebaseUids.add(firebaseUid);
    return actorUserId;
  }
}

class _FakeVendorApplicabilityGateway
    implements VendorApplicabilityProxyGateway {
  final List<_AdminListCall> listAdminCalls = <_AdminListCall>[];
  final List<_UpsertCall> upsertCalls = <_UpsertCall>[];
  final List<_EndCall> endCalls = <_EndCall>[];
  final List<_OperatorListCall> operatorCalls = <_OperatorListCall>[];

  @override
  Future<List<Map<String, Object?>>> listAdmin({
    required String actorUserId,
    String? operatorId,
    String? locationId,
    String? settingKind,
    String? settingKey,
    String? vendorSlug,
    required bool currentOnly,
    required String adminReason,
  }) async {
    listAdminCalls.add(
      _AdminListCall(
        actorUserId: actorUserId,
        operatorId: operatorId,
        locationId: locationId,
        settingKind: settingKind,
        currentOnly: currentOnly,
      ),
    );
    return <Map<String, Object?>>[_row()];
  }

  @override
  Future<Map<String, Object?>> upsert({
    required String actorUserId,
    String? operatorId,
    String? locationId,
    required String settingKind,
    required String settingKey,
    required String vendorSlug,
    required bool enabled,
    required Map<String, Object?> metadata,
    DateTime? effectiveFrom,
    String? reasonNote,
    required String adminReason,
  }) async {
    upsertCalls.add(
      _UpsertCall(
        actorUserId: actorUserId,
        operatorId: operatorId,
        locationId: locationId,
        settingKind: settingKind,
        metadata: metadata,
        adminReason: adminReason,
      ),
    );
    return _row();
  }

  @override
  Future<Map<String, Object?>?> end({
    required String actorUserId,
    String? operatorId,
    String? locationId,
    required String settingKind,
    required String settingKey,
    required String vendorSlug,
    DateTime? effectiveUntil,
    String? reasonNote,
    required String adminReason,
  }) async {
    endCalls.add(
      _EndCall(
        actorUserId: actorUserId,
        operatorId: operatorId,
        locationId: locationId,
        adminReason: adminReason,
        reasonNote: reasonNote,
      ),
    );
    return _row(effectiveUntil: '2026-05-13T16:00:00.000Z');
  }

  @override
  Future<List<Map<String, Object?>>> listForOperator({
    required OperatorContext scope,
    required String settingKind,
    String? settingKey,
  }) async {
    operatorCalls.add(
      _OperatorListCall(
        scope: scope,
        settingKind: settingKind,
        settingKey: settingKey,
      ),
    );
    return <Map<String, Object?>>[_row()];
  }

  Map<String, Object?> _row({String? effectiveUntil}) => <String, Object?>{
    'id': '44444444-4444-4444-8444-444444444444',
    'operator_id': null,
    'setting_kind': 'wage',
    'setting_key': 'tip_credit',
    'vendor_slug': 'toast',
    'enabled': true,
    'metadata': const <String, Object?>{'authority_basis': 'job_code'},
    'effective_from': '2026-05-13T15:00:00.000Z',
    'effective_until': effectiveUntil,
    'created_at': '2026-05-13T15:00:00.000Z',
    'created_by': _adminPostgresUserId,
  };
}

class _AdminListCall {
  const _AdminListCall({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.settingKind,
    required this.currentOnly,
  });

  final String actorUserId;
  final String? operatorId;
  final String? locationId;
  final String? settingKind;
  final bool currentOnly;
}

class _UpsertCall {
  const _UpsertCall({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.settingKind,
    required this.metadata,
    required this.adminReason,
  });

  final String actorUserId;
  final String? operatorId;
  final String? locationId;
  final String settingKind;
  final Map<String, Object?> metadata;
  final String adminReason;
}

class _EndCall {
  const _EndCall({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.adminReason,
    required this.reasonNote,
  });

  final String actorUserId;
  final String? operatorId;
  final String? locationId;
  final String adminReason;
  final String? reasonNote;
}

class _OperatorListCall {
  const _OperatorListCall({
    required this.scope,
    required this.settingKind,
    required this.settingKey,
  });

  final OperatorContext scope;
  final String settingKind;
  final String? settingKey;
}

class _MemoryAdminIdempotencyStore implements AdminRequestIdempotencyStore {
  final Map<String, _MemoryEntry> entries = <String, _MemoryEntry>{};
  final List<String> completedKeys = <String>[];

  @override
  Future<AdminRequestIdempotencyEntry?> lookup({
    required String idempotencyKey,
    required String requestType,
    required String requestBodyHash,
  }) async {
    final entry = entries[idempotencyKey];
    if (entry == null) return null;
    if (entry.requestType != requestType ||
        entry.requestBodyHash != requestBodyHash) {
      throw const AdminIdempotencyKeyConflict(
        message: 'idempotency key reused with a different request',
      );
    }
    return AdminRequestIdempotencyEntry(
      idempotencyKey: idempotencyKey,
      requestType: requestType,
      responseStatus: entry.responseStatus,
      responsePayload: entry.responsePayload,
      completedAt: entry.completedAt,
    );
  }

  @override
  Future<bool> reserve({
    required String idempotencyKey,
    required String requestType,
    required String? actorUserId,
    required String requestBodyHash,
  }) async {
    if (entries.containsKey(idempotencyKey)) return false;
    entries[idempotencyKey] = _MemoryEntry(
      requestType: requestType,
      requestBodyHash: requestBodyHash,
    );
    return true;
  }

  @override
  Future<void> completeReservation({
    required String idempotencyKey,
    required int responseStatus,
    required Map<String, Object?> responsePayload,
  }) async {
    final entry = entries[idempotencyKey]!;
    entry.responseStatus = responseStatus;
    entry.responsePayload = responsePayload;
    entry.completedAt = DateTime.utc(2026, 5, 13, 16);
    completedKeys.add(idempotencyKey);
  }

  @override
  Future<bool> tryReclaimOrphan({required String idempotencyKey}) async {
    return false;
  }

  @override
  Future<int> sweepExpiredOrphans() async {
    return 0;
  }
}

class _MemoryEntry {
  _MemoryEntry({required this.requestType, required this.requestBodyHash});

  final String requestType;
  final String requestBodyHash;
  int? responseStatus;
  Map<String, Object?>? responsePayload;
  DateTime? completedAt;
}
