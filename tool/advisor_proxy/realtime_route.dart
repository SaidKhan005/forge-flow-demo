// Phase 10a.0 — `/v1/realtime` WebSocket route.
//
// Authenticates the upgrade with the same JWT verifier as every other
// `/v1/...` route (operator_id and location_id come from the verified
// claims, never from query parameters or the URL — that would be the
// cross-tenant leak surface the contract explicitly forbids).
//
// Auth carrier: `Authorization: Bearer <token>` is preferred (works on
// native HTTP-capable clients). Browsers cannot set custom headers on
// the WebSocket upgrade, so the route ALSO accepts the token packed
// into the standard `Sec-WebSocket-Protocol` handshake header as
// `bearer.<token>`. The chosen subprotocol is echoed back via
// [WebSocketTransformer.upgrade]'s `protocolSelector` so the upgrade
// completes per RFC 6455. The cross-platform client transport in
// `lib/services/realtime/web_socket_channel_realtime_transport.dart`
// uses the subprotocol carrier on every platform, which makes the
// browser path work without a native code split.
//
// On successful upgrade the server subscribes to the publisher's
// per-operator stream and forwards each event as a JSON frame. The
// connection's heartbeat is owned by [WebSocket.pingInterval]:
// dart:io drives pings at that cadence and closes the connection if
// pongs are missed, which means an idle but healthy socket is NOT
// closed by an application-level liveness timer (a separate timer
// would not be reset by client-originated pongs because dart:io
// handles pongs internally and never delivers them to `socket.listen`).
//
// Phase 10a.5 — `last_event_id` reconnect-resume. The client forwards
// its most recent event_id as `?last_event_id=<id>` on the upgrade
// URI; when present and a [RealtimeReplayFetcher] is wired, the route
// replays missed events from the durable `event_outbox` (filtered to
// the connecting operator's scope, capped at [kRealtimeReplayWindow])
// BEFORE forwarding live frames. Live events arriving during the
// replay window are buffered locally so the client receives them in
// order (replay first, then buffered live, then continuous live). If
// the cursor falls outside the replay window the route emits a single
// `{"control":"replay_truncated"}` envelope and proceeds with live
// only — the contract requires the client to refresh from Postgres on
// that signal. Authority for the lifecycle:
// `docs/phases/phase_10a/phase_10a_shared_state_v1_plan.md` "Scope"
// → "WebSocket lifecycle (downstream of Pub/Sub)".
//
// Out of scope for the scaffold (Phase 10a follow-up):
//   * per-tenant rate-limit on subscribe
//   * structured WebSocket close codes for "lease expired" /
//     "operator removed"

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:forge_and_flow/services/realtime/realtime_event.dart';
import 'package:forge_and_flow/services/realtime/realtime_event_publisher.dart';

import 'advisor_proxy.dart' show OperatorContext, ProxyAuthError, ProxyRequestGuard;
import 'log.dart';

const String realtimeSubscribePath = '/v1/realtime';

/// Cadence for the dart:io WebSocket ping → pong heartbeat. dart:io
/// auto-closes the socket when the peer fails to pong within the
/// interval, which is the catch-all for half-open TCP connections.
/// Matches the Phase 10a plan's "heartbeat ping every 30s".
const Duration kRealtimeHeartbeatInterval = Duration(seconds: 30);

/// Subprotocol prefix the route accepts as a bearer-token carrier on
/// platforms (browsers) that cannot set the `Authorization` header on
/// a WebSocket upgrade.
const String kRealtimeBearerSubprotocolPrefix = 'bearer.';

/// Phase 10a.5 — query-parameter name the client uses to carry the
/// reconnect-resume cursor (`event_outbox.id` rendered as a string).
/// Must match
/// `WebSocketChannelRealtimeTransport.lastEventIdQueryParam`.
const String kRealtimeLastEventIdQueryParam = 'last_event_id';

/// Phase 10a.5 — replay-window cap. Matches the contract floor
/// (`event_outbox_contract.md` retention + plan_10a "Pub/Sub message
/// backlog (up to 5 minutes retention)"). A client whose cursor is
/// older than this gets a `replay_truncated` control envelope; the
/// contract requires the client to do a full Postgres refresh on that
/// signal rather than try to splice partial replay into stale state.
const Duration kRealtimeReplayWindow = Duration(minutes: 5);

/// Phase 10a.5 — wire JSON key the route uses to mark non-event
/// control envelopes. Mirrored on the client by
/// `lib/services/realtime/realtime_subscription.dart`.
const String kRealtimeControlKey = 'control';

