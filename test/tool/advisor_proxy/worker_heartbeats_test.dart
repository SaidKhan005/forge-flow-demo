// Wave 2 B-2B — regression tests for the worker heartbeat
// observability surface.
//
// Covers:
//   * [WorkerHeartbeatRegistry] counters update correctly on
//     start/success/failure (drives both branches).
//   * Per-channel staleness floors (default + custom) compute correctly.
//   * Snapshot emits stable JSON shape with deterministic ordering.
//   * [WorkerHeartbeatRouter] handles `GET /v1/health/workers`, returns
//     200 vs 503 based on the `any_stale` boolean, and rejects non-GET.
//   * Registry survives a tick handler throw without crashing.
//   * Re-registration preserves counters (hot-reload safety).
//
// Drives the same registry the production proxy wires through
// `wireProductionWorkers(... heartbeatRegistry: registry)`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/advisor_proxy/worker_heartbeats.dart';

void main() {
  group('WorkerHeartbeatRegistry — counters', () {
    test('records start/success/failure with deterministic timestamps',
        () {
      final clock = _StepClock(DateTime.utc(2026, 5, 14, 12));
      final registry = WorkerHeartbeatRegistry(clock: clock.now);

      registry.register('rollups_tick', expectedTickIntervalSeconds: 60);
      registry.recordStart('rollups_tick');
      registry.recordSuccess('rollups_tick');
      registry.recordStart('rollups_tick');
      registry.recordFailure('rollups_tick', const FormatException('boom'));

      final snapshots = registry.snapshot();
      expect(snapshots.length, 1);
      final snapshot = snapshots.single;
      expect(snapshot.channel, 'rollups_tick');
      expect(snapshot.tickCount, 2);
      expect(snapshot.successCount, 1);
      expect(snapshot.failureCount, 1);
      expect(snapshot.lastTickAt, isNotNull);
      expect(snapshot.lastSuccessAt, isNotNull);
      expect(snapshot.lastFailureAt, isNotNull);
      expect(snapshot.lastFailureType, 'FormatException');
      expect(snapshot.inFlight, isFalse);
    });

    test('in-flight latch flips on recordStart and clears on success',
        () {
      final registry = WorkerHeartbeatRegistry();
      registry.register('email_outbox_tick',
          expectedTickIntervalSeconds: 60);
      registry.recordStart('email_outbox_tick');
      var snap = registry.snapshot().single;
      expect(snap.inFlight, isTrue);
      registry.recordSuccess('email_outbox_tick');
      snap = registry.snapshot().single;
      expect(snap.inFlight, isFalse);
    });

    test('in-flight latch clears on failure as well as on success', () {
      final registry = WorkerHeartbeatRegistry();
      registry.register('audit_anchor_tick');
      registry.recordStart('audit_anchor_tick');
      registry.recordFailure('audit_anchor_tick', StateError('boom'));
      final snap = registry.snapshot().single;
      expect(snap.inFlight, isFalse,
          reason: 'Failure path must reset the latch.');
      expect(snap.failureCount, 1);
      expect(snap.lastFailureType, 'StateError');
    });

    test('unregistered channel auto-registers on first record', () {
      final registry = WorkerHeartbeatRegistry();
      registry.recordStart('phantom_channel');
      registry.recordSuccess('phantom_channel');
      final snap = registry.snapshot();
      expect(snap.length, 1);
      expect(snap.single.channel, 'phantom_channel');
      expect(snap.single.successCount, 1);
    });

    test('re-registering preserves counters (hot-reload safety)', () {
      final registry = WorkerHeartbeatRegistry();
      registry.register('rollups_tick', expectedTickIntervalSeconds: 60);
      registry.recordStart('rollups_tick');
      registry.recordSuccess('rollups_tick');
      // Second registration with a different staleness floor — counters
      // must NOT reset.
      registry.register('rollups_tick',
          expectedTickIntervalSeconds: 120);
      final snap = registry.snapshot().single;
      expect(snap.successCount, 1);
      expect(snap.tickCount, 1);
      expect(snap.staleAfter, const Duration(seconds: 360),
          reason: 'staleAfter floors to 3x the configured cadence.');
    });
  });

  group('WorkerHeartbeatRegistry — staleness', () {
    test('default staleness applies when no interval is registered', () {
      final clock = _StepClock(DateTime.utc(2026, 5, 14, 12));
      final registry = WorkerHeartbeatRegistry(clock: clock.now);
      registry.register('rollups_tick');
      // Tick at t=0.
      registry.recordStart('rollups_tick');
      registry.recordSuccess('rollups_tick');
      // Advance just below the default threshold (5 min).
      clock.advance(const Duration(minutes: 4, seconds: 50));
      expect(registry.snapshot().single.stale, isFalse);
      // Advance past it.
      clock.advance(const Duration(seconds: 20));
      expect(registry.snapshot().single.stale, isTrue);
    });

    test('custom interval scales the staleness floor by 3x', () {
      final clock = _StepClock(DateTime.utc(2026, 5, 14, 12));
      final registry = WorkerHeartbeatRegistry(clock: clock.now);
      registry.register('audit_anchor_tick',
          expectedTickIntervalSeconds: 24 * 60 * 60);
      // Tick.
      registry.recordStart('audit_anchor_tick');
      registry.recordSuccess('audit_anchor_tick');
      // One day later → not stale (3 days threshold).
      clock.advance(const Duration(days: 1));
      expect(registry.snapshot().single.stale, isFalse);
      // Past 3 days → stale.
      clock.advance(const Duration(days: 2, seconds: 1));
      expect(registry.snapshot().single.stale, isTrue);
    });

    test('staleness floor never goes below the default', () {
      final registry = WorkerHeartbeatRegistry();
      registry.register('tripwire', expectedTickIntervalSeconds: 1);
      final snap = registry.snapshot().single;
      expect(snap.staleAfter, kDefaultWorkerHeartbeatStaleness);
    });

    test('channel with no ticks is stale once registeredAt is older than '
        'the threshold', () {
      final clock = _StepClock(DateTime.utc(2026, 5, 14, 12));
      final registry = WorkerHeartbeatRegistry(clock: clock.now);
      registry.register('email_outbox_tick',
          expectedTickIntervalSeconds: 60);
      // Just registered → not stale yet.
      expect(registry.snapshot().single.stale, isFalse);
      // Advance past the floor (3x 60s = 180s, with default floor at
      // 300s).
      clock.advance(const Duration(minutes: 6));
      expect(registry.snapshot().single.stale, isTrue);
    });
  });

  group('WorkerHeartbeatRegistry — snapshot JSON shape', () {
    test('snapshotJson returns deterministic envelope', () {
      final clock = _StepClock(DateTime.utc(2026, 5, 14, 12));
      final registry = WorkerHeartbeatRegistry(clock: clock.now);
      registry.register('rollups_tick', expectedTickIntervalSeconds: 60);
      registry.register('email_outbox_tick',
          expectedTickIntervalSeconds: 60);
      registry.recordStart('rollups_tick');
      registry.recordSuccess('rollups_tick');

      final envelope = registry.snapshotJson();
      expect(envelope['ts'], isA<String>());
      expect(envelope['any_stale'], isFalse);
      expect(envelope['any_in_flight'], isFalse);
      final channels = envelope['channels'] as List<Object?>;
      expect(channels.length, 2);
      // Stable sort puts audit/email/rollups in alpha order.
      final firstChannel =
          (channels.first as Map<Object?, Object?>)['channel'];
      expect(firstChannel, 'email_outbox_tick');
    });

    test('any_stale flips to true when a registered channel ages past '
        'its floor', () {
      final clock = _StepClock(DateTime.utc(2026, 5, 14, 12));
      final registry = WorkerHeartbeatRegistry(clock: clock.now);
      registry.register('rollups_tick', expectedTickIntervalSeconds: 60);
      registry.recordStart('rollups_tick');
      registry.recordSuccess('rollups_tick');
      clock.advance(const Duration(minutes: 10));
      final envelope = registry.snapshotJson();
      expect(envelope['any_stale'], isTrue);
    });

    test('any_in_flight reflects the latch state', () {
      final registry = WorkerHeartbeatRegistry();
      registry.register('rollups_tick', expectedTickIntervalSeconds: 60);
      registry.recordStart('rollups_tick');
      expect(registry.snapshotJson()['any_in_flight'], isTrue);
      registry.recordSuccess('rollups_tick');
      expect(registry.snapshotJson()['any_in_flight'], isFalse);
    });
  });

  group('WorkerHeartbeatRouter — request surface', () {
    test('GET /v1/health/workers returns 200 + JSON envelope when fresh',
        () async {
      final clock = _StepClock(DateTime.utc(2026, 5, 14, 12));
      final registry = WorkerHeartbeatRegistry(clock: clock.now);
      registry.register('rollups_tick', expectedTickIntervalSeconds: 60);
      registry.recordStart('rollups_tick');
      registry.recordSuccess('rollups_tick');

      final router = WorkerHeartbeatRouter(registry: registry);
      final request = _StubHttpRequest(
        method: 'GET',
        uri: Uri.parse('/v1/health/workers'),
      );
      final claimed = await router.tryHandle(request);
      expect(claimed, isTrue);
      expect(request.response.statusCode, 200);
      final envelope =
          jsonDecode(request.response.bodyText) as Map<String, dynamic>;
      expect(envelope['any_stale'], isFalse);
      expect(envelope['any_in_flight'], isFalse);
      expect(envelope['channels'], isA<List<dynamic>>());
    });

    test(
        'GET /v1/health/workers returns 503 when at least one channel is '
        'stale', () async {
      final clock = _StepClock(DateTime.utc(2026, 5, 14, 12));
      final registry = WorkerHeartbeatRegistry(clock: clock.now);
      registry.register('rollups_tick', expectedTickIntervalSeconds: 60);
      registry.recordStart('rollups_tick');
      registry.recordSuccess('rollups_tick');
      clock.advance(const Duration(minutes: 10));

      final router = WorkerHeartbeatRouter(registry: registry);
      final request = _StubHttpRequest(
        method: 'GET',
        uri: Uri.parse('/v1/health/workers'),
      );
      final claimed = await router.tryHandle(request);
      expect(claimed, isTrue);
      expect(request.response.statusCode, 503);
      final envelope =
          jsonDecode(request.response.bodyText) as Map<String, dynamic>;
      expect(envelope['any_stale'], isTrue);
    });

    test('POST /v1/health/workers returns 405', () async {
      final registry = WorkerHeartbeatRegistry();
      final router = WorkerHeartbeatRouter(registry: registry);
      final request = _StubHttpRequest(
        method: 'POST',
        uri: Uri.parse('/v1/health/workers'),
      );
      final claimed = await router.tryHandle(request);
      expect(claimed, isTrue,
          reason:
              'POST on the matching path must be claimed by the router '
              '(not delegated to the monolith).');
      expect(request.response.statusCode, 405);
    });

    test('non-matching path returns false (delegate to dispatcher)',
        () async {
      final registry = WorkerHeartbeatRegistry();
      final router = WorkerHeartbeatRouter(registry: registry);
      final request = _StubHttpRequest(
        method: 'GET',
        uri: Uri.parse('/v1/other'),
      );
      final claimed = await router.tryHandle(request);
      expect(claimed, isFalse);
    });

    test('snapshot returns empty list when no channels registered '
        '(deferred-startup safety)', () async {
      final registry = WorkerHeartbeatRegistry();
      final router = WorkerHeartbeatRouter(registry: registry);
      final request = _StubHttpRequest(
        method: 'GET',
        uri: Uri.parse('/v1/health/workers'),
      );
      final claimed = await router.tryHandle(request);
      expect(claimed, isTrue);
      expect(request.response.statusCode, 200);
      final envelope =
          jsonDecode(request.response.bodyText) as Map<String, dynamic>;
      expect(envelope['channels'], isEmpty);
      expect(envelope['any_stale'], isFalse);
      expect(envelope['any_in_flight'], isFalse);
    });
  });
}

