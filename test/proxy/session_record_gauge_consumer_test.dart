// Slice A11.1.b — Session-record gauge consumer (producer) tests.
//
// A11.1 (PR #522) wired the increment side: every 2xx from
// POST /v1/auth/session/login calls `gauge.observe(...)` which buckets
// per-(route, missing_field) counts in memory. The 2026-05-13 deep audit
// (`docs/_audits/post_codex_wave/wave_completion_deep_audit_2026_05_13.md`
// finding #2) flagged that `.snapshot()` and `.totalIncrements()` were
// never read by any production path — the metric was effectively dead.
//
// This file covers A11.1.b: the deep-health producer
// `session_record_incomplete_count` that surfaces the gauge snapshot into
// the /health envelope so multi-instance Cloud Run can roll up per-pod
// counts. Tests:
//
//   1. Snapshot accessor returns expected counts after recording
//      increments via the existing gauge API (sanity check that the
//      consumer reads what the producer wrote — round-trip through
//      `SessionRecordIncompleteGauge.observe`).
//   2. Producer payload includes the gauge field with the correct shape
//      (route, missing_field, count) under `metadata.buckets` and a
//      coarse total under `value`.
//   3. Empty snapshot → producer emits an empty `buckets` list (not
//      null, not missing) and `value: 0` so a downstream collector can
//      distinguish "no incomplete records" from "producer broken."
//   4. Producer is defensive: when the snapshot accessor throws, the
//      producer must emit `status: 'unknown'` with the standard
//      `warning: 'producer_error'` projection — the /health endpoint
//      cannot crash because of a buggy gauge.
//   5. When the snapshot accessor is null (back-compat: production
//      bootstrap not yet wired, unit-test scaffold), the producer emits
//      `status: 'unknown'` with `warning: 'not_wired'` so the
//      observability sink can render the actionable "wire me" state
//      instead of green-with-zero.
//
// Per HP #4 (per-operator isolation) + the gauge's own no-PII contract,
// the producer output carries ONLY (route, missing_field) labels — no
// tenant identifiers, no email, no IP, no user_id, no operator_id, no
// location_id, no session_id. Tests assert this explicitly.

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';
import '../../tool/advisor_proxy/health_producers/health_producer.dart';
import '../../tool/advisor_proxy/health_producers/infra_producers.dart';
import '../../tool/advisor_proxy/health_producers/producer_registry.dart';

DateTime _fixedNow() => DateTime.utc(2026, 5, 13, 12);

ProxyHealthProducerContext _contextWithSnapshot(
  Map<String, Map<String, int>> Function()? snapshot,
) {
  // The session-record producer never touches the SQL runner. We pass a
  // throwing runner to prove that: if the producer leaks a query the test
  // fails loudly instead of silently returning empty rows.
  return ProxyHealthProducerContext(
    runner: _ThrowingRunner(),
    now: _fixedNow(),
    sessionRecordIncompleteSnapshot: snapshot,
  );
}

class _ThrowingRunner implements ProxyHealthQueryRunner {
  @override
  Future<List<Map<String, Object?>>> query(
    String sql, {
    Map<String, Object?> parameters = const <String, Object?>{},
  }) {
    throw StateError(
      'session_record_incomplete_count producer must NOT issue SQL — '
      'it reads the in-memory gauge accessor only.',
    );
  }
}

