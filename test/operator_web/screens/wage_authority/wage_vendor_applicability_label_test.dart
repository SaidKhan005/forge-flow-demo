// Wave 2 S-1 — unit tests for the wage row vendor-applicability label.
//
// Origin: debug.md:198-220 (OW-13a + OW-13b). Per
// `lib/services/integration/labor_wage_source_class.dart`:
//   * humanity / agendrix — perPositionWithRates → sync tone.
//   * seven_shifts / quickbooks_time — perEmployeeWithRates → advisory.
//   * adp / push_operations — hoursOnly → advisory.
// Plus the manual-only fallback when no vendor is wired.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/screens/wage_authority/wage_vendor_applicability_label.dart';

void main() {
  group('buildWageVendorApplicabilityLabel', () {
    test('humanity → per-position sync, friendly name included', () {
      final label = buildWageVendorApplicabilityLabel(
        vendorId: 'humanity',
        vendorRoleId: 'Cook',
      );
      expect(label.tone, WageVendorApplicabilityTone.perPositionSync);
      expect(label.text, contains('Humanity'));
      expect(label.text, contains('Cook'));
      // No engineering jargon leak.
      expect(label.text, isNot(contains('humanity')));
      expect(label.text, isNot(contains('vendor_id')));
    });

    test('agendrix → per-position sync', () {
      final label = buildWageVendorApplicabilityLabel(
        vendorId: 'agendrix',
        jobCode: 'COOK',
      );
      expect(label.tone, WageVendorApplicabilityTone.perPositionSync);
      expect(label.text, contains('Agendrix'));
      expect(label.text, contains('COOK'));
    });

    test('seven_shifts → per-employee advisory (does not overwrite)', () {
      final label = buildWageVendorApplicabilityLabel(
        vendorId: 'seven_shifts',
        vendorRoleId: 'Server',
      );
      expect(label.tone, WageVendorApplicabilityTone.perEmployeeAdvisory);
      expect(label.text, contains('7shifts'));
      expect(label.text, contains('per employee'));
      expect(label.text, contains('do not overwrite'));
    });

    test('quickbooks_time → per-employee advisory', () {
      final label = buildWageVendorApplicabilityLabel(
        vendorId: 'quickbooks_time',
      );
      expect(label.tone, WageVendorApplicabilityTone.perEmployeeAdvisory);
      expect(label.text, contains('QuickBooks Time'));
      expect(label.text, contains('per employee'));
    });

    test('adp → hours-only advisory', () {
      final label = buildWageVendorApplicabilityLabel(vendorId: 'adp');
      expect(label.tone, WageVendorApplicabilityTone.hoursOnlyAdvisory);
      expect(label.text, contains('ADP'));
      expect(label.text, contains('hours, not rates'));
    });

    test('push_operations → hours-only advisory', () {
      final label = buildWageVendorApplicabilityLabel(
        vendorId: 'push_operations',
      );
      expect(label.tone, WageVendorApplicabilityTone.hoursOnlyAdvisory);
      expect(label.text, contains('Push Operations'));
    });

    test('null vendorId + no connected vendors → "no labor vendor connected"',
        () {
      final label = buildWageVendorApplicabilityLabel(vendorId: null);
      expect(label.tone, WageVendorApplicabilityTone.manualOnly);
      expect(label.text, contains('no labor vendor connected'));
    });

    test('null vendorId + connected vendors → suggests picking a vendor role',
        () {
      final label = buildWageVendorApplicabilityLabel(
        vendorId: null,
        connectedLaborVendorIds: const <String>{'humanity'},
      );
      expect(label.tone, WageVendorApplicabilityTone.manualOnly);
      expect(label.text, contains('Manual only'));
      expect(label.text, contains('Humanity'));
    });

    test('null vendorId + multiple connected vendors → lists all', () {
      final label = buildWageVendorApplicabilityLabel(
        vendorId: null,
        connectedLaborVendorIds: const <String>{'humanity', 'adp'},
      );
      expect(label.text, contains('Humanity'));
      expect(label.text, contains('ADP'));
    });

    test('empty/whitespace vendorId same as null', () {
      final label = buildWageVendorApplicabilityLabel(vendorId: '   ');
      expect(label.tone, WageVendorApplicabilityTone.manualOnly);
    });

    test('unknown vendorId falls back gracefully (no raw id leaks)', () {
      final label = buildWageVendorApplicabilityLabel(
        vendorId: 'some_new_vendor',
      );
      expect(label.tone, WageVendorApplicabilityTone.manualOnly);
      // The raw id never appears in the operator-facing string.
      expect(label.text, isNot(contains('some_new_vendor')));
    });

    test('vendorRoleId takes precedence over jobCode when both present', () {
      final label = buildWageVendorApplicabilityLabel(
        vendorId: 'humanity',
        vendorRoleId: 'Line Cook',
        jobCode: 'BOH-001',
      );
      expect(label.text, contains('Line Cook'));
      expect(label.text, isNot(contains('BOH-001')));
    });
  });
}
