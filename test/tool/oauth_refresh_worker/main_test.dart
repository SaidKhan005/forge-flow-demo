// Phase 8 — oauth_refresh_worker tests.
//
// Covers the five scenarios called out in the slice prompt, against
// in-memory fakes (no live Postgres, no live vendor HTTP):
//
//   * happy refresh — claim → broker.refreshAccessToken called →
//     recordRefreshSuccess → success counter advances.
//   * SKIP LOCKED contention — two parallel ticks against a single
//     available row; only one claims it (the in-memory fake mirrors
//     the migration's `FOR UPDATE SKIP LOCKED` semantics).
//   * cap-and-disable — a row that fails 3 times trips
//     autoDisableConnection exactly once.
//   * vendor without refresh closure — the row is logged-and-skipped
//     (skippedNoCloser counter advances); no failure-count
//     increment, no autoDisable, no broker call.
//   * SIGTERM mid-tick — the loop's shouldStop hook fires between
//     rows so the second row in the same tick is not processed.
//   * production refresh-closure registry — vendors with optional
//     ProxyConfig-style app credentials register only when their env
//     vars are present; missing vendors land on the
//     disabled-missing-secrets list; ALL claimed rows for unsupported
//     or disabled vendors are logged-and-skipped at run time.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/_common/vendor_credential_broker.dart';
import 'package:http/http.dart' as http;

import '../../../tool/oauth_refresh_worker/main.dart';

const String _opIdA = '11111111-1111-4111-8111-111111111111';
const String _locIdA = '22222222-2222-4222-8222-222222222222';
const String _credIdA = '33333333-3333-4333-8333-333333333333';
const String _credIdB = '44444444-4444-4444-8444-444444444444';
const String _vendorWithCloser = 'lightspeed_lsk';
const String _vendorWithoutCloser = 'tock';

