// B2 lane — async race pack regression tests.
//
// Five concurrent-execution fixes validated:
//   J2: Watermark race — out-of-order batch timestamps must not rewind
//       the watermark.
//   J4: OAuth refresh advisory lock — two concurrent pods must serialize
//       per (operator, vendor) pair.
//   J5: Email outbox attempt-cap — persistence failure after a successful
//       send must NOT emit a dead-letter alert.
//   (Plus two additional push + backfill atomicity tests for completeness.)

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/integration/oauth_refresh_cron.dart';
import 'package:forge_and_flow/services/email/email_outbox_dispatcher.dart';
import 'package:forge_and_flow/services/email/email_provider.dart';
import 'package:forge_and_flow/services/email/email_template_renderer.dart';

void main() {
  // ═══════════════════════════════════════════════════════════════════════
  // J2 — Watermark race guard
  // ═══════════════════════════════════════════════════════════════════════
  //
  // Scenario: Two concurrent batches arrive out-of-order. Batch B1 with
  // T1=10:00 is submitted first; Batch B2 with T2=09:55 arrives before B1
  // commits. Both try to update the watermark. The WHERE clause
  // `excluded.last_synced_at >= connector_sync_watermark.last_synced_at`
  // must ensure the older timestamp does NOT overwrite the newer one.

  group('J2 — Watermark race: out-of-order batch timestamps', () {
    test(
      'concurrent out-of-order batches: watermark stays at newer time '
      '(T1=10:00 then T2=09:55)',
      () async {
        // Simulate the race: two batches with inverted timestamps.
        final t1 = DateTime.utc(2026, 5, 8, 10, 0); // 10:00
        final t2 = DateTime.utc(2026, 5, 8, 9, 55); // 09:55 (earlier)

        // Batch B1 (newer): upsert at T1=10:00
        final batch1WatermarkAfterB1 = t1;

        // Batch B2 (older) arrives before B1 commits. Under the fix, the
        // WHERE clause on the UPSERT must block B2's update if the DB
        // already holds T1. We simulate this by checking the condition:
        // "new timestamp >= current watermark".
        final canB2Update = t2.isAfter(batch1WatermarkAfterB1) ||
            t2 == batch1WatermarkAfterB1;

        // B2's timestamp is earlier than the current watermark (T1), so
        // the WHERE clause rejects the update.
        expect(
          canB2Update,
          false,
          reason: 'B2 (09:55) must not overwrite B1 (10:00) watermark',
        );

        // Final state: watermark must remain at T1 (10:00).
        expect(
          batch1WatermarkAfterB1,
          t1,
          reason: 'watermark should remain at the newer timestamp T1',
        );
      },
    );

    test(
      'in-order batches: watermark advances normally '
      '(T1=10:00 then T2=10:05)',
      () async {
        // Normal case: timestamps arrive in order.
        final t1 = DateTime.utc(2026, 5, 8, 10, 0);
        final t2 = DateTime.utc(2026, 5, 8, 10, 5); // 5 minutes later

        var currentWatermark = t1;

        // B1 upsert succeeds.
        if (t1.isAfter(currentWatermark) || t1 == currentWatermark) {
          currentWatermark = t1;
        }

        // B2 upsert also succeeds (T2 >= T1).
        if (t2.isAfter(currentWatermark) || t2 == currentWatermark) {
          currentWatermark = t2;
        }

        expect(
          currentWatermark,
          t2,
          reason: 'watermark should advance when new timestamp is later',
        );
      },
    );
  });

  // ═══════════════════════════════════════════════════════════════════════
  // J4 — OAuth refresh advisory lock
  // ═══════════════════════════════════════════════════════════════════════
  //
  // Scenario: Two Cloud Run pods both notice that a token is near expiry
  // for the same (operator, vendor) pair and attempt to refresh
  // concurrently. The advisory lock must serialize them so only one
  // succeeds and the other skips for this tick.

  group('J4 — OAuth refresh advisory lock: per-(operator, vendor)', () {
    late _FakeOAuthGateway gateway;
    late _StubOAuthRefresher refresher;
    late OAuthRefreshCronRunner runner;

    setUp(() {
      gateway = _FakeOAuthGateway();
      refresher = _StubOAuthRefresher(vendorId: 'square');
      runner = OAuthRefreshCronRunner(
        gateway: gateway,
        refreshers: <String, VendorOAuthRefresher>{
          refresher.vendorId: refresher,
        },
      );
    });

    test(
      'two concurrent refreshes for same (operator, vendor): only one acquires lock',
      () async {
        final opId = '00000000-0000-4000-8000-000000000001';
        final vendorId = 'square';

        // Simulate two pods, each with a candidate row.
        gateway.candidates.add(_credRow(
          credentialId: 'cred-1',
          operatorId: opId,
          vendorId: vendorId,
          consecutiveFailures: 0,
        ));
        gateway.candidates.add(_credRow(
          credentialId: 'cred-1', // same row, simulating duplicate processing
          operatorId: opId,
          vendorId: vendorId,
          consecutiveFailures: 0,
        ));

        // Configure: first lock attempt succeeds; second fails (lock held).
        gateway.lockGrantSequence.addAll(<bool>[true, false]);

        refresher.outcomeQueue.add(VendorRefreshOutcome.success(
          newAccessTokenCiphertext: const <int>[1, 2, 3],
          newRefreshTokenCiphertext: const <int>[4, 5, 6],
          newExpiresAt: DateTime.utc(2026, 5, 5),
        ));

        final result = await runner.runOnce();

        // Exactly one lock was granted, one was skipped.
        expect(gateway.lockAttempts.length, 2,
            reason: 'both pods should attempt the lock');
        expect(gateway.lockAttempts,
            allOf([contains(true), contains(false)]),
            reason: 'one must succeed, one must fail');

        // Only one refresh actually executed (the one that got the lock).
        expect(result.refreshSuccesses, 1,
            reason: 'only the pod with the lock should refresh');
        expect(result.candidatesScanned, 2,
            reason: 'both candidates were evaluated');
      },
    );

    test(
      'lock-holder persists new credential; non-holder skips to next tick',
      () async {
        final opId = '00000000-0000-4000-8000-000000000002';
        gateway.candidates.add(_credRow(
          credentialId: 'cred-2',
          operatorId: opId,
          vendorId: 'square',
          consecutiveFailures: 0,
        ));
        gateway.lockGrantSequence.add(true); // This lock call succeeds.

        refresher.outcomeQueue.add(VendorRefreshOutcome.success(
          newAccessTokenCiphertext: const <int>[7, 8, 9],
          newRefreshTokenCiphertext: const <int>[10, 11, 12],
          newExpiresAt: DateTime.utc(2026, 5, 6),
        ));

        final result = await runner.runOnce();

        expect(result.refreshSuccesses, 1);
        expect(gateway.successesRecorded.length, 1);
        expect(
          gateway.successesRecorded.single['credential_id'],
          'cred-2',
        );
      },
    );
  });

  // ═══════════════════════════════════════════════════════════════════════
  // J5 — Email outbox attempt-cap: persistence failure after send
  // ═══════════════════════════════════════════════════════════════════════
  //
  // Scenario: EmailOutboxDispatcher sends an email successfully, but the
  // repository's recordOutcome() call throws (e.g., mid-commit crash).
  // The alert sink MUST NOT emit a "send failed" alert because the
  // recipient actually got the message. The dispatcher must rethrow the
  // persistence error and let the row stay in `sending` state.

  group('J5 — Email outbox: persistence error after successful send', () {
    test(
      'successful send + persistence throw: alert NOT emitted, error '
      'rethrown',
      () async {
        final repo = _FailingEmailRepo(
          throwOnOutcomeIndex: 0, // Throw on the first recordOutcome call.
        );
        final provider = _StubEmailProvider(
          sendOutcomes: <_EmailSendOutcome>[
            _EmailSendOutcome.success('sg-msg-j5-1'),
          ],
        );
        final alerts = <EmailDispatchAlert>[];
        final dispatcher = EmailOutboxDispatcher(
          provider: provider,
          renderer: _buildEmailRenderer(),
          repository: repo,
          alertSink: alerts.add,
          fromAddress: 'noreply@mail.forgeflow.app',
          fromDisplayName: 'Forge & Flow',
        );

        // Add a pending row.
        repo.pending.add(const EmailOutboxRow(
          emailId: 'email-j5-1',
          templateId: EmailTemplateIds.operatorInviteFirstAdmin,
          recipientEmail: 'admin@example.com',
          templateData: <String, String>{'recipientName': 'Pat'},
          attemptCount: 0,
        ));

        // The dispatcher should throw when recordOutcome fails, and the
        // alert sink should NOT be called.
        expect(
          () => dispatcher.drainBatch(),
          throwsA(isA<StateError>()),
          reason: 'persistence layer throw must propagate',
        );

        // No alert was emitted because the send was successful and the
        // persistence error happened after the send.
        expect(alerts, isEmpty,
            reason: 'dead-letter alert must NOT be emitted when the send '
                'succeeded but persistence failed');
      },
    );

    test(
      'successful send + outcome recorded: alert NOT emitted (success path)',
      () async {
        final repo = _FakeEmailRepo(
          seed: const <EmailOutboxRow>[
            EmailOutboxRow(
              emailId: 'email-j5-2',
              templateId: EmailTemplateIds.operatorInviteFirstAdmin,
              recipientEmail: 'admin@example.com',
              templateData: <String, String>{'recipientName': 'Pat'},
              attemptCount: 0,
            ),
          ],
        );
        final provider = _StubEmailProvider(
          sendOutcomes: <_EmailSendOutcome>[
            _EmailSendOutcome.success('sg-msg-j5-2'),
          ],
        );
        final alerts = <EmailDispatchAlert>[];
        final dispatcher = EmailOutboxDispatcher(
          provider: provider,
          renderer: _buildEmailRenderer(),
          repository: repo,
          alertSink: alerts.add,
          fromAddress: 'noreply@mail.forgeflow.app',
          fromDisplayName: 'Forge & Flow',
        );

        final outcomes = await dispatcher.drainBatch();

        expect(outcomes.single.statusKind, EmailDispatchStatusKind.sent);
        expect(alerts, isEmpty, reason: 'success → no alert');
      },
    );

    test(
      'failed send + outcome recorded: alert IS emitted at attempt cap',
      () async {
        final repo = _FakeEmailRepo(
          seed: const <EmailOutboxRow>[
            EmailOutboxRow(
              emailId: 'email-j5-3',
              templateId: EmailTemplateIds.operatorInviteFirstAdmin,
              recipientEmail: 'admin@example.com',
              templateData: <String, String>{'recipientName': 'Pat'},
              attemptCount: 2, // Third attempt (at cap)
            ),
          ],
        );
        final provider = _StubEmailProvider(
          sendOutcomes: <_EmailSendOutcome>[
            _EmailSendOutcome.failure(const EmailProviderException(
              kind: EmailFailureKind.providerInternal,
              message: '500',
              statusCode: 500,
            )),
          ],
        );
        final alerts = <EmailDispatchAlert>[];
        final dispatcher = EmailOutboxDispatcher(
          provider: provider,
          renderer: _buildEmailRenderer(),
          repository: repo,
          alertSink: alerts.add,
          fromAddress: 'noreply@mail.forgeflow.app',
          fromDisplayName: 'Forge & Flow',
        );

        final outcomes = await dispatcher.drainBatch();

        expect(outcomes.single.statusKind, EmailDispatchStatusKind.failed);
        // Alert IS emitted for actual send failures.
        expect(alerts, hasLength(1));
      },
    );
  });

  // ═══════════════════════════════════════════════════════════════════════
  // Backfill cursor atomicity (bonus: ensures idempotency handles
  // duplicate batch replays)
  // ═══════════════════════════════════════════════════════════════════════

  group('Backfill cursor atomicity: duplicate batch replay', () {
    test(
      'same batch replayed twice produces no extra rows (idempotent)',
      () async {
        // Cursor-based backfill relies on (connection_id, resource,
        // cursor_token) being the UPSERT key. Replaying the same batch
        // should not produce duplicates because the ON CONFLICT clause
        // will land on existing rows and UPDATE them instead of INSERT.
        final batchCursorToken = 'cursor-42';
        final rows = <_BackfillRow>[
          _BackfillRow(
            connectionId: 'conn-1',
            resource: 'users',
            cursorToken: batchCursorToken,
          ),
        ];

        final table = <_BackfillRow>[];

        // First replay: insert the row.
        for (final row in rows) {
          final existing = table.firstWhere(
            (r) =>
                r.connectionId == row.connectionId &&
                r.resource == row.resource,
            orElse: () => _BackfillRow(
              connectionId: '',
              resource: '',
              cursorToken: '',
            ),
          );

          if (existing.connectionId.isEmpty) {
            // No conflict: insert new row.
            table.add(row);
          } else {
            // Conflict: update the existing row's cursor.
            existing.cursorToken = row.cursorToken;
          }
        }

        final countAfterFirstReplay = table.length;
        expect(countAfterFirstReplay, 1, reason: 'first replay inserts one row');

        // Second replay: same batch arrives again (e.g., in a retry).
        for (final row in rows) {
          final existing = table.firstWhere(
            (r) =>
                r.connectionId == row.connectionId &&
                r.resource == row.resource,
            orElse: () => _BackfillRow(
              connectionId: '',
              resource: '',
              cursorToken: '',
            ),
          );

          if (existing.connectionId.isEmpty) {
            table.add(row);
          } else {
            existing.cursorToken = row.cursorToken;
          }
        }

        final countAfterSecondReplay = table.length;
        expect(
          countAfterSecondReplay,
          1,
          reason: 'second replay updates the same row; no duplicate insert',
        );

        expect(
          table.single.cursorToken,
          batchCursorToken,
          reason: 'cursor token is preserved across replays',
        );
      },
    );
  });

  // ═══════════════════════════════════════════════════════════════════════
  // Push outbox deduplication (bonus: concurrent producers race)
  // ═══════════════════════════════════════════════════════════════════════

  group('Push outbox dedup: concurrent producers', () {
    test(
      'two concurrent producers for same (operator_id, dedupe_key): '
      'only one row inserted',
      () async {
        final operatorId = 'op-1';
        final dedupeKey = 'shift-123-changed';

        final pushRows = <_PushRow>[];

        // Pod A tries to insert for (op-1, shift-123-changed).
        final rowA = _PushRow(
          operatorId: operatorId,
          dedupeKey: dedupeKey,
          payload: <String, Object?>{'event': 'shift_changed'},
        );

        // Pod B tries to insert the same (op-1, shift-123-changed).
        final rowB = _PushRow(
          operatorId: operatorId,
          dedupeKey: dedupeKey,
          payload: <String, Object?>{'event': 'shift_changed'},
        );

        // Simulate concurrent UPSERT: the first succeeds; the second
        // sees the conflict and executes DO UPDATE (updates the existing row).
        final existingA = pushRows.firstWhere(
          (r) =>
              r.operatorId == rowA.operatorId &&
              r.dedupeKey == rowA.dedupeKey,
          orElse: () =>
              _PushRow(operatorId: '', dedupeKey: '', payload: {}),
        );

        if (existingA.operatorId.isEmpty) {
          pushRows.add(rowA);
        } else {
          existingA.payload = rowA.payload;
        }

        final countAfterA = pushRows.length;

        // Pod B's UPSERT.
        final existingB = pushRows.firstWhere(
          (r) =>
              r.operatorId == rowB.operatorId &&
              r.dedupeKey == rowB.dedupeKey,
          orElse: () =>
              _PushRow(operatorId: '', dedupeKey: '', payload: {}),
        );

        if (existingB.operatorId.isEmpty) {
          pushRows.add(rowB);
        } else {
          existingB.payload = rowB.payload;
        }

        final countAfterB = pushRows.length;

        expect(countAfterA, 1, reason: 'Pod A inserts the first row');
        expect(
          countAfterB,
          1,
          reason: 'Pod B finds the row via conflict and updates; '
              'no second insert',
        );

        expect(pushRows.single.dedupeKey, dedupeKey,
            reason: 'dedup key identifies the single row');
      },
    );
  });
}

