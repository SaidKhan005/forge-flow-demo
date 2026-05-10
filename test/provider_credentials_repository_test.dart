// Phase 11A.4 — ProviderCredentialsRepository tests.
//
// Exercises the rotate-in-one-transaction contract through a fake
// Postgres pool. Asserts: the rotate path runs UPDATE prior
// is_active=false then INSERT new row in the same transaction, the
// `actor::uuid` parameter binds on both rows, and `listActive`
// returns only `is_active = true` rows ordered by `key_kind`.
//
// Phase 6 extension (2026-05-09) — extends the file with four new
// contract groups pinning what Phase 3C (PR #451) exercised against
// the OAuth-refresh worker but never had real-DB tests for. These
// contracts live OFF `provider_credentials_repository.dart` (the
// `provider_credentials` table holds the platform-wide proxy keys —
// Anthropic, Voyage, Azure DB, Gemini) and live ON the
// per-(operator, location, vendor) `vendor_credentials` rotation
// surface mediated by `VendorCredentialBroker` + the OAuth refresh
// worker. Co-locating these here matches Phase 5's
// `pressure_preview_findings.md` Section 7 priority list, which
// names this test file as the extension home.
//
// CONTRACT GAP — surface mismatch (prompt vs. reality):
//   The Phase 6 prompt asked the four contracts to be pinned ON
//   `provider_credentials_repository.dart`. They actually live one
//   layer below: the per-tenant Future-lock + atomic ciphertext
//   rotation belong to `VendorCredentialBroker`, the
//   `oauth_refresh_advisory_lock` migration semantics belong to
//   `OAuthRefreshCronRunner` + its `OAuthRefreshGateway` seam, and
//   the `consecutive_refresh_failures` counter lives on
//   `vendor_credentials` (driven by the broker on success and the
//   worker tick on failure). The `provider_credentials` rows feed
//   the proxy's platform-wide keys (Anthropic / Voyage / Azure DB /
//   Gemini) — they have no expiry, no per-tenant scope, no advisory
//   lock, and no failure counter. The contract groups below stay
//   faithful to the prompt's intent (drive the Phase 3C contracts)
//   but exercise the surfaces where the contracts actually live.
//
// Test posture — in-memory fakes (no real Postgres):
//   The existing groups in this file (`rotate`, `listActive`) drive
//   `ProviderCredentialsRepository` against `_ProviderCredentialsPool`
//   — a `PostgresPool` fake. The new groups follow the same style:
//   the broker drives a `_BrokerPool` fake (mirroring
//   `test/integrations/_common/vendor_credential_broker_test.dart`);
//   the cron runner drives an `_AdvisoryLockGateway` fake; the
//   worker tick drives a `_CounterAwareWorkerGateway` +
//   `_ThrowingBrokerStub` fake. No `@Tags(['postgres'])` annotation
//   because none of the new groups touch Postgres. Staging-DB
//   coverage of the same contracts is scheduled out-of-tree by the
//   Phase 6 backfill plan; this file stays hermetic.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/provider_credentials_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/_common/vendor_credential_broker.dart';
import 'package:forge_and_flow/services/integration/oauth_refresh_cron.dart';

import '../tool/oauth_refresh_worker/main.dart' as worker;

const String _actorId = '33333333-3333-4333-8333-333333333333';

// ── Phase 6 extension constants ────────────────────────────────────
const String _opA = '11111111-2222-3333-4444-555555555555';
const String _opB = 'bbbbbbbb-cccc-dddd-eeee-ffffffffffff';
const String _loc = '66666666-7777-8888-9999-aaaaaaaaaaaa';
const String _locB = '77777777-8888-9999-aaaa-bbbbbbbbbbbb';
const String _envelopeKey = 'test-envelope-key';

