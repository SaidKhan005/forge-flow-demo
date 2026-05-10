// Pressure preview v1 — Phase 3C OAuth refresh storm load harness.
//
// Sprint: `pressure.preview.v1` Phase 3C of the three load lanes
// (3A webhook flood, 3B backfill flood, 3C OAuth refresh storm).
//
// What this harness drives
// ------------------------
// Simulates the OAuth refresh worker handling N concurrent vendor
// connections all approaching token expiry simultaneously, while
// polling adapters are mid-call. Asserts:
//
//   1. Advisory lock prevents a thundering herd — when 11 OAuth
//      vendors all need refresh simultaneously, the broker's per-
//      tenant in-flight Future lock + the
//      `oauth_refresh_advisory_lock` migration ensure exactly ONE
//      refresh per (operator, location, vendor) tuple actually
//      executes; concurrent callers either skip or wait on the
//      same future.
//   2. Polling adapter survives mid-call refresh — when an adapter
//      is mid-poll and the refresh worker rotates the token, the
//      adapter retries with the new token without dropping the
//      request.
//   3. Token rotation persists atomically — after refresh, the new
//      `token_expires_at` is committed in the same transaction as
//      the new `encrypted_access_token`; no transactional reader
//      observes a window where one is fresh and the other stale.
//   4. Refresh-closure registry coverage matches actual
//      `capabilityProfile.authMode`. The harness compares the
//      worker's `kVendorsWithoutRefreshClosure` constant + the
//      env-driven `buildProductionRefreshClosures` registry against
//      the adapter-declared authModes — and surfaces mismatches
//      against the audit's "Confirmed-clean" claim in
//      `docs/POST_HARDENING_FOLLOWUPS.md`.
//
// Why this is a HARNESS, not a unit test
// --------------------------------------
// The findings catalog drives Phase 5; the harness is a finding
// generator, not a gate. It writes a JSONL artifact at
// `test/load/pressure/p3c_oauth_refresh_storm_findings.jsonl` plus
// a markdown summary so Phase 5 can ingest the catalog in one read.
//
// Database connection mode
// ------------------------
// The harness deliberately runs WITHOUT a live Postgres connection.
// The OAuth refresh worker code path lives at
// `tool/oauth_refresh_worker/main.dart` and requires Azure DB
// Flexible Server to drive end-to-end. Instead, the harness:
//
//   * Imports the worker's [buildProductionRefreshClosures] +
//     `kVendorsWithoutRefreshClosure` directly so the closure-
//     registry coverage check exercises real production code.
//   * Models the `vendor_credentials` row + `pg_advisory_xact_lock`
//     semantics in [SyntheticCredentialStore] so the storm-shaped
//     concurrency checks (advisory lock, mid-poll, atomic rotation)
//     run in-process at scale without burning staging quota.
//
// CLAUDE.md alignment
// -------------------
//   * Hard Promise #4 (per-operator isolation) — every synthetic
//     refresh call carries `(operator_id, location_id, vendor_id)`
//     so cross-tuple bleed would surface as a finding.
//   * Hard Promise #7 (server-side keys) — synthetic ciphertexts
//     only; no real OAuth tokens or vendor app credentials are
//     read or written.
//   * `docs/_execution/2026-05-08_pressure_preview_v1_plan.md`
//     Phase 3 — runs against the preview proxy URL only when the
//     `--proxy-url` flag is set; default behavior is in-process.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:forge_and_flow/integrations/_common/vendor_credential_broker.dart';
import 'package:http/http.dart' as http;

import '../../test/load/pressure/_helpers/p3c_findings.dart';
import '../../test/load/pressure/_helpers/p3c_synthetic_credential_store.dart';
import '../../test/load/pressure/_helpers/p3c_vendor_authmode_catalog.dart';
import '../oauth_refresh_worker/main.dart' as worker;

const String _kPreviewProxyUrl =
    'https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app';

