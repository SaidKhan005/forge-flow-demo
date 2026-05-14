// CODE_OPS_DEBT — Theme C — worker startup wiring tests.
//
// Drives `wireProductionWorkers` against fake `PgCronNotifyConsumer`
// instances and asserts:
//
//   * Every cron NOTIFY channel has a registered consumer.
//   * A tick on each channel fans out to the matching handler.
//   * The audit-anchor sweep skips a second tick that fires while the
//     first is still in flight (single-flight guard).
//   * The tripwire poller is started and disposed via stopAll().
//
// `evaluateAuditAnchorRequireAzure` is exercised with three env
// shapes: flag off, flag on with creds, flag on with creds missing.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/pg_cron_notify_consumer.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/realtime/outbox_tripwire_evaluator.dart';
import 'package:forge_and_flow/services/rollups/rollup_models.dart';

import '../../../tool/advisor_proxy/worker_heartbeats.dart';
import '../../../tool/advisor_proxy/worker_startup_wiring.dart';

void main() {
  group('evaluateAuditAnchorRequireAzure', () {
    test('flag off → no failure even when creds are missing', () {
      final result = evaluateAuditAnchorRequireAzure(const <String, String>{});
      expect(result.required, isFalse);
      expect(result.shouldFailStartup, isFalse);
      expect(result.exitCode, isNull);
    });

    test('flag on + both creds present → no failure', () {
      final result = evaluateAuditAnchorRequireAzure(const <String, String>{
        kAuditAnchorRequireAzureEnvVar: 'true',
        kAuditAnchorAzureTenantEnvVar: 'tenant-uuid',
        kAuditAnchorAzureClientEnvVar: 'client-uuid',
      });
      expect(result.required, isTrue);
      expect(result.shouldFailStartup, isFalse);
      expect(result.tenantIdLoaded, isTrue);
      expect(result.clientIdLoaded, isTrue);
    });

    test('flag on + creds missing → exit 78 with names-only message', () {
      final result = evaluateAuditAnchorRequireAzure(const <String, String>{
        kAuditAnchorRequireAzureEnvVar: 'true',
      });
      expect(result.required, isTrue);
      expect(result.shouldFailStartup, isTrue);
      expect(result.exitCode, 78);
      expect(result.message, contains(kAuditAnchorAzureTenantEnvVar));
      expect(result.message, contains(kAuditAnchorAzureClientEnvVar));
    });

    test('flag value variants: 1 / yes / TRUE → all enable the gate', () {
      for (final value in <String>['1', 'yes', 'TRUE']) {
        final result = evaluateAuditAnchorRequireAzure(<String, String>{
          kAuditAnchorRequireAzureEnvVar: value,
        });
        expect(
          result.required,
          isTrue,
          reason: 'value "$value" should enable the require-azure gate',
        );
        expect(result.shouldFailStartup, isTrue);
      }
    });
  });

  group('wireProductionWorkers', () {
    test('registers a consumer for every cron channel', () async {
      final fakes = <_FakeConsumer>[];
      _FakeConsumer factory({
        required String connectionString,
        required List<String> channels,
        PgCronNotifyConsumerLogger? logger,
      }) {
        final fake = _FakeConsumer(channels: channels);
        fakes.add(fake);
        return fake;
      }

      final tenantWrapper = _stubTenantWrapper();
      final handle = wireProductionWorkers(
        postgresUrl: 'postgres://stub',
        adminWrapper: tenantWrapper,
        tenantWrapper: tenantWrapper,
        tripwireFetcher: () async => OutboxTripwireStatus.green,
        auditAnchorHandler: () async {},
        emailTickHandler: () async {},
        mobilePushHandler: () async {},
        rollupTickHandler: (RollupGrain grain) async {},
        consumerFactory: factory,
      );

      final wiredChannels = fakes
          .expand((c) => c.channels)
          .toSet();
      expect(
        wiredChannels,
        containsAll(<String>{
          kAuditAnchorTickChannel,
          kRollupsTickChannel,
          kEmailOutboxTickChannel,
          kMobilePushOutboxChannel,
        }),
      );
      expect(handle.consumers.length, fakes.length);

      await handle.stopAll();
      for (final fake in fakes) {
        expect(fake.stopped, isTrue);
      }
    });

    test('audit-anchor tick fans out to the handler', () async {
      final fakes = <_FakeConsumer>[];
      _FakeConsumer factory({
        required String connectionString,
        required List<String> channels,
        PgCronNotifyConsumerLogger? logger,
      }) {
        final fake = _FakeConsumer(channels: channels);
        fakes.add(fake);
        return fake;
      }

      var auditAnchorCalls = 0;
      final completer = Completer<void>();
      final tenantWrapper = _stubTenantWrapper();
      final handle = wireProductionWorkers(
        postgresUrl: 'postgres://stub',
        adminWrapper: tenantWrapper,
        tenantWrapper: tenantWrapper,
        tripwireFetcher: () async => OutboxTripwireStatus.green,
        auditAnchorHandler: () async {
          auditAnchorCalls += 1;
          completer.complete();
        },
        emailTickHandler: () async {},
        mobilePushHandler: () async {},
        rollupTickHandler: (RollupGrain grain) async {},
        consumerFactory: factory,
      );

      final auditFake = fakes.firstWhere(
        (c) => c.channels.contains(kAuditAnchorTickChannel),
      );
      auditFake.publish('{"fired_at":"2026-05-07T02:00:00Z"}');

      await completer.future.timeout(const Duration(seconds: 2));
      expect(auditAnchorCalls, 1);

      await handle.stopAll();
    });

    test('rollups tick fires the handler once per RollupGrain', () async {
      final fakes = <_FakeConsumer>[];
      _FakeConsumer factory({
        required String connectionString,
        required List<String> channels,
        PgCronNotifyConsumerLogger? logger,
      }) {
        final fake = _FakeConsumer(channels: channels);
        fakes.add(fake);
        return fake;
      }

      final calls = <RollupGrain>[];
      final completer = Completer<void>();
      final tenantWrapper = _stubTenantWrapper();
      final handle = wireProductionWorkers(
        postgresUrl: 'postgres://stub',
        adminWrapper: tenantWrapper,
        tenantWrapper: tenantWrapper,
        tripwireFetcher: () async => OutboxTripwireStatus.green,
        auditAnchorHandler: () async {},
        emailTickHandler: () async {},
        mobilePushHandler: () async {},
        rollupTickHandler: (RollupGrain grain) async {
          calls.add(grain);
          if (calls.length == RollupGrain.values.length &&
              !completer.isCompleted) {
            completer.complete();
          }
        },
        consumerFactory: factory,
      );

      final rollupsFake = fakes.firstWhere(
        (c) => c.channels.contains(kRollupsTickChannel),
      );
      rollupsFake.publish('{}');

      await completer.future.timeout(const Duration(seconds: 2));
      expect(calls.toSet(), RollupGrain.values.toSet());

      await handle.stopAll();
    });

    test('audit-anchor single-flight guard skips a concurrent tick',
        () async {
      final fakes = <_FakeConsumer>[];
      _FakeConsumer factory({
        required String connectionString,
        required List<String> channels,
        PgCronNotifyConsumerLogger? logger,
      }) {
        final fake = _FakeConsumer(channels: channels);
        fakes.add(fake);
        return fake;
      }

      var concurrentCalls = 0;
      final firstStarted = Completer<void>();
      final firstReleases = Completer<void>();
      final tenantWrapper = _stubTenantWrapper();
      final handle = wireProductionWorkers(
        postgresUrl: 'postgres://stub',
        adminWrapper: tenantWrapper,
        tenantWrapper: tenantWrapper,
        tripwireFetcher: () async => OutboxTripwireStatus.green,
        auditAnchorHandler: () async {
          concurrentCalls += 1;
          if (!firstStarted.isCompleted) firstStarted.complete();
          await firstReleases.future;
        },
        emailTickHandler: () async {},
        mobilePushHandler: () async {},
        rollupTickHandler: (RollupGrain grain) async {},
        consumerFactory: factory,
      );

      final auditFake = fakes.firstWhere(
        (c) => c.channels.contains(kAuditAnchorTickChannel),
      );
      auditFake.publish('{}');
      await firstStarted.future.timeout(const Duration(seconds: 2));

      // Second tick while the first sweep is still running — must be
      // dropped.
      auditFake.publish('{}');
      // Give the consumer enough time to deliver the second tick if
      // it were going to. The sweep should still be blocked on
      // firstReleases.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(concurrentCalls, 1);

      firstReleases.complete();
      await handle.stopAll();
    });

    test('B-2B — heartbeat registry records tick fan-out across every '
        'wired worker channel', () async {
      final fakes = <_FakeConsumer>[];
      _FakeConsumer factory({
        required String connectionString,
        required List<String> channels,
        PgCronNotifyConsumerLogger? logger,
      }) {
        final fake = _FakeConsumer(channels: channels);
        fakes.add(fake);
        return fake;
      }

      final tenantWrapper = _stubTenantWrapper();
      final heartbeats = WorkerHeartbeatRegistry();
      final auditCompleter = Completer<void>();
      final rollupCompleter = Completer<void>();
      final emailCompleter = Completer<void>();
      final mobileCompleter = Completer<void>();

      final handle = wireProductionWorkers(
        postgresUrl: 'postgres://stub',
        adminWrapper: tenantWrapper,
        tenantWrapper: tenantWrapper,
        tripwireFetcher: () async => OutboxTripwireStatus.green,
        auditAnchorHandler: () async {
          if (!auditCompleter.isCompleted) auditCompleter.complete();
        },
        emailTickHandler: () async {
          if (!emailCompleter.isCompleted) emailCompleter.complete();
        },
        mobilePushHandler: () async {
          if (!mobileCompleter.isCompleted) mobileCompleter.complete();
        },
        rollupTickHandler: (RollupGrain grain) async {
          if (grain == RollupGrain.values.last &&
              !rollupCompleter.isCompleted) {
            rollupCompleter.complete();
          }
        },
        heartbeatRegistry: heartbeats,
        consumerFactory: factory,
      );

      // Every cron channel + the tripwire poller channel are registered
      // up-front so the snapshot lists them before any tick fires.
      final preTickSnapshot = heartbeats.snapshot();
      final preTickChannels =
          preTickSnapshot.map((s) => s.channel).toSet();
      expect(
        preTickChannels,
        containsAll(<String>{
          kAuditAnchorTickChannel,
          kRollupsTickChannel,
          kEmailOutboxTickChannel,
          kMobilePushOutboxChannel,
          kHeartbeatChannelTripwirePoller,
        }),
      );
      // Cron-driven workers have zero ticks pre-fire. The tripwire
      // poller starts polling synchronously inside
      // `wireProductionWorkers` (the poller has its own internal timer
      // wired by `tripwirePoller.start()`), so its tickCount may
      // already be >= 0 by the time we snapshot.
      for (final s in preTickSnapshot) {
        if (s.channel == kHeartbeatChannelTripwirePoller) continue;
        expect(s.tickCount, 0, reason: '${s.channel} pre-tick count');
      }

      // Fire a tick on every worker channel.
      for (final fake in fakes) {
        fake.publish('{}');
      }

      await Future.wait<void>(<Future<void>>[
        auditCompleter.future.timeout(const Duration(seconds: 2)),
        rollupCompleter.future.timeout(const Duration(seconds: 2)),
        emailCompleter.future.timeout(const Duration(seconds: 2)),
        mobileCompleter.future.timeout(const Duration(seconds: 2)),
      ]);
      // Microtask drain so the success recordings settle.
      await Future<void>.delayed(const Duration(milliseconds: 25));

      final postTickByChannel = <String, WorkerHeartbeatSnapshot>{
        for (final s in heartbeats.snapshot()) s.channel: s,
      };
      for (final channel in <String>{
        kAuditAnchorTickChannel,
        kRollupsTickChannel,
        kEmailOutboxTickChannel,
        kMobilePushOutboxChannel,
      }) {
        final s = postTickByChannel[channel]!;
        expect(s.tickCount, greaterThanOrEqualTo(1),
            reason: '$channel did not record a tick');
        expect(s.successCount, greaterThanOrEqualTo(1),
            reason: '$channel did not record a success');
        expect(s.failureCount, 0, reason: '$channel recorded a failure');
        expect(s.inFlight, isFalse,
            reason: '$channel left in-flight latch set');
      }

      await handle.stopAll();
    });

    test('B-2B — heartbeat registry records tick failures with error '
        'type', () async {
      final fakes = <_FakeConsumer>[];
      _FakeConsumer factory({
        required String connectionString,
        required List<String> channels,
        PgCronNotifyConsumerLogger? logger,
      }) {
        final fake = _FakeConsumer(channels: channels);
        fakes.add(fake);
        return fake;
      }

      final tenantWrapper = _stubTenantWrapper();
      final heartbeats = WorkerHeartbeatRegistry();
      final emailCompleter = Completer<void>();

      final handle = wireProductionWorkers(
        postgresUrl: 'postgres://stub',
        adminWrapper: tenantWrapper,
        tenantWrapper: tenantWrapper,
        tripwireFetcher: () async => OutboxTripwireStatus.green,
        auditAnchorHandler: () async {},
        emailTickHandler: () async {
          if (!emailCompleter.isCompleted) emailCompleter.complete();
          throw const FormatException('email outbox handler boom');
        },
        mobilePushHandler: () async {},
        rollupTickHandler: (RollupGrain grain) async {},
        heartbeatRegistry: heartbeats,
        onTickError: (channel, error, stack) {
          // Swallow — the registry capture is what we are asserting.
        },
        consumerFactory: factory,
      );

      final emailFake = fakes
          .firstWhere((c) => c.channels.contains(kEmailOutboxTickChannel));
      emailFake.publish('{}');

      await emailCompleter.future.timeout(const Duration(seconds: 2));
      // Microtask drain so the failure recording settles.
      await Future<void>.delayed(const Duration(milliseconds: 25));

      final snapshots = heartbeats.snapshot();
      final emailSnap =
          snapshots.firstWhere((s) => s.channel == kEmailOutboxTickChannel);
      expect(emailSnap.tickCount, 1);
      expect(emailSnap.failureCount, 1);
      expect(emailSnap.successCount, 0);
      expect(emailSnap.lastFailureType, 'FormatException');
      expect(emailSnap.inFlight, isFalse,
          reason: 'failure path must reset the in-flight latch');

      await handle.stopAll();
    });
  });
}

