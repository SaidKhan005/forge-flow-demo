// Phase 10a.5 — RealtimeReplayResolver.
//
// Server-side helper that hands the WebSocket route the events a
// reconnecting client missed during the disconnect window. The route
// (`tool/advisor_proxy/realtime_route.dart`) reads `?last_event_id=...`
// from the upgrade URI; when present it asks this resolver for missed
// events on a topic, scoped to the connecting operator, and forwards
// them ahead of the live stream.
//
// Authority:
//   * `docs/contracts/event_outbox_contract.md` — `event_id` for dedupe
//     across reconnects, `occurred_at` for ordering and lag.
//   * `docs/phases/phase_10a/phase_10a_shared_state_v1_plan.md`
//     "WebSocket lifecycle" — "On reconnect, client provides last-seen
//     `event_id`; server replays missed events from Pub/Sub message
//     backlog (up to 5 minutes retention)".
//
// Why a seam (RealtimeReplayBacklog), not a direct dependency on the
// publisher: the production wiring layers a Cloud Pub/Sub backlog query
// behind the same shape (Phase 10a follow-up); the demo / single-
// instance binding answers from the in-process publisher's per-topic
// ring buffer. Keeping the seam narrow means the route never has to
// know which transport answered the replay query.
//
// Web-compat: this file does NOT import `dart:io`, `sqflite`, or
// `sqflite_common_ffi`. The resolver is server-side runtime only;
// nothing here can leak into a Flutter Web entrypoint. The watermark
// persistence on the client side is its own seam.

import 'dart:collection';

import 'realtime_event.dart';

/// Default backlog retention window the resolver applies when a caller
/// does not pin one. Mirrors the route-level
/// `kRealtimeReplayWindow` and the contract floor in
/// `docs/contracts/event_outbox_contract.md` (Pub/Sub message backlog
/// up to 5 minutes retention). Both constants must move together.
const Duration kRealtimeReplayBacklogWindow = Duration(minutes: 5);

/// In-process ring-buffer capacity per `(operator_id, topic)` pair.
/// Single-instance demo mode uses this size; the production Pub/Sub
/// backlog is bounded by retention time, not entry count, and ignores
/// this constant.
const int kRealtimeReplayRingBufferCapacity = 256;

/// Sentinel returned by the resolver when the supplied `lastEventId`
/// is older than the backlog window (or the backlog otherwise cannot
/// guarantee completeness). Callers MUST distinguish this from the
/// regular "no events to replay" empty list — the contract requires a
/// one-shot polling refresh from Postgres on this signal, not a no-op.
///
/// Surfaced as a `List<RealtimeEvent>` subtype so it can flow back
/// through the resolver's `Future<List<RealtimeEvent>>` return type
/// without forcing every consumer to switch on a tagged-union return.
/// Identity comparison is the contract:
/// `identical(result, RealtimeReplayStaleSentinel.instance)`.
class RealtimeReplayStaleSentinel extends ListBase<RealtimeEvent> {
  RealtimeReplayStaleSentinel._();

  static final RealtimeReplayStaleSentinel instance =
      RealtimeReplayStaleSentinel._();

  @override
  int get length => 0;

  @override
  set length(int newLength) {
    throw UnsupportedError(
      'RealtimeReplayStaleSentinel is immutable; treat it as an '
      'identity signal, not a mutable list',
    );
  }

  @override
  RealtimeEvent operator [](int index) {
    throw RangeError.index(index, this, 'index', null, 0);
  }

  @override
  void operator []=(int index, RealtimeEvent value) {
    throw UnsupportedError(
      'RealtimeReplayStaleSentinel is immutable; the route emits a '
      'replay_truncated control envelope on this signal instead of '
      'forwarding events.',
    );
  }
}

/// Storage seam over the recent-events backlog. Implementations:
///   * `PubsubRealtimePublisher` (in-process ring buffer keyed by
///     `(operator_id, topic)`, capacity
///     [kRealtimeReplayRingBufferCapacity]).
///   * Cloud Pub/Sub backlog query — Phase 10a follow-up.
///
/// Implementations MUST scope every read to the supplied `operatorId`
/// (the contract pins this independently of any RLS guard) and order
/// the returned events oldest → newest by `occurred_at`. When the
/// supplied `lastEventId` is unknown to the backlog OR the cursor is
/// older than `window`, implementations MUST return
/// [RealtimeReplayStaleSentinel.instance] so the route can emit the
/// truncation control envelope.
abstract class RealtimeReplayBacklog {
  Future<List<RealtimeEvent>> replayMissed({
    required String operatorId,
    required String topic,
    required String lastEventId,
    required Duration window,
  });
}

/// Resolver invoked by the WebSocket route on reconnect. The route
/// converts the resolver's result into a `RealtimeReplayResult` for
/// transport — events flow before the live stream; the stale sentinel
/// trips the `replay_truncated` control envelope.
///
/// Construction binds the resolver to one [RealtimeReplayBacklog]
/// implementation; in single-instance demo mode this is the in-process
/// publisher's ring buffer, in production it is the Cloud Pub/Sub
/// backlog query.
class RealtimeReplayResolver {
  RealtimeReplayResolver({required RealtimeReplayBacklog backlog})
    : _backlog = backlog;

  final RealtimeReplayBacklog _backlog;

  /// Resolve the events the connecting client missed on `topic` since
  /// `lastEventId`. Contract:
  ///   * `lastEventId == null` → empty list (first-connect path; the
  ///     resolver MUST NOT consult the backlog because there is
  ///     nothing to dedupe against).
  ///   * cursor inside `backlogWindow` and known to the backlog →
  ///     events ordered oldest → newest by `occurred_at`.
  ///   * cursor unknown / older than `backlogWindow` →
  ///     [RealtimeReplayStaleSentinel.instance] (identity-checked by
  ///     the route).
  ///
  /// `operatorId` and `topic` together select the per-(operator,
  /// topic) slice; the backlog never returns another operator's rows.
  Future<List<RealtimeEvent>> resolveMissedSince({
    required String operatorId,
    required String topic,
    required String? lastEventId,
    required Duration backlogWindow,
  }) async {
    if (lastEventId == null) return const <RealtimeEvent>[];
    return _backlog.replayMissed(
      operatorId: operatorId,
      topic: topic,
      lastEventId: lastEventId,
      window: backlogWindow,
    );
  }
}