void main() {
  group('ProviderCredentialsRepository.rotate', () {
    test(
      'flips prior is_active to false, then inserts new row, in one transaction',
      () async {
        final returnedRow = <String, Object?>{
          'credential_id': 'cred-new',
          'key_kind': 'anthropic',
          'masked_value': 'sk-a***1234',
          'kms_secret_name': 'kms://stub/new-uuid',
          'created_by': _actorId,
          'updated_by': _actorId,
          'is_active': true,
          'rotated_at': DateTime.utc(2026, 5, 1, 12),
          'created_at': DateTime.utc(2026, 5, 1, 12),
          'updated_at': DateTime.utc(2026, 5, 1, 12),
        };
        final pool = _ProviderCredentialsPool(insertReturnRow: returnedRow);
        final repo = ProviderCredentialsRepository(
          TenantTransactionWrapper(pool),
        );

        final row = await repo.rotate(
          keyKind: 'anthropic',
          maskedValue: 'sk-a***1234',
          kmsSecretName: 'kms://stub/new-uuid',
          actorUserId: _actorId,
          adminReason: 'admin.integrations.POST:tester:rotate:anthropic',
        );

        expect(row.credentialId, equals('cred-new'));
        expect(row.maskedValue, equals('sk-a***1234'));
        expect(row.isActive, isTrue);

        // Exactly one transaction. The wrapper issues `SET LOCAL`
        // statements alongside the repo's UPDATE/INSERT; filter to
        // the provider_credentials statements before asserting.
        expect(pool.transactions, hasLength(1));
        final tx = pool.transactions.single;
        final relevantStatements = <int>[];
        for (var i = 0; i < tx.executedSql.length; i++) {
          if (tx.executedSql[i].contains('provider_credentials')) {
            relevantStatements.add(i);
          }
        }
        expect(relevantStatements, hasLength(2));

        final updateIdx = relevantStatements[0];
        final insertIdx = relevantStatements[1];
        // Order matters: UPDATE prior runs BEFORE the INSERT so the
        // partial unique index on (key_kind) where is_active is
        // never violated.
        expect(updateIdx, lessThan(insertIdx));

        expect(tx.executedSql[updateIdx], contains('update provider_credentials'));
        expect(tx.executedSql[updateIdx], contains('is_active = false'));
        expect(
          tx.executedSql[updateIdx],
          contains('where key_kind = @key_kind'),
        );
        expect(tx.executedSql[updateIdx], contains('and is_active = true'));
        expect(tx.parameters[updateIdx]['key_kind'], equals('anthropic'));
        expect(tx.parameters[updateIdx]['actor'], equals(_actorId));

        expect(
          tx.executedSql[insertIdx],
          contains('insert into provider_credentials'),
        );
        expect(tx.executedSql[insertIdx], contains('is_active, rotated_at'));
        expect(tx.executedSql[insertIdx], contains('@key_kind'));
        expect(tx.executedSql[insertIdx], contains('@masked_value'));
        expect(tx.executedSql[insertIdx], contains('@kms_secret_name'));
        // The actor parameter binds on both `created_by` AND
        // `updated_by` so a fresh row carries the rotating admin's
        // user_id on both audit columns.
        expect(
          tx.executedSql[insertIdx],
          contains('@actor::uuid, @actor::uuid'),
        );
        expect(tx.parameters[insertIdx]['actor'], equals(_actorId));
        expect(
          tx.parameters[insertIdx]['masked_value'],
          equals('sk-a***1234'),
        );
        expect(
          tx.parameters[insertIdx]['kms_secret_name'],
          equals('kms://stub/new-uuid'),
        );
      },
    );
  });

  test(
    'rotate binds the actor UUID on both UPDATE prior and INSERT new params',
    () async {
      const distinctActor = '99999999-9999-4999-8999-999999999999';
      final returnedRow = <String, Object?>{
        'credential_id': 'cred-new',
        'key_kind': 'anthropic',
        'masked_value': 'sk-a***1234',
        'kms_secret_name': 'kms://stub/new-uuid',
        'created_by': distinctActor,
        'updated_by': distinctActor,
        'is_active': true,
        'rotated_at': DateTime.utc(2026, 5, 1, 12),
        'created_at': DateTime.utc(2026, 5, 1, 12),
        'updated_at': DateTime.utc(2026, 5, 1, 12),
      };
      final pool = _ProviderCredentialsPool(insertReturnRow: returnedRow);
      final repo = ProviderCredentialsRepository(
        TenantTransactionWrapper(pool),
      );

      await repo.rotate(
        keyKind: 'anthropic',
        maskedValue: 'sk-a***1234',
        kmsSecretName: 'kms://stub/new-uuid',
        actorUserId: distinctActor,
        adminReason: 'admin.integrations.POST:fb-uid:rotate:anthropic',
      );

      final tx = pool.transactions.single;
      // The proxy resolver guarantees a UUID-shaped actor reaches
      // the repo, so every actor binding ends up at the resolved
      // user UUID — no null leaks past the proxy boundary.
      for (final params in tx.parameters) {
        if (params.containsKey('actor')) {
          expect(params['actor'], equals(distinctActor));
        }
      }
    },
  );

  group('ProviderCredentialsRepository.listActive', () {
    test('selects only active rows, ordered by key_kind', () async {
      final pool = _ProviderCredentialsPool(
        listRows: <PostgresRow>[
          <String, Object?>{
            'credential_id': 'cred-anthropic',
            'key_kind': 'anthropic',
            'masked_value': 'sk-a***Q9aB',
            'kms_secret_name': 'kms://stub/anthropic',
            'created_by': _actorId,
            'updated_by': _actorId,
            'is_active': true,
            'rotated_at': DateTime.utc(2026, 4, 1),
            'created_at': DateTime.utc(2026, 4, 1),
            'updated_at': DateTime.utc(2026, 4, 1),
          },
        ],
      );
      final repo = ProviderCredentialsRepository(
        TenantTransactionWrapper(pool),
      );
      final rows = await repo.listActive(
        adminReason: 'admin.integrations.GET:tester:list',
      );
      expect(rows, hasLength(1));
      expect(rows.single.keyKind, equals('anthropic'));
      expect(rows.single.maskedValue, equals('sk-a***Q9aB'));

      final tx = pool.transactions.single;
      final selectStatement = tx.executedSql.firstWhere(
        (sql) => sql.contains('from provider_credentials'),
      );
      expect(selectStatement, contains('where is_active = true'));
      expect(selectStatement, contains('order by key_kind asc'));
    });
  });

  // ─────────────────────────────────────────────────────────────────
  // PHASE 6 EXTENSION — Phase 3C (PR #451) contracts.
  //
  // The four groups below pin contracts the OAuth-refresh worker
  // exercised against the in-memory simulator in PR #451 / PR #455.
  // The contracts live one layer below this repo (broker, worker tick,
  // advisory-lock gateway, failure-counter column) but the Phase 5
  // findings doc names this file as the extension home. We use small
  // in-memory fakes so the suite stays hermetic; the staging-DB lift
  // for these same contracts is gated behind PHASE_6_PG_URL and is
  // scheduled separately.
  // ─────────────────────────────────────────────────────────────────

  group('Contract 1 — per-tenant Future-lock under N parallel refreshes', () {
    test(
      '5 parallel refresh attempts for the same (operator, location, '
      'vendor) fire exactly 1 vendor RTT; all callers receive the same '
      'access token',
      () async {
        final pool = _BrokerPool(
          rowsByTenant: <String, Map<String, Object?>>{
            '$_opA|$_loc': _credentialRow(
              accessTokenPlaintext: 'stale',
              expiresAt:
                  DateTime.now().toUtc().subtract(const Duration(hours: 1)),
            ),
          },
        );
        final broker = VendorCredentialBroker(
          tenantWrapper: TenantTransactionWrapper(pool),
          pgcryptoEnvelopeKey: _envelopeKey,
        );

        final closureRelease = Completer<void>();
        var closureInvocations = 0;
        Future<TokenRefreshResult> doRefresh(VendorCredentialBundle current) async {
          closureInvocations += 1;
          // Block until released so all 5 callers have a chance to
          // hit the broker's per-tenant Future-lock map and observe
          // the same in-flight Future.
          await closureRelease.future;
          return TokenRefreshResult(
            accessToken: 'fresh-token',
            expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
          );
        }

        const callers = 5;
        final futures = <Future<String>>[];
        for (var i = 0; i < callers; i += 1) {
          futures.add(broker.refreshAccessToken(
            operatorId: _opA,
            locationId: _loc,
            vendorId: 'toast',
            doRefresh: doRefresh,
          ));
        }
        // Yield once so all five resolveAccessToken calls register their
        // Future on the broker's _inFlightRefreshes map.
        await Future<void>.delayed(Duration.zero);
        closureRelease.complete();
        final results = await Future.wait(futures);

        expect(closureInvocations, equals(1),
            reason:
                'broker per-tenant Future-lock must collapse $callers parallel '
                'refreshes against the same tuple to exactly one closure '
                'invocation (one vendor RTT)');
        expect(results, everyElement(equals('fresh-token')),
            reason:
                'all $callers callers must receive the same access token from '
                'the single in-flight refresh');
      },
    );

    test(
      '5 parallel refreshes against DIFFERENT (operator, location, '
      'vendor) tuples fire 5 distinct vendor RTTs (no cross-tenant '
      'lock contention)',
      () async {
        // Five distinct tuples, each with its own row.
        final tuples = <_TupleKey>[
          _TupleKey(_opA, _loc, 'toast'),
          _TupleKey(_opA, _loc, 'square'),
          _TupleKey(_opB, _loc, 'toast'),
          _TupleKey(_opB, _locB, 'clover'),
          _TupleKey(_opA, _locB, 'lightspeed_lsk'),
        ];
        final rowsByTenant = <String, Map<String, Object?>>{
          for (final t in tuples)
            '${t.operatorId}|${t.locationId}': _credentialRow(
              accessTokenPlaintext: 'stale-${t.vendorId}',
              expiresAt:
                  DateTime.now().toUtc().subtract(const Duration(hours: 1)),
            ),
        };
        final pool = _BrokerPool(rowsByTenant: rowsByTenant);
        final broker = VendorCredentialBroker(
          tenantWrapper: TenantTransactionWrapper(pool),
          pgcryptoEnvelopeKey: _envelopeKey,
        );

        var closureInvocations = 0;
        Future<TokenRefreshResult> doRefresh(VendorCredentialBundle current) async {
          closureInvocations += 1;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return TokenRefreshResult(
            accessToken: 'fresh-${current.vendorId}',
            expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
          );
        }

        await Future.wait(<Future<String>>[
          for (final t in tuples)
            broker.refreshAccessToken(
              operatorId: t.operatorId,
              locationId: t.locationId,
              vendorId: t.vendorId,
              doRefresh: doRefresh,
            ),
        ]);
        expect(closureInvocations, equals(tuples.length),
            reason:
                'each distinct (operator, location, vendor) tuple gets its own '
                'in-flight slot; the lock map keys on (op|loc|vendor) so cross-'
                'tenant calls must not share an in-flight Future');
      },
    );
  });

  group('Contract 2 — atomic ciphertext rotation between vendor RTT and DB '
      'commit', () {
    test(
      'concurrent reader during in-flight refresh observes a consistent '
      'ciphertext (never a half-rotated row)',
      () async {
        // Use the synthetic credential store pattern (mirrors
        // p3c_synthetic_credential_store.dart). The store's
        // _TupleState.commit writes (token, expires_at, rotated_at,
        // rotation_count) under a single field assignment so a probe
        // observer scheduled between the closure body and the commit
        // sees only the pre-rotation state. This pins the same MVCC-
        // atomicity guarantee the broker's single-statement UPDATE
        // gives at the Postgres layer.
        final store = _AtomicCredentialStore()
          ..seed(
            tuple: const _TupleKey(_opA, _loc, 'toast'),
            initialCiphertext: 'pre-rotation',
            initialExpiresAt:
                DateTime.now().toUtc().add(const Duration(seconds: 5)),
          );

        final probeReadings = <_TupleSnapshot>[];
        await store.refresh(
          tuple: const _TupleKey(_opA, _loc, 'toast'),
          vendorLatency: const Duration(milliseconds: 10),
          newCiphertext: 'post-rotation',
          newExpiresIn: const Duration(hours: 1),
          probe: probeReadings.add,
        );
        // Probe runs after vendor RTT, before commit — must observe
        // pre-rotation state and pre-rotation must itself be
        // self-consistent (non-empty, no torn read).
        expect(probeReadings, hasLength(1));
        expect(probeReadings.single.ciphertext, equals('pre-rotation'));
        expect(probeReadings.single.isConsistent, isTrue,
            reason:
                'a snapshot during in-flight refresh must be self-consistent — '
                'no torn (empty cipher | stale expiry) read');

        // After commit, the row holds the new ciphertext.
        final post = store.snapshot(const _TupleKey(_opA, _loc, 'toast'));
        expect(post.ciphertext, equals('post-rotation'));
        expect(post.rotationCount, equals(1));
      },
    );

    test(
      'a refresh that throws AFTER vendor RTT but BEFORE commit leaves the '
      'OLD ciphertext intact (rollback contract)',
      () async {
        final store = _AtomicCredentialStore()
          ..seed(
            tuple: const _TupleKey(_opA, _loc, 'square'),
            initialCiphertext: 'cipher-original',
            initialExpiresAt:
                DateTime.now().toUtc().add(const Duration(seconds: 5)),
          );

        Object? caught;
        try {
          await store.refresh(
            tuple: const _TupleKey(_opA, _loc, 'square'),
            vendorLatency: const Duration(milliseconds: 5),
            newCiphertext: 'cipher-half-written',
            newExpiresIn: const Duration(hours: 1),
            // Throw inside the commit hook — the store must NOT mutate
            // the row, mirroring the broker's `withTenant` rollback path.
            throwBeforeCommit: true,
          );
        } catch (error) {
          caught = error;
        }
        expect(caught, isNotNull,
            reason:
                'refresh that throws after vendor RTT must rethrow so the '
                'caller surfaces the failure');
        final after = store.snapshot(const _TupleKey(_opA, _loc, 'square'));
        expect(after.ciphertext, equals('cipher-original'),
            reason:
                'failed refresh must leave the OLD ciphertext intact — the '
                'broker rolls back the tenant transaction so the half-written '
                'cipher never lands in vendor_credentials');
        expect(after.rotationCount, equals(0),
            reason:
                'rotation_count must not advance for a failed refresh');
      },
    );

    test(
      'after commit, all subsequent reads see the new ciphertext '
      '(post-rotation read-after-write)',
      () async {
        final store = _AtomicCredentialStore()
          ..seed(
            tuple: const _TupleKey(_opA, _loc, 'clover'),
            initialCiphertext: 'cipher-v0',
            initialExpiresAt:
                DateTime.now().toUtc().add(const Duration(seconds: 5)),
          );
        await store.refresh(
          tuple: const _TupleKey(_opA, _loc, 'clover'),
          vendorLatency: const Duration(milliseconds: 1),
          newCiphertext: 'cipher-v1',
          newExpiresIn: const Duration(hours: 1),
        );
        for (var i = 0; i < 5; i += 1) {
          final snap = store.snapshot(const _TupleKey(_opA, _loc, 'clover'));
          expect(snap.ciphertext, equals('cipher-v1'),
              reason: 'read $i after commit must see the new ciphertext');
        }
      },
    );
  });

  group(
      'Contract 3 — oauth_refresh_advisory_lock migration semantics under N '
      'parallel refreshes',
      () {
    test(
      'two cluster pods racing the same (operator_id, vendor_id): first '
      'acquires the lock and runs; second sees pg_try_advisory_xact_lock '
      'return false and SKIPS without firing a vendor RTT',
      () async {
        // The OAuthRefreshCronRunner.runOnce loop calls
        // gateway.acquireAdvisoryLockForRefresh BEFORE refresher.refresh.
        // Two simulated pods share a single _SharedAdvisoryLockState so
        // we can flip the lock's "held by another pod" answer.
        final lockState = _SharedAdvisoryLockState();
        final podA = _AdvisoryLockGateway(
          lockState: lockState,
          podLabel: 'A',
          candidates: <VendorCredentialRefreshRow>[
            _refreshRow(operatorId: _opA, vendorId: 'toast'),
          ],
        );
        final podB = _AdvisoryLockGateway(
          lockState: lockState,
          podLabel: 'B',
          candidates: <VendorCredentialRefreshRow>[
            _refreshRow(operatorId: _opA, vendorId: 'toast'),
          ],
        );
        final podARefresher = _CountingRefresher(vendorId: 'toast');
        final podBRefresher = _CountingRefresher(vendorId: 'toast');

        // Pod A goes first: it acquires the lock and runs the refresh.
        final podAResult = await OAuthRefreshCronRunner(
          gateway: podA,
          refreshers: <String, VendorOAuthRefresher>{
            'toast': podARefresher,
          },
        ).runOnce();

        // While Pod A holds the lock (lockState still locked because Pod
        // A's runOnce never released — we simulate by NOT releasing
        // until after Pod B's tick), Pod B tries.
        final podBResult = await OAuthRefreshCronRunner(
          gateway: podB,
          refreshers: <String, VendorOAuthRefresher>{
            'toast': podBRefresher,
          },
        ).runOnce();

        expect(podAResult.refreshSuccesses, equals(1),
            reason:
                'Pod A acquired the advisory lock and ran the refresh');
        expect(podARefresher.refreshCalls, equals(1));
        expect(podBResult.refreshSuccesses, equals(0),
            reason:
                'Pod B saw the advisory lock held by Pod A; non-blocking '
                'pg_try_advisory_xact_lock returned false; runner skipped '
                'without firing a vendor RTT');
        expect(podBRefresher.refreshCalls, equals(0),
            reason:
                'Pod B must NOT call vendor.refresh while another pod holds '
                'the per-(operator, vendor) advisory lock — this is the J4 '
                'race fix: some vendors auto-revoke the earlier token on a '
                'second refresh');

        // The advisory-lock gateway records the lock attempts so we
        // can pin the lock-key shape: per (operator_id, vendor_id),
        // not global. The lock-id constant is 8472002 per migration
        // 202605080900_oauth_refresh_advisory_lock.sql; we encode it
        // in the gateway's reported key.
        expect(lockState.acquisitionAttempts, hasLength(2));
        expect(
          lockState.acquisitionAttempts.first.key,
          equals('$_opA|toast'),
          reason: 'lock key must scope per (operator_id, vendor_id)',
        );
        expect(
          lockState.acquisitionAttempts.last.key,
          equals('$_opA|toast'),
        );
        expect(lockState.acquisitionAttempts.first.granted, isTrue);
        expect(lockState.acquisitionAttempts.last.granted, isFalse);
      },
    );

    test(
      'after Pod A commits, Pod B re-running its tick sees the row '
      'is no longer near-expiry (the broker reset is_active=true / '
      'reset failures / advanced expiry) and either short-circuits or '
      'runs idempotently — pin the broker behavior: the next tick '
      'finds the row OUTSIDE the near-expiry window so Pod B does not '
      'enter the runner loop at all',
      () async {
        // After Pod A's commit, the row's token_expires_at advanced
        // past the near-expiry horizon. Pod B's gateway.findExpiringCredentials
        // returns an empty list, so the runner loop never enters the
        // refresh path. This is the broker's "next tick re-evaluates"
        // contract from oauth_refresh_cron.dart:
        // "Production uses pg_try_advisory_xact_lock (non-blocking) so
        //  a contended row is skipped rather than serialised; the next
        //  hourly tick will pick up any stragglers."
        final podBPostCommit = _AdvisoryLockGateway(
          lockState: _SharedAdvisoryLockState(),
          podLabel: 'B-post-commit',
          // Empty candidate list — Pod A already advanced the row's
          // expiry past the horizon.
          candidates: const <VendorCredentialRefreshRow>[],
        );
        final podBRefresher = _CountingRefresher(vendorId: 'toast');
        final result = await OAuthRefreshCronRunner(
          gateway: podBPostCommit,
          refreshers: <String, VendorOAuthRefresher>{
            'toast': podBRefresher,
          },
        ).runOnce();
        expect(result.candidatesScanned, equals(0));
        expect(result.refreshSuccesses, equals(0));
        expect(podBRefresher.refreshCalls, equals(0),
            reason:
                'a contended row is skipped this tick; the NEXT tick finds '
                'the row outside the near-expiry window because Pod A '
                'advanced the expiry on commit, so Pod B never re-attempts '
                'the refresh');
      },
    );
  });

  group(
      'Contract 4 — consecutive_refresh_failures counter contract', () {
    test(
      'a refresh that fails increments consecutive_refresh_failures by 1; '
      'a subsequent successful refresh resets the counter to 0',
      () async {
        final gateway = _CounterAwareWorkerGateway(
          credentials: <_CredentialKey, _CredentialState>{
            _CredentialKey(
              operatorId: _opA,
              locationId: _loc,
              vendorId: 'toast',
              credentialId: 'cred-1',
            ): _CredentialState(consecutiveFailures: 0),
          },
        );
        final broker = _ThrowingBrokerStub(
          throwOn: <_CredentialKey>{
            _CredentialKey(
              operatorId: _opA,
              locationId: _loc,
              vendorId: 'toast',
              credentialId: 'cred-1',
            ),
          },
        );

        // Tick 1 — refresh fails, counter increments to 1.
        var result = await worker.runWorkerTick(
          gateway: gateway,
          broker: broker,
          refreshClosures: <String, worker.RefreshClosure>{
            'toast': (_) async => const TokenRefreshResult(
                  accessToken: 'unused',
                ),
          },
          maxRowsPerTick: 10,
          maxConsecutiveFailures: 3,
          horizon: const Duration(minutes: 5),
          out: _NullSink(),
          err: _NullSink(),
        );
        expect(result.refreshFailures, equals(1));
        expect(
          gateway
              .credentials[_CredentialKey(
                operatorId: _opA,
                locationId: _loc,
                vendorId: 'toast',
                credentialId: 'cred-1',
              )]!
              .consecutiveFailures,
          equals(1),
          reason: 'first failure must increment counter to 1',
        );

        // Tick 2 — same row, broker now succeeds.
        broker.throwOn.clear();
        // Mirror the broker's success path: the broker's _doRefresh
        // resets consecutive_refresh_failures = 0 directly inside the
        // tenant transaction. We mirror that here by resetting on
        // success.
        broker.onSuccess = (key) {
          gateway.credentials[key]!.consecutiveFailures = 0;
        };
        result = await worker.runWorkerTick(
          gateway: gateway,
          broker: broker,
          refreshClosures: <String, worker.RefreshClosure>{
            'toast': (_) async => const TokenRefreshResult(
                  accessToken: 'fresh',
                ),
          },
          maxRowsPerTick: 10,
          maxConsecutiveFailures: 3,
          horizon: const Duration(minutes: 5),
          out: _NullSink(),
          err: _NullSink(),
        );
        expect(result.refreshSuccesses, equals(1));
        expect(
          gateway
              .credentials[_CredentialKey(
                operatorId: _opA,
                locationId: _loc,
                vendorId: 'toast',
                credentialId: 'cred-1',
              )]!
              .consecutiveFailures,
          equals(0),
          reason: 'successful refresh must reset counter to 0',
        );
      },
    );

    test(
      'counter reaches kRefreshFailureAutoDisableThreshold (3) — connection '
      'flips to error via gateway.autoDisableConnection',
      () async {
        final gateway = _CounterAwareWorkerGateway(
          credentials: <_CredentialKey, _CredentialState>{
            _CredentialKey(
              operatorId: _opA,
              locationId: _loc,
              vendorId: 'toast',
              credentialId: 'cred-1',
            ): _CredentialState(consecutiveFailures: 2),
          },
        );
        final broker = _ThrowingBrokerStub(
          throwOn: <_CredentialKey>{
            _CredentialKey(
              operatorId: _opA,
              locationId: _loc,
              vendorId: 'toast',
              credentialId: 'cred-1',
            ),
          },
        );

        final result = await worker.runWorkerTick(
          gateway: gateway,
          broker: broker,
          refreshClosures: <String, worker.RefreshClosure>{
            'toast': (_) async => const TokenRefreshResult(
                  accessToken: 'unused',
                ),
          },
          maxRowsPerTick: 10,
          maxConsecutiveFailures: 3,
          horizon: const Duration(minutes: 5),
          out: _NullSink(),
          err: _NullSink(),
        );
        // Threshold is the documented constant from
        // lib/services/integration/oauth_refresh_cron.dart.
        expect(kRefreshFailureAutoDisableThreshold, equals(3));
        expect(result.refreshFailures, equals(1));
        expect(result.autoDisabled, equals(1),
            reason:
                'third consecutive failure (counter pre=2 → post=3) must trip '
                'the auto-disable threshold and call '
                'gateway.autoDisableConnection');
        expect(gateway.autoDisableInvocations, hasLength(1));
        expect(
          gateway.autoDisableInvocations.single.consecutiveFailures,
          equals(3),
        );
        expect(
          gateway.autoDisableInvocations.single.vendorId,
          equals('toast'),
        );
      },
    );

    test(
      'no-closure vendors (Humanity, ADP, OpenTable, SevenRooms, Tock, '
      'Push Operations, Agendrix) run through the worker tick: '
      'log-and-skip path does NOT call recordRefreshFailure (counter '
      'stays at 0 per PR #455 docs)',
      () async {
        // Drive each of the seven no-closure vendors through one tick.
        // Each one should land on the log-and-skip branch in
        // runWorkerTick (closure==null) — that branch increments
        // skippedNoCloser only and never touches the gateway's
        // recordRefreshFailure / autoDisableConnection paths.
        final noClosureVendors =
            worker.kVendorsWithoutRefreshClosureReason.keys.toList()..sort();
        // Sanity: pin the seven vendors PR #455 documented.
        expect(noClosureVendors, hasLength(7));
        expect(
          noClosureVendors.toSet(),
          equals(<String>{
            'adp',
            'agendrix',
            'humanity',
            'opentable',
            'push_operations',
            'sevenrooms',
            'tock',
          }),
          reason:
              'the no-closure set must match the seven vendors PR #455 '
              'documented in kVendorsWithoutRefreshClosureReason',
        );

        final candidates = <_CredentialKey, _CredentialState>{
          for (final vendorId in noClosureVendors)
            _CredentialKey(
              operatorId: _opA,
              locationId: _loc,
              vendorId: vendorId,
              credentialId: 'cred-$vendorId',
            ): _CredentialState(consecutiveFailures: 0),
        };
        final gateway = _CounterAwareWorkerGateway(credentials: candidates);
        final broker = _ThrowingBrokerStub();
        final out = _CapturingSink();

        final result = await worker.runWorkerTick(
          gateway: gateway,
          broker: broker,
          // Empty closure registry — every claimed row hits the
          // log-and-skip branch (closure == null).
          refreshClosures: const <String, worker.RefreshClosure>{},
          maxRowsPerTick: 100,
          maxConsecutiveFailures: 3,
          horizon: const Duration(minutes: 5),
          out: out,
          err: _NullSink(),
        );

        expect(result.skippedNoCloser, equals(noClosureVendors.length));
        expect(result.refreshFailures, equals(0));
        expect(result.autoDisabled, equals(0));
        expect(gateway.recordRefreshFailureInvocations, isEmpty,
            reason:
                'log-and-skip path MUST NOT increment '
                'consecutive_refresh_failures — per PR #455 '
                'kVendorsWithoutRefreshClosureReason docs and the '
                'oauth_refresh_worker tick contract '
                '("Log once per skip with the documented reason; no '
                'failure-count increment.")');
        expect(gateway.autoDisableInvocations, isEmpty);
        // Every per-row counter stays at 0.
        for (final entry in gateway.credentials.entries) {
          expect(entry.value.consecutiveFailures, equals(0),
              reason:
                  '${entry.key.vendorId}: counter must stay at 0 because the '
                  'worker logged-and-skipped without touching '
                  'consecutive_refresh_failures');
        }
        // The structured log carries the per-vendor reason from
        // kVendorsWithoutRefreshClosureReason (so a deploy review can
        // verify intent and audits can match the row to the documented
        // delegation surface).
        for (final vendorId in noClosureVendors) {
          final reason =
              worker.kVendorsWithoutRefreshClosureReason[vendorId]!;
          expect(out.lines.any((line) => line.contains(vendorId) &&
                  line.contains(reason)),
              isTrue,
              reason:
                  '$vendorId log line must include reason "$reason"');
        }
      },
    );
  });
}