/// In-memory test double for `PgCronNotifyConsumer` used by the
/// wiring tests. Mirrors the public surface but never opens a
/// `package:postgres` connection.
class _FakeConsumer implements PgCronNotifyConsumer {
  _FakeConsumer({required List<String> channels})
      : _channels = List<String>.unmodifiable(channels),
        _controller = StreamController<PgCronNotifyTick>.broadcast();

  final List<String> _channels;
  final StreamController<PgCronNotifyTick> _controller;
  bool started = false;
  bool stopped = false;

  void publish(String payload) {
    final tick = PgCronNotifyTick(
      channel: _channels.first,
      payload: payload,
      observedAt: DateTime.utc(2026, 5, 7, 2, 0),
    );
    _controller.add(tick);
  }

  @override
  Stream<PgCronNotifyTick> get ticks => _controller.stream;

  @override
  List<String> get channels => _channels;

  @override
  Future<void> start() async {
    started = true;
  }

  @override
  Future<void> stop() async {
    stopped = true;
    if (!_controller.isClosed) await _controller.close();
  }
}

TenantTransactionWrapper _stubTenantWrapper() =>
    TenantTransactionWrapper(_StubPostgresPool());

class _StubPostgresPool implements PostgresPool {
  @override
  Future<PostgresTransaction> beginTransaction() {
    throw UnimplementedError(
      'StubPostgresPool.beginTransaction was called; the worker '
      'startup test should not reach the live SQL path.',
    );
  }
}