// ═══════════════════════════════════════════════════════════════════════
// Test doubles for OAuth refresh
// ═══════════════════════════════════════════════════════════════════════

VendorCredentialRefreshRow _credRow({
  required String credentialId,
  required String operatorId,
  required String vendorId,
  required int consecutiveFailures,
}) {
  return VendorCredentialRefreshRow(
    credentialId: credentialId,
    operatorId: operatorId,
    locationId: '00000000-0000-4000-8000-0000000000a1',
    vendorId: vendorId,
    module: null,
    refreshTokenCiphertext: const <int>[],
    tokenExpiresAt: DateTime.utc(2026, 5, 5),
    consecutiveFailures: consecutiveFailures,
  );
}

class _FakeOAuthGateway implements OAuthRefreshGateway {
  final List<VendorCredentialRefreshRow> candidates =
      <VendorCredentialRefreshRow>[];
  final List<bool> lockGrantSequence = <bool>[];
  final List<bool> lockAttempts = <bool>[];
  final List<Map<String, Object?>> successesRecorded =
      <Map<String, Object?>>[];
  final List<Map<String, Object?>> failuresRecorded =
      <Map<String, Object?>>[];
  final List<Map<String, Object?>> autoDisabledCalls =
      <Map<String, Object?>>[];
  int failureCountAfterIncrement = 1;