void main() {
  group('session_record_incomplete_count — accessor → producer round-trip', () {
    test(
      'snapshot accessor returns expected counts after recording '
      'increments via the existing gauge API',
      () {
        // Sanity check the producer's READ side against the gauge's
        // WRITE side: the producer is just a thin projection over the
        // same `.snapshot()` API the unit test for A11.1 already covers,
        // so we exercise the round-trip explicitly here so the consumer
        // test catches an accidental shape change on either side.
        final gauge = SessionRecordIncompleteGauge();
        gauge.observe(
          route: authSessionLoginPath,
          body: <String, Object?>{
            'session_id': 'sid-1',
            'user_id': 'uid-1',
            'operator_id': '',
            'location_id': 'loc-1',
          },
          roles: <String>{'operator_owner'},
        );
        gauge.observe(
          route: authSessionLoginPath,
          body: <String, Object?>{
            'session_id': 'sid-2',
            'user_id': '',
            'operator_id': '',
            'location_id': 'loc-1',
          },
          roles: <String>{'operator_owner'},
        );

        final snapshot = gauge.snapshot();
        expect(snapshot[authSessionLoginPath]?['operator_id'], equals(2));
        expect(snapshot[authSessionLoginPath]?['user_id'], equals(1));
        expect(gauge.totalIncrements(), equals(3));
      },
    );

    test(
      'producer payload includes the gauge field with correct shape '
      '(route, missing_field, count)',
      () async {
        final gauge = SessionRecordIncompleteGauge();
        gauge.observe(
          route: authSessionLoginPath,
          body: <String, Object?>{
            'session_id': 'sid-1',
            'user_id': 'uid-1',
            'operator_id': '',
            'location_id': 'loc-1',
          },
          roles: <String>{'operator_owner'},
        );
        gauge.observe(
          route: authSessionLoginPath,
          body: <String, Object?>{
            'session_id': '',
            'user_id': 'uid-2',
            'operator_id': 'op-1',
            'location_id': 'loc-1',
          },
          roles: <String>{'operator_owner'},
        );

        final metric = await sessionRecordIncompleteCountProducer(
          _contextWithSnapshot(gauge.snapshot),
        );

        expect(metric.status, equals('green'));
        expect(metric.value, equals(2));
        expect(metric.unit, equals('count'));
        expect(metric.source, equals('session_record_incomplete_gauge'));
        expect(metric.metadata['tier'], equals(2));

        final buckets = metric.metadata['buckets'] as List<Object?>;
        expect(buckets, hasLength(2));
        // Buckets carry only route + missing_field + count — NO PII.
        for (final bucket in buckets) {
          final map = bucket as Map<String, Object?>;
          expect(map.keys.toSet(), <String>{'route', 'missing_field', 'count'});
          expect(map['route'], equals(authSessionLoginPath));
          // No tenant identifier leakage in any bucket entry.
          expect(map.containsKey('user_id'), isFalse);
          expect(map.containsKey('operator_id'), isFalse);
          expect(map.containsKey('location_id'), isFalse);
          expect(map.containsKey('session_id'), isFalse);
          expect(map.containsKey('email'), isFalse);
          expect(map.containsKey('ip'), isFalse);
        }
        final byField = <String, int>{
          for (final entry in buckets)
            (entry as Map<String, Object?>)['missing_field']! as String:
                entry['count']! as int,
        };
        expect(byField['operator_id'], equals(1));
        expect(byField['session_id'], equals(1));
      },
    );

    test(
      'empty snapshot → producer emits an empty buckets list (not null, '
      'not missing) and value: 0',
      () async {
        // Steady-state on a healthy proxy: the gauge has observed zero
        // incomplete records. The producer must still emit a well-formed
        // payload so a downstream collector can distinguish "no
        // incompletes" from "producer broken." Empty list, not null and
        // not missing.
        final gauge = SessionRecordIncompleteGauge();
        final metric = await sessionRecordIncompleteCountProducer(
          _contextWithSnapshot(gauge.snapshot),
        );
        expect(metric.status, equals('green'));
        expect(metric.value, equals(0));
        expect(metric.metadata['buckets'], isA<List<Object?>>());
        expect(metric.metadata['buckets'], isEmpty);
        expect(metric.metadata.containsKey('warning'), isFalse);
      },
    );

    test(
      'producer is defensive: if the snapshot accessor throws, producer '
      'emits status: unknown + warning: producer_error (no /health crash)',
      () async {
        // A buggy gauge (or a future refactor regression) must NEVER
        // crash the /health endpoint. The `runProducer` outer catch
        // projects any throw to the standard error envelope.
        final metric = await sessionRecordIncompleteCountProducer(
          _contextWithSnapshot(() {
            throw StateError('simulated gauge corruption');
          }),
        );
        expect(metric.status, equals('unknown'));
        expect(metric.value, isNull);
        expect(metric.metadata['warning'], equals('producer_error'));
        // Tenant-identifier absence holds even on the error path.
        expect(metric.metadata.containsKey('operator_id'), isFalse);
        expect(metric.metadata.containsKey('location_id'), isFalse);
        expect(metric.metadata.containsKey('user_id'), isFalse);
      },
    );

    test(
      'null accessor (back-compat: bootstrap not yet wired) → producer '
      'emits status: unknown + warning: not_wired',
      () async {
        // The accessor is optional on the context so unit-test scaffolds
        // and the legacy "no gauge" production posture stay alive. The
        // producer renders the actionable `not_wired` warning rather
        // than green-with-zero so the observability surface tells the
        // operator the gauge is silent because nobody is reading it
        // (vs. silent because nothing failed).
        final metric = await sessionRecordIncompleteCountProducer(
          _contextWithSnapshot(null),
        );
        expect(metric.status, equals('unknown'));
        expect(metric.value, isNull);
        expect(metric.metadata['warning'], equals('not_wired'));
        expect(metric.metadata['tier'], equals(2));
      },
    );

    test(
      'producer is registered in the infra family + reserved metric '
      'catalog (registry catalog consumer wiring is live)',
      () {
        // Catches accidental removal from either map and proves the
        // observability path is end-to-end wired through the registry,
        // not just stranded behind a feature flag.
        expect(
          infraProducers.containsKey('session_record_incomplete_count'),
          isTrue,
        );
        expect(
          proxyHealthProducerCatalog().containsKey(
            'session_record_incomplete_count',
          ),
          isTrue,
        );
        expect(
          proxyHealthReservedMetrics.containsKey(
            'session_record_incomplete_count',
          ),
          isTrue,
        );
        // Surfaces in the 'infra' surface group so the deep-health
        // envelope's tier-2 surface rollup picks it up.
        final infraSurface = proxyHealthReservedSurfaces['infra']!;
        expect(
          infraSurface.metrics.contains('session_record_incomplete_count'),
          isTrue,
        );
      },
    );
  });
}