void main() {
  group('runWorkerTick', () {
    test(
      'happy path: claim → broker.refreshAccessToken → recordRefreshSuccess',
      () async {
        final gateway = _FakeGateway()
          ..addClaimable(
            ClaimedCredentialRow(
              credentialId: _credIdA,
              operatorId: _opIdA,
              locationId: _locIdA,
              vendorId: _vendorWithCloser,
              consecutiveFailuresBefore: 0,
            ),
          );
        final broker = _RecordingBroker();
        final closure = _AlwaysSucceedClosure();

        final result = await runWorkerTick(
          gateway: gateway,
          broker: broker,
          refreshClosures: <String, RefreshClosure>{
            _vendorWithCloser: closure.call,
          },
          maxRowsPerTick: 50,
          maxConsecutiveFailures: 3,
          horizon: const Duration(minutes: 5),
        );

        expect(result.candidatesScanned, 1);
        expect(result.refreshSuccesses, 1);
        expect(result.refreshFailures, 0);
        expect(result.skippedNoCloser, 0);
        expect(result.autoDisabled, 0);
        expect(broker.refreshCalls, 1);
        expect(broker.lastRefreshArgs?.vendorId, _vendorWithCloser);
        expect(gateway.recordedSuccesses, hasLength(1));
        expect(gateway.recordedSuccesses.single.credentialId, _credIdA);
        expect(gateway.recordedFailures, isEmpty);
        expect(gateway.autoDisabledRows, isEmpty);
      },
    );

    test(
      'SKIP LOCKED: only one of two parallel ticks claims a single row',
      () async {
        // The fake gateway models `FOR UPDATE SKIP LOCKED`: each
        // enqueued row is handed out exactly once across all
        // concurrent claimers.
        final gateway = _FakeGateway()
          ..addClaimable(
            ClaimedCredentialRow(
              credentialId: _credIdA,
              operatorId: _opIdA,
              locationId: _locIdA,
              vendorId: _vendorWithCloser,
              consecutiveFailuresBefore: 0,
            ),
          );
        final brokerA = _RecordingBroker();
        final brokerB = _RecordingBroker();
        final closureA = _AlwaysSucceedClosure();
        final closureB = _AlwaysSucceedClosure();

        final futures = <Future<WorkerTickResult>>[
          runWorkerTick(
            gateway: gateway,
            broker: brokerA,
            refreshClosures: <String, RefreshClosure>{
              _vendorWithCloser: closureA.call,
            },
            maxRowsPerTick: 50,
            maxConsecutiveFailures: 3,
            horizon: const Duration(minutes: 5),
          ),
          runWorkerTick(
            gateway: gateway,
            broker: brokerB,
            refreshClosures: <String, RefreshClosure>{
              _vendorWithCloser: closureB.call,
            },
            maxRowsPerTick: 50,
            maxConsecutiveFailures: 3,
            horizon: const Duration(minutes: 5),
          ),
        ];
        final results = await Future.wait(futures);

        final totalSuccesses = results.fold<int>(
          0,
          (acc, r) => acc + r.refreshSuccesses,
        );
        expect(
          totalSuccesses,
          1,
          reason:
              'SKIP LOCKED: a single available row must be refreshed exactly once '
              'across two concurrent worker ticks',
        );
        expect(brokerA.refreshCalls + brokerB.refreshCalls, 1);
      },
    );

    test(
      'cap-and-disable: 3 consecutive failures trips autoDisable once',
      () async {
        // Each tick claims the same single row whose failure count is
        // incremented by 1 per failure. We drive the gateway directly:
        // the worker's loop is called three times.
        final gateway = _FakeGateway();
        final broker = _AlwaysFailBroker();
        final closure = _AlwaysSucceedClosure();

        final config = _Config(
          maxRowsPerTick: 50,
          maxConsecutiveFailures: 3,
          horizon: const Duration(minutes: 5),
        );

        for (var i = 1; i <= 3; i += 1) {
          gateway.addClaimable(
            ClaimedCredentialRow(
              credentialId: _credIdA,
              operatorId: _opIdA,
              locationId: _locIdA,
              vendorId: _vendorWithCloser,
              consecutiveFailuresBefore: i - 1,
            ),
          );
          await runWorkerTick(
            gateway: gateway,
            broker: broker,
            refreshClosures: <String, RefreshClosure>{
              _vendorWithCloser: closure.call,
            },
            maxRowsPerTick: config.maxRowsPerTick,
            maxConsecutiveFailures: config.maxConsecutiveFailures,
            horizon: config.horizon,
          );
        }

        expect(gateway.recordedFailures, hasLength(3));
        expect(
          gateway.autoDisabledRows,
          hasLength(1),
          reason:
              'autoDisable fires exactly once on the post-increment count >= '
              'threshold; subsequent ticks would no longer claim the row '
              'because is_active=false in the real schema',
        );
        final disabled = gateway.autoDisabledRows.single;
        expect(disabled.credentialId, _credIdA);
        expect(disabled.consecutiveFailures, 3);
        expect(disabled.errorMessage, contains('boom'));
      },
    );

    test(
      'vendor without refresh closure: row is logged-and-skipped',
      () async {
        // The fake gateway returns a row for `tock` (no closure). The
        // worker must NOT increment failures, NOT call broker, and
        // NOT auto-disable. The skippedNoCloser counter advances.
        final gateway = _FakeGateway()
          ..addClaimable(
            ClaimedCredentialRow(
              credentialId: _credIdB,
              operatorId: _opIdA,
              locationId: _locIdA,
              vendorId: _vendorWithoutCloser,
              consecutiveFailuresBefore: 0,
            ),
          );
        final broker = _RecordingBroker();

        final result = await runWorkerTick(
          gateway: gateway,
          broker: broker,
          // Empty registry — no closure for `tock`.
          refreshClosures: const <String, RefreshClosure>{},
          maxRowsPerTick: 50,
          maxConsecutiveFailures: 3,
          horizon: const Duration(minutes: 5),
        );

        expect(result.skippedNoCloser, 1);
        expect(result.refreshSuccesses, 0);
        expect(result.refreshFailures, 0);
        expect(result.autoDisabled, 0);
        expect(broker.refreshCalls, 0);
        expect(gateway.recordedSuccesses, isEmpty);
        expect(gateway.recordedFailures, isEmpty);
        expect(gateway.autoDisabledRows, isEmpty);
        expect(
          kVendorsWithoutRefreshClosure,
          contains(_vendorWithoutCloser),
          reason:
              'tock is in the documented coverage list of vendors without an '
              'OAuth refresh closure',
        );
      },
    );

    test('shouldStop fires between rows', () async {
      // Two rows in one tick. shouldStop returns true after the first
      // row is processed; the second row must not be touched.
      final gateway = _FakeGateway()
        ..addClaimable(
          ClaimedCredentialRow(
            credentialId: _credIdA,
            operatorId: _opIdA,
            locationId: _locIdA,
            vendorId: _vendorWithCloser,
            consecutiveFailuresBefore: 0,
          ),
        )
        ..addClaimable(
          ClaimedCredentialRow(
            credentialId: _credIdB,
            operatorId: _opIdA,
            locationId: _locIdA,
            vendorId: _vendorWithCloser,
            consecutiveFailuresBefore: 0,
          ),
        );
      final broker = _RecordingBroker();
      final closure = _AlwaysSucceedClosure();

      var brokerCallCount = 0;
      final result = await runWorkerTick(
        gateway: gateway,
        broker: _StopAfterFirstBroker(broker, () {
          brokerCallCount += 1;
        }),
        refreshClosures: <String, RefreshClosure>{
          _vendorWithCloser: closure.call,
        },
        maxRowsPerTick: 50,
        maxConsecutiveFailures: 3,
        horizon: const Duration(minutes: 5),
        shouldStop: () => brokerCallCount >= 1,
      );

      expect(result.candidatesScanned, 2);
      expect(
        result.refreshSuccesses,
        1,
        reason:
            'shouldStop fires after the first broker call; second row is left '
            'for the next tick',
      );
    });
  });

  group('buildProductionRefreshClosures', () {
    test(
      'registers all 11 closures when every optional credential set '
      'is present',
      () {
        final env = <String, String>{
          // Aloha NCR Voyix bundle (binder-style 4 secrets gate).
          OAuthRefreshWorkerVendorEnvNames.alohaNcrVoyixClientId: 'aloha-id',
          OAuthRefreshWorkerVendorEnvNames.alohaNcrVoyixClientSecret:
              'aloha-secret',
          OAuthRefreshWorkerVendorEnvNames.alohaNcrVoyixApplicationKey:
              'aloha-app-key',
          OAuthRefreshWorkerVendorEnvNames.alohaNcrVoyixOrganizationId:
              'aloha-org-id',
          // Square / Clover / Humanity / QBT / 7shifts / Libro pairs.
          OAuthRefreshWorkerVendorEnvNames.squareClientId: 'sq-id',
          OAuthRefreshWorkerVendorEnvNames.squareClientSecret: 'sq-secret',
          OAuthRefreshWorkerVendorEnvNames.cloverAppId: 'clover-app-id',
          OAuthRefreshWorkerVendorEnvNames.humanityClientId: 'hum-id',
          OAuthRefreshWorkerVendorEnvNames.humanityClientSecret: 'hum-secret',
          OAuthRefreshWorkerVendorEnvNames.quickBooksTimeClientId: 'qbt-id',
          OAuthRefreshWorkerVendorEnvNames.quickBooksTimeClientSecret:
              'qbt-secret',
          OAuthRefreshWorkerVendorEnvNames.sevenShiftsClientId: '7s-id',
          OAuthRefreshWorkerVendorEnvNames.sevenShiftsClientSecret: '7s-secret',
          OAuthRefreshWorkerVendorEnvNames.libroClientId: 'libro-id',
          OAuthRefreshWorkerVendorEnvNames.libroClientSecret: 'libro-secret',
        };
        final result = buildProductionRefreshClosures(
          env: env,
          httpClient: _StubHttpClient(),
        );

        expect(
          result.wiredVendorIds,
          equals(<String>[
            'aloha_ncr_voyix',
            'clover',
            'humanity',
            'libro',
            'lightspeed_lsk',
            'oracle_micros_simphony',
            'quickbooks_time',
            'revel',
            'seven_shifts',
            'square',
            'toast',
          ]),
          reason:
              'all 11 production OAuth refresh factories must register '
              'when their app-credential env names are non-blank',
        );
        expect(result.disabledVendorIds, isEmpty);
        // The six unsupported vendors stay outside the registry.
        for (final id in kVendorsWithoutRefreshClosure) {
          expect(
            result.registry.containsKey(id),
            isFalse,
            reason: '$id is unsupported and must not be in the registry',
          );
        }
      },
    );

    test(
      'unconditionally-wired vendors register without any env',
      () {
        // Toast / Lightspeed LSK / Oracle MICROS Simphony / Revel pull
        // credentials from bundle metadata at refresh time, so they
        // wire without any boot-env app credentials.
        final result = buildProductionRefreshClosures(
          env: const <String, String>{},
          httpClient: _StubHttpClient(),
        );
        expect(
          result.wiredVendorIds,
          containsAll(<String>[
            'toast',
            'lightspeed_lsk',
            'oracle_micros_simphony',
            'revel',
          ]),
        );
        expect(
          result.disabledVendorIds.keys,
          containsAll(<String>[
            'aloha_ncr_voyix',
            'square',
            'clover',
            'humanity',
            'quickbooks_time',
            'seven_shifts',
            'libro',
          ]),
          reason:
              'every gated vendor must land on the disabled list when '
              'its app-credential env names are absent — same warn-disable '
              'shape as the binder',
        );
      },
    );

    test(
      'partial Aloha credentials still mark Aloha disabled',
      () {
        // Only client_id + client_secret set; application_key and
        // organization_id absent. Aloha must NOT register because all
        // four pieces are required for a valid bundle.
        final env = <String, String>{
          OAuthRefreshWorkerVendorEnvNames.alohaNcrVoyixClientId: 'aloha-id',
          OAuthRefreshWorkerVendorEnvNames.alohaNcrVoyixClientSecret:
              'aloha-secret',
        };
        final result = buildProductionRefreshClosures(
          env: env,
          httpClient: _StubHttpClient(),
        );
        expect(result.registry.containsKey('aloha_ncr_voyix'), isFalse);
        expect(
          result.disabledVendorIds['aloha_ncr_voyix'],
          equals('aloha_ncr_voyix_credentials_missing'),
        );
      },
    );

    test(
      'a blank env value is treated the same as missing',
      () {
        // Cloud Run / Secret Manager sometimes mounts an empty string
        // when a secret is undefined; the gate must reject blank
        // values just like the binder's `hasSecretFor` check.
        final env = <String, String>{
          OAuthRefreshWorkerVendorEnvNames.squareClientId: '',
          OAuthRefreshWorkerVendorEnvNames.squareClientSecret: '   ',
        };
        final result = buildProductionRefreshClosures(
          env: env,
          httpClient: _StubHttpClient(),
        );
        expect(result.registry.containsKey('square'), isFalse);
        expect(
          result.disabledVendorIds['square'],
          equals('square_app_credentials_missing'),
        );
      },
    );

    test(
      'tick: claimed row for a disabled vendor is logged-and-skipped — '
      'no broker call, no failure-count increment',
      () async {
        // Build a registry from an env map that disables `square` and
        // `humanity`. Then enqueue a Square claim and confirm the
        // worker logs-and-skips it, identical to the
        // unsupported-vendor path.
        final closures = buildProductionRefreshClosures(
          env: const <String, String>{},
          httpClient: _StubHttpClient(),
        ).registry;
        expect(closures.containsKey('square'), isFalse);

        final gateway = _FakeGateway()
          ..addClaimable(
            ClaimedCredentialRow(
              credentialId: _credIdA,
              operatorId: _opIdA,
              locationId: _locIdA,
              vendorId: 'square',
              consecutiveFailuresBefore: 0,
            ),
          );
        final broker = _RecordingBroker();

        final result = await runWorkerTick(
          gateway: gateway,
          broker: broker,
          refreshClosures: closures,
          maxRowsPerTick: 50,
          maxConsecutiveFailures: 3,
          horizon: const Duration(minutes: 5),
        );

        expect(result.skippedNoCloser, 1);
        expect(result.refreshSuccesses, 0);
        expect(result.refreshFailures, 0);
        expect(broker.refreshCalls, 0);
        expect(gateway.recordedFailures, isEmpty);
        expect(gateway.autoDisabledRows, isEmpty);
      },
    );
  });
}