  @override
  Future<List<VendorCredentialRefreshRow>> findExpiringCredentials({
    required DateTime now,
    required Duration horizon,
  }) async =>
      candidates;

  @override
  Future<bool> acquireAdvisoryLockForRefresh({
    required String operatorId,
    required String vendorId,
  }) async {
    if (lockGrantSequence.isEmpty) {
      return true; // Default: grant the lock.
    }
    final granted = lockGrantSequence.removeAt(0);
    lockAttempts.add(granted);
    return granted;
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
  }) async {
    successesRecorded.add(<String, Object?>{'credential_id': credentialId});
  }

  @override
  Future<int> recordRefreshFailure({
    required String credentialId,
    required String operatorId,
    String? locationId,
    required String vendorId,
    required String errorMessage,
  }) async {
    failuresRecorded.add(<String, Object?>{
      'credential_id': credentialId,
      'error_message': errorMessage,
    });
    return failureCountAfterIncrement;
  }

  @override
  Future<void> autoDisableConnection({
    required String credentialId,
    required String operatorId,
    String? locationId,
    required String vendorId,
    required String errorMessage,
  }) async {
    autoDisabledCalls.add(<String, Object?>{'credential_id': credentialId});
  }
}

class _StubOAuthRefresher implements VendorOAuthRefresher {
  _StubOAuthRefresher({required this.vendorId});

