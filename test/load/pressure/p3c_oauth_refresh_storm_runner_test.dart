// Pressure preview v1 — Phase 3C OAuth refresh storm runner test.
//
// Drives `tool/pressure/p3c_oauth_refresh_storm.dart` programmatically
// against a synthetic in-process credential store and asserts the
// harness's invariants:
//
//   1. The advisory-lock probe collapses N parallel refreshes against
//      a single (operator, location, vendor) tuple to exactly one
//      closure invocation.
//   2. The mid-poll probe never observes an empty bearer.
//   3. The atomic-rotation probe never observes a half-rotated row.
//   4. The closure-registry coverage check enumerates the 11 expected
//      OAuth-flavored vendors and the 6 expected unsupported ones,
//      and surfaces the audit's Agendrix / Oracle Simphony mis-
//      classifications as findings.
//
// The runner test never spawns the production OAuth refresh worker
// process; it instead exercises the helpers + worker-side
// `buildProductionRefreshClosures` factory in-process so the test
// suite stays hermetic.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../../../tool/oauth_refresh_worker/main.dart' as worker;
import '_helpers/p3c_findings.dart';
import '_helpers/p3c_synthetic_credential_store.dart';
import '_helpers/p3c_vendor_authmode_catalog.dart';

const String _opUuidA = '11111111-1111-4111-8111-111111111111';
const String _opUuidB = '22222222-2222-4222-8222-222222222222';
const String _locUuidA = '33333333-3333-4333-8333-333333333333';
const String _locUuidB = '44444444-4444-4444-8444-444444444444';

