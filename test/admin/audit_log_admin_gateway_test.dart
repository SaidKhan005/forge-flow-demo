// Lane B B8 — AuditLogAdminGateway tests.
//
// Covers the InMemory gateway shape + the HTTP gateway request/
// response codec (URL construction, header binding, JSON parse,
// error envelope mapping). The HTTP path uses a fake `http.Client`
// (via `package:http/testing`) so the test does not bind a socket.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:forge_and_flow/admin/services/audit_log_admin_gateway.dart';

void main() {
  group('auditLogAdminScope wire codec', () {
    test('round-trips every scope value', () {
      for (final scope in AuditLogAdminScopeType.values) {
        final wire = auditLogAdminScopeWire(scope);
        expect(auditLogAdminScopeFromWire(wire), scope);
      }
    });

    test('rejects unknown wire tokens', () {
      expect(auditLogAdminScopeFromWire(null), isNull);
      expect(auditLogAdminScopeFromWire('invalid'), isNull);
    });
  });

  group('AuditLogAdminRow.fromJson', () {
    test('parses the canonical wire shape', () {
      final row = AuditLogAdminRow.fromJson(<String, Object?>{
        'id': '42',
        'operator_id': 'op-1',
        'location_id': 'loc-1',
        'occurred_at': '2026-05-13T12:00:00Z',
        'actor_kind': 'user',
        'actor_user_id': 'user-1',
        'action': 'auth.password_changed',
        'payload': <String, Object?>{'demo': true},
      });
      expect(row.id, '42');
      expect(row.action, 'auth.password_changed');
      expect(row.payload['demo'], true);
    });

    test('tolerates missing optional fields', () {
      final row = AuditLogAdminRow.fromJson(<String, Object?>{
        'id': '1',
        'operator_id': 'op-1',
        'occurred_at': '2026-05-13T12:00:00Z',
        'actor_kind': 'user',
        'action': 'x',
      });
      expect(row.locationId, isNull);
      expect(row.actorUserId, isNull);
      expect(row.payload, isEmpty);
    });
  });

  group('InMemoryAuditLogAdminGateway', () {
    test('returns the seeded rows for operator_wide scope', () async {
      final gateway = InMemoryAuditLogAdminGateway(
        rows: <AuditLogAdminRow>[
          _row(id: '1'),
          _row(id: '2'),
        ],
      );
      final result = await gateway.listByHierarchy(
        const AuditLogAdminListCommand(
          adminReason: 'tk-1',
          scopeType: AuditLogAdminScopeType.operatorWide,
        ),
      );
      expect(result.rows, hasLength(2));
      expect(gateway.calls, hasLength(1));
    });

    test('location scope filter narrows to a single location', () async {
      final gateway = InMemoryAuditLogAdminGateway(
        rows: <AuditLogAdminRow>[
          _row(id: '1', locationId: 'loc-a'),
          _row(id: '2', locationId: 'loc-b'),
        ],
      );
      final result = await gateway.listByHierarchy(
        const AuditLogAdminListCommand(
          adminReason: 'tk-1',
          scopeType: AuditLogAdminScopeType.location,
          locationFilter: 'loc-a',
        ),
      );
      expect(result.rows.map((r) => r.id).toList(), <String>['1']);
    });

    test('action filter narrows', () async {
      final gateway = InMemoryAuditLogAdminGateway(
        rows: <AuditLogAdminRow>[
          _row(id: '1', action: 'auth.password_changed'),
          _row(id: '2', action: 'auth.mfa_enrolled'),
        ],
      );
      final result = await gateway.listByHierarchy(
        const AuditLogAdminListCommand(
          adminReason: 'tk-1',
          scopeType: AuditLogAdminScopeType.operatorWide,
          action: 'auth.password_changed',
        ),
      );
      expect(result.rows.map((r) => r.id).toList(), <String>['1']);
    });

    test('time range filter excludes rows outside the window', () async {
      final gateway = InMemoryAuditLogAdminGateway(
        rows: <AuditLogAdminRow>[
          _row(id: '1', occurredAt: DateTime.utc(2026, 5, 10)),
          _row(id: '2', occurredAt: DateTime.utc(2026, 5, 13)),
        ],
      );
      final result = await gateway.listByHierarchy(
        AuditLogAdminListCommand(
          adminReason: 'tk-1',
          scopeType: AuditLogAdminScopeType.operatorWide,
          from: DateTime.utc(2026, 5, 11),
          to: DateTime.utc(2026, 5, 14),
        ),
      );
      expect(result.rows.map((r) => r.id).toList(), <String>['2']);
    });

    test('throws the seeded gateway error when failWith is set', () async {
      final gateway = InMemoryAuditLogAdminGateway(
        failWith:
            const AuditLogAdminGatewayError('forced', statusCode: 500),
      );
      expect(
        () => gateway.listByHierarchy(
          const AuditLogAdminListCommand(
            adminReason: 'tk-1',
            scopeType: AuditLogAdminScopeType.operatorWide,
          ),
        ),
        throwsA(isA<AuditLogAdminGatewayError>()),
      );
    });
  });

  group('HttpAuditLogAdminGateway', () {
    test('builds the URL with the seven filter query params and binds '
        'the admin_reason header', () async {
      Uri? capturedUri;
      Map<String, String>? capturedHeaders;
      final client = MockClient((request) async {
        capturedUri = request.url;
        capturedHeaders = request.headers;
        return http.Response(
          jsonEncode(<String, Object?>{
            'rows': <Map<String, Object?>>[],
            'next_cursor': null,
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpAuditLogAdminGateway(
        proxyBaseUri: Uri.parse('https://proxy.example.com'),
        tokenProvider: () async => 'token-abc',
        httpClient: client,
      );
      await gateway.listByHierarchy(
        AuditLogAdminListCommand(
          adminReason: 'support-ticket-99',
          scopeType: AuditLogAdminScopeType.orgUnit,
          orgUnitId: '11111111-1111-1111-1111-111111111111',
          actorUserId: '22222222-2222-2222-2222-222222222222',
          action: 'auth.password_changed',
          limit: 50,
          from: DateTime.utc(2026, 5, 1),
          to: DateTime.utc(2026, 5, 13),
        ),
      );
      expect(capturedUri, isNotNull);
      expect(capturedUri!.path, '/v1/admin/auth/audit-log/hierarchy');
      expect(capturedUri!.queryParameters['scope_type'], 'org_unit');
      expect(capturedUri!.queryParameters['org_unit_id'],
          '11111111-1111-1111-1111-111111111111');
      expect(capturedUri!.queryParameters['actor_user_id'],
          '22222222-2222-2222-2222-222222222222');
      expect(capturedUri!.queryParameters['action'],
          'auth.password_changed');
      expect(capturedUri!.queryParameters['limit'], '50');
      expect(capturedHeaders!['authorization'], 'Bearer token-abc');
      expect(capturedHeaders!['admin_reason'], 'support-ticket-99');
    });

    test('200 happy path parses rows + next_cursor', () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'rows': <Map<String, Object?>>[
              <String, Object?>{
                'id': '42',
                'operator_id': 'op-1',
                'occurred_at': '2026-05-13T12:00:00Z',
                'actor_kind': 'user',
                'action': 'auth.password_changed',
              },
            ],
            'next_cursor': '41',
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpAuditLogAdminGateway(
        proxyBaseUri: Uri.parse('https://proxy.example.com'),
        tokenProvider: () async => 'token-abc',
        httpClient: client,
      );
      final result = await gateway.listByHierarchy(
        const AuditLogAdminListCommand(
          adminReason: 'tk-1',
          scopeType: AuditLogAdminScopeType.operatorWide,
        ),
      );
      expect(result.rows, hasLength(1));
      expect(result.rows.first.id, '42');
      expect(result.nextCursor, '41');
    });

    test('non-200 response throws AuditLogAdminGatewayError with the '
        'proxy error message', () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'error': 'missing_admin_reason',
            'message': 'admin_reason header is required',
          }),
          400,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpAuditLogAdminGateway(
        proxyBaseUri: Uri.parse('https://proxy.example.com'),
        tokenProvider: () async => 'token-abc',
        httpClient: client,
      );
      try {
        await gateway.listByHierarchy(
          const AuditLogAdminListCommand(
            adminReason: '',
            scopeType: AuditLogAdminScopeType.operatorWide,
          ),
        );
        fail('expected throw');
      } on AuditLogAdminGatewayError catch (error) {
        expect(error.statusCode, 400);
        expect(error.message, contains('admin_reason header'));
      }
    });

    test('non-200 with no parseable JSON falls back to status-code-only '
        'envelope', () async {
      final client = MockClient((request) async {
        return http.Response('not json', 503);
      });
      final gateway = HttpAuditLogAdminGateway(
        proxyBaseUri: Uri.parse('https://proxy.example.com'),
        tokenProvider: () async => 'token-abc',
        httpClient: client,
      );
      try {
        await gateway.listByHierarchy(
          const AuditLogAdminListCommand(
            adminReason: 'tk-1',
            scopeType: AuditLogAdminScopeType.operatorWide,
          ),
        );
        fail('expected throw');
      } on AuditLogAdminGatewayError catch (error) {
        expect(error.statusCode, 503);
        expect(error.message, contains('HTTP 503'));
      }
    });
  });
}

AuditLogAdminRow _row({
  required String id,
  String? locationId,
  String action = 'auth.password_changed',
  DateTime? occurredAt,
}) {
  return AuditLogAdminRow(
    id: id,
    operatorId: 'op-1',
    locationId: locationId,
    occurredAt: occurredAt ?? DateTime.utc(2026, 5, 13, 12),
    actorKind: 'user',
    actorUserId: 'user-1',
    action: action,
  );
}