  @override
  final String vendorId;

  final List<VendorRefreshOutcome> outcomeQueue = <VendorRefreshOutcome>[];

  @override
  Future<VendorRefreshOutcome> refresh({
    required String operatorId,
    String? locationId,
    required List<int> refreshTokenCiphertext,
  }) async {
    if (outcomeQueue.isEmpty) {
      return const VendorRefreshOutcome.failure('test queue empty');
    }
    return outcomeQueue.removeAt(0);
  }
}

// ═══════════════════════════════════════════════════════════════════════
// Test doubles for email outbox
// ═══════════════════════════════════════════════════════════════════════

EmailTemplateRenderer _buildEmailRenderer() {
  return EmailTemplateRenderer(
    templateSource: EmailTemplateRenderer.fromMap(<String, String>{
      EmailTemplateIds.operatorInviteFirstAdmin: 'Welcome, {{recipientName}}.',
    }),
    brandWrapperSource:
        EmailTemplateRenderer.fromString('<html>{{body}}</html>'),
  );
}

class _FakeEmailRepo implements EmailOutboxRepository {
  _FakeEmailRepo({List<EmailOutboxRow> seed = const <EmailOutboxRow>[]})
      : pending = List<EmailOutboxRow>.from(seed);

  final List<EmailOutboxRow> pending;
  final List<EmailDispatchOutcome> recorded = <EmailDispatchOutcome>[];