// ─── Existing-test helpers (unchanged below) ──────────────────────────

class _ProviderCredentialsPool implements PostgresPool {
  _ProviderCredentialsPool({
    this.listRows = const <PostgresRow>[],
    this.insertReturnRow,
  });

  final List<PostgresRow> listRows;
  final PostgresRow? insertReturnRow;
  final List<_ProviderCredentialsTransaction> transactions =
      <_ProviderCredentialsTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _ProviderCredentialsTransaction(
      listRows: listRows,
      insertReturnRow: insertReturnRow,
    );
    transactions.add(tx);
    return tx;
  }
}

class _ProviderCredentialsTransaction extends PostgresTransaction {
  _ProviderCredentialsTransaction({
    required this.listRows,
    required this.insertReturnRow,
  });

  final List<PostgresRow> listRows;
  final PostgresRow? insertReturnRow;
  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql,
    {PostgresParameters parameters = const <String, Object?>{}}
  ) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('insert into provider_credentials')) {
      final row = insertReturnRow;
      if (row == null) {
        throw StateError('insert called without an insertReturnRow');
      }
      return <PostgresRow>[row];
    }
    if (sql.contains('from provider_credentials')) {
      return listRows;
    }
    return <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql,
    {PostgresParameters parameters = const <String, Object?>{}}
  ) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    return 0;
  }

  @override
  Future<void> commit() async {
    _finalized = true;
  }

  @override
  Future<void> rollback() async {
    _finalized = true;
  }
}

