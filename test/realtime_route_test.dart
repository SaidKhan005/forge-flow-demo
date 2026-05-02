// Phase 10a.0 — `/v1/realtime` route auth tests.
//
// Pinned behavior:
//   * Authorization: Bearer <token> path → 101 upgrade, frames flow
//   * Sec-WebSocket-Protocol: bearer.<token> path → 101 upgrade, the
//     server echoes the chosen subprotocol back per RFC 6455, frames flow
//   * No bearer (neither carrier present) → 401
//   * Wrong subprotocol prefix → 401
//   * Verifier rejection → 401
//
// Spins up a real loopback HttpServer that calls `handleRealtimeUpgrade`
// per request; connects via package:web_socket_channel using both
// carriers. No external network.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/realtime/realtime_event.dart';
import 'package:forge_and_flow/services/realtime/realtime_event_publisher.dart';
import 'package:web_socket_channel/io.dart';

import '../tool/advisor_proxy/advisor_proxy.dart';
import '../tool/advisor_proxy/realtime_route.dart';

const String _opOk = 'op_ok';

void main() {
  late HttpServer server;
  late InProcessRealtimePublisher publisher;
  late _SettableVerifier verifier;
  late ProxyRequestGuard authGuard;
  late int port;

  setUp(() async {
    publisher = InProcessRealtimePublisher();
    verifier = _SettableVerifier()
      ..claims = const ProxyJwtClaims(
        userId: 'user_ok',
        operatorId: _opOk,
        locationId: 'loc_ok',
        roles: <String>[],
      );
    authGuard = ProxyRequestGuard(verifier: verifier);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    server.listen((HttpRequest request) {
      // Run handler unawaited; the route handler completes only when
      // the client closes the socket, and we want the loop to keep
      // accepting new connections in parallel.
      unawaited(
        handleRealtimeUpgrade(
          request: request,
          authGuard: authGuard,
          publisher: publisher,
        ),
      );
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await publisher.close();
  });

  group('Authorization header carrier', () {
    test('bearer token in Authorization header upgrades + frames flow',
        () async {
      final received = <String>[];
      final completer = Completer<void>();
      final channel = IOWebSocketChannel.connect(
        Uri.parse('ws://127.0.0.1:$port/v1/realtime'),
        headers: <String, dynamic>{HttpHeaders.authorizationHeader: 'Bearer t'},
      );
      await channel.ready;
      final sub = channel.stream.listen(
        (Object? frame) {
          received.add(frame is String ? frame : frame.toString());
          if (received.length == 1 && !completer.isCompleted) {
            completer.complete();
          }
        },
        onError: (Object e) {
          if (!completer.isCompleted) completer.completeError(e);
        },
      );
      // Give the server a tick to register the subscription before
      // we publish into the publisher's per-operator stream.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await publisher.publish(
        RealtimeEvent(
          eventId: 'evt-header',
          topic: 'rollup.invalidate.variance_week',
          operatorId: _opOk,
          occurredAt: DateTime.utc(2026, 5, 2, 12),
          payload: const <String, Object?>{},
        ),
      );
      await completer.future.timeout(const Duration(seconds: 2));
      expect(received, hasLength(1));
      final decoded = jsonDecode(received.single) as Map<String, Object?>;
      expect(decoded['event_id'], 'evt-header');
      await sub.cancel();
      await channel.sink.close();
    });
  });

  group('Sec-WebSocket-Protocol bearer carrier (browser fallback)', () {
    test(
      'bearer.<token> subprotocol upgrades, server echoes the subprotocol, '
      'frames flow',
      () async {
        final received = <String>[];
        final completer = Completer<void>();
        final channel = IOWebSocketChannel.connect(
          Uri.parse('ws://127.0.0.1:$port/v1/realtime'),
          protocols: const <String>['bearer.t'],
        );
        await channel.ready;
        // RFC 6455: when the client requested a subprotocol, the
        // server MUST echo the chosen one back, otherwise the upgrade
        // is invalid and most clients close the connection. The
        // server's protocolSelector returns the subprotocol that
        // carried the bearer token.
        expect(channel.protocol, 'bearer.t');
        final sub = channel.stream.listen(
          (Object? frame) {
            received.add(frame is String ? frame : frame.toString());
            if (received.length == 1 && !completer.isCompleted) {
              completer.complete();
            }
          },
          onError: (Object e) {
            if (!completer.isCompleted) completer.completeError(e);
          },
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await publisher.publish(
          RealtimeEvent(
            eventId: 'evt-subprotocol',
            topic: 'rollup.invalidate.variance_week',
            operatorId: _opOk,
            occurredAt: DateTime.utc(2026, 5, 2, 12),
            payload: const <String, Object?>{},
          ),
        );
        await completer.future.timeout(const Duration(seconds: 2));
        expect(received, hasLength(1));
        final decoded = jsonDecode(received.single) as Map<String, Object?>;
        expect(decoded['event_id'], 'evt-subprotocol');
        await sub.cancel();
        await channel.sink.close();
      },
    );
  });

  group('rejection paths', () {
    test('no auth carrier → 401, no upgrade', () async {
      final response = await _httpGet(port, '/v1/realtime', headers: const {
        'connection': 'Upgrade',
        'upgrade': 'websocket',
        'sec-websocket-version': '13',
        'sec-websocket-key': 'dGhlIHNhbXBsZSBub25jZQ==',
      });
      expect(response.statusCode, 401);
      // Body is chunked-encoded over the wire; checking the status
      // code is the contract here. The error envelope shape is
      // verified in the verifier-rejects test below via an exact
      // substring match on the dechunked body.
    });

    test('subprotocol with wrong prefix → 401', () async {
      final response = await _httpGet(port, '/v1/realtime', headers: const {
        'connection': 'Upgrade',
        'upgrade': 'websocket',
        'sec-websocket-version': '13',
        'sec-websocket-key': 'dGhlIHNhbXBsZSBub25jZQ==',
        'sec-websocket-protocol': 'graphql-ws, mqtt',
      });
      expect(response.statusCode, 401);
    });

    test('verifier rejects → 401 with verification-failed body', () async {
      verifier
        ..claims = null
        ..errorMessage = 'invalid signature';
      final response = await _httpGet(port, '/v1/realtime', headers: const {
        'connection': 'Upgrade',
        'upgrade': 'websocket',
        'sec-websocket-version': '13',
        'sec-websocket-key': 'dGhlIHNhbXBsZSBub25jZQ==',
        'authorization': 'Bearer bad-token',
      });
      expect(response.statusCode, 401);
      // dart:io HttpServer chunk-encodes responses by default; the
      // raw body contains transfer-encoding markers. A substring
      // match is safer than a full JSON parse.
      expect(response.body, contains('token verification failed'));
      expect(response.body, contains('invalid signature'));
    });
  });
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

class _HttpResponseSnapshot {
  const _HttpResponseSnapshot({required this.statusCode, required this.body});
  final int statusCode;
  final String body;
}

/// Send a raw HTTP/1.1 GET over a TCP socket. Used for the rejection
/// paths where we want to assert the 401 envelope WITHOUT going
/// through `HttpClient` (the flutter_test binding installs an
/// `HttpOverrides` that intercepts every `HttpClient` and always
/// returns 400, which would shadow the route's real response). The
/// `package:web_socket_channel` client also can't surface a 401
/// because it expects a 101 upgrade.
Future<_HttpResponseSnapshot> _httpGet(
  int port,
  String path, {
  Map<String, String> headers = const <String, String>{},
}) async {
  final socket = await Socket.connect('127.0.0.1', port);
  try {
    final buffer = StringBuffer()
      ..write('GET $path HTTP/1.1\r\n')
      ..write('Host: 127.0.0.1:$port\r\n');
    headers.forEach((key, value) {
      buffer.write('$key: $value\r\n');
    });
    buffer.write('\r\n');
    socket.add(utf8.encode(buffer.toString()));
    await socket.flush();
    final responseBytes = <int>[];
    await for (final chunk in socket) {
      responseBytes.addAll(chunk);
    }
    final raw = utf8.decode(responseBytes);
    final headerEnd = raw.indexOf('\r\n\r\n');
    final statusLine = raw.split('\r\n').first;
    final parts = statusLine.split(' ');
    final statusCode = int.parse(parts[1]);
    final body = headerEnd < 0 ? '' : raw.substring(headerEnd + 4);
    return _HttpResponseSnapshot(statusCode: statusCode, body: body);
  } finally {
    await socket.close();
  }
}