/// Minimal [http.Client] stub. The closure factories only construct
/// closures (deferred network calls) at build time; the stubbed
/// `Client` is never actually invoked in these unit tests.
class _StubHttpClient implements http.Client {
  @override
  void close() {}

  @override
  noSuchMethod(Invocation invocation) {
    throw StateError(
      '_StubHttpClient.${invocation.memberName} called; closure builders '
      'should not perform live HTTP requests during unit tests',
    );
  }
}

// ─── Fakes ──────────────────────────────────────────────────────────

class _Config {
  _Config({
    required this.maxRowsPerTick,
    required this.maxConsecutiveFailures,
    required this.horizon,
  });

  final int maxRowsPerTick;
  final int maxConsecutiveFailures;
  final Duration horizon;
}

class _FakeGateway implements OAuthRefreshWorkerGateway {
  final List<ClaimedCredentialRow> _claimable = <ClaimedCredentialRow>[];
  final List<_RecordedSuccess> recordedSuccesses = <_RecordedSuccess>[];
  final List<_RecordedFailure> recordedFailures = <_RecordedFailure>[];
  final List<_AutoDisabledRow> autoDisabledRows = <_AutoDisabledRow>[];

  void addClaimable(ClaimedCredentialRow row) {
    _claimable.add(row);
  }