/// Phase 10a.5 — control kind emitted when the client's cursor is
/// outside the replay window.
const String kRealtimeControlReplayTruncated = 'replay_truncated';

/// Phase 10a.5 — outcome of a server-side replay query. The route
/// either fans out [events] (in-order, oldest first) or signals
/// [truncated] = true so the route emits a `replay_truncated`
/// control envelope. Both fields are populated independently because
/// a fetcher MAY return events AND mark truncated when it can deliver
/// the most recent slice but knows older events fell off the window;
/// in that case the contract still calls for the full-refresh signal.
class RealtimeReplayResult {
  const RealtimeReplayResult({
    required this.events,
    required this.truncated,
  });

  /// Ordered oldest → newest. The route sends them as JSON frames in
  /// order before draining the live buffer.
  final List<RealtimeEvent> events;

  /// True when the cursor is outside [kRealtimeReplayWindow] (or the
  /// fetcher otherwise determined it cannot guarantee completeness).
  /// The route forwards the signal as a `replay_truncated` control
  /// envelope; consumers refresh from Postgres.
  final bool truncated;
}

/// Phase 10a.5 — server-side replay seam. Production wires this to a
/// closure over `EventOutboxRepository.claimBatch`-style read path
/// scoped to [scope.operatorId] (the operator must come from the
/// verified JWT, never from the URL — same cross-tenant rule as
/// every other route). Tests inject a fake to pin behavior without
/// spinning Postgres.
///
/// Implementations MUST:
///   * filter on the connecting operator's id (no cross-operator
///     reads — RLS via `runInTenantContext` is the production
///     guard, but the seam contract pins the rule independently);
///   * ignore rows older than [window] (return them as nothing — or
///     return `truncated: true` so the route emits the control
///     envelope);
///   * order ascending by `event_outbox.id` so the wire order
///     matches producer order.
typedef RealtimeReplayFetcher = Future<RealtimeReplayResult> Function({
  required OperatorContext scope,
  required String lastEventId,
  required Duration window,
});

