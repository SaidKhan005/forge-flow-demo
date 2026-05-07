// Phase 8 framework — RepositoryInboundWebhookGateway tests.
//
// Covers the four behaviours the slice promises:
//
//   1. Duplicate webhook (same vendor+event_id) — second
//      `claimIdempotency` call returns `duplicate` because the UNIQUE
//      constraint short-circuits the INSERT (zero rows returned).
//   2. Synthetic event_id soft cap — once
//      [kSyntheticEventIdSoftCap] unprocessed synthetic rows exist,
//      the next claim short-circuits to dead-letter without
//      incrementing the attempts counter or growing the idempotency
//      table further.
//   3. PII in payload — the redactor strips sensitive field names
//      from every preview the gateway writes
//      (`connector_sync_log.payload_preview`,
//      `inbound_webhook_dead_letter.payload_preview`,
//      `sanity_log.payload_summary`).
//   4. Cross-tenant isolation — every write rides
//      `withTenant(operator_id, location_id)` so SET LOCAL injects
//      the tenant context before any DB write.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/integration/inbound_webhook_handler.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/repository_inbound_webhook_gateway.dart';

const String _opId = '11111111-2222-3333-4444-555555555555';
const String _locId = '66666666-7777-8888-9999-aaaaaaaaaaaa';
const String _otherOpId = 'bbbbbbbb-cccc-dddd-eeee-ffffffffffff';
const String _vendorId = 'libro';
const String _vendorEventId = 'evt-001';
const String _envelopeKey = 'test-pgcrypto-envelope-key';