  @override
  Future<List<ClaimedCredentialRow>> claimNearExpiryRows({
    required DateTime now,
    required Duration horizon,
    required int maxRows,
  }) async {
    if (_claimable.isEmpty) return const <ClaimedCredentialRow>[];
    final n = _claimable.length < maxRows ? _claimable.length : maxRows;
    final claimed = _claimable.sublist(0, n);
    _claimable.removeRange(0, n);
    return claimed;
  }

  @override
  Future<int> recordRefreshFailure({
    required String credentialId,
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String errorMessage,
  }) async {
    recordedFailures.add(_RecordedFailure(
      credentialId: credentialId,
      vendorId: vendorId,
      errorMessage: errorMessage,
    ));
    // Mirrors the production semantics: post-increment count =
    // pre-claim + 1.
    return recordedFailures
        .where((row) => row.credentialId == credentialId)
        .length;
  }

  @override
  Future<void> recordRefreshSuccess({
    required String credentialId,
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) async {
    recordedSuccesses.add(_RecordedSuccess(
      credentialId: credentialId,
      vendorId: vendorId,
    ));
  }

  @override
  Future<void> autoDisableConnection({
    required String credentialId,
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String errorMessage,
    required int consecutiveFailures,
  }) async {
    autoDisabledRows.add(_AutoDisabledRow(
      credentialId: credentialId,
      vendorId: vendorId,
      errorMessage: errorMessage,
      consecutiveFailures: consecutiveFailures,
    ));
  }
}

class _RecordedSuccess {
  _RecordedSuccess({required this.credentialId, required this.vendorId});
  final String credentialId;
  final String vendorId;
}

class _RecordedFailure {
  _RecordedFailure({
    required this.credentialId,
    required this.vendorId,
    required this.errorMessage,
  });
  final String credentialId;
  final String vendorId;
  final String errorMessage;
}

class _AutoDisabledRow {
  _AutoDisabledRow({
    required this.credentialId,
    required this.vendorId,
    required this.errorMessage,
    required this.consecutiveFailures,
  });
  final String credentialId;
  final String vendorId;
  final String errorMessage;
  final int consecutiveFailures;
}

/// Recording fake of [VendorCredentialBroker]. The production broker
/// extends OperatorScopedRepository which forces a TenantTransactionWrapper
/// in the constructor; we subclass it but override every method the
/// worker calls so the parent's tenant-transaction wiring is never
/// touched.
class _RecordingBroker extends VendorCredentialBroker {
  _RecordingBroker()
      : super(
          tenantWrapper: _buildUnusedTenantWrapper(),
          pgcryptoEnvelopeKey: 'test',
        );