/// Handle a `/v1/realtime` upgrade. Returns after the WebSocket is
/// closed (either by the client or by ping/pong timeout).
///
/// Authentication failures short-circuit with a JSON error body on the
/// underlying HTTP response. WebSocket upgrade failures (non-GET
/// request, missing upgrade headers, etc) short-circuit with 400.
Future<void> handleRealtimeUpgrade({
  required HttpRequest request,
  required ProxyRequestGuard authGuard,
  required InProcessRealtimePublisher publisher,
  RealtimeReplayFetcher? replayFetcher,
}) async {
  if (request.method != 'GET') {
    request.response.statusCode = 405;
    await request.response.close();
    return;
  }
  if (!WebSocketTransformer.isUpgradeRequest(request)) {
    request.response.statusCode = 400;
    request.response.headers.contentType = ContentType.json;
    request.response.write('{"error":"websocket_upgrade_required"}');
    await request.response.close();
    return;
  }

  // Resolve the bearer token. Authorization header wins; the
  // subprotocol carrier is the browser-compatible fallback.
  final authResolution = _resolveBearerToken(request);
  if (authResolution.token == null) {
    request.response.statusCode = 401;
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      '{"error":"missing or malformed Authorization bearer token"}',
    );
    await request.response.close();
    return;
  }

  OperatorContext scope;
  try {
    scope = await authGuard.requireOperatorContext(
      authorizationHeader: 'Bearer ${authResolution.token}',
    );
  } on ProxyAuthError catch (error) {
    request.response.statusCode = error.statusCode;
    request.response.headers.contentType = ContentType.json;
    request.response.write('{"error":"${error.message}"}');
    await request.response.close();
    return;
  }

  // Echo the chosen subprotocol back via protocolSelector so the
  // upgrade response carries the matching `Sec-WebSocket-Protocol`
  // header — required by RFC 6455 when the client requested any
  // subprotocol. When the token came from the Authorization header,
  // selectedSubprotocol is null and dart:io omits the header.
  final selectedSubprotocol = authResolution.subprotocol;
  // The socket lifecycle ends in [socket.listen]'s onDone/onError; the
  // close_sinks lint is structural and cannot trace through the
  // listener callbacks.
  // ignore: close_sinks
  final WebSocket socket;
  try {
    socket = await WebSocketTransformer.upgrade(
      request,
      protocolSelector: selectedSubprotocol == null
          ? null
          : (List<String> protocols) => selectedSubprotocol,
    );
  } catch (error, stack) {
    log(
      LogSeverity.error,
      'realtime.upgrade_failed',
      fields: <String, Object?>{
        'auth_carrier': authResolution.carrier,
        'error_type': error.runtimeType.toString(),
        'error_message': error.toString(),
        'stack_first_frame': firstStackFrame(stack),
      },
    );
    return;
  }

  final operatorId = scope.operatorId;
  log(
    LogSeverity.info,
    'realtime.subscribed',
    fields: <String, Object?>{
      'operator_id': operatorId,
      'user_id': scope.userId,
      'auth_carrier': authResolution.carrier,
    },
  );

  // dart:io owns the heartbeat: pings fire on this cadence, and the
  // socket auto-closes on missed pongs. No explicit application-level
  // deadline timer — that pattern would close healthy idle sockets
  // because pongs never reach `socket.listen`.
  socket.pingInterval = kRealtimeHeartbeatInterval;

  final completer = Completer<void>();

  // Phase 10a.5 — read the resume cursor from the upgrade URI. The
  // client puts it on the URL because browsers cannot set custom
  // WebSocket headers and the bearer subprotocol carrier is already
  // pulling double duty for auth. The cursor is non-secret (just the
  // event_outbox.id rendered as a string).
  final rawLastEventId =
      request.uri.queryParameters[kRealtimeLastEventIdQueryParam];
  final lastEventId = (rawLastEventId == null || rawLastEventId.isEmpty)
      ? null
      : rawLastEventId;
  final shouldReplay = lastEventId != null && replayFetcher != null;

  // Phase 10a.5 — buffer live events that arrive while the replay
  // query is in flight. The `InProcessRealtimePublisher` controller is
  // an async broadcast stream, so listener callbacks fire on
  // microtasks; subscribing BEFORE awaiting the replay fetcher means
  // anything published during the await lands in [liveBuffer] instead
  // of being dropped. After replay completes the route drains the
  // buffer in order, then flips [isReplaying] off and the listener
  // forwards live events directly. Consumers dedupe on event_id per
  // contract, so a rare overlap between replay and buffer is safe.
  final liveBuffer = <RealtimeEvent>[];
  var isReplaying = shouldReplay;

  void sendEvent(RealtimeEvent event) {
    try {
      socket.add(event.encode());
    } catch (error, stack) {
      log(
        LogSeverity.error,
        'realtime.frame_send_failed',
        fields: <String, Object?>{
          'operator_id': operatorId,
          'event_id': event.eventId,
          'topic': event.topic,
          'error_type': error.runtimeType.toString(),
          'error_message': error.toString(),
          'stack_first_frame': firstStackFrame(stack),
        },
      );
    }
  }

  // Subscribe to the publisher's per-operator stream and forward each
  // event. The publisher's stream is broadcast so multiple
  // connections from the same operator each get a fresh subscription.
  final subscription = publisher.subscribe(operatorId).listen(
    (RealtimeEvent event) {
      if (isReplaying) {
        liveBuffer.add(event);
        return;
      }
      sendEvent(event);
    },
    onError: (Object error, StackTrace stack) {
      log(
        LogSeverity.error,
        'realtime.publisher_stream_error',
        fields: <String, Object?>{
          'operator_id': operatorId,
          'error_type': error.runtimeType.toString(),
          'error_message': error.toString(),
          'stack_first_frame': firstStackFrame(stack),
        },
      );
    },
  );

  if (shouldReplay) {
    try {
      final result = await replayFetcher(
        scope: scope,
        lastEventId: lastEventId,
        window: kRealtimeReplayWindow,
      );
      if (result.truncated) {
        try {
          socket.add(jsonEncode(<String, Object?>{
            kRealtimeControlKey: kRealtimeControlReplayTruncated,
          }));
        } catch (error, stack) {
          log(
            LogSeverity.error,
            'realtime.control_send_failed',
            fields: <String, Object?>{
              'operator_id': operatorId,
              'control': kRealtimeControlReplayTruncated,
              'error_type': error.runtimeType.toString(),
              'error_message': error.toString(),
              'stack_first_frame': firstStackFrame(stack),
            },
          );
        }
        log(
          LogSeverity.info,
          'realtime.replay_truncated',
          fields: <String, Object?>{
            'operator_id': operatorId,
            'last_event_id': lastEventId,
            'window_seconds': kRealtimeReplayWindow.inSeconds,
          },
        );
      } else {
        for (final event in result.events) {
          // Defense in depth: a fetcher MUST scope to the connecting
          // operator (the contract pins this on the seam), but a
          // last-line check keeps a buggy fetcher from leaking another
          // operator's row across the WebSocket.
          if (event.operatorId != operatorId) {
            log(
              LogSeverity.error,
              'realtime.replay_cross_operator_drop',
              fields: <String, Object?>{
                'operator_id': operatorId,
                'event_operator_id': event.operatorId,
                'event_id': event.eventId,
              },
            );
            continue;
          }
          sendEvent(event);
        }
        log(
          LogSeverity.info,
          'realtime.replay_delivered',
          fields: <String, Object?>{
            'operator_id': operatorId,
            'last_event_id': lastEventId,
            'event_count': result.events.length,
          },
        );
      }
    } catch (error, stack) {
      // Best-effort: a replay failure must not drop the connection.
      // Live frames keep flowing once isReplaying flips off below.
      log(
        LogSeverity.warning,
        'realtime.replay_failed',
        fields: <String, Object?>{
          'operator_id': operatorId,
          'last_event_id': lastEventId,
          'error_type': error.runtimeType.toString(),
          'error_message': error.toString(),
          'stack_first_frame': firstStackFrame(stack),
        },
      );
    } finally {
      // Drain BEFORE flipping isReplaying so events that arrived
      // during the await preserve their producer order on the wire.
      // After the synchronous drain, isReplaying = false makes the
      // listener forward the next event directly; microtasks queued
      // during the drain run after this synchronous block returns.
      for (final event in liveBuffer) {
        sendEvent(event);
      }
      liveBuffer.clear();
      isReplaying = false;
    }
  }

  socket.listen(
    (Object? message) {
      // Inbound application frames are not part of the contract today
      // (no client → server messages defined). Future replay requests
      // would land here.
    },
    onDone: () {
      subscription.cancel();
      log(
        LogSeverity.info,
        'realtime.unsubscribed',
        fields: <String, Object?>{'operator_id': operatorId},
      );
      if (!completer.isCompleted) completer.complete();
    },
    onError: (Object error, StackTrace stack) {
      subscription.cancel();
      log(
        LogSeverity.warning,
        'realtime.socket_error',
        fields: <String, Object?>{
          'operator_id': operatorId,
          'error_type': error.runtimeType.toString(),
          'error_message': error.toString(),
          'stack_first_frame': firstStackFrame(stack),
        },
      );
      if (!completer.isCompleted) completer.complete();
    },
    cancelOnError: true,
  );

  return completer.future;
}