const String _kFindingsJsonlPath =
    'test/load/pressure/p3c_oauth_refresh_storm_findings.jsonl';
const String _kSummaryMdPath =
    'test/load/pressure/p3c_oauth_refresh_storm_summary.md';

// ─── CLI ────────────────────────────────────────────────────────────

class _StormCliArgs {
  _StormCliArgs({
    required this.ops,
    required this.connectionsPerOp,
    required this.nearExpiryMs,
    required this.concurrentPolls,
    required this.workerPods,
    required this.proxyUrl,
  });

  final int ops;
  final int connectionsPerOp;
  final int nearExpiryMs;
  final int concurrentPolls;
  final int workerPods;

  /// Optional preview proxy URL the harness may probe for liveness.
  /// Defaults to null (no network call). When set, must equal the
  /// pressure plan's preview URL — the harness rejects production-
  /// looking URLs as a hard fail.
  final String? proxyUrl;

  Map<String, Object?> toLogFields() => <String, Object?>{
        'ops': ops,
        'connections_per_op': connectionsPerOp,
        'near_expiry_ms': nearExpiryMs,
        'concurrent_polls': concurrentPolls,
        'worker_pods': workerPods,
        if (proxyUrl != null) 'proxy_url': proxyUrl,
      };
}

_StormCliArgs _parseArgs(List<String> args) {
  int ops = 3;
  int connectionsPerOp = 11;
  int nearExpiryMs = 5000;
  int concurrentPolls = 5;
  int workerPods = 2;
  String? proxyUrl;
  for (final raw in args) {
    if (raw.startsWith('--ops=')) {
      ops = _positiveInt(raw.substring('--ops='.length), 'ops');
    } else if (raw.startsWith('--connections-per-op=')) {
      connectionsPerOp = _positiveInt(
        raw.substring('--connections-per-op='.length),
        'connections-per-op',
      );
    } else if (raw.startsWith('--near-expiry-ms=')) {
      nearExpiryMs = _positiveInt(
        raw.substring('--near-expiry-ms='.length),
        'near-expiry-ms',
      );
    } else if (raw.startsWith('--concurrent-polls=')) {
      concurrentPolls = _positiveInt(
        raw.substring('--concurrent-polls='.length),
        'concurrent-polls',
      );
    } else if (raw.startsWith('--worker-pods=')) {
      workerPods = _positiveInt(
        raw.substring('--worker-pods='.length),
        'worker-pods',
      );
    } else if (raw.startsWith('--proxy-url=')) {
      proxyUrl = raw.substring('--proxy-url='.length);
    } else if (raw == '--help' || raw == '-h') {
      stderr.writeln(_usage);
      exit(0);
    } else {
      throw FormatException('unknown flag "$raw"\n\n$_usage');
    }
  }
  return _StormCliArgs(
    ops: ops,
    connectionsPerOp: connectionsPerOp,
    nearExpiryMs: nearExpiryMs,
    concurrentPolls: concurrentPolls,
    workerPods: workerPods,
    proxyUrl: proxyUrl,
  );
}

int _positiveInt(String raw, String label) {
  final n = int.tryParse(raw);
  if (n == null || n <= 0) {
    throw FormatException(
      '--$label expects a positive integer; got "$raw"',
    );
  }
  return n;
}

const String _usage =
    'usage: dart run tool/pressure/p3c_oauth_refresh_storm.dart '
    '[--ops=N] [--connections-per-op=N] [--near-expiry-ms=N] '
    '[--concurrent-polls=N] [--worker-pods=N] [--proxy-url=URL]\n'
    '\n'
    'Defaults: ops=3 connections-per-op=11 near-expiry-ms=5000 '
    'concurrent-polls=5 worker-pods=2\n'
    '\n'
    'The harness runs in-process by default. Pass --proxy-url=<preview-url> '
    'to probe the preview proxy for liveness; production URLs are rejected '
    'as a hard fail.\n';

// ─── Main ───────────────────────────────────────────────────────────