void main() {
  group('redactWebhookPayload (pure function)', () {
    test('drops sensitive top-level keys', () {
      final out = redactWebhookPayload(<String, Object?>{
        'reservation_id': 'rsv-1',
        'password': 'sekret',
        'access_token': 'aaa',
        'email': 'guest@example.com',
        'guest_email': 'guest@example.com',
        'phone': '555-0100',
        'guest_name': 'Alice',
        'first_name': 'Alice',
        'authorization': 'Bearer xyz',
      });
      expect(out, <String, Object?>{
        'reservation_id': 'rsv-1',
      });
    });

    test('drops sensitive keys nested in maps and lists', () {
      final out = redactWebhookPayload(<String, Object?>{
        'event_id': 'evt-1',
        'guest': <String, Object?>{
          'first_name': 'Alice',
          'last_name': 'Lee',
          'email_address': 'alice@example.com',
          'phone_number': '555-0100',
          'loyalty': <String, Object?>{
            'tier': 'gold',
            'guest_email': 'alice@example.com',
          },
        },
        'card_number': '4111111111111111',
        'parties': <Map<String, Object?>>[
          <String, Object?>{
            'guest_email': 'a@b.com',
            'party_size': 2,
          },
        ],
      });
      expect(out, <String, Object?>{
        'event_id': 'evt-1',
        'guest': <String, Object?>{
          'loyalty': <String, Object?>{'tier': 'gold'},
        },
        'parties': <Map<String, Object?>>[
          <String, Object?>{'party_size': 2},
        ],
      });
    });

    test('substring rules drop bespoke vendor field names', () {
      // Field names that are not in the explicit set but contain
      // `token` / `secret` / `password` / `api_key` are still dropped.
      final out = redactWebhookPayload(<String, Object?>{
        'reservation_id': 'rsv-1',
        'session_token': 'tk-abc',
        'webhook_signature_secret': 'whsec-xyz',
        'vendor_apikey': 'ak-1',
        'admin_password_hash': 'pw-hash',
      });
      expect(out, <String, Object?>{
        'reservation_id': 'rsv-1',
      });
    });

    test('hashed surrogates are NOT dropped (their key contains hash)',
        () {
      // The redactor drops *_email but allows *_email_hash because
      // hashed surrogates carry no PII.
      final out = redactWebhookPayload(<String, Object?>{
        'guest_email_hash': 'sha256:abc',
        'email_domain': 'example.com',
      });
      expect(out['guest_email_hash'], equals('sha256:abc'));
      expect(out['email_domain'], equals('example.com'));
    });
  });

  group('claimIdempotency', () {
    test('first call returns firstTime, INSERT runs', () async {
      final pool = _GatewayPool(
        idempotencyInsertReturning: 'idem-1',
      );
      final gw = RepositoryInboundWebhookGateway(
        TenantTransactionWrapper(pool),
        pgcryptoEnvelopeKey: _envelopeKey,
      );

      final outcome = await gw.claimIdempotency(
        operatorId: _opId,
        locationId: _locId,
        vendorId: _vendorId,
        vendorEventId: _vendorEventId,
        receivedAt: DateTime.utc(2026, 5, 6, 12),
      );

      expect(outcome, IdempotencyOutcome.firstTime);
      final tx = pool.transactions.single;
      // SET LOCAL ran first.
      expect(
        tx.executedSql.first,
        contains("'app.operator_id'"),
        reason: 'tenant SET LOCAL must run before any DB read',
      );
      // INSERT included ON CONFLICT DO NOTHING.
      final insertSql =
          tx.executedSql.firstWhere((s) => s.contains('insert into '
              'public.inbound_webhook_idempotency'));
      expect(insertSql, contains('on conflict'));
      expect(insertSql, contains('do nothing'));
    });

    test('duplicate vendor_event_id returns duplicate without re-processing',
        () async {
      final pool = _GatewayPool(
        idempotencyInsertReturning: null, // ON CONFLICT short-circuit
      );
      final gw = RepositoryInboundWebhookGateway(
        TenantTransactionWrapper(pool),
        pgcryptoEnvelopeKey: _envelopeKey,
      );

      final outcome = await gw.claimIdempotency(
        operatorId: _opId,
        locationId: _locId,
        vendorId: _vendorId,
        vendorEventId: _vendorEventId,
        receivedAt: DateTime.utc(2026, 5, 6, 12),
      );

      expect(outcome, IdempotencyOutcome.duplicate);
      // Second call: no second INSERT runs in the gateway, only the
      // DB's UNIQUE short-circuits — the gateway always issues exactly
      // one INSERT. Caller (handler) is responsible for not invoking
      // adapter dispatch when the gateway returns duplicate.
      expect(
        pool.transactions.single.executedSql
            .where((s) => s.contains('insert into '
                'public.inbound_webhook_idempotency'))
            .length,
        1,
      );
    });
  });

  group('synthetic event-id cap', () {
    test('claim short-circuits to dead-letter once cap is reached', () async {
      final pool = _GatewayPool(
        unprocessedSyntheticCount: kSyntheticEventIdSoftCap,
      );
      final gw = RepositoryInboundWebhookGateway(
        TenantTransactionWrapper(pool),
        pgcryptoEnvelopeKey: _envelopeKey,
      );

      final outcome = await gw.claimIdempotency(
        operatorId: _opId,
        locationId: _locId,
        vendorId: _vendorId,
        vendorEventId: 'sha256:deadbeef-${DateTime.now().millisecond}',
        receivedAt: DateTime.utc(2026, 5, 6, 12),
      );

      expect(outcome, IdempotencyOutcome.duplicate);

      // Verify a count(*) ran first, then a dead-letter row was
      // written, and NO insert into inbound_webhook_idempotency.
      final tx = pool.transactions.single;
      final dbSql = tx.executedSql
          .where((s) => !s.contains('app.'))
          .toList();
      expect(
        dbSql.any((s) => s.contains('count(*)') &&
            s.contains('inbound_webhook_idempotency') &&
            s.contains('processed = false') &&
            s.contains("vendor_event_id like 'sha256:%'")),
        isTrue,
        reason: 'must count UNPROCESSED synthetic rows for the triple',
      );
      expect(
        dbSql.any((s) => s.contains('insert into '
            'public.inbound_webhook_dead_letter')),
        isTrue,
        reason: 'cap reached → dead-letter row must be written',
      );
      expect(
        dbSql.any((s) => s.contains('insert into '
            'public.inbound_webhook_idempotency')),
        isFalse,
        reason: 'cap reached → idempotency table must NOT grow further',
      );
    });

    test('below cap behaves normally and inserts the idempotency row',
        () async {
      final pool = _GatewayPool(
        unprocessedSyntheticCount: kSyntheticEventIdSoftCap - 1,
        idempotencyInsertReturning: 'idem-1',
      );
      final gw = RepositoryInboundWebhookGateway(
        TenantTransactionWrapper(pool),
        pgcryptoEnvelopeKey: _envelopeKey,
      );

      final outcome = await gw.claimIdempotency(
        operatorId: _opId,
        locationId: _locId,
        vendorId: _vendorId,
        vendorEventId: 'sha256:still-room',
        receivedAt: DateTime.utc(2026, 5, 6, 12),
      );

      expect(outcome, IdempotencyOutcome.firstTime);
      final tx = pool.transactions.single;
      expect(
        tx.executedSql.any((s) => s.contains('insert into '
            'public.inbound_webhook_dead_letter')),
        isFalse,
      );
    });

    test('non-synthetic event-ids skip the cap query entirely', () async {
      final pool = _GatewayPool(
        idempotencyInsertReturning: 'idem-1',
      );
      final gw = RepositoryInboundWebhookGateway(
        TenantTransactionWrapper(pool),
        pgcryptoEnvelopeKey: _envelopeKey,
      );

      await gw.claimIdempotency(
        operatorId: _opId,
        locationId: _locId,
        vendorId: _vendorId,
        vendorEventId: 'real-vendor-event-id',
        receivedAt: DateTime.utc(2026, 5, 6, 12),
      );

      final tx = pool.transactions.single;
      expect(
        tx.executedSql.any((s) => s.contains('count(*)') &&
            s.contains('inbound_webhook_idempotency')),
        isFalse,
        reason:
            'vendor-issued ids never trip the synthetic-cap pre-check',
      );
    });
  });

  group('appendSyncLog redacts PII', () {
    test('payload_preview is scrubbed of sensitive keys before INSERT',
        () async {
      final pool = _GatewayPool();
      final gw = RepositoryInboundWebhookGateway(
        TenantTransactionWrapper(pool),
        pgcryptoEnvelopeKey: _envelopeKey,
      );

      await gw.appendSyncLog(
        operatorId: _opId,
        locationId: _locId,
        connectionId: 'cccccccc-1111-2222-3333-444444444444',
        eventKind: 'webhook_received',
        recordsCount: 1,
        payloadPreview: <String, Object?>{
          'reservation_id': 'rsv-1',
          'guest_email': 'guest@example.com',
          'guest_name': 'Alice',
          'access_token': 'aaa',
        },
      );

      final tx = pool.transactions.single;
      final insertParams = tx.parameters[
          tx.executedSql.indexWhere(
              (s) => s.contains('insert into public.connector_sync_log'))];
      final encoded = insertParams['payload_preview'] as String;
      final decoded = jsonDecode(encoded) as Map<String, Object?>;
      expect(decoded['reservation_id'], 'rsv-1');
      expect(decoded.containsKey('guest_email'), isFalse);
      expect(decoded.containsKey('guest_name'), isFalse);
      expect(decoded.containsKey('access_token'), isFalse);
    });

    test('null payload_preview stays null (no jsonb cast on null)',
        () async {
      final pool = _GatewayPool();
      final gw = RepositoryInboundWebhookGateway(
        TenantTransactionWrapper(pool),
        pgcryptoEnvelopeKey: _envelopeKey,
      );

      await gw.appendSyncLog(
        operatorId: _opId,
        locationId: _locId,
        connectionId: 'cccccccc-1111-2222-3333-444444444444',
        eventKind: 'poll_success',
        recordsCount: 5,
      );

      final tx = pool.transactions.single;
      final params = tx.parameters[
          tx.executedSql.indexWhere(
              (s) => s.contains('insert into public.connector_sync_log'))];
      expect(params['payload_preview'], isNull);
    });
  });

  group('cross-tenant isolation', () {
    test('appendSyncLog binds operator_id from the call argument', () async {
      final pool = _GatewayPool();
      final gw = RepositoryInboundWebhookGateway(
        TenantTransactionWrapper(pool),
        pgcryptoEnvelopeKey: _envelopeKey,
      );

      await gw.appendSyncLog(
        operatorId: _opId,
        locationId: _locId,
        connectionId: 'cccccccc-1111-2222-3333-444444444444',
        eventKind: 'webhook_received',
        recordsCount: 1,
      );

      // Re-issue with a different operator and verify a second
      // transaction is opened with that operator's SET LOCAL — the
      // gateway never reuses an open transaction across operators.
      await gw.appendSyncLog(
        operatorId: _otherOpId,
        locationId: _locId,
        connectionId: 'cccccccc-1111-2222-3333-444444444444',
        eventKind: 'webhook_received',
        recordsCount: 1,
      );

      expect(pool.transactions.length, 2);
      // Tx #1 SET LOCAL parameter carries _opId.
      final tx1 = pool.transactions[0];
      final setOp1Idx = tx1.executedSql
          .indexWhere((s) => s.contains("'app.operator_id'"));
      expect(tx1.parameters[setOp1Idx]['value'], equals(_opId));
      // Tx #2 SET LOCAL parameter carries _otherOpId.
      final tx2 = pool.transactions[1];
      final setOp2Idx = tx2.executedSql
          .indexWhere((s) => s.contains("'app.operator_id'"));
      expect(tx2.parameters[setOp2Idx]['value'], equals(_otherOpId));
      // Each insert binds the same operator_id its transaction
      // SET LOCAL'd — the only operator_id that flows into the row is
      // the one the wrapper bound.
      final insert1Idx = tx1.executedSql
          .indexWhere((s) => s.contains('insert into '
              'public.connector_sync_log'));
      expect(tx1.parameters[insert1Idx]['operator_id'], equals(_opId));
      final insert2Idx = tx2.executedSql
          .indexWhere((s) => s.contains('insert into '
              'public.connector_sync_log'));
      expect(tx2.parameters[insert2Idx]['operator_id'],
          equals(_otherOpId));
    });

    test('every write enters withTenant (SET LOCAL precedes the write)',
        () async {
      final pool = _GatewayPool(
        idempotencyInsertReturning: 'idem-1',
      );
      final gw = RepositoryInboundWebhookGateway(
        TenantTransactionWrapper(pool),
        pgcryptoEnvelopeKey: _envelopeKey,
      );

      await gw.claimIdempotency(
        operatorId: _opId,
        locationId: _locId,
        vendorId: _vendorId,
        vendorEventId: _vendorEventId,
        receivedAt: DateTime.utc(2026, 5, 6, 12),
      );
      await gw.markProcessed(
        operatorId: _opId,
        locationId: _locId,
        vendorId: _vendorId,
        vendorEventId: _vendorEventId,
        receivedAt: DateTime.utc(2026, 5, 6, 12),
      );
      await gw.recordFailedAttempt(
        operatorId: _opId,
        locationId: _locId,
        vendorId: _vendorId,
        vendorEventId: _vendorEventId,
        failureMessage: 'adapter blew up',
        receivedAt: DateTime.utc(2026, 5, 6, 12),
      );
      await gw.deadLetter(
        operatorId: _opId,
        locationId: _locId,
        vendorId: _vendorId,
        vendorEventId: _vendorEventId,
        payloadPreview: const <String, Object?>{'k': 'v'},
        failureKind: InboundWebhookFailureKind.adapterError,
        failureMessage: 'too many adapter errors',
      );

      // 4 writes → 4 transactions.
      expect(pool.transactions.length, 4);
      for (final tx in pool.transactions) {
        // First SQL is always the operator SET LOCAL.
        expect(tx.executedSql.first, contains("'app.operator_id'"));
        // The DB write follows the SET LOCAL trio +
        // bypass_rls_audit marker.
        expect(tx.commitCount, 1,
            reason: 'every successful write commits exactly once');
        expect(tx.rollbackCount, 0);
      }
    });
  });

  group('recordFailedAttempt', () {
    test('UPSERT increments attempt_count and returns the new value',
        () async {
      final pool = _GatewayPool(failedAttemptReturning: 4);
      final gw = RepositoryInboundWebhookGateway(
        TenantTransactionWrapper(pool),
        pgcryptoEnvelopeKey: _envelopeKey,
      );

      final attempts = await gw.recordFailedAttempt(
        operatorId: _opId,
        locationId: _locId,
        vendorId: _vendorId,
        vendorEventId: _vendorEventId,
        failureMessage: 'signature invalid',
        receivedAt: DateTime.utc(2026, 5, 6, 12),
      );
      expect(attempts, 4);

      final tx = pool.transactions.single;
      final upsertSql = tx.executedSql.firstWhere(
          (s) => s.contains('insert into '
              'public.inbound_webhook_idempotency'));
      expect(upsertSql, contains('on conflict'));
      expect(upsertSql, contains('attempt_count = '));
      expect(upsertSql, contains('returning attempt_count'));
    });
  });

  group('deadLetter', () {
    test('writes to inbound_webhook_dead_letter with redacted payload',
        () async {
      final pool = _GatewayPool();
      final gw = RepositoryInboundWebhookGateway(
        TenantTransactionWrapper(pool),
        pgcryptoEnvelopeKey: _envelopeKey,
      );

      await gw.deadLetter(
        operatorId: _opId,
        locationId: _locId,
        vendorId: _vendorId,
        vendorEventId: _vendorEventId,
        payloadPreview: <String, Object?>{
          'reservation_id': 'rsv-1',
          'access_token': 'aaa',
          'guest_email': 'g@e.com',
          'first_name': 'Alice',
        },
        failureKind: InboundWebhookFailureKind.adapterError,
        failureMessage: 'three strikes',
      );

      final tx = pool.transactions.single;
      final idx = tx.executedSql.indexWhere(
          (s) => s.contains('insert into '
              'public.inbound_webhook_dead_letter'));
      final params = tx.parameters[idx];
      final encoded = params['payload_preview'] as String;
      final decoded = jsonDecode(encoded) as Map<String, Object?>;
      expect(decoded['reservation_id'], 'rsv-1');
      expect(decoded.containsKey('access_token'), isFalse);
      expect(decoded.containsKey('guest_email'), isFalse);
      expect(decoded.containsKey('first_name'), isFalse);
      expect(params['failure_kind'], equals('adapter_error'));
      expect(params['failure_message'], equals('three strikes'));
      expect(params['operator_id'], equals(_opId));
    });
  });

  group('lookupBinding', () {
    test('returns null when no row exists', () async {
      final pool = _GatewayPool();
      final gw = RepositoryInboundWebhookGateway(
        TenantTransactionWrapper(pool),
        pgcryptoEnvelopeKey: _envelopeKey,
      );

      final binding = await gw.lookupBinding(
        operatorId: _opId,
        locationId: _locId,
        vendorId: _vendorId,
      );
      expect(binding, isNull);
    });

    test('projects connector_connection row into ConnectionBinding',
        () async {
      final pool = _GatewayPool(
        bindingRow: <String, Object?>{
          'connection_id': 'cccccccc-1111-2222-3333-444444444444',
          'metadata': <String, Object?>{'venue_id': 'vn-42'},
          'status': 'connected',
        },
      );
      final gw = RepositoryInboundWebhookGateway(
        TenantTransactionWrapper(pool),
        pgcryptoEnvelopeKey: _envelopeKey,
      );

      final binding = await gw.lookupBinding(
        operatorId: _opId,
        locationId: _locId,
        vendorId: _vendorId,
      );
      expect(binding, isNotNull);
      expect(binding!.connectionId,
          equals('cccccccc-1111-2222-3333-444444444444'));
      expect(binding.metadata, equals(<String, Object?>{'venue_id': 'vn-42'}));
      expect(binding.status, ConnectionStatus.connected);
    });
  });

  group('lookupSigningSecret (CODE_OPS_DEBT Theme G #2)', () {
    test('reads webhook_signing_secret_ciphertext, NOT access_token_ciphertext',
        () async {
      // Critical fail-closed posture: the gateway must read the
      // dedicated webhook signing secret column added by
      // db/migrations/202605080600_ops_debt_vendor_credentials_webhook_signing_secret.sql.
      // Reading the OAuth bearer column (the previous bug) is what
      // broke signature verification for every real vendor.
      final pool = _GatewayPool(
        signingSecretRow: <String, Object?>{
          'signing_secret': 'whsec_toast_per_op_secret',
        },
      );
      final gw = RepositoryInboundWebhookGateway(
        TenantTransactionWrapper(pool),
        pgcryptoEnvelopeKey: _envelopeKey,
      );

      final secret = await gw.lookupSigningSecret(
        operatorId: _opId,
        locationId: _locId,
        vendorId: 'toast',
      );
      expect(secret, equals('whsec_toast_per_op_secret'));

      final tx = pool.transactions.single;
      final selectSql = tx.executedSql.firstWhere(
        (s) => s.contains('from public.vendor_credentials'),
        orElse: () => '',
      );
      expect(selectSql, isNotEmpty,
          reason: 'gateway must read from vendor_credentials');
      // The new column appears in both the SELECT projection (decrypt
      // target) AND the WHERE clause (skip un-provisioned rows).
      expect(
        selectSql,
        contains('pgp_sym_decrypt(webhook_signing_secret_ciphertext'),
        reason: 'must decrypt the dedicated webhook signing secret column',
      );
      expect(
        selectSql,
        contains('webhook_signing_secret_ciphertext is not null'),
        reason:
            'must skip rows where the webhook signing secret has not been '
            'provisioned (fail-closed at the read path)',
      );
      // Read path MUST NOT touch the OAuth bearer column — that is
      // the bug being fixed. The bearer is still used for outbound
      // polling elsewhere; this read must NOT confuse the two.
      expect(
        selectSql,
        isNot(contains('access_token_ciphertext')),
        reason:
            'CODE_OPS_DEBT G#2: webhook signing secret read must not '
            'reach for the OAuth bearer column',
      );
    });

    test('returns null when the column is null (vendor not provisioned yet)',
        () async {
      // No row matches the `webhook_signing_secret_ciphertext is not
      // null` filter — the SELECT returns zero rows. The gateway
      // returns null and the handler fails closed (403).
      final pool = _GatewayPool(signingSecretRow: null);
      final gw = RepositoryInboundWebhookGateway(
        TenantTransactionWrapper(pool),
        pgcryptoEnvelopeKey: _envelopeKey,
      );

      final secret = await gw.lookupSigningSecret(
        operatorId: _opId,
        locationId: _locId,
        vendorId: 'toast',
      );
      expect(secret, isNull,
          reason:
              'null column → null secret → handler fail-closes with 403 '
              '"no signing secret on file"');
    });

    test(
        'empty-string secret coerces to null (fail-closed if pgcrypto '
        'returns empty bytea)', () async {
      final pool = _GatewayPool(
        signingSecretRow: <String, Object?>{'signing_secret': ''},
      );
      final gw = RepositoryInboundWebhookGateway(
        TenantTransactionWrapper(pool),
        pgcryptoEnvelopeKey: _envelopeKey,
      );

      final secret = await gw.lookupSigningSecret(
        operatorId: _opId,
        locationId: _locId,
        vendorId: 'toast',
      );
      expect(secret, isNull);
    });

    test('binds the pgcrypto envelope key as a parameter (not concatenated)',
        () async {
      final pool = _GatewayPool(
        signingSecretRow: <String, Object?>{'signing_secret': 'whsec_abc'},
      );
      final gw = RepositoryInboundWebhookGateway(
        TenantTransactionWrapper(pool),
        pgcryptoEnvelopeKey: _envelopeKey,
      );
      await gw.lookupSigningSecret(
        operatorId: _opId,
        locationId: _locId,
        vendorId: 'toast',
      );

      final tx = pool.transactions.single;
      final idx = tx.executedSql.indexWhere(
        (s) => s.contains('from public.vendor_credentials'),
      );
      expect(idx, greaterThanOrEqualTo(0));
      final params = tx.parameters[idx];
      expect(params['envelope_key'], equals(_envelopeKey));
      expect(params['operator_id'], equals(_opId));
      expect(params['vendor_id'], equals('toast'));
    });

    test('runs inside withTenant — SET LOCAL precedes the SELECT', () async {
      final pool = _GatewayPool(
        signingSecretRow: <String, Object?>{'signing_secret': 'whsec_abc'},
      );
      final gw = RepositoryInboundWebhookGateway(
        TenantTransactionWrapper(pool),
        pgcryptoEnvelopeKey: _envelopeKey,
      );
      await gw.lookupSigningSecret(
        operatorId: _opId,
        locationId: _locId,
        vendorId: 'toast',
      );
      final tx = pool.transactions.single;
      // First statement is the operator SET LOCAL.
      expect(tx.executedSql.first, contains("'app.operator_id'"));
      // SELECT happens AFTER the tenant context is bound.
      final selectIdx = tx.executedSql.indexWhere(
        (s) => s.contains('from public.vendor_credentials'),
      );
      final operatorSetIdx = tx.executedSql.indexWhere(
        (s) => s.contains("'app.operator_id'"),
      );
      expect(selectIdx, greaterThan(operatorSetIdx));
    });
  });

  group('recordSanityDrop', () {
    test('writes to sanity_log with a redacted summary', () async {
      final pool = _GatewayPool();
      final gw = RepositoryInboundWebhookGateway(
        TenantTransactionWrapper(pool),
        pgcryptoEnvelopeKey: _envelopeKey,
      );

      await gw.recordSanityDrop(
        operatorId: _opId,
        locationId: _locId,
        vendorId: _vendorId,
        vendorEventId: _vendorEventId,
        rule: 'opened_in_future',
        payloadSummary: <String, Object?>{
          'opened_at': '2099-01-01T00:00:00Z',
          'guest_email': 'g@e.com',
        },
      );

      final tx = pool.transactions.single;
      final idx = tx.executedSql
          .indexWhere((s) => s.contains('insert into public.sanity_log'));
      final params = tx.parameters[idx];
      final encoded = params['payload_summary'] as String;
      final decoded = jsonDecode(encoded) as Map<String, Object?>;
      expect(decoded['opened_at'], equals('2099-01-01T00:00:00Z'));
      expect(decoded.containsKey('guest_email'), isFalse);
      expect(params['rule'], equals('opened_in_future'));
    });
  });

  group('constructor validation', () {
    test('rejects an empty pgcrypto envelope key', () {
      expect(
        () => RepositoryInboundWebhookGateway(
          TenantTransactionWrapper(_GatewayPool()),
          pgcryptoEnvelopeKey: '',
        ),
        throwsArgumentError,
      );
    });
  });
}

