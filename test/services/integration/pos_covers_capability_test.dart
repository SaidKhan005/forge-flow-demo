// Wave 2 MO-2 — POS-vendor covers-capability lookup tests.
//
// Verifies the mobile-side mirror of `VendorCapabilityProfile.coversFieldExposed`
// stays aligned with the per-adapter truth declared in
// `lib/integrations/pos/*_pos_adapter.dart`. If a new POS adapter
// lands without updating the mirror, the explicit-table assertion
// here fails and the engineer is told to add the row.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/services/integration/pos_covers_capability.dart';

void main() {
  group('pos_covers_capability', () {
    test('every documented POS vendor has an explicit coverage flag', () {
      // The per-adapter `coversFieldExposed` truth (sourced from the
      // adapter file cited next to each entry below). Any change in
      // `lib/integrations/pos/*_pos_adapter.dart` must mirror through
      // `kPosVendorCoversFieldExposed` and re-pin the expectation here.
      const expected = <String, bool>{
        // aloha_ncr_voyix_pos_adapter.dart line 305
        'aloha': true,
        // clover_pos_adapter.dart line 276
        'clover': false,
        // lightspeed_lsk_pos_adapter.dart line 410
        'lightspeed_lsk': true,
        // oracle_micros_simphony_pos_adapter.dart line 187
        'oracle_micros_simphony': true,
        // revel_pos_adapter.dart line 364
        'revel': true,
        // square_pos_adapter.dart line 371
        'square': false,
        // toast_pos_adapter.dart line 274
        'toast': true,
      };
      expect(kPosVendorCoversFieldExposed, expected);
    });

    test('posVendorExposesCovers returns the table value for known vendors',
        () {
      expect(posVendorExposesCovers('square'), isFalse);
      expect(posVendorExposesCovers('toast'), isTrue);
      expect(posVendorExposesCovers('clover'), isFalse);
      expect(posVendorExposesCovers('aloha'), isTrue);
    });

    test('posVendorExposesCovers returns null for unknown / absent vendor',
        () {
      expect(posVendorExposesCovers(null), isNull);
      expect(posVendorExposesCovers('some_unrecognized_pos'), isNull);
    });
  });
}