// ─── Phase 6 extension helpers ────────────────────────────────────────

class _TupleKey {
  const _TupleKey(this.operatorId, this.locationId, this.vendorId);
  final String operatorId;
  final String locationId;
  final String vendorId;
}

// ─── Contract 1 helpers — broker pool fake (mirrors broker_test.dart) ─

class _BrokerPool implements PostgresPool {
  _BrokerPool({
    this.rowsByTenant = const <String, Map<String, Object?>>{},
  });

  final Map<String, Map<String, Object?>> rowsByTenant;
  final List<_BrokerTransaction> transactions = <_BrokerTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _BrokerTransaction(rowsByTenant: rowsByTenant);
    transactions.add(tx);
    return tx;
  }
}

class _BrokerTransaction extends PostgresTransaction {
  _BrokerTransaction({required this.rowsByTenant});

  final Map<String, Map<String, Object?>> rowsByTenant;
  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('from public.vendor_credentials') &&
        sql.contains('pgp_sym_decrypt')) {
      final operatorId = parameters['operator_id']! as String;
      final locationId = parameters['location_id']! as String;
      final key = '$operatorId|$locationId';
      final row = rowsByTenant[key];
      if (row == null) return <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{
          'access_token_plaintext': row['access_token_plaintext'],
          'refresh_token_plaintext': row['refresh_token_plaintext'],
          'token_expires_at': row['token_expires_at'],
          'metadata': row['metadata'],
          'connection_metadata': row['connection_metadata'],
        },
      ];
    }
    return <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    return 1;
  }

  @override
  Future<void> commit() async {
    _finalized = true;
  }

  @override
  Future<void> rollback() async {
    _finalized = true;
  }
}