// ── Test fakes ──────────────────────────────────────────────────────

class _GatewayPool implements PostgresPool {
  _GatewayPool({
    this.idempotencyInsertReturning,
    this.failedAttemptReturning,
    this.unprocessedSyntheticCount = 0,
    this.bindingRow,
    this.signingSecretRow,
  });

  /// When non-null the INSERT into `inbound_webhook_idempotency`
  /// returns one row with this idempotency_id (firstTime path).
  /// When null the INSERT returns zero rows (ON CONFLICT short-circuit
  /// → duplicate).
  final String? idempotencyInsertReturning;

  /// New `attempt_count` value returned by the failed-attempt UPSERT.
  final int? failedAttemptReturning;

  /// Count returned by the synthetic-cap pre-check
  /// (`SELECT count(*) FROM inbound_webhook_idempotency WHERE
  /// processed = false AND vendor_event_id LIKE 'sha256:%'`).
  final int unprocessedSyntheticCount;

  /// Row returned by `SELECT … FROM connector_connection WHERE …
  /// LIMIT 1`.
  final Map<String, Object?>? bindingRow;

  /// Row returned by `SELECT pgp_sym_decrypt(...) FROM vendor_credentials …`.
  /// Map carries the projected `signing_secret` value (post-decrypt).
  /// When null, the SELECT returns zero rows (column was NULL or row
  /// not yet provisioned) — gateway returns null, handler fails closed.
  final Map<String, Object?>? signingSecretRow;

