// Phase 8 spine-bridge Lane .2 — leaf value-object tests for
// `AggregatorProvenanceContext`. Three concerns:
//
//   1. Construct + read fields with canonical contract names.
//   2. Null `priorTargetProfileVersionId` (first-time aggregation slot).
//   3. Banned-items grep across the impl source per
//      `memory/project_v1_lean_cut_2_2026_05_03.md`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/aggregator_provenance_context.dart';

void main() {
  group('AggregatorProvenanceContext — construct + read fields', () {
    test('round-trips canonical provenance strings + prior version id', () {
      const ctx = AggregatorProvenanceContext(
        coversProvenance: 'vendor_oracle_micros_simphony',
        laborDollarsProvenance:
            'vendor_quickbooks_time_per_employee_actual_dollars_per_employee_rates',
        priorTargetProfileVersionId: 'tpv_2026_05_initial',
      );

      expect(ctx.coversProvenance, 'vendor_oracle_micros_simphony');
      expect(
        ctx.laborDollarsProvenance,
        'vendor_quickbooks_time_per_employee_actual_dollars_per_employee_rates',
      );
      expect(ctx.priorTargetProfileVersionId, 'tpv_2026_05_initial');
    });
  });

  group('AggregatorProvenanceContext — null priorTargetProfileVersionId', () {
    test('reads null when no prior shift_records row exists at the slot', () {
      const ctx = AggregatorProvenanceContext(
        coversProvenance: 'vendor_oracle_micros_simphony',
        laborDollarsProvenance:
            'vendor_quickbooks_time_per_employee_actual_dollars_per_employee_rates',
        priorTargetProfileVersionId: null,
      );

      expect(ctx.priorTargetProfileVersionId, isNull);
    });
  });

  group('AggregatorProvenanceContext — banned-items grep', () {
    test('impl source contains zero V1 lean cut 2 banned items', () async {
      final source = await File(
        'lib/domain/models/aggregator_provenance_context.dart',
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
          reason: 'banned item present in impl source: $token',
        );
      }
    });
  });
}