void main() {
  group('SyntheticCredentialStore — advisory-lock semantics', () {
    test('collapses N parallel refreshes to one closure invocation',
        () async {
      final store = SyntheticCredentialStore()
        ..seed(
          operatorId: _opUuidA,
          locationId: _locUuidA,
          vendorId: 'toast',
          initialToken: 'cipher-init',
          initialExpiresAt:
              DateTime.now().toUtc().add(const Duration(seconds: 5)),
        );

      const concurrentCallers = 8;
      await Future.wait(<Future<void>>[
        for (var i = 0; i < concurrentCallers; i += 1)
          store.refresh(
            operatorId: _opUuidA,
            locationId: _locUuidA,
            vendorId: 'toast',
            vendorLatency: const Duration(milliseconds: 30),
            newCiphertext: 'cipher-after-storm',
            newExpiresIn: const Duration(hours: 1),
          ),
      ]);

      expect(store.closureInvocations, 1,
          reason: 'advisory lock must collapse $concurrentCallers '
              'parallel callers to exactly one closure invocation');
      final snap = store.snapshot(
        operatorId: _opUuidA,
        locationId: _locUuidA,
        vendorId: 'toast',
      );
      expect(snap.rotationCount, 1,
          reason:
              'rotation_count after storm must be 1, not $concurrentCallers');
      expect(snap.encryptedAccessToken, 'cipher-after-storm');
    });

    test(
        'per-tuple lock isolation: parallel refreshes against different '
        'tuples do not block each other', () async {
      final store = SyntheticCredentialStore();
      for (final vendorId in const <String>['toast', 'square']) {
        for (final pair in <List<String>>[
          [_opUuidA, _locUuidA],
          [_opUuidB, _locUuidB],
        ]) {
          store.seed(
            operatorId: pair[0],
            locationId: pair[1],
            vendorId: vendorId,
            initialToken: 'cipher-init-${pair[0]}-$vendorId',
            initialExpiresAt:
                DateTime.now().toUtc().add(const Duration(seconds: 5)),
          );
        }
      }
      await Future.wait(<Future<void>>[
        for (final vendorId in const <String>['toast', 'square'])
          for (final pair in <List<String>>[
            [_opUuidA, _locUuidA],
            [_opUuidB, _locUuidB],
          ])
            store.refresh(
              operatorId: pair[0],
              locationId: pair[1],
              vendorId: vendorId,
              vendorLatency: const Duration(milliseconds: 10),
              newCiphertext: 'cipher-${pair[0]}-$vendorId',
              newExpiresIn: const Duration(hours: 1),
            ),
      ]);
      expect(store.closureInvocations, 4,
          reason:
              'each tuple must run its own refresh — locks are per-tuple, '
              'not global');
    });
  });

  group('SyntheticCredentialStore — atomic rotation', () {
    test(
        'snapshot probe in flight observes pre-rotation state, never '
        'a torn read', () async {
      final store = SyntheticCredentialStore()
        ..seed(
          operatorId: _opUuidA,
          locationId: _locUuidA,
          vendorId: 'lightspeed_lsk',
          initialToken: 'pre-rotation-token',
          initialExpiresAt:
              DateTime.now().toUtc().add(const Duration(seconds: 5)),
        );
      final snapshots = <CredentialSnapshot>[];
      await store.refresh(
        operatorId: _opUuidA,
        locationId: _locUuidA,
        vendorId: 'lightspeed_lsk',
        vendorLatency: const Duration(milliseconds: 25),
        newCiphertext: 'post-rotation-token',
        newExpiresIn: const Duration(hours: 1),
        snapshotProbe: snapshots.add,
      );
      expect(snapshots, hasLength(1));
      expect(snapshots.single.encryptedAccessToken, 'pre-rotation-token',
          reason:
              'probe runs after vendor RTT but before commit — the row must '
              'still hold the pre-rotation ciphertext');
      expect(snapshots.single.isConsistent, isTrue);
      final post = store.snapshot(
        operatorId: _opUuidA,
        locationId: _locUuidA,
        vendorId: 'lightspeed_lsk',
      );
      expect(post.encryptedAccessToken, 'post-rotation-token');
      expect(post.tokenExpiresAt.isAfter(post.rotatedAt!), isTrue);
    });
  });

  group('SyntheticCredentialStore — mid-poll-during-refresh', () {
    test(
        'pollers reading concurrently with a refresh never observe '
        'an empty bearer', () async {
      final store = SyntheticCredentialStore()
        ..seed(
          operatorId: _opUuidA,
          locationId: _locUuidA,
          vendorId: 'square',
          initialToken: 'pre-poll-token',
          initialExpiresAt:
              DateTime.now().toUtc().add(const Duration(seconds: 5)),
        );
      var emptyObservations = 0;
      final pollers = <Future<void>>[];
      for (var i = 0; i < 10; i += 1) {
        pollers.add(() async {
          final pre = store.snapshot(
            operatorId: _opUuidA,
            locationId: _locUuidA,
            vendorId: 'square',
          );
          if (pre.encryptedAccessToken.isEmpty) emptyObservations += 1;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          final post = store.snapshot(
            operatorId: _opUuidA,
            locationId: _locUuidA,
            vendorId: 'square',
          );
          if (post.encryptedAccessToken.isEmpty) emptyObservations += 1;
        }());
      }
      pollers.add(store.refresh(
        operatorId: _opUuidA,
        locationId: _locUuidA,
        vendorId: 'square',
        vendorLatency: const Duration(milliseconds: 15),
        newCiphertext: 'post-poll-token',
        newExpiresIn: const Duration(hours: 1),
      ));
      await Future.wait(pollers);
      expect(emptyObservations, 0,
          reason: 'mid-poll snapshots must never observe an empty bearer');
    });
  });

  group('Closure registry coverage', () {
    test('catalog enumerates exactly the 17 Phase 8 vendors', () {
      // The catalog is the source of truth for authMode in this
      // harness. The accompanying p2a registry (which DOES exercise
      // adapter capability profiles directly via the
      // VendorRegistryEntry catalog) is the authority for adapter-
      // surface accuracy; the p3c catalog mirrors it for the
      // closure-coverage probe.
      expect(kAdapterAuthModes, hasLength(17));
      expect(allVendorIds.toSet(), <String>{
        // POS (7)
        'toast', 'square', 'clover', 'lightspeed_lsk', 'aloha_ncr_voyix',
        'oracle_micros_simphony', 'revel',
        // Reservation (4)
        'libro', 'tock', 'opentable', 'sevenrooms',
        // Labor (6)
        'quickbooks_time', 'adp', 'seven_shifts', 'humanity', 'agendrix',
        'push_operations',
      });
    });

    test(
        'worker registry wires exactly the 11 expected OAuth vendors when '
        'all app credentials are present', () {
      final fullEnv = <String, String>{
        worker.OAuthRefreshWorkerVendorEnvNames.alohaNcrVoyixClientId: 'a',
        worker.OAuthRefreshWorkerVendorEnvNames.alohaNcrVoyixClientSecret:
            'b',
        worker.OAuthRefreshWorkerVendorEnvNames.alohaNcrVoyixApplicationKey:
            'c',
        worker.OAuthRefreshWorkerVendorEnvNames.alohaNcrVoyixOrganizationId:
            'd',
        worker.OAuthRefreshWorkerVendorEnvNames.squareClientId: 'e',
        worker.OAuthRefreshWorkerVendorEnvNames.squareClientSecret: 'f',
        worker.OAuthRefreshWorkerVendorEnvNames.cloverAppId: 'g',
        worker.OAuthRefreshWorkerVendorEnvNames.humanityClientId: 'h',
        worker.OAuthRefreshWorkerVendorEnvNames.humanityClientSecret: 'i',
        worker.OAuthRefreshWorkerVendorEnvNames.quickBooksTimeClientId: 'j',
        worker.OAuthRefreshWorkerVendorEnvNames.quickBooksTimeClientSecret:
            'k',
        worker.OAuthRefreshWorkerVendorEnvNames.sevenShiftsClientId: 'l',
        worker.OAuthRefreshWorkerVendorEnvNames.sevenShiftsClientSecret: 'm',
        worker.OAuthRefreshWorkerVendorEnvNames.libroClientId: 'n',
        worker.OAuthRefreshWorkerVendorEnvNames.libroClientSecret: 'o',
      };
      final result = worker.buildProductionRefreshClosures(
        env: fullEnv,
        httpClient: _NoopHttpClient(),
      );
      expect(result.wiredVendorIds, hasLength(11),
          reason:
              'every Phase 8 OAuth-using vendor (per the worker closure file) '
              'must be wired when its app-credential env vars are present');
      expect(result.disabledVendorIds, isEmpty);
      expect(
        result.wiredVendorIds,
        containsAll(<String>[
          'toast',
          'square',
          'clover',
          'lightspeed_lsk',
          'aloha_ncr_voyix',
          'oracle_micros_simphony',
          'revel',
          'seven_shifts',
          'quickbooks_time',
          'libro',
          'humanity',
        ]),
      );
      expect(worker.kVendorsWithoutRefreshClosure, hasLength(6));
      expect(
        worker.kVendorsWithoutRefreshClosure,
        containsAll(<String>[
          'sevenrooms',
          'tock',
          'push_operations',
          'agendrix',
          'adp',
          'opentable',
        ]),
      );
    });

    test(
        'oauth-flavored vendors NOT in the worker registry surface a '
        'missing-closure finding (Agendrix / OpenTable / ADP / SevenRooms)',
        () {
      final oauthFlavoredButUnsupported = <String>[];
      for (final entry in kAdapterAuthModes.entries) {
        final isUnsupported =
            worker.kVendorsWithoutRefreshClosure.contains(entry.key);
        if (isOauthFlavored(entry.value) && isUnsupported) {
          oauthFlavoredButUnsupported.add(entry.key);
        }
      }
      expect(
        oauthFlavoredButUnsupported,
        containsAll(<String>['agendrix', 'opentable', 'adp', 'sevenrooms']),
      );
    });

    test('Oracle Simphony has a closure (audits mTLS claim was wrong)', () {
      final result = worker.buildProductionRefreshClosures(
        env: const <String, String>{},
        httpClient: _NoopHttpClient(),
      );
      expect(result.registry.containsKey('oracle_micros_simphony'), isTrue,
          reason:
              'Simphony is in the unconditionally-wired set; capabilityProfile '
              'says oauth; audit claim of mTLS was wrong');
      expect(kAdapterAuthModes['oracle_micros_simphony'], 'oauth');
    });
  });

  group('Finding sink writes JSONL artifact', () {
    test('flush emits one JSON line per finding', () async {
      final tmp = Directory.systemTemp.createTempSync('p3c_runner_');
      try {
        final sink = P3cFindingSink(
          outputJsonlPath: '${tmp.path}/findings.jsonl',
          summaryMdPath: '${tmp.path}/summary.md',
        );
        sink.record(P3cFinding(
          category: 'advisory_lock_failed',
          detail: 'demo',
          vendorId: 'toast',
        ));
        sink.record(P3cFinding(
          category: 'oauth_vendor_missing_closure',
          detail: 'demo',
          vendorId: 'agendrix',
        ));
        sink.flush();
        final lines =
            File('${tmp.path}/findings.jsonl').readAsLinesSync();
        expect(lines, hasLength(2));
        expect(lines.first, contains('"category":"advisory_lock_failed"'));
        expect(lines.last, contains('"vendor_id":"agendrix"'));
        sink.writeSummaryMarkdown(
          smokeParameters: const <String, Object?>{
            'ops': 1,
            'connections_per_op': 11,
          },
          registryReconciliation: const <String, Object?>{
            'wired_oauth_count': 11,
          },
        );
        final md = File('${tmp.path}/summary.md').readAsStringSync();
        expect(md, contains('# P3C OAuth Refresh Storm'));
        expect(md, contains('Total findings: 2'));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
}

class _NoopHttpClient implements http.Client {
  @override
  void close() {}
  @override
  noSuchMethod(Invocation invocation) {
    throw StateError(
      '_NoopHttpClient.${invocation.memberName} called; closure builders '
      'should not perform live HTTP requests during unit tests',
    );
  }
}