  int refreshCalls = 0;
  _RefreshArgs? lastRefreshArgs;

  @override
  Future<String> refreshAccessToken({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required Future<TokenRefreshResult> Function(VendorCredentialBundle)
        doRefresh,
  }) async {
    refreshCalls += 1;
    lastRefreshArgs = _RefreshArgs(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: vendorId,
    );
    return 'access-token-stub';
  }
}

class _StopAfterFirstBroker extends VendorCredentialBroker {
  _StopAfterFirstBroker(this._delegate, this._onCall)
      : super(
          tenantWrapper: _buildUnusedTenantWrapper(),
          pgcryptoEnvelopeKey: 'test',
        );

  final _RecordingBroker _delegate;
  final void Function() _onCall;

  @override
  Future<String> refreshAccessToken({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required Future<TokenRefreshResult> Function(VendorCredentialBundle)
        doRefresh,
  }) async {
    final result = await _delegate.refreshAccessToken(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: vendorId,
      doRefresh: doRefresh,
    );
    _onCall();
    return result;
  }
}

class _AlwaysFailBroker extends VendorCredentialBroker {
  _AlwaysFailBroker()
      : super(
          tenantWrapper: _buildUnusedTenantWrapper(),
          pgcryptoEnvelopeKey: 'test',
        );

