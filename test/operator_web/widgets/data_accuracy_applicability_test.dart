import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/models/data_accuracy_settings.dart';
import 'package:forge_and_flow/integrations/ui/vendor_connections/vendor_connections_models.dart';
import 'package:forge_and_flow/operator_web/widgets/data_accuracy_applicability.dart';
import 'package:forge_and_flow/services/integration/labor_wage_source_class.dart';

void main() {
  VendorConnectionRow row({
    required String vendorId,
    required VendorCategory category,
  }) => VendorConnectionRow(
    connectionId: '$vendorId-conn',
    vendorId: vendorId,
    displayName: vendorId,
    category: category,
    status: VendorConnectionStatus.connected,
    metadata: const <String, Object?>{},
  );

  VendorConnectionsBundle bundle({
    VendorConnectionRow? pos,
    VendorConnectionRow? labor,
    VendorConnectionRow? reservation,
  }) => VendorConnectionsBundle(
    operatorId: 'op-1',
    locationId: 'loc-1',
    locationName: 'Water Street',
    posConnection: pos,
    laborConnection: labor,
    reservationConnection: reservation,
    demoFlags: const <VendorCategory, bool>{},
  );

  VendorConnectionsBundle bundleWith(VendorConnectionRow row) {
    return switch (row.category) {
      VendorCategory.pos => bundle(pos: row),
      VendorCategory.labor => bundle(labor: row),
      VendorCategory.reservation => bundle(reservation: row),
    };
  }

  group('Data Accuracy vendor truth', () {
    test('freshness applies only to connected poll-only vendors', () {
      const pollOnlyVendors = <String>{
        'oracle_micros_simphony',
        'quickbooks_time',
        'humanity',
        'agendrix',
        'push_operations',
      };
      expect(kDataAccuracyPollOnlyVendorIds, pollOnlyVendors);

      for (final vendorId in pollOnlyVendors) {
        final category = vendorId == 'oracle_micros_simphony'
            ? VendorCategory.pos
            : VendorCategory.labor;
        expect(
          dataFreshnessAppliesToBundle(
            bundleWith(row(vendorId: vendorId, category: category)),
          ),
          isTrue,
          reason: '$vendorId should unlock freshness when connected.',
        );
      }

      for (final vendorId in <String>[
        'toast',
        'square',
        'clover',
        'lightspeed_lsk',
        'revel',
        'aloha',
        'seven_shifts',
        'adp',
        'libro',
        'opentable',
        'sevenrooms',
        'tock',
      ]) {
        final category = switch (vendorId) {
          'seven_shifts' || 'adp' => VendorCategory.labor,
          'libro' ||
          'opentable' ||
          'sevenrooms' ||
          'tock' => VendorCategory.reservation,
          _ => VendorCategory.pos,
        };
        expect(
          dataFreshnessAppliesToBundle(
            bundleWith(row(vendorId: vendorId, category: category)),
          ),
          isFalse,
          reason: '$vendorId should not unlock scheduled freshness.',
        );
      }
      expect(
        connectedPollingCadences(
          bundle(
            pos: row(vendorId: 'toast', category: VendorCategory.pos),
          ),
          const <String, int>{'oracle_micros_simphony': 300},
        ),
        isEmpty,
        reason:
            'Old tier cadence rows must not unlock freshness by themselves.',
      );
    });

    test(
      'polling turn-offs drop a vendor only when applicability is bound',
      () {
        // Two connected poll-only vendors: a POS and a labor vendor.
        final twoPollOnly = bundle(
          pos: row(
            vendorId: 'oracle_micros_simphony',
            category: VendorCategory.pos,
          ),
          labor: row(
            vendorId: 'quickbooks_time',
            category: VendorCategory.labor,
          ),
        );
        const source = <String, int>{
          'oracle_micros_simphony': 300,
          'quickbooks_time': 300,
        };

        // Default (no turn-offs) leaves both vendors, bound or not.
        for (final bound in <bool>[true, false]) {
          expect(
            connectedPollingCadencesHonoringApplicability(
              bundle: twoPollOnly,
              source: source,
              vendorApplicabilityBound: bound,
              turnedOffVendorSlugs: const <String>[],
            ),
            source,
            reason: 'No turn-offs must not change the cadence map.',
          );
        }

        // When bound, a turned-off vendor is dropped.
        expect(
          connectedPollingCadencesHonoringApplicability(
            bundle: twoPollOnly,
            source: source,
            vendorApplicabilityBound: true,
            turnedOffVendorSlugs: const <String>['quickbooks_time'],
          ),
          const <String, int>{'oracle_micros_simphony': 300},
        );

        // When NOT bound, the turn-off list is ignored: behavior is
        // exactly connectedPollingCadences (never loosened/changed).
        expect(
          connectedPollingCadencesHonoringApplicability(
            bundle: twoPollOnly,
            source: source,
            vendorApplicabilityBound: false,
            turnedOffVendorSlugs: const <String>['quickbooks_time'],
          ),
          connectedPollingCadences(twoPollOnly, source),
          reason:
              'Unbound applicability must not honor turn-offs, leaving the '
              'existing connection-only behavior intact.',
        );

        // dataFreshnessAppliesHonoringApplicability mirrors the above.
        // Both on by default -> applies regardless of bound.
        for (final bound in <bool>[true, false]) {
          expect(
            dataFreshnessAppliesHonoringApplicability(
              bundle: twoPollOnly,
              vendorApplicabilityBound: bound,
              turnedOffVendorSlugs: const <String>[],
            ),
            isTrue,
          );
        }

        // One of two turned off (bound) still applies (the other polls).
        expect(
          dataFreshnessAppliesHonoringApplicability(
            bundle: twoPollOnly,
            vendorApplicabilityBound: true,
            turnedOffVendorSlugs: const <String>['quickbooks_time'],
          ),
          isTrue,
        );

        // BOTH connected poll-only vendors turned off (bound) -> does
        // not apply: the card shows the "does not apply" state.
        expect(
          dataFreshnessAppliesHonoringApplicability(
            bundle: twoPollOnly,
            vendorApplicabilityBound: true,
            turnedOffVendorSlugs: const <String>[
              'oracle_micros_simphony',
              'quickbooks_time',
            ],
          ),
          isFalse,
        );

        // Same both-off list, but NOT bound -> still applies (turn-offs
        // ignored). Guards against loosening when unbound.
        expect(
          dataFreshnessAppliesHonoringApplicability(
            bundle: twoPollOnly,
            vendorApplicabilityBound: false,
            turnedOffVendorSlugs: const <String>[
              'oracle_micros_simphony',
              'quickbooks_time',
            ],
          ),
          isTrue,
        );
      },
    );

    test(
      'covers choices are locked to connected POS and reservation vendors',
      () {
        expect(
          coversSourceOptionApplies(
            CoversSource.vendor,
            bundle(
              pos: row(vendorId: 'toast', category: VendorCategory.pos),
            ),
          ),
          isTrue,
        );
        for (final vendorId in <String>[
          'toast',
          'lightspeed_lsk',
          'revel',
          'aloha',
          'oracle_micros_simphony',
        ]) {
          expect(
            coversSourceOptionApplies(
              CoversSource.vendor,
              bundle(
                pos: row(vendorId: vendorId, category: VendorCategory.pos),
              ),
            ),
            isTrue,
            reason: '$vendorId exposes POS covers.',
          );
        }
        for (final vendorId in <String>['square', 'clover']) {
          expect(
            coversSourceOptionApplies(
              CoversSource.vendor,
              bundle(
                pos: row(vendorId: vendorId, category: VendorCategory.pos),
              ),
            ),
            isFalse,
            reason: '$vendorId does not expose POS covers.',
          );
        }
        expect(
          coversSourceOptionApplies(
            CoversSource.reservationPlusWalkin,
            bundle(
              pos: row(vendorId: 'toast', category: VendorCategory.pos),
            ),
          ),
          isFalse,
        );
        expect(
          coversSourceOptionApplies(
            CoversSource.reservationPlusWalkin,
            bundle(
              reservation: row(
                vendorId: 'libro',
                category: VendorCategory.reservation,
              ),
            ),
          ),
          isTrue,
        );
        expect(
          coversSourceOptionApplies(CoversSource.manual, bundle()),
          isTrue,
        );
      },
    );

    test(
      'labor choices are locked to labor vendor presence and wage class',
      () {
        expect(wageVendorOptionApplies(bundle()), isFalse);
        expect(
          wageVendorOptionApplies(
            bundle(
              labor: row(
                vendorId: 'seven_shifts',
                category: VendorCategory.labor,
              ),
            ),
          ),
          isTrue,
        );

        expect(
          laborWageSourceClassFor('seven_shifts'),
          LaborWageSourceClass.perEmployeeWithDollars,
        );
        expect(
          laborWageSourceClassFor('quickbooks_time'),
          LaborWageSourceClass.perEmployeeWithRates,
        );
        expect(
          laborWageSourceClassFor('humanity'),
          LaborWageSourceClass.perPositionWithRates,
        );
        expect(
          laborWageSourceClassFor('agendrix'),
          LaborWageSourceClass.perPositionWithRates,
        );
        expect(laborWageSourceClassFor('adp'), LaborWageSourceClass.hoursOnly);
        expect(
          laborWageSourceClassFor('push_operations'),
          LaborWageSourceClass.hoursOnly,
        );
        expect(laborWageSourceClassFor('libro'), isNull);
      },
    );
  });
}