Future<int> main(List<String> rawArgs) async {
  _StormCliArgs args;
  try {
    args = _parseArgs(rawArgs);
  } on FormatException catch (error) {
    stderr.writeln('p3c_oauth_refresh_storm: ${error.message}');
    return 2;
  }

  final sink = P3cFindingSink(
    outputJsonlPath: _kFindingsJsonlPath,
    summaryMdPath: _kSummaryMdPath,
  );

  // ── Preview-URL guard ────────────────────────────────────────────
  // Mirrors the bounded-run discipline in
  // `test/load/pressure/README.md`: production URLs are a hard fail.
  if (args.proxyUrl != null) {
    if (args.proxyUrl != _kPreviewProxyUrl) {
      sink.record(P3cFinding(
        category: 'setup_skipped',
        detail: 'rejected proxy URL — only the preview URL is allowed',
        context: <String, Object?>{
          'rejected_url': args.proxyUrl,
          'expected_url': _kPreviewProxyUrl,
        },
      ));
    } else {
      await _probePreviewProxy(args.proxyUrl!, sink);
    }
  }

  // ── Closure registry coverage ────────────────────────────────────
  final registryReconciliation =
      _runClosureRegistryCoverage(sink: sink);

  // ── Storm: seed N (operator × OAuth vendor) tuples ──────────────
  final store = SyntheticCredentialStore();
  final oauthVendorIds = kAdapterAuthModes.entries
      .where((e) => isOauthFlavored(e.value))
      .map((e) => e.key)
      .toList();

  // The harness treats `connections-per-op` as a request for one
  // synthetic connection per OAuth vendor up to the cap. If the
  // operator asked for more than the OAuth vendor count we round
  // down — there's no closure for non-OAuth vendors so seeding them
  // would muddy the storm.
  final perOpVendors = oauthVendorIds.take(args.connectionsPerOp).toList();
  if (args.connectionsPerOp > oauthVendorIds.length) {
    sink.record(P3cFinding(
      category: 'setup_skipped',
      detail:
          'connections-per-op exceeds OAuth-flavored vendor count; seeding '
          'one tuple per OAuth vendor instead',
      context: <String, Object?>{
        'requested': args.connectionsPerOp,
        'oauth_vendor_count': oauthVendorIds.length,
      },
    ));
  }

  for (var i = 0; i < args.ops; i += 1) {
    final operatorId = _operatorUuid(i);
    final locationId = _locationUuid(i);
    for (final vendorId in perOpVendors) {
      store.seed(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: vendorId,
        initialToken: 'cipher-init-$operatorId-$vendorId',
        initialExpiresAt: DateTime.now()
            .toUtc()
            .add(Duration(milliseconds: args.nearExpiryMs)),
      );
    }
  }

  // ── Probe 1: Advisory lock prevents thundering herd ──────────────
  await _probeAdvisoryLock(
    sink: sink,
    store: store,
    workerPods: args.workerPods,
    operatorId: _operatorUuid(0),
    locationId: _locationUuid(0),
    vendorId: perOpVendors.first,
  );

  // ── Probe 2: Mid-poll-during-refresh ─────────────────────────────
  await _probeMidPollDuringRefresh(
    sink: sink,
    store: store,
    concurrentPolls: args.concurrentPolls,
    operatorId: _operatorUuid(0),
    locationId: _locationUuid(0),
    vendorId: perOpVendors[1 % perOpVendors.length],
  );

  // ── Probe 3: Atomic rotation ─────────────────────────────────────
  await _probeAtomicRotation(
    sink: sink,
    store: store,
    operatorId: _operatorUuid(0),
    locationId: _locationUuid(0),
    vendorId: perOpVendors[2 % perOpVendors.length],
  );

  // ── Probe 4: Full storm — every (op, vendor) tuple refreshes
  //               concurrently, observed via per-tuple lock counts ─
  await _probeFullStorm(
    sink: sink,
    store: store,
    ops: args.ops,
    perOpVendors: perOpVendors,
    workerPods: args.workerPods,
  );

  // ── Flush artifacts ──────────────────────────────────────────────
  sink.flush();
  sink.writeSummaryMarkdown(
    smokeParameters: args.toLogFields(),
    registryReconciliation: registryReconciliation,
  );

  // ── stdout summary ───────────────────────────────────────────────
  final counts = sink.countsByCategory();
  stdout.writeln('p3c_oauth_refresh_storm: smoke complete');
  stdout.writeln('  parameters: ${jsonEncode(args.toLogFields())}');
  stdout.writeln('  registry  : ${jsonEncode(registryReconciliation)}');
  stdout.writeln('  findings  : ${jsonEncode(counts)}');
  stdout.writeln('  total     : ${sink.findings.length}');
  stdout.writeln('  artifacts :');
  stdout.writeln('    jsonl   : $_kFindingsJsonlPath');
  stdout.writeln('    summary : $_kSummaryMdPath');
  return 0;
}