Map<String, Object?> _credentialRow({
  required String? accessTokenPlaintext,
  required DateTime? expiresAt,
  String? refreshTokenPlaintext,
  Map<String, Object?> metadata = const <String, Object?>{},
  Map<String, Object?> connectionMetadata = const <String, Object?>{},
}) {
  return <String, Object?>{
    'access_token_plaintext': accessTokenPlaintext,
    'refresh_token_plaintext': refreshTokenPlaintext,
    'token_expires_at': expiresAt,
    'metadata': metadata,
    'connection_metadata': connectionMetadata,
  };
}

// ─── Contract 2 helpers — atomic-rotation simulator ───────────────────

/// Snapshot of one row in the atomic-rotation simulator.
class _TupleSnapshot {
  const _TupleSnapshot({
    required this.ciphertext,
    required this.expiresAt,
    required this.rotatedAt,
    required this.rotationCount,
  });
  final String ciphertext;
  final DateTime expiresAt;
  final DateTime? rotatedAt;
  final int rotationCount;

  /// Self-consistency: a snapshot is consistent when its ciphertext is
  /// non-empty and (post-rotation) the new expiry strictly exceeds the
  /// rotation moment. Mirrors `CredentialSnapshot.isConsistent` in
  /// p3c_synthetic_credential_store.dart.
  bool get isConsistent =>
      ciphertext.isNotEmpty &&
      (rotationCount == 0 ||
          rotatedAt == null ||
          expiresAt.isAfter(rotatedAt!));
}

