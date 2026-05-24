// Admin audit-integrity badge — admin/cross-tenant audit-chain-anchor
// client gateway tests.
//
// Locks the client contract for [HttpAdminAuditChainAnchorsGateway]:
//   * the request hits the ADMIN path
//     `/v1/admin/operators/<operatorId>/audit-chain-anchors/latest`
//     (NEVER the operator path `/v1/operator/...`), with the
//     URL-encoded operatorId;
//   * the signed-in admin's bearer token is attached;
//   * a 200 `{operator_id, anchor: {...}}` body parses into a snapshot
//     carrying the server-classified status + timestamps;
//   * a 200 `{anchor: null}` body parses into the neutral unknown
//     snapshot;
//   * a non-2xx surfaces an [AdminAuditChainAnchorsGatewayError] with
//     the proxy error code.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:forge_and_flow/admin/services/admin_audit_chain_anchors_gateway.dart';

const String _kOp = '22222222-2222-4222-8222-222222222222';

void main() {
  group('HttpAdminAuditChainAnchorsGateway', () {
    test('GETs the ADMIN path with the bearer; parses a healthy snapshot',
        () async {
      final client = _ScriptedClient(<_ScriptedReply>[
        _ScriptedReply(
          statusCode: 200,
          body: jsonEncode(<String, Object?>{
            'operator_id': _kOp,
            'anchor': <String, Object?>{
              'chain_date': '2026-05-07',
              'anchored_at': '2026-05-07T02:00:14Z',
              'row_count': 1234,
              'blob_uri': 'https://example.blob/$_kOp/2026-05-07.json',
              'last_anchor_blob_url':
                  'https://example.blob/$_kOp/2026-05-07.json',
              'last_anchor_blob_at': '2026-05-07T02:00:12Z',
              'status': 'healthy',
            },
          }),
        ),
      ]);
      final gateway = HttpAdminAuditChainAnchorsGateway(
        baseUri: Uri.parse('https://admin-proxy.forgeflow.app'),
        bearerTokenProvider: () async => 'admin-token-xyz',
        httpClient: client,
      );

      final snapshot = await gateway.latest(operatorId: _kOp);

      // URL is the ADMIN cross-tenant path, never the operator path.
      final sent = client.sent.single;
      expect(sent.method, 'GET');
      expect(
        sent.url.path,
        '/v1/admin/operators/$_kOp/audit-chain-anchors/latest',
      );
      expect(sent.url.path, isNot(contains('/v1/operator/')));
      // Bearer attached.
      expect(sent.headers['authorization'], 'Bearer admin-token-xyz');

      // Snapshot carries the SERVER-classified status + timestamps.
      // The full ISO timestamps carry an explicit `Z`, so they parse to
      // an exact UTC instant regardless of the host timezone.
      expect(snapshot.status, AdminAuditChainAnchorStatus.healthy);
      expect(snapshot.isHealthy, isTrue);
      expect(snapshot.anchoredAt, DateTime.utc(2026, 5, 7, 2, 0, 14));
      expect(snapshot.lastAnchorBlobAt, DateTime.utc(2026, 5, 7, 2, 0, 12));
      // `chain_date` is a date-only wire value; it is parsed as a local
      // date then normalized to UTC (same as the operator-web gateway),
      // so assert it is carried (non-null) rather than an exact instant.
      expect(snapshot.chainDate, isNotNull);
    });

    test('URL-encodes the operatorId segment', () async {
      final client = _ScriptedClient(<_ScriptedReply>[
        _ScriptedReply(
          statusCode: 200,
          body: jsonEncode(<String, Object?>{'anchor': null}),
        ),
      ]);
      final gateway = HttpAdminAuditChainAnchorsGateway(
        baseUri: Uri.parse('https://admin-proxy.forgeflow.app'),
        bearerTokenProvider: () async => 't',
        httpClient: client,
      );

      await gateway.latest(operatorId: 'op with space');

      expect(
        client.sent.single.url.path,
        '/v1/admin/operators/op%20with%20space/audit-chain-anchors/latest',
      );
    });

    test('200 with anchor:null parses into the neutral unknown snapshot',
        () async {
      final client = _ScriptedClient(<_ScriptedReply>[
        _ScriptedReply(
          statusCode: 200,
          body: jsonEncode(<String, Object?>{
            'operator_id': _kOp,
            'anchor': null,
          }),
        ),
      ]);
      final gateway = HttpAdminAuditChainAnchorsGateway(
        baseUri: Uri.parse('https://admin-proxy.forgeflow.app'),
        bearerTokenProvider: () async => 't',
        httpClient: client,
      );

      final snapshot = await gateway.latest(operatorId: _kOp);
      expect(snapshot.status, AdminAuditChainAnchorStatus.unknown);
      expect(snapshot.isUnknown, isTrue);
      expect(snapshot.anchoredAt, isNull);
    });

    test('non-2xx surfaces an AdminAuditChainAnchorsGatewayError', () async {
      final client = _ScriptedClient(<_ScriptedReply>[
        _ScriptedReply(
          statusCode: 403,
          body: jsonEncode(<String, Object?>{
            'error': 'permission_denied',
            'message': 'admin role required',
          }),
        ),
      ]);
      final gateway = HttpAdminAuditChainAnchorsGateway(
        baseUri: Uri.parse('https://admin-proxy.forgeflow.app'),
        bearerTokenProvider: () async => 't',
        httpClient: client,
      );

      await expectLater(
        gateway.latest(operatorId: _kOp),
        throwsA(
          isA<AdminAuditChainAnchorsGatewayError>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.errorCode, 'errorCode', 'permission_denied'),
        ),
      );
    });
  });

  group('InMemoryAdminAuditChainAnchorsGateway', () {
    test('returns a healthy snapshot for the demo walkthrough', () async {
      final gateway = InMemoryAdminAuditChainAnchorsGateway(
        clock: () => DateTime.utc(2026, 5, 7, 6),
      );
      final snapshot = await gateway.latest(operatorId: _kOp);
      expect(snapshot.status, AdminAuditChainAnchorStatus.healthy);
      expect(snapshot.anchoredAt, isNotNull);
    });

    test('honors a fixed snapshot for the badge state matrix', () async {
      final gateway = InMemoryAdminAuditChainAnchorsGateway(
        snapshot: const AdminAuditChainAnchorSnapshot(
          status: AdminAuditChainAnchorStatus.failed,
        ),
      );
      final snapshot = await gateway.latest(operatorId: _kOp);
      expect(snapshot.isFailed, isTrue);
    });
  });
}

class _ScriptedReply {
  const _ScriptedReply({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

class _SentSnapshot {
  const _SentSnapshot({
    required this.method,
    required this.url,
    required this.headers,
  });

  final String method;
  final Uri url;
  final Map<String, String> headers;
}

class _ScriptedClient extends http.BaseClient {
  _ScriptedClient(this._replies);

  final List<_ScriptedReply> _replies;
  final List<_SentSnapshot> sent = <_SentSnapshot>[];
  int _index = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final req = request as http.Request;
    sent.add(
      _SentSnapshot(
        method: req.method,
        url: req.url,
        headers: Map<String, String>.from(req.headers),
      ),
    );
    final reply = _replies[_index++];
    final bytes = utf8.encode(reply.body);
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      reply.statusCode,
      contentLength: bytes.length,
      request: req,
    );
  }
}