// ─── Probes ─────────────────────────────────────────────────────────

Future<void> _probePreviewProxy(String url, P3cFindingSink sink) async {
  final client = http.Client();
  try {
    final response = await client
        .get(Uri.parse('$url/healthz'),
            headers: <String, String>{
              'User-Agent':
                  'pressure.preview.v1/p3c_oauth_refresh_storm liveness probe',
            })
        .timeout(const Duration(seconds: 5));
    if (response.statusCode >= 500) {
      sink.record(P3cFinding(
        category: 'setup_skipped',
        detail: 'preview proxy returned ${response.statusCode} on /healthz',
        context: <String, Object?>{'status_code': response.statusCode},
      ));
    }
  } on TimeoutException {
    sink.record(P3cFinding(
      category: 'setup_skipped',
      detail: 'preview proxy /healthz probe timed out (5s)',
    ));
  } catch (error) {
    sink.record(P3cFinding(
      category: 'setup_skipped',
      detail: 'preview proxy /healthz probe failed: ${error.runtimeType}',
    ));
  } finally {
    client.close();
  }
}

/// Walk the worker's refresh-closure registry + adapter authModes.
/// Records mismatches as findings and returns a small summary map for
/// the smoke output.
Map<String, Object?> _runClosureRegistryCoverage({
  required P3cFindingSink sink,
}) {
  // Build the wired registry exactly as the production worker would,
  // with every optional vendor's app credentials supplied so we see
  // the maximal closure coverage. Missing-secret cases are exercised
  // by the existing test/tool/oauth_refresh_worker/main_test.dart.
  final fullEnv = <String, String>{
    worker.OAuthRefreshWorkerVendorEnvNames.alohaNcrVoyixClientId: 'aloha-id',
    worker.OAuthRefreshWorkerVendorEnvNames.alohaNcrVoyixClientSecret:
        'aloha-secret',
    worker.OAuthRefreshWorkerVendorEnvNames.alohaNcrVoyixApplicationKey:
        'aloha-app-key',
    worker.OAuthRefreshWorkerVendorEnvNames.alohaNcrVoyixOrganizationId:
        'aloha-org-id',
    worker.OAuthRefreshWorkerVendorEnvNames.squareClientId: 'sq-id',
    worker.OAuthRefreshWorkerVendorEnvNames.squareClientSecret: 'sq-secret',
    worker.OAuthRefreshWorkerVendorEnvNames.cloverAppId: 'clover-app-id',
    worker.OAuthRefreshWorkerVendorEnvNames.humanityClientId: 'hum-id',
    worker.OAuthRefreshWorkerVendorEnvNames.humanityClientSecret: 'hum-secret',
    worker.OAuthRefreshWorkerVendorEnvNames.quickBooksTimeClientId: 'qbt-id',
    worker.OAuthRefreshWorkerVendorEnvNames.quickBooksTimeClientSecret:
        'qbt-secret',
    worker.OAuthRefreshWorkerVendorEnvNames.sevenShiftsClientId: '7s-id',
    worker.OAuthRefreshWorkerVendorEnvNames.sevenShiftsClientSecret:
        '7s-secret',
    worker.OAuthRefreshWorkerVendorEnvNames.libroClientId: 'libro-id',
    worker.OAuthRefreshWorkerVendorEnvNames.libroClientSecret: 'libro-secret',
  };
  final closureBuild = worker.buildProductionRefreshClosures(
    env: fullEnv,
    httpClient: _NoopHttpClient(),
  );
  final wired = closureBuild.registry.keys.toSet();
  final unsupported = worker.kVendorsWithoutRefreshClosure;

  // Every vendor in the catalog is checked twice:
  //   * If the adapter says oauth-flavored AND the registry has no
  //     closure AND the vendor isn't in the explicit unsupported set
  //     → oauth_vendor_missing_closure.
  //   * If the adapter says NOT oauth-flavored AND the registry has
  //     a closure → non_oauth_vendor_has_closure.
  for (final entry in kAdapterAuthModes.entries) {
    final vendorId = entry.key;
    final authMode = entry.value;
    final hasClosure = wired.contains(vendorId);
    final isUnsupported = unsupported.contains(vendorId);
    final oauthFlavored = isOauthFlavored(authMode);

    if (oauthFlavored && !hasClosure && !isUnsupported) {
      sink.record(P3cFinding(
        category: 'oauth_vendor_missing_closure',
        detail:
            'adapter declares authMode=$authMode but worker has no '
            'closure registered AND vendor is not in '
            'kVendorsWithoutRefreshClosure',
        vendorId: vendorId,
      ));
    }
    if (!oauthFlavored && hasClosure) {
      sink.record(P3cFinding(
        category: 'non_oauth_vendor_has_closure',
        detail:
            'adapter declares authMode=$authMode but worker registered '
            'a refresh closure',
        vendorId: vendorId,
      ));
    }
  }

  // Audit reconciliation: the audit's "Confirmed-clean" entry claimed
  // 6 specific vendors are non-OAuth. Cross-check each one.
  for (final entry in kAuditClaimedNonOauthReason.entries) {
    final vendorId = entry.key;
    final claimedReason = entry.value;
    final actualAuthMode = kAdapterAuthModes[vendorId];
    final isUnsupported = unsupported.contains(vendorId);
    final agreesWithClaim = actualAuthMode != null &&
        !isOauthFlavored(actualAuthMode);
    if (!agreesWithClaim) {
      // The audit says non-OAuth; the adapter says oauth (or
      // oauthOrKeyPaste). That's a documented mis-classification.
      // The worker's `kVendorsWithoutRefreshClosure` correctly omits
      // the vendor from its closure list (see 6 entries) so the row
      // would be log-and-skipped at runtime — but operators looking
      // at the audit doc would be misled about why.
      final category = vendorId == 'agendrix'
          ? 'agendrix_closure_status'
          : (vendorId == 'opentable' ||
                  vendorId == 'adp' ||
                  vendorId == 'sevenrooms')
              ? 'oauth_vendor_missing_closure'
              : 'oauth_vendor_missing_closure';
      sink.record(P3cFinding(
        category: category,
        detail:
            'audit claimed non-OAuth ($claimedReason) but adapter '
            'declares authMode=$actualAuthMode; worker $isUnsupported '
            'has it on kVendorsWithoutRefreshClosure (so refresh '
            'rows would be log-and-skipped at runtime).',
        vendorId: vendorId,
        context: <String, Object?>{
          'audit_claim': claimedReason,
          'adapter_auth_mode': actualAuthMode,
          'worker_unsupported_set': isUnsupported,
        },
      ));
    } else {
      // Audit + adapter agree (Tock=keyPaste, Push=keyPaste). Log a
      // status finding so the catalog has the explicit pass record.
      if (vendorId == 'agendrix') {
        sink.record(P3cFinding(
          category: 'agendrix_closure_status',
          detail: 'audit claim agrees with adapter authMode=$actualAuthMode',
          vendorId: vendorId,
          context: <String, Object?>{
            'audit_claim': claimedReason,
            'adapter_auth_mode': actualAuthMode,
          },
        ));
      }
    }
  }

  // Oracle Simphony — the prompt singles this out. The audit claimed
  // mTLS; the adapter declares OAuth and the worker has a closure
  // for `oracle_micros_simphony` (Toast/LSK/Simphony/Revel are
  // unconditionally wired with no app-credential gating).
  final oracleAuth = kAdapterAuthModes['oracle_micros_simphony'];
  final oracleHasClosure = wired.contains('oracle_micros_simphony');
  sink.record(P3cFinding(
    category: 'oracle_simphony_closure_status',
    detail: 'capabilityProfile.authMode=$oracleAuth, '
        'worker has closure=$oracleHasClosure',
    vendorId: 'oracle_micros_simphony',
    context: <String, Object?>{
      'audit_claimed_auth': 'mTLS',
      'adapter_auth_mode': oracleAuth,
      'worker_has_closure': oracleHasClosure,
    },
  ));

  return <String, Object?>{
    'wired_oauth_count': wired.length,
    'wired_oauth_vendors': wired.toList()..sort(),
    'unsupported_count': unsupported.length,
    'unsupported_vendors': unsupported.toList()..sort(),
    'expected_oauth_count': 11,
    'expected_unsupported_count': 6,
  };
}

