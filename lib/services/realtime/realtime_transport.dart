// Phase 10a.0 — RealtimeTransport seam.
//
// Abstracts the WebSocket layer so [RealtimeSubscription] can be unit-
// tested without opening a real socket. The production binding uses
// `package:web_socket_channel` for cross-platform support (native +
// web targets behind a single API).
//
// The subscription does its own back-off / reconnect / dispose
// orchestration; this seam only owns "open a channel, expose its
// inbound text frames, close it on demand".

import 'dart:async';

abstract class RealtimeTransport {
  /// Open a channel to [uri]. The optional [authToken] is the bearer
  /// token forwarded as `Authorization: Bearer <token>` (native
  /// platforms only — browsers cannot set custom WebSocket headers,
  /// so the production transport falls back to a `Sec-WebSocket-Protocol`
  /// subprotocol carrying the token; that fallback is a Phase 10a
  /// follow-up so the scaffold uses native HTTP-header auth).
  ///
  /// Throws on connection failure so [RealtimeSubscription] can
  /// schedule a back-off.
  Future<RealtimeChannel> connect(Uri uri, {String? authToken});
}

abstract class RealtimeChannel {
  /// Inbound text frames as the server sent them. The subscription
  /// parses each frame as a [RealtimeEvent].
  Stream<String> get incoming;

  /// Close the underlying connection. After [close], [incoming] is
  /// done and the channel cannot be reused — the subscription opens a
  /// fresh channel via the transport's [connect] for reconnect.
  Future<void> close();
}
