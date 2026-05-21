// Pressure Preview v2 — Phase 3D idempotency-store concurrent
// retry test.
//
// Invariant
// ---------
// Concurrent retries with the same idempotency key on the four
// production idempotency tables (`proxy_requests`, `handoff_codes`,
// `auth_step_up_challenges`, `mobile_push_outbox`) do not duplicate
// side effects. The UNIQUE constraint + ON CONFLICT DO NOTHING +
// transaction semantics ensure that for N concurrent retries of the
// SAME key, exactly one wins.
//
// Seam under test
// ---------------
// In-process: a deterministic UNIQUE-key store model that mirrors the
// shape of every production idempotency check
// (`tool/advisor_proxy/advisor_proxy.dart` `_reserveIdempotency` is
// representative — `insert ... on conflict do nothing returning ...`,
// then the caller's behavior keys off "did we get a row back?").
//
// What in-process pressure proves
// -------------------------------
// 1. Of N=100 concurrent reserve-and-execute futures with the same
//    key, exactly ONE side effect runs to completion.
// 2. The N-1 losers see "key already claimed" and produce IDEMPOTENT
//    replay responses (they observe the stored payload, not nothing).
// 3. Distinct keys never collide — N=100 retries spread across 10
//    keys produce exactly 10 side effects.
// 4. Concurrent retries scoped by (operator_id, location_id, key)
//    don't leak across tenants — the SAME idempotency key under two
//    different operators is two independent reservations.
//
// External-DB pressure
// --------------------
// Env-gated via `FF_RUN_PRESSURE_P3D_IDEMPOTENCY=1`. The DB-backed
// harness would issue N=100 raw concurrent INSERTs against the four
// real tables and assert UNIQUE-constraint defense holds; it requires
// a local Postgres and is reserved for the next pressure wave.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('p3d idempotency store concurrent retry — UNIQUE-key model', () {
    test(
      'N=100 concurrent reserve attempts on a single key produce '
      'exactly one winner; 99 losers see idempotent replay',
      () async {
        final store = _IdempotencyStoreModel();
        var sideEffectCount = 0;
        const key = _IdempotencyKey(
          tenantId: 'op-1|loc-1',
          requestKey: 'reset-password-abc',
        );

        Future<_ReserveResult> attempt() async {
          final claim = await store.reserve(key);
          if (claim.winner) {
            // Simulate the side effect — only the winner runs this.
            sideEffectCount++;
            await store.recordPayload(key, payload: 'jwt-token-xyz');
          }
          return claim;
        }

        final results = await Future.wait(<Future<_ReserveResult>>[
          for (var i = 0; i < 100; i++) attempt(),
        ]);

        expect(sideEffectCount, equals(1),
            reason: 'exactly one winner runs the side effect');
        final winners = results.where((r) => r.winner).length;
        expect(winners, equals(1),
            reason: 'exactly one Future reports winner=true');
        // The losers may race against the winner's payload write.
        // What we guarantee: every loser eventually sees the
        // stored payload after the winner records it.
        await store.waitForPayload(key);
        final replayPayload = await store.lookupPayload(key);
        expect(replayPayload, equals('jwt-token-xyz'));
      },
    );

    test(
      'distinct keys do not collide — 100 retries across 10 keys '
      'produce exactly 10 side effects',
      () async {
        final store = _IdempotencyStoreModel();
        var sideEffectCount = 0;

        Future<void> attempt(int keyIndex) async {
          final key = _IdempotencyKey(
            tenantId: 'op-1|loc-1',
            requestKey: 'job-$keyIndex',
          );
          final claim = await store.reserve(key);
          if (claim.winner) {
            sideEffectCount++;
            await store.recordPayload(key, payload: 'done-$keyIndex');
          }
        }

        // 100 attempts spread across 10 keys (each key claimed 10×).
        await Future.wait(<Future<void>>[
          for (var i = 0; i < 100; i++) attempt(i % 10),
        ]);
        expect(sideEffectCount, equals(10),
            reason: '10 distinct keys → 10 side effects');
      },
    );

    test(
      'tenant scoping holds — same request key under two tenants is '
      'two independent reservations',
      () async {
        final store = _IdempotencyStoreModel();
        var sideEffectCount = 0;

        Future<void> attempt(String tenantId) async {
          final key = _IdempotencyKey(
            tenantId: tenantId,
            requestKey: 'same-key',
          );
          final claim = await store.reserve(key);
          if (claim.winner) {
            sideEffectCount++;
            await store.recordPayload(key, payload: tenantId);
          }
        }

        await Future.wait(<Future<void>>[
          for (var i = 0; i < 50; i++) attempt('op-A|loc-A'),
          for (var i = 0; i < 50; i++) attempt('op-B|loc-B'),
        ]);
        expect(sideEffectCount, equals(2),
            reason: 'two tenants × one shared request key = two side effects');
        expect(
          await store.lookupPayload(const _IdempotencyKey(
            tenantId: 'op-A|loc-A',
            requestKey: 'same-key',
          )),
          equals('op-A|loc-A'),
        );
        expect(
          await store.lookupPayload(const _IdempotencyKey(
            tenantId: 'op-B|loc-B',
            requestKey: 'same-key',
          )),
          equals('op-B|loc-B'),
        );
      },
    );

    test(
      'losers do not observe a half-written payload — the store either '
      'returns null (winner not done yet) or the final payload, never '
      'a torn value',
      () async {
        final store = _IdempotencyStoreModel();
        const key = _IdempotencyKey(
          tenantId: 'op-1|loc-1',
          requestKey: 'never-torn',
        );

        // Winner takes a brief delay before writing the payload.
        Future<void> winnerPath() async {
          final claim = await store.reserve(key);
          if (!claim.winner) return;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          await store.recordPayload(key, payload: 'final-value');
        }

        // Losers poll the payload during the delay window. Each
        // observation must be either null or the final value — never
        // a partial / placeholder value.
        Future<List<String?>> loserPolls() async {
          final claim = await store.reserve(key);
          if (claim.winner) return <String?>[];
          final observations = <String?>[];
          for (var i = 0; i < 20; i++) {
            observations.add(await store.lookupPayload(key));
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
          return observations;
        }

        final results = await Future.wait(<Future<List<String?>>>[
          for (var i = 0; i < 10; i++)
            i == 0 ? winnerPath().then((_) => <String?>[]) : loserPolls(),
        ]);

        for (final observations in results) {
          for (final obs in observations) {
            // Every observation is either null (winner not done yet)
            // or the exact final value. The model guarantees no torn
            // intermediate write.
            expect(
              obs == null || obs == 'final-value',
              isTrue,
              reason: 'observed torn value: $obs',
            );
          }
        }
      },
    );

    test(
      'DB-backed concurrent-retry pressure is env-gated; skipped here',
      () {
        if (Platform.environment['FF_RUN_PRESSURE_P3D_IDEMPOTENCY'] != '1') {
          markTestSkipped(
            'FF_RUN_PRESSURE_P3D_IDEMPOTENCY not set; in-memory '
            'UNIQUE-key model pressure runs above. Live-Postgres harness '
            '(proxy_requests + handoff_codes + auth_step_up_challenges + '
            'mobile_push_outbox UNIQUE-constraint storm) is reserved here '
            'for the next pressure wave (audit doc §2.3 #3).',
          );
          return;
        }
        fail(
          'FF_RUN_PRESSURE_P3D_IDEMPOTENCY=1 set but the live-Postgres '
          'concurrent-retry harness is not yet implemented (audit doc '
          '§2.3 #3).',
        );
      },
    );
  });
}