Future<void> _probeAdvisoryLock({
  required P3cFindingSink sink,
  required SyntheticCredentialStore store,
  required int workerPods,
  required String operatorId,
  required String locationId,
  required String vendorId,
}) async {
  // Fire `workerPods` parallel refreshes against the same tuple. The
  // store's per-tuple advisory-lock collapses concurrent callers
  // onto a single in-flight Future; only one closure invocation
  // should land.
  final closureCountBefore = store.closureInvocations;
  final futures = <Future<void>>[];
  for (var i = 0; i < workerPods; i += 1) {
    futures.add(store.refresh(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: vendorId,
      vendorLatency: const Duration(milliseconds: 50),
      newCiphertext: 'cipher-pod-$i-after-refresh',
      newExpiresIn: const Duration(hours: 1),
    ));
  }
  await Future.wait(futures);
  final actualClosureInvocations = store.closureInvocations - closureCountBefore;
  if (actualClosureInvocations != 1) {
    sink.record(P3cFinding(
      category: 'advisory_lock_failed',
      detail:
          'expected exactly 1 closure invocation across $workerPods parallel '
          'refresh calls against same tuple; observed $actualClosureInvocations',
      vendorId: vendorId,
      operatorId: operatorId,
      locationId: locationId,
      context: <String, Object?>{
        'worker_pods': workerPods,
        'closure_invocations': actualClosureInvocations,
      },
    ));
  }
  // The post-refresh row should also have rotation_count = 1, not N.
  final snap = store.snapshot(
    operatorId: operatorId,
    locationId: locationId,
    vendorId: vendorId,
  );
  if (snap.rotationCount != 1) {
    sink.record(P3cFinding(
      category: 'advisory_lock_failed',
      detail:
          'expected rotation_count=1 after parallel refresh; observed '
          '${snap.rotationCount}',
      vendorId: vendorId,
      operatorId: operatorId,
      locationId: locationId,
    ));
  }
}

