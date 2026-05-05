// Phase 8 Wave B `8.spine-bridge.0.amendment` cross-category capability
// index tests.
//
// Two responsibilities:
//   1. [pollOnlyVendorIds] returns exactly the 5 Wave B vendors whose
//      capability profile carries
//      `webhookSupport: VendorWebhookSupport.pollOnly`. ADP MUST NOT
//      appear (architecture amendment: ADP is autoRegister).
//   2. [lookupVendorCapability] resolves a vendor across all 3
//      categories.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/labor/adp_labor_adapter.dart'
    show kAdpVendorId;
import 'package:forge_and_flow/integrations/labor/agendrix_labor_adapter.dart'
    show agendrixVendorId;
import 'package:forge_and_flow/integrations/labor/humanity_labor_adapter.dart'
    show kHumanityVendorId;
import 'package:forge_and_flow/integrations/labor/push_operations_labor_adapter.dart'
    show pushOperationsVendorId;
import 'package:forge_and_flow/integrations/labor/quickbooks_time_labor_adapter.dart'
    show kQuickBooksTimeVendorId;
import 'package:forge_and_flow/integrations/pos/oracle_micros_simphony_pos_adapter.dart'
    show oracleMicrosSimphonyVendorId;
import 'package:forge_and_flow/integrations/pos/square_pos_adapter.dart'
    show kSquareVendorId;
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import '../../../tool/advisor_proxy/vendor_capability_index.dart';

void main() {
  group('pollOnlyVendorIds', () {
    test(
        'returns exactly the 5 Wave B pollOnly vendors '
        '(oracle_micros_simphony, quickbooks_time, humanity, agendrix, '
        'push_operations)', () {
      final pollOnly = pollOnlyVendorIds.toSet();

      expect(pollOnly, <String>{
        oracleMicrosSimphonyVendorId,
        kQuickBooksTimeVendorId,
        kHumanityVendorId,
        agendrixVendorId,
        pushOperationsVendorId,
      });
      expect(pollOnly, hasLength(5),
          reason:
              'pollOnly cohort must be exactly 5; if this trips after a '
              'Wave B vendor is added/changed, update the cadence picker '
              'invariant document and this test in the same change.');
    });

    test('ADP is NOT in the pollOnly cohort (autoRegister, not pollOnly)', () {
      final pollOnly = pollOnlyVendorIds.toSet();
      expect(pollOnly.contains(kAdpVendorId), isFalse,
          reason:
              'ADP must NOT appear in pollOnlyVendorIds; the cadence picker '
              'would otherwise wrongly enroll ADP in the recurring poll '
              'loop instead of the webhook auto-register path.');
    });
  });

  group('lookupVendorCapability', () {
    test(
        'resolves a vendor across all 3 categories and returns null for '
        'unknown vendors', () {
      // POS hit
      final square = lookupVendorCapability(kSquareVendorId);
      expect(square, isNotNull);
      expect(square!.category, IntegrationCategory.pos);

      // Labor hit
      final adp = lookupVendorCapability(kAdpVendorId);
      expect(adp, isNotNull);
      expect(adp!.category, IntegrationCategory.labor);
      // Cross-check the ADP webhookSupport invariant from this seam too.
      expect(adp.webhookSupport, VendorWebhookSupport.autoRegister);

      // Reservation hit
      final humanity = lookupVendorCapability(kHumanityVendorId);
      expect(humanity, isNotNull);
      expect(humanity!.category, IntegrationCategory.labor);

      // Miss
      expect(lookupVendorCapability('unknown_vendor_id'), isNull);
    });
  });
}