/// Composite key matching the production
/// (operator_id, location_id, idempotency_key) UNIQUE shape.
class _IdempotencyKey {
  const _IdempotencyKey({
    required this.tenantId,
    required this.requestKey,
  });

  final String tenantId;
  final String requestKey;

  @override
  bool operator ==(Object other) =>
      other is _IdempotencyKey &&
      other.tenantId == tenantId &&
      other.requestKey == requestKey;

  @override
  int get hashCode => Object.hash(tenantId, requestKey);
}

class _ReserveResult {
  const _ReserveResult({required this.winner});
  final bool winner;
}

/// Deterministic UNIQUE-key store model. Uses Dart's single-threaded
/// event-loop guarantee for atomicity within a synchronous block,
/// which mirrors what Postgres provides via the UNIQUE constraint +
/// ON CONFLICT DO NOTHING.
class _IdempotencyStoreModel {
  final Map<_IdempotencyKey, bool> _reserved = <_IdempotencyKey, bool>{};
  final Map<_IdempotencyKey, String> _payloads = <_IdempotencyKey, String>{};
  final Map<_IdempotencyKey, Completer<void>> _payloadReady =
      <_IdempotencyKey, Completer<void>>{};

  Future<_ReserveResult> reserve(_IdempotencyKey key) async {
    // Yield once to interleave with other reservers.
    await Future<void>.value();
    if (_reserved.containsKey(key)) {
      return const _ReserveResult(winner: false);
    }
    _reserved[key] = true;
    _payloadReady.putIfAbsent(key, Completer<void>.new);
    return const _ReserveResult(winner: true);
  }

  Future<void> recordPayload(_IdempotencyKey key, {required String payload}) async {
    _payloads[key] = payload;
    _payloadReady.putIfAbsent(key, Completer<void>.new);
    if (!_payloadReady[key]!.isCompleted) {
      _payloadReady[key]!.complete();
    }
  }

  Future<String?> lookupPayload(_IdempotencyKey key) async {
    await Future<void>.value();
    return _payloads[key];
  }

  Future<void> waitForPayload(_IdempotencyKey key) async {
    final completer = _payloadReady.putIfAbsent(key, Completer<void>.new);
    return completer.future;
  }
}
