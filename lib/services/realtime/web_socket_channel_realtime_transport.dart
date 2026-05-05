// Phase 10a.0 — package:web_socket_channel binding for RealtimeTransport.
//
// One-line wrapper around `WebSocketChannel.connect`. Cross-platform
// (native + web). The Authorization header is set via the underlying
// HTTP request on native targets; on web the browser does not allow
// custom headers, so this transport currently does NOT pass the token
// — fixing the browser path with a `Sec-WebSocket-Protocol`
// subprotocol or a token-as-query-parameter fallback is documented as
// a Phase 10a follow-up.

import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'realtime_transport.dart';

class WebSocketChannelRealtimeTransport implements RealtimeTransport {
  const WebSocketChannelRealtimeTransport();

  /// Query-parameter name for the reconnect-resume cursor. Lives on
  /// the URL because it is non-secret (just an `event_outbox.id`
  /// rendered as a string) and because browsers cannot set custom
  /// WebSocket headers — the bearer subprotocol carrier is already
  /// pulling double duty for auth and we don't want to mix concerns.
  /// The route reads the same parameter via
  /// `request.uri.queryParameters['last_event_id']`.
  static const String lastEventIdQueryParam = 'last_event_id';

  @override
  Future<RealtimeChannel> connect(
    Uri uri, {
    String? authToken,
    String? lastEventId,
  }) async {
    final connectUri = lastEventId == null
        ? uri
        : uri.replace(
            queryParameters: <String, String>{
              ...uri.queryParameters,
              lastEventIdQueryParam: lastEventId,
            },
          );
    final channel = WebSocketChannel.connect(
      connectUri,
      protocols: authToken == null ? null : <String>['bearer.$authToken'],
    );
    await channel.ready;
    return _Channel(channel);
  }
}

class _Channel implements RealtimeChannel {
  _Channel(this._channel)
    : incoming = _channel.stream
          .map((dynamic frame) => frame is String ? frame : frame.toString())
          .asBroadcastStream();

  final WebSocketChannel _channel;

  @override
  final Stream<String> incoming;

  @override
  Future<void> close() async {
    await _channel.sink.close();
  }
}