  @override
  Future<String> refreshAccessToken({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required Future<TokenRefreshResult> Function(VendorCredentialBundle)
        doRefresh,
  }) async {
    throw const VendorRefreshFailed('boom: synthetic test failure');
  }
}

class _RefreshArgs {
  _RefreshArgs({
    required this.operatorId,
    required this.locationId,
    required this.vendorId,
  });
  final String operatorId;
  final String locationId;
  final String vendorId;
}

class _AlwaysSucceedClosure {
  Future<TokenRefreshResult> call(VendorCredentialBundle current) async {
    return TokenRefreshResult(
      accessToken: 'new-access-token',
      refreshToken: 'new-refresh-token',
      expiresAt: DateTime.utc(2026, 5, 7).add(const Duration(hours: 1)),
    );
  }
}

/// Minimal [PostgresPool] for satisfying [TenantTransactionWrapper]'s
/// constructor in tests. The broker subclasses below override
/// `refreshAccessToken` so this pool is never actually used; if a
/// path ever does invoke `beginTransaction` the test fails loud.
class _UnusedPostgresPool implements PostgresPool {
  @override
  Future<PostgresTransaction> beginTransaction() {
    throw StateError(
      '_UnusedPostgresPool.beginTransaction called; broker subclasses in '
      'this test must override every method the worker invokes',
    );
  }
}

TenantTransactionWrapper _buildUnusedTenantWrapper() {
  return TenantTransactionWrapper(_UnusedPostgresPool());
}