  final List<_GatewayTransaction> transactions = <_GatewayTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _GatewayTransaction(
      idempotencyInsertReturning: idempotencyInsertReturning,
      failedAttemptReturning: failedAttemptReturning,
      unprocessedSyntheticCount: unprocessedSyntheticCount,
      bindingRow: bindingRow,
      signingSecretRow: signingSecretRow,
    );
    transactions.add(tx);
    return tx;
  }
}

class _GatewayTransaction extends PostgresTransaction {
  _GatewayTransaction({
    required this.idempotencyInsertReturning,
    required this.failedAttemptReturning,
    required this.unprocessedSyntheticCount,
    required this.bindingRow,
    required this.signingSecretRow,
  });

  final String? idempotencyInsertReturning;
  final int? failedAttemptReturning;
  final int unprocessedSyntheticCount;
  final Map<String, Object?>? bindingRow;
  final Map<String, Object?>? signingSecretRow;

  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  bool _finalized = false;
  int commitCount = 0;
  int rollbackCount = 0;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('count(*)') &&
        sql.contains('public.inbound_webhook_idempotency') &&
        sql.contains('processed = false')) {
      return <PostgresRow>[
        <String, Object?>{'cnt': unprocessedSyntheticCount},
      ];
    }
    if (sql.contains('insert into public.inbound_webhook_idempotency') &&
        sql.contains('returning idempotency_id')) {
      final id = idempotencyInsertReturning;
      if (id == null) return <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'idempotency_id': id},
      ];
    }
    if (sql.contains('insert into public.inbound_webhook_idempotency') &&
        sql.contains('returning attempt_count')) {
      final n = failedAttemptReturning;
      if (n == null) {
        // Default: pretend the row was new so attempt_count = 1.
        return <PostgresRow>[
          <String, Object?>{'attempt_count': 1},
        ];
      }
      return <PostgresRow>[
        <String, Object?>{'attempt_count': n},
      ];
    }
    if (sql.contains('from public.connector_connection')) {
      final row = bindingRow;
      if (row == null) return <PostgresRow>[];
      return <PostgresRow>[row];
    }
    if (sql.contains('from public.vendor_credentials') &&
        sql.contains('webhook_signing_secret_ciphertext')) {
      final row = signingSecretRow;
      if (row == null) return <PostgresRow>[];
      return <PostgresRow>[row];
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
    if (_finalized) return;
    _finalized = true;
    commitCount += 1;
  }

  @override
  Future<void> rollback() async {
    if (_finalized) return;
    _finalized = true;
    rollbackCount += 1;
  }
}
