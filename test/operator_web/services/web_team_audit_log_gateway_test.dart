// Theme B#5 N3 - Live operator-web audit log CSV export wire test.
//
// Pins the new server-side streaming CSV export path the
// `WebTeamAuditLogGatewayLive.exportCsv` impl now hits, plus the
// filter shape (time window + action bucket + actor + target) it
// flattens onto the URL. Uses `MockClient` from `package:http` so the
// test runs in pure Dart (no real network).

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:forge_and_flow/operator_web/services/web_team_audit_log_gateway.dart';

void main() {
  final Uri kProxyBase = Uri.parse('https://proxy.forgeflow.test');

  Future<String?> tokenProvider() async => 'test-id-token';

  group('WebTeamAuditLogGatewayLive.exportCsv (server-side streaming)', () {
    test(
      'GETs /v1/auth/audit-log/export.csv with the bearer token + idempotency '
      'header + RFC 4180 column order survives end-to-end',
      () async {
        late http.Request captured;
        final client = MockClient((request) async {
          captured = request;
          return http.Response(
            'created_at,action,actor_user_id,actor_display_name,actor_email,'
            'actor_kind,target_kind,target_id,admin_reason,payload\r\n'
            '2026-04-28T12:05:00.000Z,auth.user.signed_in,'
            '11111111-1111-4111-8111-111111111111,Team member,,'
            'team_member,,99999999-9999-4999-8999-999999999999,,\r\n',
            200,
            headers: <String, String>{
              'content-type': 'text/csv; charset=utf-8',
              'content-disposition':
                  'attachment; filename="forge_flow_audit_log_'
                  '20260428_1205_utc.csv"',
            },
          );
        });
        final gateway = WebTeamAuditLogGatewayLive(
          proxyBaseUri: kProxyBase,
          idTokenProvider: tokenProvider,
          httpClient: client,
        );

        final result = await gateway.exportCsv(
          const WebAuditLogQuery(
            timeWindow: WebAuditLogTimeWindow.custom,
            customFrom: null,
            customTo: null,
            limit: 200,
          ),
          idempotencyKey: 'audit-log-export-key-1',
        );

        // Path + method.
        expect(captured.method, equals('GET'));
        expect(captured.url.scheme, equals('https'));
        expect(captured.url.path, equals(WebTeamAuditLogPaths.exportCsv));
        expect(captured.url.path, equals('/v1/auth/audit-log/export.csv'));

        // Bearer + idempotency-key forwarded.
        expect(
          captured.headers['authorization'],
          equals('Bearer test-id-token'),
        );
        expect(
          captured.headers['Idempotency-Key'],
          equals('audit-log-export-key-1'),
        );

        // Streamed body returned verbatim + filename pulled out of
        // the proxy's Content-Disposition header.
        expect(result.csv, contains('auth.user.signed_in'));
        expect(result.csv.split('\r\n').first, startsWith('created_at,'));
        expect(
          result.filename,
          equals('forge_flow_audit_log_20260428_1205_utc.csv'),
        );
      },
    );

    test(
      'forwards the time window onto the proxy as ?from=&to= ISO-8601 UTC',
      () async {
        late http.Request captured;
        final client = MockClient((request) async {
          captured = request;
          return http.Response(
            'created_at,action,actor_user_id,actor_display_name,actor_email,'
            'actor_kind,target_kind,target_id,admin_reason,payload\r\n',
            200,
            headers: <String, String>{
              'content-type': 'text/csv; charset=utf-8',
              'content-disposition':
                  'attachment; filename="forge_flow_audit_log_test.csv"',
            },
          );
        });
        final gateway = WebTeamAuditLogGatewayLive(
          proxyBaseUri: kProxyBase,
          idTokenProvider: tokenProvider,
          httpClient: client,
        );

        await gateway.exportCsv(
          WebAuditLogQuery(
            timeWindow: WebAuditLogTimeWindow.custom,
            customFrom: DateTime.utc(2026, 4, 1),
            customTo: DateTime.utc(2026, 4, 30, 23, 59, 59),
            limit: 200,
          ),
          idempotencyKey: 'audit-log-export-key-2',
        );

        expect(
          captured.url.queryParameters['from'],
          equals('2026-04-01T00:00:00.000Z'),
        );
        expect(
          captured.url.queryParameters['to'],
          equals('2026-04-30T23:59:59.000Z'),
        );
      },
    );

    test(
      'flattens action/actor/target filters onto the export query string',
      () async {
        late http.Request captured;
        final client = MockClient((request) async {
          captured = request;
          return http.Response(
            'created_at,action,actor_user_id,actor_display_name,actor_email,'
            'actor_kind,target_kind,target_id,admin_reason,payload\r\n',
            200,
            headers: <String, String>{
              'content-type': 'text/csv',
              'content-disposition': 'attachment; filename="export.csv"',
            },
          );
        });
        final gateway = WebTeamAuditLogGatewayLive(
          proxyBaseUri: kProxyBase,
          idTokenProvider: tokenProvider,
          httpClient: client,
        );

        await gateway.exportCsv(
          const WebAuditLogQuery(
            actions: <String>['auth.user.password_changed'],
            actorUserIds: <String>['actor-1', 'actor-2'],
            targetKind: 'team_user',
            targetId: 'target-uuid',
            timeWindow: WebAuditLogTimeWindow.last7d,
            limit: 200,
          ),
          idempotencyKey: 'audit-log-export-key-3',
        );

        expect(
          captured.url.queryParameters['event_kind'],
          equals('password'),
        );
        expect(
          captured.url.queryParameters['action'],
          equals('auth.user.password_changed'),
        );
        expect(
          captured.url.queryParameters['actor_user_id'],
          equals('actor-1,actor-2'),
        );
        expect(
          captured.url.queryParameters['target_kind'],
          equals('team_user'),
        );
        expect(
          captured.url.queryParameters['target_id'],
          equals('target-uuid'),
        );
      },
    );

    test('surfaces a non-2xx export response as a WebTeamAuditLogError',
        () async {
      final client = MockClient((request) async {
        return http.Response(
          '{"error":"permission_denied",'
          '"message":"team.audit_log.export permission is required"}',
          403,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = WebTeamAuditLogGatewayLive(
        proxyBaseUri: kProxyBase,
        idTokenProvider: tokenProvider,
        httpClient: client,
      );

      try {
        await gateway.exportCsv(
          const WebAuditLogQuery(
            timeWindow: WebAuditLogTimeWindow.last24h,
            limit: 200,
          ),
          idempotencyKey: 'audit-log-export-key-4',
        );
        fail('expected WebTeamAuditLogError');
      } on WebTeamAuditLogError catch (error) {
        expect(error.statusCode, equals(403));
        expect(error.code, equals('permission_denied'));
      }
    });
  });
}