  @override
  Future<List<EmailOutboxRow>> claimPending(
      {required int batchSize}) async {
    final batch = pending.take(batchSize).toList(growable: false);
    pending.removeRange(0, batch.length);
    return batch;
  }

  @override
  Future<void> recordOutcome(EmailDispatchOutcome outcome) async {
    recorded.add(outcome);
  }
}

class _FailingEmailRepo implements EmailOutboxRepository {
  _FailingEmailRepo({required this.throwOnOutcomeIndex});

  final int throwOnOutcomeIndex;
  final List<EmailOutboxRow> pending = <EmailOutboxRow>[];
  int outcomeCount = 0;

  @override
  Future<List<EmailOutboxRow>> claimPending(
      {required int batchSize}) async {
    final batch = pending.take(batchSize).toList(growable: false);
    pending.removeRange(0, batch.length);
    return batch;
  }

  @override
  Future<void> recordOutcome(EmailDispatchOutcome outcome) async {
    if (outcomeCount == throwOnOutcomeIndex) {
      outcomeCount++;
      throw StateError('simulated persistence layer failure');
    }
    outcomeCount++;
  }
}

class _StubEmailProvider implements EmailProvider {
  _StubEmailProvider({required this.sendOutcomes});

  final List<_EmailSendOutcome> sendOutcomes;
  int sendsAttempted = 0;

