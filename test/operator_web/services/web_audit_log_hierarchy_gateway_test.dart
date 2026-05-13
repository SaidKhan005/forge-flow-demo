// Lane B B8.b — Operator Web hierarchy audit log gateway wire test.
//
// Pins the HTTP shape of `HttpWebAuditLogHierarchyGateway.listByHierarchy`:
//
//   * Path             /v1/auth/audit-log/hierarchy
//   * Method           GET
//   * Bearer header    Authorization: Bearer <token>
//   * NO admin_reason  (operator-web posture vs the admin route)
//   * NO operator_id / location_id query params (proxy clamps to JWT)
//   * Filter params    scope_type / org_unit_id / location_filter /
//                       from / to / actor_user_id / action / limit /
//                       before_id flattened onto the URL
//   * Happy path       200 with `{rows, next_cursor}` decodes into
//                       `WebAuditLogHierarchyListResult`
//   * Sad path         non-2xx raises `WebAuditLogHierarchyGatewayError`
//                       with the proxy's `message`/`error` text

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:forge_and_flow/operator_web/services/web_audit_log_hierarchy_gateway.dart';

void main() {
  final Uri proxyBase = Uri.parse('https://proxy.forgeflow.test');

  Future<String> tokenProvider() async => 'test-id-token';

  group('HttpWebAuditLogHierarchyGateway.listByHierarchy', () {
    test('GET /v1/auth/audit-log/hierarchy with bearer + no admin_reason',
        () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, Object?>{
            'rows': <Map<String, Object?>>[],
            'next_cursor': null,
            'scope': <String, Object?>{
              'operator_id': 'op-1',
              'location_id': 'loc-1',
              'scope_type': 'operator_wide',
              'org_unit_id': null,
              'location_filter': null,
              'from': '2026-05-06T00:00:00.000Z',
              'to': '2026-05-13T00:00:00.000Z',
            },
          }),
          200,
          headers: <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      });
      final gateway = HttpWebAuditLogHierarchyGateway(
        proxyBaseUri: proxyBase,
        tokenProvider: tokenProvider,
        httpClient: client,
      );

      await gateway.listByHierarchy(
        const WebAuditLogHierarchyListCommand(
          scopeType: WebAuditLogHierarchyScopeType.operatorWide,
        ),
      );

      expect(captured.method, 'GET');
      expect(captured.url.path,
          HttpWebAuditLogHierarchyGateway.wirePath);
      expect(captured.url.path, '/v1/auth/audit-log/hierarchy');
      expect(captured.url.queryParameters['scope_type'], 'operator_wide');
      // Operator-web posture: no admin_reason header on the wire.
      expect(captured.headers.containsKey('admin_reason'), isFalse);
      // Proxy clamps tenant from JWT: gateway must not send these.
      expect(
        captured.url.queryParameters.containsKey('operator_id'),
        isFalse,
      );
      expect(
        captured.url.queryParameters.containsKey('location_id'),
        isFalse,
      );
      expect(captured.headers['authorization'], 'Bearer test-id-token');
    });

    test('flattens scope_type=org_unit + org_unit_id onto the URL',
        () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, Object?>{'rows': const <Object?>[]}),
          200,
        );
      });
      final gateway = HttpWebAuditLogHierarchyGateway(
        proxyBaseUri: proxyBase,
        tokenProvider: tokenProvider,
        httpClient: client,
      );

      await gateway.listByHierarchy(
        const WebAuditLogHierarchyListCommand(
          scopeType: WebAuditLogHierarchyScopeType.orgUnit,
          orgUnitId: '11111111-1111-1111-1111-111111111111',
        ),
      );

      expect(captured.url.queryParameters['scope_type'], 'org_unit');
      expect(captured.url.queryParameters['org_unit_id'],
          '11111111-1111-1111-1111-111111111111');
    });

    test('flattens scope_type=location + location_filter onto the URL',
        () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, Object?>{'rows': const <Object?>[]}),
          200,
        );
      });
      final gateway = HttpWebAuditLogHierarchyGateway(
        proxyBaseUri: proxyBase,
        tokenProvider: tokenProvider,
        httpClient: client,
      );

      await gateway.listByHierarchy(
        const WebAuditLogHierarchyListCommand(
          scopeType: WebAuditLogHierarchyScopeType.location,
          locationFilter: '22222222-2222-2222-2222-222222222222',
        ),
      );

      expect(captured.url.queryParameters['scope_type'], 'location');
      expect(captured.url.queryParameters['location_filter'],
          '22222222-2222-2222-2222-222222222222');
    });

    test(
        'forwards from/to/actor_user_id/action/limit/before_id when '
        'supplied', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, Object?>{'rows': const <Object?>[]}),
          200,
        );
      });
      final gateway = HttpWebAuditLogHierarchyGateway(
        proxyBaseUri: proxyBase,
        tokenProvider: tokenProvider,
        httpClient: client,
      );

      await gateway.listByHierarchy(
        WebAuditLogHierarchyListCommand(
          scopeType: WebAuditLogHierarchyScopeType.operatorWide,
          from: DateTime.utc(2026, 5, 1),
          to: DateTime.utc(2026, 5, 13),
          actorUserId: '33333333-3333-3333-3333-333333333333',
          action: 'auth.password_changed',
          limit: 50,
          beforeId: '42',
        ),
      );

      expect(captured.url.queryParameters['from'],
          '2026-05-01T00:00:00.000Z');
      expect(captured.url.queryParameters['to'],
          '2026-05-13T00:00:00.000Z');
      expect(captured.url.queryParameters['actor_user_id'],
          '33333333-3333-3333-3333-333333333333');
      expect(captured.url.queryParameters['action'],
          'auth.password_changed');
      expect(captured.url.queryParameters['limit'], '50');
      expect(captured.url.queryParameters['before_id'], '42');
    });

    test('decodes rows + next_cursor from the proxy envelope', () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'rows': <Map<String, Object?>>[
              <String, Object?>{
                'id': '101',
                'operator_id': 'op-1',
                'location_id': 'loc-a',
                'occurred_at': '2026-05-13T12:00:00.000Z',
                'actor_kind': 'team_member',
                'actor_user_id': 'user-1',
                'action': 'auth.password_changed',
                'payload': <String, Object?>{'demo': true},
              },
            ],
            'next_cursor': '100',
          }),
          200,
          headers: <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      });
      final gateway = HttpWebAuditLogHierarchyGateway(
        proxyBaseUri: proxyBase,
        tokenProvider: tokenProvider,
        httpClient: client,
      );

      final result = await gateway.listByHierarchy(
        const WebAuditLogHierarchyListCommand(
          scopeType: WebAuditLogHierarchyScopeType.operatorWide,
        ),
      );

      expect(result.rows, hasLength(1));
      expect(result.rows.first.id, '101');
      expect(result.rows.first.action, 'auth.password_changed');
      expect(result.rows.first.actorUserId, 'user-1');
      expect(result.rows.first.payload['demo'], isTrue);
      expect(result.nextCursor, '100');
    });

    test('raises typed error with proxy message on 403', () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'error': 'permission_denied',
            'message':
                'team.audit_log.view permission is required to read the '
                'audit log',
          }),
          403,
        );
      });
      final gateway = HttpWebAuditLogHierarchyGateway(
        proxyBaseUri: proxyBase,
        tokenProvider: tokenProvider,
        httpClient: client,
      );

      expect(
        () => gateway.listByHierarchy(
          const WebAuditLogHierarchyListCommand(
            scopeType: WebAuditLogHierarchyScopeType.operatorWide,
          ),
        ),
        throwsA(
          isA<WebAuditLogHierarchyGatewayError>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.message, 'message',
                  contains('team.audit_log.view')),
        ),
      );
    });

    test('raises typed error on opaque 503', () async {
      final client = MockClient((request) async {
        return http.Response('upstream down', 503);
      });
      final gateway = HttpWebAuditLogHierarchyGateway(
        proxyBaseUri: proxyBase,
        tokenProvider: tokenProvider,
        httpClient: client,
      );

      expect(
        () => gateway.listByHierarchy(
          const WebAuditLogHierarchyListCommand(
            scopeType: WebAuditLogHierarchyScopeType.operatorWide,
          ),
        ),
        throwsA(isA<WebAuditLogHierarchyGatewayError>()
            .having((e) => e.statusCode, 'statusCode', 503)),
      );
    });
  });

  group('InMemoryWebAuditLogHierarchyGateway', () {
    test('returns deterministic page from seeded rows', () async {
      final gateway = InMemoryWebAuditLogHierarchyGateway(
        rows: <WebAuditLogHierarchyRow>[
          WebAuditLogHierarchyRow(
            id: '1',
            operatorId: 'op-1',
            locationId: 'loc-a',
            occurredAt: DateTime.utc(2026, 5, 13, 12),
            actorKind: 'team_member',
            actorUserId: 'user-1',
            action: 'auth.password_changed',
          ),
          WebAuditLogHierarchyRow(
            id: '2',
            operatorId: 'op-1',
            locationId: 'loc-b',
            occurredAt: DateTime.utc(2026, 5, 13, 12),
            actorKind: 'team_member',
            actorUserId: 'user-2',
            action: 'team.users.invite',
          ),
        ],
      );

      final result = await gateway.listByHierarchy(
        const WebAuditLogHierarchyListCommand(
          scopeType: WebAuditLogHierarchyScopeType.operatorWide,
        ),
      );

      expect(result.rows, hasLength(2));
      expect(gateway.calls, hasLength(1));
    });

    test('filters by location when scopeType=location', () async {
      final gateway = InMemoryWebAuditLogHierarchyGateway(
        rows: <WebAuditLogHierarchyRow>[
          WebAuditLogHierarchyRow(
            id: '1',
            operatorId: 'op-1',
            locationId: 'loc-a',
            occurredAt: DateTime.utc(2026, 5, 13),
            actorKind: 'team_member',
            action: 'auth.user.signed_in',
          ),
          WebAuditLogHierarchyRow(
            id: '2',
            operatorId: 'op-1',
            locationId: 'loc-b',
            occurredAt: DateTime.utc(2026, 5, 13),
            actorKind: 'team_member',
            action: 'auth.user.signed_in',
          ),
        ],
      );

      final result = await gateway.listByHierarchy(
        const WebAuditLogHierarchyListCommand(
          scopeType: WebAuditLogHierarchyScopeType.location,
          locationFilter: 'loc-a',
        ),
      );

      expect(result.rows, hasLength(1));
      expect(result.rows.single.locationId, 'loc-a');
    });

    test('raises the configured failure on every call', () async {
      final gateway = InMemoryWebAuditLogHierarchyGateway(
        failWith: const WebAuditLogHierarchyGatewayError('boom'),
      );
      expect(
        () => gateway.listByHierarchy(
          const WebAuditLogHierarchyListCommand(
            scopeType: WebAuditLogHierarchyScopeType.operatorWide,
          ),
        ),
        throwsA(isA<WebAuditLogHierarchyGatewayError>()),
      );
    });
  });
}
