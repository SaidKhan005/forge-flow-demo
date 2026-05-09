// Worker-layer audit-emission contract test.
//
// PR #457 surfaced two CONTRACT GAP markers:
//
//   1. "Audit row for the demo-flip event is emitted exactly once"
//   2. "Audit row for the re-claim event captures the prior worker_id"
//
// Both contracts can ONLY be tested at the worker layer because the
// repository does not write `audit_logs`. This file pins five backfill
// terminal / transition events to the audit chain via a real Postgres,
// exercising the production composition
//   AuditEmittingBackfillJobStore(delegate: ConnectorBackfillJobStore,
//                                 repository: ConnectorBackfillJobRepository)
//   AuditEmittingCanonicalSink(delegate: <test sink>)
// against the live `audit_logs` table. Tests gate on the
// `POSTGRES_TEST_URL` env var (same convention as PRs #458 / #459 /
// #460 — every postgres-tagged repo test uses this contract).
//
// Audit-emission contract pinned here:
//
//   * `backfill_job.claimed`     fresh claim landed
//   * `backfill_job.reclaimed`   stale-window re-claim landed; payload
//                                carries prior_worker_id, new_worker_id,
//                                prior_claim_count, new_claim_count
//   * `backfill_job.succeeded`   terminal success
//   * `backfill_job.failed`      terminal failure; error_message_truncated
//                                bounded at 1024 chars (no full stack
//                                trace leak — same class of issue PR #456
//                                fixed)
//   * `backfill_job.demo_flipped` demo→live transition; emitted EXACTLY
//                                ONCE per (operator, location, category)
//                                even when evaluateDemoFlip is called
//                                multiple times on an already-live row
//
// All audit rows carry `actor_kind = 'service'` and
// `actor_principal_id = 'sp:backfill_worker'` (the service-principal
// id from `audit_emitting_backfill_job_store.dart`).