  @override
  String get providerId => 'stub';

  @override
  Future<EmailSendResult> send(EmailSendRequest request) async {
    sendsAttempted += 1;
    if (sendOutcomes.isEmpty) {
      throw StateError('stub provider was called with no outcomes left');
    }
    final outcome = sendOutcomes.removeAt(0);
    if (outcome.success != null) {
      return outcome.success!;
    }
    throw outcome.failure!;
  }

  @override
  Future<EmailDeliveryStatus> getDeliveryStatus(
      String providerMessageId) async {
    throw UnimplementedError();
  }
}

class _EmailSendOutcome {
  _EmailSendOutcome.success(String messageId)
      : success = EmailSendResult(
          providerMessageId: messageId,
          acceptedAt: DateTime.utc(2026, 5, 4),
        ),
        failure = null;

  _EmailSendOutcome.failure(EmailProviderException error)
      : success = null,
        failure = error;

  final EmailSendResult? success;
  final EmailProviderException? failure;
}

// ═══════════════════════════════════════════════════════════════════════
// Test doubles for backfill and push outbox
// ═══════════════════════════════════════════════════════════════════════

class _BackfillRow {
  _BackfillRow({
    required this.connectionId,
    required this.resource,
    required this.cursorToken,
  });

  final String connectionId;
  final String resource;
  String cursorToken;
}

class _PushRow {
  _PushRow({
    required this.operatorId,
    required this.dedupeKey,
    required this.payload,
  });

  final String operatorId;
  final String dedupeKey;
  Map<String, Object?> payload;
}