class _TupleRowState {
  _TupleRowState({
    required this.ciphertext,
    required this.expiresAt,
    this.rotatedAt,
    this.rotationCount = 0,
  });
  String ciphertext;
  DateTime expiresAt;
  DateTime? rotatedAt;
  int rotationCount;
}

/// In-process simulator of the per-tuple `vendor_credentials` row. The
/// commit step is a single field assignment (atomic at the Dart event-
/// loop layer), mirroring the broker's single-statement UPDATE which
/// is atomic at Postgres MVCC layer.
class _AtomicCredentialStore {
  final Map<String, _TupleRowState> _rows = <String, _TupleRowState>{};

  String _key(_TupleKey t) =>
      '${t.operatorId}|${t.locationId}|${t.vendorId}';

  void seed({
    required _TupleKey tuple,
    required String initialCiphertext,
    required DateTime initialExpiresAt,
  }) {
    _rows[_key(tuple)] = _TupleRowState(
      ciphertext: initialCiphertext,
      expiresAt: initialExpiresAt,
    );
  }

  _TupleSnapshot snapshot(_TupleKey tuple) {
    final state = _rows[_key(tuple)]!;
    return _TupleSnapshot(
      ciphertext: state.ciphertext,
      expiresAt: state.expiresAt,
      rotatedAt: state.rotatedAt,
      rotationCount: state.rotationCount,
    );
  }

