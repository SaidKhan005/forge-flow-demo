import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _migrationPath =
    'db/migrations/202605080600_ops_debt_vendor_credentials_webhook_signing_secret.sql';

void main() {
  final sql = File(_migrationPath).readAsStringSync().replaceAll('\r\n', '\n');
  final normalized = sql.toLowerCase();
  final compact = sql.replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

  group('ops-debt vendor_credentials.webhook_signing_secret_ciphertext migration', () {
    test('adds the new column to vendor_credentials', () {
      expect(
        compact,
        contains('alter table public.vendor_credentials '
            'add column if not exists webhook_signing_secret_ciphertext bytea'),
      );
    });

    test('column type matches access_token_ciphertext (bytea)', () {
      // Both columns must be bytea so pgp_sym_encrypt / pgp_sym_decrypt
      // work uniformly. The column comment makes the intent explicit.
      expect(
        compact,
        contains('webhook_signing_secret_ciphertext bytea'),
      );
    });

    test('column is NULL-allowed (no NOT NULL constraint, no default)', () {
      // Critical: existing rows must continue to load. The handler
      // fail-closes when the column is null (rejects 403); no
      // backfill needed.
      expect(
        compact,
        isNot(contains('webhook_signing_secret_ciphertext bytea not null')),
      );
      expect(
        compact,
        isNot(contains(
            'webhook_signing_secret_ciphertext bytea default')),
      );
    });

    test('does NOT drop or rename access_token_ciphertext', () {
      // OAuth bearer is still used for outbound polling. The fix is
      // additive — never destructive of the existing column.
      expect(
        compact,
        isNot(contains('drop column access_token_ciphertext')),
      );
      expect(
        compact,
        isNot(contains('rename column access_token_ciphertext')),
      );
    });

    test('writes a comment describing fail-closed posture and runbook', () {
      expect(
        compact,
        contains('comment on column public.vendor_credentials.'
            'webhook_signing_secret_ciphertext'),
      );
      expect(normalized, contains('fail '));
      expect(normalized, contains('runbook'));
    });

    test('header lists every affected vendor (webhookSupport != pollOnly)', () {
      // Each vendor must appear in the header so operators can audit
      // which rows still need the secret staged. Mirrors the list in
      // the migration comment block.
      const affectedVendors = <String>[
        'toast',
        'square',
        'clover',
        'revel',
        'lightspeed_lsk',
        'aloha_ncr_voyix',
        'adp',
        'seven_shifts',
        'libro',
        'opentable',
        'sevenrooms',
        'tock',
      ];
      for (final vendor in affectedVendors) {
        expect(
          normalized,
          contains(vendor),
          reason: 'header must name $vendor as an affected vendor',
        );
      }
    });

    test('uses idempotent ALTER (add column if not exists)', () {
      expect(compact, contains('add column if not exists'));
    });

    test('respects time + lock guardrails', () {
      // CLAUDE.md migration hygiene: bound the lock window so a hot
      // table does not stall behind us.
      expect(normalized, contains('set local statement_timeout'));
      expect(normalized, contains('set local lock_timeout'));
    });
  });
}
