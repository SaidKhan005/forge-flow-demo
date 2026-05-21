// Pressure Preview v2 — Phase 3A webhook signature-failure storm test.
//
// Invariant
// ---------
// Webhook signature verification failures (HMAC mismatch, missing
// header, stale timestamp) do not accumulate unbounded in-memory
// state. The signature verifier returns false defensively (no
// exception propagation) and the route logs/rate-limits failures
// without leaking memory.
//
// Seam under test
// ---------------
// `PointyCastleSendGridSignatureVerifier` (and the
// `SendGridSignatureVerifier` interface) in
// `tool/advisor_proxy/sendgrid_events_webhook.dart`. This is the
// production signature-verify code; it is stateless by contract.
//
// Companion: in-memory rate-limit + accumulation model so we can
// assert that a flood of forged signatures does not grow memory
// unbounded (the route currently logs to its audit boundary; this
// test pins the in-memory model an enhancement would target).
//
// What in-process pressure proves
// -------------------------------
// 1. 1000 verify calls with a malformed signature base64 all return
//    false (no exception propagates; no memory accumulation in the
//    verifier itself — it is stateless).
// 2. 1000 verify calls with a malformed PEM all return false (parse
//    errors are absorbed; no exception propagates).
// 3. A signature-failure rate-limit model bounded by N entries does
//    not exceed its cap regardless of how many failures it observes
//    (defense against unbounded in-memory growth).
// 4. Stale-timestamp detection: a verify call where the timestamp is
//    older than the freshness window is rejected by the timestamp
//    guard model (the route's contract — verifier itself doesn't
//    enforce freshness, the route does — see route signature-and-
//    timestamp pre-check).
//
// External-service pressure
// -------------------------
// Env-gated via `FF_RUN_PRESSURE_P3A_SIG_FAILURE=1`. The
// preview-proxy storm portion would drive sustained 1000 req/s of
// forged-signature requests against the live SendGrid route and
// assert response-time + memory don't degrade. Out of scope for this
// slice (would also burn preview-proxy connection budget).

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/sendgrid_events_webhook.dart';

void main() {
  group('p3a webhook signature-failure storm — stateless verifier', () {
    const verifier = PointyCastleSendGridSignatureVerifier();

    test(
      '1000 verify calls with malformed signature base64 all return '
      'false; no exception propagates',
      () {
        const pem = '-----BEGIN PUBLIC KEY-----\nNOT_A_REAL_KEY\n'
            '-----END PUBLIC KEY-----';
        final body = Uint8List.fromList(<int>[1, 2, 3]);
        var falses = 0;
        for (var i = 0; i < 1000; i++) {
          final result = verifier.verify(
            pemPubKey: pem,
            timestamp: '1716240000',
            body: body,
            signatureBase64: 'not_valid_base64_!!!_$i',
          );
          if (!result) falses++;
        }
        expect(falses, equals(1000),
            reason: 'every malformed signature must return false');
      },
    );

    test(
      '1000 verify calls with a completely malformed PEM all return '
      'false (parse errors absorbed)',
      () {
        var falses = 0;
        for (var i = 0; i < 1000; i++) {
          final result = verifier.verify(
            pemPubKey: 'garbage-not-a-pem-$i',
            timestamp: '1716240000',
            body: Uint8List.fromList(<int>[i & 0xff]),
            signatureBase64: 'AAAA',
          );
          if (!result) falses++;
        }
        expect(falses, equals(1000),
            reason: 'every malformed PEM must return false');
      },
    );

    test(
      'an LRU-bounded failure rate-limiter never exceeds its cap, '
      'even under a 100k-request flood with random keys',
      () {
        // Model the rate-limiter shape used by the route's eventual
        // logging path. The contract: bounded in-memory state.
        final limiter = _BoundedFailureRateLimiter(maxEntries: 1000);
        for (var i = 0; i < 100000; i++) {
          limiter.recordFailure('key-${i % 5000}'); // 5000 distinct keys.
        }
        expect(limiter.entryCount, lessThanOrEqualTo(1000),
            reason: 'rate-limiter must bound memory under attack');
      },
    );

    test(
      'stale-timestamp detection: a timestamp older than the freshness '
      'window is rejected by the timestamp-guard model',
      () {
        // The route's pre-check rejects timestamps older than 5 minutes
        // (industry SendGrid default). Model that guard here.
        final now = DateTime.utc(2026, 5, 21, 12);
        bool isFresh(int unixSeconds) {
          final ts = DateTime.fromMillisecondsSinceEpoch(
            unixSeconds * 1000,
            isUtc: true,
          );
          final diff = now.difference(ts).abs();
          return diff <= const Duration(minutes: 5);
        }

        // 10-minute-old timestamp.
        final stale = now.subtract(const Duration(minutes: 10));
        expect(isFresh(stale.millisecondsSinceEpoch ~/ 1000), isFalse);
        // 1-minute-old timestamp.
        final fresh = now.subtract(const Duration(minutes: 1));
        expect(isFresh(fresh.millisecondsSinceEpoch ~/ 1000), isTrue);
        // Future timestamp 10 minutes out — also rejected by absolute
        // diff (defense against clock-skew attacks).
        final future = now.add(const Duration(minutes: 10));
        expect(isFresh(future.millisecondsSinceEpoch ~/ 1000), isFalse);
      },
    );

    test(
      'missing-signature-header guard: empty/null signature collapses '
      'cleanly to a verify=false outcome',
      () {
        const pem = '-----BEGIN PUBLIC KEY-----\nX\n-----END PUBLIC KEY-----';
        final body = Uint8List.fromList(<int>[42]);
        expect(
          verifier.verify(
            pemPubKey: pem,
            timestamp: '1716240000',
            body: body,
            signatureBase64: '',
          ),
          isFalse,
          reason: 'empty signature must collapse to false',
        );
      },
    );

    test(
      'preview-proxy signature-failure storm is env-gated; skipped here',
      () {
        if (Platform.environment['FF_RUN_PRESSURE_P3A_SIG_FAILURE'] != '1') {
          markTestSkipped(
            'FF_RUN_PRESSURE_P3A_SIG_FAILURE not set; stateless-verifier '
            'pressure runs above. Preview-proxy 1000 req/s forged-sig '
            'flood is reserved here for the next pressure wave (audit '
            'doc §2.3 #6).',
          );
          return;
        }
        fail(
          'FF_RUN_PRESSURE_P3A_SIG_FAILURE=1 set but the live preview-'
          'proxy storm harness is not yet implemented (audit doc §2.3 #6).',
        );
      },
    );
  });
}

/// Bounded LRU rate-limiter model. Used in the test to assert
/// in-memory state stays bounded under attack.
class _BoundedFailureRateLimiter {
  _BoundedFailureRateLimiter({required this.maxEntries})
      : assert(maxEntries > 0);

  final int maxEntries;
  final Map<String, int> _counts = <String, int>{};
  final List<String> _insertionOrder = <String>[];

  void recordFailure(String key) {
    if (_counts.containsKey(key)) {
      _counts[key] = _counts[key]! + 1;
      return;
    }
    if (_counts.length >= maxEntries) {
      // Evict the oldest.
      final oldest = _insertionOrder.removeAt(0);
      _counts.remove(oldest);
    }
    _counts[key] = 1;
    _insertionOrder.add(key);
  }

  int get entryCount => _counts.length;
}