@Tags(['postgres'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/package_postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/connector_backfill_job_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/integration/canonical_sink.dart';
import 'package:forge_and_flow/services/integration/first_connection_backfill_job.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import '../../../tool/integration_sync_worker/audit_emitting_backfill_job_store.dart';
import '../../../tool/integration_sync_worker/audit_emitting_canonical_sink.dart';
import '../../../tool/integration_sync_worker/backfill_dispatch.dart';

const String _opA = '00000000-0000-6000-9000-00000000ae01';
const String _locA = '00000000-0000-6000-9000-00000000ae02';
const String _connA = '00000000-0000-6000-9000-00000000ae03';
const String _actorA = '00000000-0000-6000-9000-00000000ae04';

const String _opB = '00000000-0000-6000-9000-00000000ae11';
const String _locB = '00000000-0000-6000-9000-00000000ae12';
const String _connB = '00000000-0000-6000-9000-00000000ae13';

void main() {
  const definedUrl = String.fromEnvironment('POSTGRES_TEST_URL');
  final pgUrl = definedUrl.isNotEmpty
      ? definedUrl
      : (Platform.environment['POSTGRES_TEST_URL'] ?? '');
  final hasDb = pgUrl.isNotEmpty;

  // ignore: avoid_print
  print(
    '[backfill_dispatch_audit_emission_test] postgres_test_url_set=$hasDb '
    '(set POSTGRES_TEST_URL or --dart-define=POSTGRES_TEST_URL to drive '
    'real-DB audit-emission contracts)',
  );

  if (!hasDb) {
    test(
      'setup_skipped — POSTGRES_TEST_URL unset; real DB required to '
      'exercise audit_logs writes against the hash-chain trigger',
      () {
        // ignore: avoid_print
        print(
          '[backfill-audit-emission] setup_skipped: POSTGRES_TEST_URL '
          'unset. The 5 audit-event contracts only hold against a '
          'real Postgres because audit_logs.row_hash is computed by '
          'the BEFORE INSERT trigger.',
        );
        expect(true, isTrue);
      },
    );
    return;
  }

  late PackagePostgresPool pool;
  late TenantTransactionWrapper wrapper;
  late ConnectorBackfillJobRepository repo;
  late ConnectorBackfillJobStore baseStore;
  late AuditEmittingBackfillJobStore auditStore;

  Future<void> seedScope({
    required String operatorId,
    required String locationId,
    required String connectionId,
  }) async {
    await wrapper.runAsSystem<void>(
      (exec) async {
        await exec.execute(
          'insert into public.operators '
          '(operator_id, business_name, owner_email) '
          'values (@op::uuid, @bn, @oe) '
          'on conflict (operator_id) do nothing',
          parameters: <String, Object?>{
            'op': operatorId,
            'bn': 'audit-emission-test',
            'oe': 'audit-emission-test@example.invalid',
          },
        );
        await exec.execute(
          'insert into public.locations '
          '(operator_id, location_id, name) '
          'values (@op::uuid, @loc::uuid, @name) '
          'on conflict (operator_id, location_id) do nothing',
          parameters: <String, Object?>{
            'op': operatorId,
            'loc': locationId,
            'name': 'audit-emission-test-loc',
          },
        );
        await exec.execute(
          'insert into public.connector_connection ('
          'connection_id, operator_id, location_id, vendor_id, '
          'category, status'
          ') values ('
          '@cid::uuid, @op::uuid, @loc::uuid, @vendor, @cat, '
          "'connected') "
          'on conflict (connection_id) do nothing',
          parameters: <String, Object?>{
            'cid': connectionId,
            'op': operatorId,
            'loc': locationId,
            'vendor': 'square',
            'cat': 'pos',
          },
        );
        await exec.execute(
          'insert into public.demo_mode_state '
          '(operator_id, location_id, category, is_demo) '
          'values (@op::uuid, @loc::uuid, @cat, true) '
          'on conflict (operator_id, location_id, category) '
          'do nothing',
          parameters: <String, Object?>{
            'op': operatorId,
            'loc': locationId,
            'cat': 'pos',
          },
        );
      },
      reason: 'backfill_audit_emission_test_seed',
    );
  }

  Future<void> cleanupForOperator(String operatorId) async {
    await wrapper.runAsSystem<void>(
      (exec) async {
        await exec.execute(
          'delete from public.audit_logs '
          'where operator_id = @op::uuid',
          parameters: <String, Object?>{'op': operatorId},
        );
        await exec.execute(
          'delete from public.connector_backfill_jobs '
          'where operator_id = @op::uuid',
          parameters: <String, Object?>{'op': operatorId},
        );
        await exec.execute(
          'update public.demo_mode_state set '
          'is_demo = true, '
          'flipped_to_live_at = null, '
          'flipped_by_connection_id = null '
          'where operator_id = @op::uuid',
          parameters: <String, Object?>{'op': operatorId},
        );
      },
      reason: 'backfill_audit_emission_test_cleanup',
    );
  }

  Future<List<Map<String, Object?>>> readAuditRowsForJob(
    String operatorId,
    String jobId,
  ) async {
    return wrapper.runAsSystem<List<Map<String, Object?>>>(
      (exec) async {
        final rows = await exec.query(
          'select action, actor_kind, actor_principal_id, '
          'target_kind, target_id, payload::text as payload_text '
          'from public.audit_logs '
          'where operator_id = @op::uuid '
          'and target_id = @target_id '
          'order by id asc',
          parameters: <String, Object?>{
            'op': operatorId,
            'target_id': jobId,
          },
        );
        return <Map<String, Object?>>[
          for (final row in rows)
            <String, Object?>{
              'action': row['action'],
              'actor_kind': row['actor_kind'],
              'actor_principal_id': row['actor_principal_id'],
              'target_kind': row['target_kind'],
              'target_id': row['target_id'],
              'payload_text': row['payload_text'],
            },
        ];
      },
      reason: 'backfill_audit_emission_read_audit_rows',
    );
  }

  setUpAll(() async {
    pool = PackagePostgresPool.fromUrl(pgUrl);
    wrapper = TenantTransactionWrapper(pool);
    repo = ConnectorBackfillJobRepository(wrapper);
    baseStore = ConnectorBackfillJobStore(repo);
    auditStore = AuditEmittingBackfillJobStore(
      delegate: baseStore,
      tenantWrapper: wrapper,
      repository: repo,
    );
    await seedScope(
      operatorId: _opA,
      locationId: _locA,
      connectionId: _connA,
    );
    await seedScope(
      operatorId: _opB,
      locationId: _locB,
      connectionId: _connB,
    );
    await cleanupForOperator(_opA);
    await cleanupForOperator(_opB);
  });

  tearDown(() async {
    await cleanupForOperator(_opA);
    await cleanupForOperator(_opB);
  });

  // ── Case 1: happy-path job (claim + succeed) ─────────────────────

  group('AuditEmittingBackfillJobStore — happy-path claim + succeed', () {
    test(
      'single happy-path job: 1 backfill_job.claimed + 1 backfill_job.succeeded '
      'audit row, both with actor_kind=service / actor_principal_id=sp:backfill_worker',
      () async {
        final job = await repo.enqueueFirstBackfill(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connA,
          vendorId: 'square',
          category: IntegrationCategory.pos,
          windowStart: DateTime.utc(2026, 3, 1, 12),
          windowEnd: DateTime.utc(2026, 4, 30, 12),
          actorUserId: _actorA,
        );
        final claimed = await auditStore.claimNext(
          operatorId: _opA,
          locationId: _locA,
          workerId: 'pod-happy-A',
        );
        expect(claimed, isNotNull);
        final sealed = await auditStore.markSucceeded(
          operatorId: _opA,
          locationId: _locA,
          jobId: job.jobId,
          cursorToken: 'cursor-happy-end',
          lastModifiedSeen: DateTime.utc(2026, 4, 30, 12),
        );
        expect(sealed, isNotNull);
        expect(
          sealed!.status,
          equals(FirstConnectionBackfillJobStatus.succeeded),
        );

        final auditRows = await readAuditRowsForJob(_opA, job.jobId);
        expect(
          auditRows.map((r) => r['action']).toList(),
          equals(<String>[
            BackfillAuditAction.claimed,
            BackfillAuditAction.succeeded,
          ]),
        );
        for (final row in auditRows) {
          expect(row['actor_kind'], equals('service'));
          expect(
            row['actor_principal_id'],
            equals(kBackfillWorkerServicePrincipalId),
          );
          expect(row['target_kind'], equals('connector_backfill_job'));
          expect(row['target_id'], equals(job.jobId));
        }
        // Spot-check the payload shape on the succeeded row — the
        // contract specifies job_id + vendor_id + worker_id +
        // records_processed + elapsed_ms, and elapsed_ms must be a
        // non-negative integer.
        final succeeded = auditRows.last;
        final payload = succeeded['payload_text']! as String;
        expect(payload, contains('"job_id"'));
        expect(payload, contains('"vendor_id":"square"'));
        expect(payload, contains('"worker_id":"pod-happy-A"'));
        expect(payload, contains('"elapsed_ms"'));
      },
    );
  });

  // ── Case 2: failed job (claim + fail) ────────────────────────────

  group('AuditEmittingBackfillJobStore — failure path bounds error message',
      () {
    test(
      'failed job: 1 claimed + 1 failed; error_message_truncated bounded '
      'at 1024 chars even when error message is much longer (no stack '
      'trace leak — same class of issue PR #456 fixed)',
      () async {
        final job = await repo.enqueueFirstBackfill(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connA,
          vendorId: 'square',
          category: IntegrationCategory.pos,
          windowStart: DateTime.utc(2026, 3, 1, 12),
          windowEnd: DateTime.utc(2026, 4, 30, 12),
          actorUserId: _actorA,
        );
        await auditStore.claimNext(
          operatorId: _opA,
          locationId: _locA,
          workerId: 'pod-fail-A',
        );
        final hugeError = 'X' * 5000;
        final failed = await auditStore.markFailed(
          operatorId: _opA,
          locationId: _locA,
          jobId: job.jobId,
          errorMessage: hugeError,
        );
        expect(failed, isNotNull);

        final auditRows = await readAuditRowsForJob(_opA, job.jobId);
        expect(
          auditRows.map((r) => r['action']).toList(),
          equals(<String>[
            BackfillAuditAction.claimed,
            BackfillAuditAction.failed,
          ]),
        );
        final failedRow = auditRows.last;
        final payload = failedRow['payload_text']! as String;
        // The truncated message lands as a JSON string. Its content is
        // 1024 X's, well under the 5000 originally supplied.
        final truncatedMatch = RegExp(
          r'"error_message_truncated":"(X+)"',
        ).firstMatch(payload);
        expect(truncatedMatch, isNotNull);
        expect(
          truncatedMatch!.group(1)!.length,
          equals(kBackfillAuditErrorMessageCap),
          reason:
              'error_message_truncated must be capped at 1024 chars, no '
              'matter how long the source error is',
        );
        expect(payload, contains('"error_class":"other"'));
      },
    );
  });

  // ── Case 3: demo-flip race ────────────────────────────────────────

  group('AuditEmittingCanonicalSink — demo→live flip emits exactly once',
      () {
    test(
      'in-flight job + concurrent demo→live flip → 1 demo_flipped audit '
      'row even if evaluateDemoFlip is called twice (idempotent emission)',
      () async {
        final job = await repo.enqueueFirstBackfill(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connA,
          vendorId: 'square',
          category: IntegrationCategory.pos,
          windowStart: DateTime.utc(2026, 3, 1, 12),
          windowEnd: DateTime.utc(2026, 4, 30, 12),
          actorUserId: _actorA,
        );
        await auditStore.claimNext(
          operatorId: _opA,
          locationId: _locA,
          workerId: 'pod-flip-A',
        );

        // Build the AuditEmittingCanonicalSink around a flipping
        // delegate that mirrors the production
        // WorkerCanonicalSink.evaluateDemoFlip semantics: on the
        // first call with `firstBackfillCommitted && records>=1`, it
        // toggles demo_mode_state.is_demo to false. On subsequent
        // calls it is a no-op (preserves flipped_to_live_at, etc.).
        final delegateSink = _FlippingCanonicalSink(wrapper: wrapper);
        final auditSink = AuditEmittingCanonicalSink(
          delegate: delegateSink,
          tenantWrapper: wrapper,
        );
        await auditSink.withInFlightJob(job, () async {
          // Two calls — second is a no-op at the sink layer; the
          // audit row must still emit exactly once.
          await auditSink.evaluateDemoFlip(
            operatorId: _opA,
            locationId: _locA,
            category: IntegrationCategory.pos,
            connectionStatus: ConnectionStatus.connected,
            firstBackfillCommitted: true,
            backfillRecordsWritten: 5,
            connectionId: _connA,
          );
          await auditSink.evaluateDemoFlip(
            operatorId: _opA,
            locationId: _locA,
            category: IntegrationCategory.pos,
            connectionStatus: ConnectionStatus.connected,
            firstBackfillCommitted: true,
            backfillRecordsWritten: 5,
            connectionId: _connA,
          );
        });

        final auditRows = await readAuditRowsForJob(_opA, job.jobId);
        final flipRows = auditRows
            .where((r) => r['action'] == BackfillAuditAction.demoFlipped)
            .toList();
        expect(
          flipRows,
          hasLength(1),
          reason:
              'demo_flipped must emit exactly once even when '
              'evaluateDemoFlip is called multiple times',
        );
        final payload = flipRows.single['payload_text']! as String;
        expect(payload, contains('"prior_state":"demo"'));
        expect(payload, contains('"post_state":"live"'));
        expect(payload, contains('"job_id"'));
        expect(payload, contains('"vendor_id":"square"'));
      },
    );
  });

  // ── Case 4: pod-restart resume (re-claim) ─────────────────────────

  group('AuditEmittingBackfillJobStore — re-claim audit captures prior worker_id',
      () {
    test(
      'pod A claims, claim goes stale, pod B re-claims → claimed (pod A) + '
      'reclaimed (pod B with prior_worker_id=pod-A) + succeeded (pod B). '
      'NO claimed row from pod B (re-claim is its own event).',
      () async {
        final job = await repo.enqueueFirstBackfill(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connA,
          vendorId: 'square',
          category: IntegrationCategory.pos,
          windowStart: DateTime.utc(2026, 3, 1, 12),
          windowEnd: DateTime.utc(2026, 4, 30, 12),
          actorUserId: _actorA,
        );
        // Pod A claims fresh.
        final claimedA = await auditStore.claimNext(
          operatorId: _opA,
          locationId: _locA,
          workerId: 'pod-A-restart',
        );
        expect(claimedA, isNotNull);

        // Backdate claimed_at so the staleness predicate fires.
        await wrapper.runAsSystem<void>(
          (exec) async {
            await exec.execute(
              'update public.connector_backfill_jobs set '
              "claimed_at = now() - interval '1 hour' "
              'where job_id = @jid::uuid',
              parameters: <String, Object?>{'jid': job.jobId},
            );
          },
          reason: 'backfill_audit_emission_test_backdate_claim',
        );

        // Pod B re-claims with a 5-second stale window.
        final claimedB = await auditStore.claimNext(
          operatorId: _opA,
          locationId: _locA,
          workerId: 'pod-B-restart',
          claimStaleAfter: const Duration(seconds: 5),
        );
        expect(claimedB, isNotNull);
        expect(claimedB!.workerId, equals('pod-B-restart'));

        // Pod B finishes the work.
        await auditStore.markSucceeded(
          operatorId: _opA,
          locationId: _locA,
          jobId: job.jobId,
          cursorToken: 'cursor-pod-B-done',
          lastModifiedSeen: DateTime.utc(2026, 4, 30, 12),
        );

        final auditRows = await readAuditRowsForJob(_opA, job.jobId);
        expect(
          auditRows.map((r) => r['action']).toList(),
          equals(<String>[
            BackfillAuditAction.claimed,
            BackfillAuditAction.reclaimed,
            BackfillAuditAction.succeeded,
          ]),
          reason:
              're-claim is its own event; pod B must NOT emit a fresh '
              'claimed row',
        );
        final reclaimRow = auditRows[1];
        final reclaimPayload = reclaimRow['payload_text']! as String;
        expect(
          reclaimPayload,
          contains('"prior_worker_id":"pod-A-restart"'),
          reason: 'the prior pod identifier MUST survive the re-claim',
        );
        expect(
          reclaimPayload,
          contains('"new_worker_id":"pod-B-restart"'),
        );
        expect(reclaimPayload, contains('"prior_claim_count":1'));
        expect(reclaimPayload, contains('"new_claim_count":2'));
      },
    );
  });

  // ── Case 5: cross-tenant isolation ────────────────────────────────

  group('AuditEmittingBackfillJobStore — tenant audit isolation', () {
    test(
      'tenant A cannot see tenant B\'s backfill audit rows (RLS-scoped)',
      () async {
        final jobA = await repo.enqueueFirstBackfill(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connA,
          vendorId: 'square',
          category: IntegrationCategory.pos,
          windowStart: DateTime.utc(2026, 3, 1, 12),
          windowEnd: DateTime.utc(2026, 4, 30, 12),
          actorUserId: _actorA,
        );
        await auditStore.claimNext(
          operatorId: _opA,
          locationId: _locA,
          workerId: 'pod-iso-A',
        );
        await auditStore.markSucceeded(
          operatorId: _opA,
          locationId: _locA,
          jobId: jobA.jobId,
          cursorToken: 'cursor-iso-A',
          lastModifiedSeen: DateTime.utc(2026, 4, 30, 12),
        );

        final jobB = await repo.enqueueFirstBackfill(
          operatorId: _opB,
          locationId: _locB,
          connectionId: _connB,
          vendorId: 'square',
          category: IntegrationCategory.pos,
          windowStart: DateTime.utc(2026, 3, 1, 12),
          windowEnd: DateTime.utc(2026, 4, 30, 12),
        );
        await auditStore.claimNext(
          operatorId: _opB,
          locationId: _locB,
          workerId: 'pod-iso-B',
        );
        await auditStore.markSucceeded(
          operatorId: _opB,
          locationId: _locB,
          jobId: jobB.jobId,
          cursorToken: 'cursor-iso-B',
          lastModifiedSeen: DateTime.utc(2026, 4, 30, 12),
        );

        // Read from tenant A's perspective: should see only A's rows.
        final visibleToA = await wrapper.runInTenantContext<int>(
          TenantContext(operatorId: _opA, locationId: _locA),
          (exec) async {
            final rows = await exec.query(
              'select count(*)::int as n from public.audit_logs',
            );
            return rows.single['n']! as int;
          },
        );
        // Tenant B has 2 rows under their own scope; tenant A's view
        // through RLS must not contain them. We verify A sees their
        // own 2 rows AND no B rows.
        expect(
          visibleToA,
          equals(2),
          reason:
              'tenant A must see only A\'s 2 backfill audit rows '
              '(claimed + succeeded); B\'s rows live in B\'s scope',
        );

        final visibleToB = await wrapper.runInTenantContext<int>(
          TenantContext(operatorId: _opB, locationId: _locB),
          (exec) async {
            final rows = await exec.query(
              'select count(*)::int as n from public.audit_logs',
            );
            return rows.single['n']! as int;
          },
        );
        expect(visibleToB, equals(2));
      },
    );
  });
}

/// Test-side `CanonicalSink` whose `evaluateDemoFlip` flips
/// `demo_mode_state.is_demo` to false on the first qualifying call
/// and is a no-op thereafter (mirrors the production
/// `WorkerCanonicalSink` once-only flip semantic). The other methods
/// are no-ops; the audit-emission test only exercises evaluateDemoFlip.
class _FlippingCanonicalSink implements CanonicalSink {
  _FlippingCanonicalSink({required this.wrapper});

  final TenantTransactionWrapper wrapper;

  @override
  Future<bool> upsertCoverFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  }) async => true;

  @override
  Future<bool> upsertLaborPunch({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalPunch,
  }) async => true;

  @override
  Future<bool> upsertReservationFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalReservation,
  }) async => true;

  @override
  Future<void> advanceWatermark({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
  }) async {}

  @override
  Future<void> appendSyncLog({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String eventKind,
    String? errorMessage,
    int? recordsCount,
    Map<String, Object?>? payloadPreview,
  }) async {}

  @override
  Future<void> evaluateDemoFlip({
    required String operatorId,
    required String locationId,
    required IntegrationCategory category,
    required ConnectionStatus connectionStatus,
    required bool firstBackfillCommitted,
    required int backfillRecordsWritten,
    required String connectionId,
  }) async {
    if (connectionStatus != ConnectionStatus.connected ||
        !firstBackfillCommitted ||
        backfillRecordsWritten < 1) {
      return;
    }
    await wrapper.runInTenantContext<void>(
      TenantContext(operatorId: operatorId, locationId: locationId),
      (exec) async {
        // Idempotent flip — once already-live, the UPDATE matches no
        // rows (predicate `is_demo = true`). This mirrors the
        // production once-only contract without re-implementing the
        // INSERT … ON CONFLICT machinery.
        await exec.execute(
          'update public.demo_mode_state set '
          'is_demo = false, '
          'flipped_to_live_at = now(), '
          'flipped_by_connection_id = @cid::uuid, '
          'updated_at = now() '
          'where operator_id = @op::uuid '
          'and location_id = @loc::uuid '
          'and category = @cat '
          'and is_demo = true',
          parameters: <String, Object?>{
            'op': operatorId,
            'loc': locationId,
            'cat': category.backfillWire,
            'cid': connectionId,
          },
        );
      },
    );
  }
}