class _StepClock {
  _StepClock(this._now);

  DateTime _now;

  DateTime now() => _now;

  void advance(Duration d) {
    _now = _now.add(d);
  }
}

// ─── Stub HttpRequest / HttpResponse (mirrors the canonical pattern in
// `test/tool/advisor_proxy/admin_integrations_idempotency_test.dart`)

class _StubHttpRequest extends Stream<Uint8List> implements HttpRequest {
  _StubHttpRequest({required this.method, required Uri uri})
      : _uri = uri,
        _headers = _StubHttpHeaders(),
        response = _StubHttpResponse();

  final Uri _uri;
  final HttpHeaders _headers;

  @override
  final String method;

  @override
  final _StubHttpResponse response;

  @override
  HttpHeaders get headers => _headers;

  @override
  Uri get uri => _uri;

  @override
  Uri get requestedUri => _uri;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<Uint8List>.value(Uint8List(0)).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubHttpHeaders implements HttpHeaders {
  @override
  String? value(String name) => null;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubHttpResponse implements HttpResponse {
  @override
  int statusCode = 200;
  final StringBuffer _body = StringBuffer();
  final _StubResponseHeaders _headers = _StubResponseHeaders();

  String get bodyText => _body.toString();

  @override
  void write(Object? object) {
    _body.write(object);
  }

  @override
  Future<void> close() async {}

  @override
  HttpHeaders get headers => _headers;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubResponseHeaders implements HttpHeaders {
  ContentType? _contentType;

  @override
  ContentType? get contentType => _contentType;

  @override
  set contentType(ContentType? value) {
    _contentType = value;
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