Future<void> _probeMidPollDuringRefresh({
  required P3cFindingSink sink,
  required SyntheticCredentialStore store,
  required int concurrentPolls,
  required String operatorId,
  required String locationId,
  required String vendorId,
}) async {
  // Snapshot the pre-refresh token. Pollers read the bearer; we
  // rotate; pollers re-read post-rotation. A "drop" here means a
  // poller observed an inconsistent snapshot (empty ciphertext) or
  // saw the bearer disappear without a replacement.
  var droppedRequests = 0;
  final pollers = <Future<void>>[];
  for (var i = 0; i < concurrentPolls; i += 1) {
    pollers.add(() async {
      // Read pre-refresh.
      final pre = store.snapshot(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: vendorId,
      );
      if (pre.encryptedAccessToken.isEmpty) droppedRequests += 1;
      // Yield a few microtasks so the refresh can interleave.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      // Re-read post-refresh; the new bearer should be present and
      // non-empty.
      final post = store.snapshot(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: vendorId,
      );
      if (post.encryptedAccessToken.isEmpty) droppedRequests += 1;
    }());
  }
  // Concurrently rotate the token. The pollers read either pre or
  // post but never see an empty bearer because the commit is
  // atomic in the store.
  pollers.add(store.refresh(
    operatorId: operatorId,
    locationId: locationId,
    vendorId: vendorId,
    vendorLatency: const Duration(milliseconds: 30),
    newCiphertext: 'cipher-mid-poll-rotated',
    newExpiresIn: const Duration(hours: 1),
  ));
  await Future.wait(pollers);
  if (droppedRequests > 0) {
    sink.record(P3cFinding(
      category: 'mid_poll_dropped_request',
      detail:
          'observed $droppedRequests poller snapshots with empty ciphertext '
          'during mid-poll refresh',
      vendorId: vendorId,
      operatorId: operatorId,
      locationId: locationId,
      context: <String, Object?>{
        'concurrent_polls': concurrentPolls,
      },
    ));
  }
}

