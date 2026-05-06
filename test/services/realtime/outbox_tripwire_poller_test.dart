// Phase 10a.4 — outbox tripwire poller tests.
//
// Pins the polling cadence + error-policy contract that the sync
// badge depends on:
//   * start() fires an immediate fetch (badge sees the current
//     status without waiting out the full 60s interval),
//   * subsequent fetches honor the configured interval,
//   * fetcher exceptions do NOT crash the stream or bubble to
//     subscribers,
//   * dispose() cancels the timer + closes the stream.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/services/realtime/outbox_tripwire_evaluator.dart';
import 'package:forge_and_flow/services/realtime/outbox_tripwire_poller.dart';

void main() {
  group('OutboxTripwirePoller', () {
    test('start fires an immediate fetch and emits the result', () async {
      var calls = 0;
      final poller = OutboxTripwirePoller(
        fetcher: () async {
          calls += 1;
          return OutboxTripwireStatus.yellow;
        },
        interval: const Duration(seconds: 60),
      );
      addTearDown(poller.dispose);

      final received = <OutboxTripwireStatus>[];
      final subscription = poller.stream.listen(received.add);
      addTearDown(subscription.cancel);

      poller.start();
      // Allow the immediate fetch to resolve.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(calls, equals(1));
      expect(received, equals(<OutboxTripwireStatus>[OutboxTripwireStatus.yellow]));
      expect(poller.latest, OutboxTripwireStatus.yellow);
    });

    test('start is idempotent; calling twice does not double-fire', () async {
      var calls = 0;
      final poller = OutboxTripwirePoller(
        fetcher: () async {
          calls += 1;
          return OutboxTripwireStatus.green;
        },
        interval: const Duration(seconds: 60),
      );
      addTearDown(poller.dispose);

      poller.start();
      poller.start();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      // One immediate fetch only — the second start() is a no-op
      // while the poller is already running.
      expect(calls, equals(1));
    });

    test(
      'fetcher exceptions are swallowed and reported via onError; '
      'the stream stays open',
      () async {
        Object? captured;
        final poller = OutboxTripwirePoller(
          fetcher: () async => throw StateError('boom'),
          interval: const Duration(seconds: 60),
          onError: (error, _) => captured = error,
        );
        addTearDown(poller.dispose);

        var unexpectedErrors = 0;
        final subscription = poller.stream.listen(
          (_) {},
          onError: (_) => unexpectedErrors += 1,
        );
        addTearDown(subscription.cancel);

        poller.start();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(captured, isA<StateError>());
        // Listeners must NOT receive the error — a crashing fetcher
        // would otherwise tear down the badge mid-render.
        expect(unexpectedErrors, equals(0));
        // The latest stays at the seed (green by default) because no
        // fetch has succeeded yet.
        expect(poller.latest, OutboxTripwireStatus.green);
      },
    );

    test('dispose closes the stream and stops further fetches', () async {
      var calls = 0;
      final poller = OutboxTripwirePoller(
        fetcher: () async {
          calls += 1;
          return OutboxTripwireStatus.green;
        },
        interval: const Duration(milliseconds: 10),
      );

      poller.start();
      // First fetch.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final beforeDispose = calls;

      await poller.dispose();
      // Wait several intervals — no more fetches must fire.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, equals(beforeDispose));
      // Stream is closed; new listeners receive an immediate done.
      var done = false;
      poller.stream.listen((_) {}, onDone: () => done = true);
      await Future<void>.delayed(Duration.zero);
      expect(done, isTrue);
    });

    test('dispose is idempotent', () async {
      final poller = OutboxTripwirePoller(
        fetcher: () async => OutboxTripwireStatus.green,
      );
      poller.start();
      await poller.dispose();
      // Second dispose must not throw.
      await poller.dispose();
    });

    test('seedStatus controls the initial latest value', () {
      final poller = OutboxTripwirePoller(
        fetcher: () async => OutboxTripwireStatus.green,
        seedStatus: OutboxTripwireStatus.red,
      );
      addTearDown(poller.dispose);
      // Before any fetch settles, the initial state is the seed.
      expect(poller.latest, OutboxTripwireStatus.red);
    });
  });
}