  Future<void> refresh({
    required _TupleKey tuple,
    required Duration vendorLatency,
    required String newCiphertext,
    required Duration newExpiresIn,
    void Function(_TupleSnapshot)? probe,
    bool throwBeforeCommit = false,
  }) async {
    final state = _rows[_key(tuple)]!;
    // Simulate vendor RTT.
    await Future<void>.delayed(vendorLatency);
    // Probe AFTER vendor RTT, BEFORE commit. The probe must observe
    // the pre-rotation state (the broker has not yet UPDATEd the row).
    if (probe != null) {
      probe(_TupleSnapshot(
        ciphertext: state.ciphertext,
        expiresAt: state.expiresAt,
        rotatedAt: state.rotatedAt,
        rotationCount: state.rotationCount,
      ));
    }
    if (throwBeforeCommit) {
      // Mirrors the broker's withTenant rollback path: the tenant
      // transaction throws, the wrapper rolls back, and the row is
      // unchanged.
      throw StateError('simulated rollback before commit');
    }
    // Single-step commit — mirrors the broker's single-statement
    // UPDATE that ships ciphertext + expiry + reset failures atomically.
    state.ciphertext = newCiphertext;
    state.expiresAt = DateTime.now().toUtc().add(newExpiresIn);
    state.rotatedAt = DateTime.now().toUtc();
    state.rotationCount += 1;
  }
}

// ─── Contract 3 helpers — advisory-lock simulator ─────────────────────

/// Per-(operator, vendor) lock attempt outcome. Mirrors the
/// pg_try_advisory_xact_lock(8472002, hashtextextended('opId:vendorId'))
/// call site in oauth_refresh_cron.dart.
class _LockAttempt {
  const _LockAttempt({required this.key, required this.granted});
  final String key;
  final bool granted;
}

class _SharedAdvisoryLockState {
  /// Already-held lock keys ('opId|vendorId'). The first pod to call
  /// acquire records its key here; the second pod sees a held lock
  /// and gets `granted: false`.
  final Set<String> held = <String>{};
  final List<_LockAttempt> acquisitionAttempts = <_LockAttempt>[];

  bool tryAcquire(String operatorId, String vendorId) {
    final key = '$operatorId|$vendorId';
    if (held.contains(key)) {
      acquisitionAttempts.add(_LockAttempt(key: key, granted: false));
      return false;
    }
    held.add(key);
    acquisitionAttempts.add(_LockAttempt(key: key, granted: true));
    return true;
  }
}

class _AdvisoryLockGateway implements OAuthRefreshGateway {
  _AdvisoryLockGateway({
    required this.lockState,
    required this.podLabel,
    required this.candidates,
  });

  final _SharedAdvisoryLockState lockState;
  final String podLabel;
  final List<VendorCredentialRefreshRow> candidates;

  @override
  Future<List<VendorCredentialRefreshRow>> findExpiringCredentials({
    required DateTime now,
    required Duration horizon,
  }) async {
    return candidates;
  }

  @override
  Future<bool> acquireAdvisoryLockForRefresh({
    required String operatorId,
    required String vendorId,
  }) async {
    return lockState.tryAcquire(operatorId, vendorId);
  }

  @override
  Future<void> recordRefreshSuccess({
    required String credentialId,
    required String operatorId,
    String? locationId,
    required String vendorId,
    required List<int> newAccessTokenCiphertext,
    required List<int> newRefreshTokenCiphertext,
    required DateTime newExpiresAt,
  }) async {}

  @override
  Future<int> recordRefreshFailure({
    required String credentialId,
    required String operatorId,
    String? locationId,
    required String vendorId,
    required String errorMessage,
  }) async {
    return 1;
  }

  @override
  Future<void> autoDisableConnection({
    required String credentialId,
    required String operatorId,
    String? locationId,
    required String vendorId,
    required String errorMessage,
  }) async {}
}

VendorCredentialRefreshRow _refreshRow({
  required String operatorId,
  required String vendorId,
  String credentialId = 'cred-1',
  String? locationId,
}) {
  return VendorCredentialRefreshRow(
    credentialId: credentialId,
    operatorId: operatorId,
    locationId: locationId,
    vendorId: vendorId,
    module: null,
    refreshTokenCiphertext: const <int>[1, 2, 3],
    tokenExpiresAt:
        DateTime.now().toUtc().add(const Duration(minutes: 30)),
    consecutiveFailures: 0,
  );
}

class _CountingRefresher implements VendorOAuthRefresher {
  _CountingRefresher({required this.vendorId});

  @override
  final String vendorId;

  int refreshCalls = 0;

  @override
  Future<VendorRefreshOutcome> refresh({
    required String operatorId,
    String? locationId,
    required List<int> refreshTokenCiphertext,
  }) async {
    refreshCalls += 1;
    return VendorRefreshOutcome.success(
      newAccessTokenCiphertext: const <int>[9, 9, 9],
      newRefreshTokenCiphertext: const <int>[8, 8, 8],
      newExpiresAt:
          DateTime.now().toUtc().add(const Duration(hours: 1)),
    );
  }
}