Future<void> _probeAtomicRotation({
  required P3cFindingSink sink,
  required SyntheticCredentialStore store,
  required String operatorId,
  required String locationId,
  required String vendorId,
}) async {
  // Drive a refresh whose closure body fires the snapshot probe. The
  // probe checks that the row is in the PRE-rotation state (the
  // commit hasn't happened yet) — if the store ever shows a half-
  // rotated state we surface a finding.
  var inconsistentSnapshots = 0;
  await store.refresh(
    operatorId: operatorId,
    locationId: locationId,
    vendorId: vendorId,
    vendorLatency: const Duration(milliseconds: 20),
    newCiphertext: 'cipher-atomic-rotation',
    newExpiresIn: const Duration(hours: 1),
    snapshotProbe: (snap) {
      // The probe fires AFTER the simulated vendor RTT but BEFORE
      // the commit. The row should still hold the pre-refresh state.
      if (!snap.isConsistent) {
        inconsistentSnapshots += 1;
      }
    },
  );
  if (inconsistentSnapshots > 0) {
    sink.record(P3cFinding(
      category: 'non_atomic_rotation',
      detail:
          'observed $inconsistentSnapshots inconsistent snapshots during '
          'rotation (token_expires_at advanced before ciphertext landed, '
          'or ciphertext null/empty)',
      vendorId: vendorId,
      operatorId: operatorId,
      locationId: locationId,
    ));
  }
  // Verify the post-refresh state is consistent: ciphertext non-
  // empty, expiry strictly after rotated_at.
  final post = store.snapshot(
    operatorId: operatorId,
    locationId: locationId,
    vendorId: vendorId,
  );
  if (!post.isConsistent) {
    sink.record(P3cFinding(
      category: 'non_atomic_rotation',
      detail: 'post-refresh row is inconsistent: '
          'ciphertext_empty=${post.encryptedAccessToken.isEmpty}, '
          'expires_at=${post.tokenExpiresAt.toIso8601String()}, '
          'rotated_at=${post.rotatedAt?.toIso8601String()}',
      vendorId: vendorId,
      operatorId: operatorId,
      locationId: locationId,
    ));
  }
}

