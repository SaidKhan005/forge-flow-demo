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
    test('QuickBooks Time maps to perEmployeeWithRates', () {
      expect(
        laborWageSourceClassFor('quickbooks_time'),
        LaborWageSourceClass.perEmployeeWithRates,
      );
    });
  });

  group(
      'LaborWageSourceClass — A2. per-employee-with-dollars classification '
      '(8.spine-bridge.7S.upgrade)', () {
    test(
        '7shifts maps to perEmployeeWithDollars after the '
        '/reports/hours_and_wages adapter upgrade', () {
      expect(
        laborWageSourceClassFor('seven_shifts'),
        LaborWageSourceClass.perEmployeeWithDollars,
        reason: '7shifts qualifies as perEmployeeWithDollars now that the '
            'adapter consumes /reports/hours_and_wages — per-shift total_pay '
            'merged onto canonical facts via (employee_id, shift_id). Lower '
            'plan tiers fall back via SevenShiftsHoursAndWagesReportGated'
            'Exception → substituted-wage provenance, but the SIDECAR '
            'classification stays perEmployeeWithDollars (the aggregator '
            'falls through to Stage 5 when dollars missing).',
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

  group('LaborWageSourceClass — D. perEmployeeWithDollars membership', () {
    test(
        'only 7shifts is in perEmployeeWithDollars after the '
        '8.spine-bridge.7S.upgrade lane wired /reports/hours_and_wages', () {
      // Other Wave B labor vendors must NOT be in perEmployeeWithDollars
      // (their adapter doc packs explicitly classify them otherwise per
      // 2026-05-05 falsehood corrections #6, #8, #9).
      const otherWaveBLaborVendors = <String>[
        'quickbooks_time',
        'humanity',
        'agendrix',
        'adp',
        'push_operations',
      ];
      for (final vendorId in otherWaveBLaborVendors) {
        expect(
          laborWageSourceClassFor(vendorId),
          isNot(LaborWageSourceClass.perEmployeeWithDollars),
          reason:
              '$vendorId must NOT be perEmployeeWithDollars per 2026-05-05 '
              'falsehood corrections (only 7shifts qualifies after the '
              'hours_and_wages upgrade)',
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