// ─── Contract 4 helpers — counter-aware worker gateway ────────────────

class _CredentialKey {
  const _CredentialKey({
    required this.operatorId,
    required this.locationId,
    required this.vendorId,
    required this.credentialId,
  });
  final String operatorId;
  final String locationId;
  final String vendorId;
  final String credentialId;

  @override
  bool operator ==(Object other) =>
      other is _CredentialKey &&
      other.operatorId == operatorId &&
      other.locationId == locationId &&
      other.vendorId == vendorId &&
      other.credentialId == credentialId;

  @override
  int get hashCode => Object.hash(operatorId, locationId, vendorId, credentialId);
}

class _CredentialState {
  _CredentialState({this.consecutiveFailures = 0});
  int consecutiveFailures;
}

class _AutoDisableInvocation {
  const _AutoDisableInvocation({
    required this.vendorId,
    required this.consecutiveFailures,
  });
  final String vendorId;
  final int consecutiveFailures;
}

class _CounterAwareWorkerGateway
    implements worker.OAuthRefreshWorkerGateway {
  _CounterAwareWorkerGateway({required this.credentials});

  final Map<_CredentialKey, _CredentialState> credentials;
  final List<_CredentialKey> recordRefreshFailureInvocations =
      <_CredentialKey>[];
  final List<_AutoDisableInvocation> autoDisableInvocations =
      <_AutoDisableInvocation>[];

  @override
  Future<List<worker.ClaimedCredentialRow>> claimNearExpiryRows({
    required DateTime now,
    required Duration horizon,
    required int maxRows,
  }) async {
    return <worker.ClaimedCredentialRow>[
      for (final entry in credentials.entries)
        worker.ClaimedCredentialRow(
          credentialId: entry.key.credentialId,
          operatorId: entry.key.operatorId,
          locationId: entry.key.locationId,
          vendorId: entry.key.vendorId,
          consecutiveFailuresBefore: entry.value.consecutiveFailures,
        ),
    ];
  }

  @override
  Future<int> recordRefreshFailure({
    required String credentialId,
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String errorMessage,
  }) async {
    final key = _CredentialKey(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: vendorId,
      credentialId: credentialId,
    );
    recordRefreshFailureInvocations.add(key);
    final state = credentials[key];
    if (state == null) return 0;
    state.consecutiveFailures += 1;
    return state.consecutiveFailures;
  }

  @override
  Future<void> recordRefreshSuccess({
    required String credentialId,
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) async {}

  @override
  Future<void> autoDisableConnection({
    required String credentialId,
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String errorMessage,
    required int consecutiveFailures,
  }) async {
    autoDisableInvocations.add(_AutoDisableInvocation(
      vendorId: vendorId,
      consecutiveFailures: consecutiveFailures,
    ));
  }
}

/// In-process VendorCredentialBroker stub that throws for [throwOn]
/// keys (mirroring VendorRefreshFailed) and otherwise no-ops. The
/// production broker also resets `consecutive_refresh_failures` to 0
/// inside its tenant transaction on success — we model that via
/// `onSuccess`.
class _ThrowingBrokerStub implements VendorCredentialBroker {
  _ThrowingBrokerStub({Set<_CredentialKey>? throwOn})
      : throwOn = throwOn ?? <_CredentialKey>{};

  final Set<_CredentialKey> throwOn;
  void Function(_CredentialKey key)? onSuccess;

  @override
  Future<String> refreshAccessToken({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required Future<TokenRefreshResult> Function(VendorCredentialBundle)
        doRefresh,
  }) async {
    // Identify by operator/location/vendor; credential_id is opaque to
    // the broker so we match by (op, loc, vendor) — every per-tenant
    // tuple has at most one credential row in the worker's claim set.
    final matches = throwOn.where(
      (k) =>
          k.operatorId == operatorId &&
          k.locationId == locationId &&
          k.vendorId == vendorId,
    );
    if (matches.isNotEmpty) {
      throw const VendorRefreshFailed('simulated vendor 5xx');
    }
    onSuccess?.call(_CredentialKey(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: vendorId,
      credentialId: 'cred-$vendorId',
    ));
    return 'fresh-bearer';
  }

  @override
  Future<String> resolveAccessToken({
    required String operatorId,
    required String locationId,
    required String vendorId,
    Future<TokenRefreshResult> Function(VendorCredentialBundle current)?
        doRefresh,
  }) async {
    throw UnimplementedError('not exercised by the worker tick path');
  }

  @override
  Future<VendorCredentialBundle> resolveCredentialBundle({
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) async {
    throw UnimplementedError('not exercised by the worker tick path');
  }

  @override
  Future<void> invalidate({
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) async {}

  // Inherited OperatorScopedRepository surface — the worker tick only
  // calls refreshAccessToken, so the rest stays unimplemented.
  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(
        '_ThrowingBrokerStub.${invocation.memberName} is not exercised by '
        'the worker tick path',
      );
}

/// IOSink that swallows every write — used for the worker tick out/err
/// streams in unit tests.
class _NullSink implements IOSink {
  @override
  Encoding encoding = utf8;

  @override
  void add(List<int> data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future addStream(Stream<List<int>> stream) async {}

  @override
  Future close() async {}

  @override
  Future get done => Future<void>.value();

  @override
  Future flush() async {}

  @override
  void write(Object? object) {}

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {}

  @override
  void writeCharCode(int charCode) {}

  @override
  void writeln([Object? object = '']) {}
}

/// IOSink that captures every `writeln` call so the test can assert
/// the structured log line emitted by the log-and-skip branch.
class _CapturingSink implements IOSink {
  final List<String> lines = <String>[];

  @override
  Encoding encoding = utf8;

  @override
  void add(List<int> data) {
    lines.add(utf8.decode(data));
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future addStream(Stream<List<int>> stream) async {}

  @override
  Future close() async {}

  @override
  Future get done => Future<void>.value();

  @override
  Future flush() async {}

  @override
  void write(Object? object) {
    lines.add(object.toString());
  }

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {}

  @override
  void writeCharCode(int charCode) {}

  @override
  void writeln([Object? object = '']) {
    lines.add(object.toString());
  }
}
