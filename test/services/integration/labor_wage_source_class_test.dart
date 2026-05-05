// Phase 8 spine-bridge Lane .2 — leaf test for the labor wage source
// class sidecar. Authority:
//   * docs/contracts/integration_spine_architecture_contract.md
//     "2026-05-05 falsehood corrections" (binding) items 6-9.
//   * docs/contracts/core_app_architecture.md Layer 4 (wage authority).
//
// No mocks, no Postgres. Pure lookup contract.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/integration/labor_wage_source_class.dart';

void main() {
  group('LaborWageSourceClass — A. per-employee-with-rates classification',
      () {
    test('QuickBooks Time and 7shifts both map to perEmployeeWithRates', () {
      expect(
        laborWageSourceClassFor('quickbooks_time'),
        LaborWageSourceClass.perEmployeeWithRates,
      );
      expect(
        laborWageSourceClassFor('seven_shifts'),
        LaborWageSourceClass.perEmployeeWithRates,
      );
    });
  });

  group('LaborWageSourceClass — B. per-position-with-rates classification',
      () {
    test('Humanity and Agendrix both map to perPositionWithRates', () {
      expect(
        laborWageSourceClassFor('humanity'),
        LaborWageSourceClass.perPositionWithRates,
      );
      expect(
        laborWageSourceClassFor('agendrix'),
        LaborWageSourceClass.perPositionWithRates,
      );
    });
  });

  group('LaborWageSourceClass — C. hours-only classification', () {
    test('ADP and Push Operations both map to hoursOnly', () {
      expect(
        laborWageSourceClassFor('adp'),
        LaborWageSourceClass.hoursOnly,
      );
      expect(
        laborWageSourceClassFor('push_operations'),
        LaborWageSourceClass.hoursOnly,
      );
    });
  });

  group('LaborWageSourceClass — D. per-employee-with-dollars empty for V1',
      () {
    test('no Wave B labor vendor resolves to perEmployeeWithDollars', () {
      const waveBLaborVendors = <String>[
        'quickbooks_time',
        'seven_shifts',
        'humanity',
        'agendrix',
        'adp',
        'push_operations',
      ];
      for (final vendorId in waveBLaborVendors) {
        expect(
          laborWageSourceClassFor(vendorId),
          isNot(LaborWageSourceClass.perEmployeeWithDollars),
          reason:
              'no Wave B vendor qualifies for perEmployeeWithDollars at V1; '
              '7shifts joins after the /reports/hours_and_wages follow-up '
              '(8.7S.upgrade.hours_and_wages). Got hit on: $vendorId',
        );
      }
    });
  });

  group('LaborWageSourceClass — E. unknown vendor returns null', () {
    test('non-labor / unknown ids resolve to null', () {
      expect(
        laborWageSourceClassFor('not_a_real_vendor'),
        isNull,
        reason: 'unknown vendor must resolve to null',
      );
      expect(
        laborWageSourceClassFor('toast'),
        isNull,
        reason: 'toast is a POS, not a labor vendor — must be null',
      );
      expect(
        laborWageSourceClassFor('libro'),
        isNull,
        reason: 'libro is a reservation vendor, not a labor vendor — must be null',
      );
    });
  });

  group('LaborWageSourceClass — F. banned-items grep', () {
    test('sidecar source contains zero V1 lean cut 2 banned items', () async {
      final source = await File(
        'lib/services/integration/labor_wage_source_class.dart',
      ).readAsString();

      const banned = <String>[
        'KMS',
        'pgp_sym_encrypt_kms',
        'rotateSigningKey',
        'parse_warnings',
        'parse_partial',
        'kStrictReplayFiveMinute',
        'pg_try_advisory_lock',
        'pg_advisory_lock',
        'sigtermDrainHandler',
        'inboundWebhookDLQTile',
        'raw_payload_partition',
        'pg_partman_raw',
      ];

      for (final token in banned) {
        expect(
          source.toLowerCase().contains(token.toLowerCase()),
          isFalse,
          reason: 'banned item present in sidecar source: $token',
        );
      }
    });
  });
}