Future<void> _probeFullStorm({
  required P3cFindingSink sink,
  required SyntheticCredentialStore store,
  required int ops,
  required List<String> perOpVendors,
  required int workerPods,
}) async {
  // The storm fires `workerPods` refresh attempts CONCURRENTLY against
  // each (op, vendor) tuple. The advisory-lock contract guarantees
  // that simultaneous attempts collapse onto a single in-flight
  // Future — i.e. each tuple sees exactly one closure invocation per
  // burst even when N pods race.
  //
  // To model "simultaneous" correctly inside a single Dart event
  // loop we kick off all pods for a given tuple as one batch under
  // `Future.wait`, then move to the next tuple. (The previous
  // implementation interleaved pod loops with tuple loops, which let
  // pod 2 see pod 1's completed in-flight slot and legitimately
  // re-acquire the lock — a false positive in the test, not a real
  // contention bug.)
  //
  // Cross-tuple parallelism still happens because tuple-batches
  // themselves are awaited in `Future.wait` over all tuples below.
  final tupleBatches = <Future<void>>[];
  for (var i = 0; i < ops; i += 1) {
    final operatorId = _operatorUuid(i);
    final locationId = _locationUuid(i);
    for (final vendorId in perOpVendors) {
      tupleBatches.add(() async {
        await Future.wait(<Future<void>>[
          for (var pod = 0; pod < workerPods; pod += 1)
            store.refresh(
              operatorId: operatorId,
              locationId: locationId,
              vendorId: vendorId,
              vendorLatency: const Duration(milliseconds: 25),
              newCiphertext: 'cipher-storm-$pod-$i-$vendorId',
              newExpiresIn: const Duration(hours: 1),
            ),
        ]);
      }());
    }
  }
  await Future.wait(tupleBatches);

  store.perTupleLockAcquisitions.forEach((key, count) {
    final parts = key.split('|');
    final operatorId = parts[0];
    final locationId = parts[1];
    final vendorId = parts[2];
    // The targeted advisory-lock probe earlier already exercised the
    // (op0, loc0, vendor[0]) tuple, so its count includes the prior
    // burst. Ditto for the mid-poll probe (vendor[1]) and the
    // atomic-rotation probe (vendor[2]). Skip those tuples here so
    // we don't double-flag.
    final isTargetedProbeTuple = operatorId == _operatorUuid(0) &&
        locationId == _locationUuid(0) &&
        (vendorId == perOpVendors.first ||
            vendorId == perOpVendors[1 % perOpVendors.length] ||
            vendorId == perOpVendors[2 % perOpVendors.length]);
    if (isTargetedProbeTuple) return;
    if (count != 1) {
      sink.record(P3cFinding(
        category: 'advisory_lock_failed',
        detail:
            'tuple saw $count lock acquisitions across full storm '
            '(expected 1 — concurrent pods should collapse)',
        operatorId: operatorId,
        locationId: locationId,
        vendorId: vendorId,
        context: <String, Object?>{
          'lock_acquisitions': count,
          'worker_pods': workerPods,
        },
      ));
    }
  });
}

// ─── Identifiers ────────────────────────────────────────────────────

String _operatorUuid(int index) =>
    '00000000-0000-4000-8000-${index.toString().padLeft(12, '0')}';

String _locationUuid(int index) =>
    '00000000-0000-4001-8000-${index.toString().padLeft(12, '0')}';

// ─── Stub HTTP client ───────────────────────────────────────────────

/// `buildProductionRefreshClosures` only constructs closures (deferred
/// network calls) — it never invokes the http client during the
/// registry build. Mirrors the unit-test stub at
/// `test/tool/oauth_refresh_worker/main_test.dart#_StubHttpClient`.
class _NoopHttpClient implements http.Client {
  @override
  void close() {}

  @override
  noSuchMethod(Invocation invocation) {
    throw StateError(
      '_NoopHttpClient.${invocation.memberName} called; '
      'p3c_oauth_refresh_storm should not perform live HTTP requests',
    );
  }
}

// Prevent Dart's unused-import elimination from dropping the broker
// import (it's documentation-load-bearing — the harness exists to
// pressure-test the broker's contract even when it doesn't directly
// invoke it).
// ignore: unused_element
final _kBrokerSentinel = VendorCredentialBroker;