/// Result of the bearer-token resolution. [token] is the bearer value
/// (without the `Bearer ` prefix or the `bearer.` subprotocol prefix).
/// [subprotocol] is the literal subprotocol value the route MUST echo
/// back via `protocolSelector` when the token came from the
/// subprotocol carrier; null when the Authorization header path was
/// used. [carrier] is a short tag for structured logs (`header` or
/// `subprotocol`).
class _BearerResolution {
  const _BearerResolution({
    required this.token,
    required this.subprotocol,
    required this.carrier,
  });

  const _BearerResolution.unauthenticated()
    : token = null,
      subprotocol = null,
      carrier = 'none';

  final String? token;
  final String? subprotocol;
  final String carrier;
}

_BearerResolution _resolveBearerToken(HttpRequest request) {
  final authHeader = request.headers.value(HttpHeaders.authorizationHeader);
  if (authHeader != null && authHeader.startsWith('Bearer ')) {
    final token = authHeader.substring('Bearer '.length).trim();
    if (token.isNotEmpty) {
      return _BearerResolution(
        token: token,
        subprotocol: null,
        carrier: 'header',
      );
    }
  }
  // The browser fallback. `Sec-WebSocket-Protocol` may arrive as one
  // header with comma-separated values OR as multiple repeated
  // headers; HttpHeaders.[] returns the joined list. The first
  // `bearer.<token>` value wins; any same-list co-protocols are
  // preserved in the request but ignored here (the route does not
  // negotiate non-auth subprotocols today). dart:io exposes no named
  // constant for this header — the literal string is the canonical
  // form per RFC 6455.
  final wsProtocols = request.headers['sec-websocket-protocol'];
  if (wsProtocols != null) {
    for (final raw in wsProtocols) {
      for (final value in raw.split(',')) {
        final trimmed = value.trim();
        if (trimmed.startsWith(kRealtimeBearerSubprotocolPrefix)) {
          final token = trimmed
              .substring(kRealtimeBearerSubprotocolPrefix.length)
              .trim();
          if (token.isNotEmpty) {
            return _BearerResolution(
              token: token,
              subprotocol: trimmed,
              carrier: 'subprotocol',
            );
          }
        }
      }
    }
  }
  return const _BearerResolution.unauthenticated();
}
