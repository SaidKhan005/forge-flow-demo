// Phase 8 spine-bridge Lane .B — VendorRelativityLabel widget tests.
//
// Covers acceptance item H: dynamic per connected vendors. The
// composeVendorRelativityLines() helper produces different copy when
// Toast+QBT+Libro is connected vs Square+QBT+Libro, and the widget
// surface renders those lines as Text descendants.
//
// Authority:
//   docs/contracts/data_accuracy_settings_contract.md
//   "Vendor relativity rules" section.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/integrations/ui/vendor_connections/vendor_connections_models.dart';
import 'package:forge_and_flow/operator_web/widgets/vendor_relativity_label.dart';

String _displayName(String vendorId) {
  switch (vendorId) {
    case 'toast':
      return 'Toast';
    case 'square':
      return 'Square';
    case 'quickbooks_time':
      return 'QuickBooks Time';
    case 'humanity':
      return 'Humanity';
    case 'libro':
      return 'Libro';
    default:
      return vendorId;
  }
}

VendorConnectionRow _row(
  String vendorId,
  String displayName,
  VendorCategory category,
) => VendorConnectionRow(
  connectionId: '$vendorId-conn',
  vendorId: vendorId,
  displayName: displayName,
  category: category,
  status: VendorConnectionStatus.connected,
  metadata: const <String, Object?>{},
);

VendorConnectionsBundle _bundle({
  String? pos,
  String? labor,
  String? reservation,
}) => VendorConnectionsBundle(
  operatorId: 'op',
  locationId: 'loc',
  locationName: 'Test',
  posConnection: pos == null
      ? null
      : _row(pos, _displayName(pos), VendorCategory.pos),
  laborConnection: labor == null
      ? null
      : _row(labor, _displayName(labor), VendorCategory.labor),
  reservationConnection: reservation == null
      ? null
      : _row(
          reservation,
          _displayName(reservation),
          VendorCategory.reservation,
        ),
  demoFlags: const <VendorCategory, bool>{},
);

bool _anyLineContains(List<String> lines, String needle) {
  for (final line in lines) {
    if (line.contains(needle)) return true;
  }
  return false;
}

void main() {
  group('composeVendorRelativityLines — covers (acceptance item H)', () {
    test('Toast (covers exposed) mentions Toast and Vendor', () {
      final lines = composeVendorRelativityLines(
        VendorRelativitySetting.covers,
        _bundle(pos: 'toast'),
      );
      expect(
        _anyLineContains(lines, 'Toast exposes covers'),
        isTrue,
        reason:
            'expected a line mentioning Toast exposes covers, got '
            '$lines',
      );
      expect(
        _anyLineContains(lines, 'Vendor option'),
        isTrue,
        reason: 'expected vendor option copy; got $lines',
      );
    });

    test('Square (covers NOT exposed) — copy says Square does not expose '
        'covers', () {
      final lines = composeVendorRelativityLines(
        VendorRelativitySetting.covers,
        _bundle(pos: 'square'),
      );
      expect(
        _anyLineContains(lines, 'Square does not expose covers'),
        isTrue,
        reason: 'expected Square does-not-expose copy, got $lines',
      );
    });

    test('null bundle — generic fallback copy', () {
      final lines = composeVendorRelativityLines(
        VendorRelativitySetting.covers,
        null,
      );
      expect(
        _anyLineContains(lines, 'POS that exposes guest counts'),
        isTrue,
        reason: 'expected compact fallback copy, got $lines',
      );
    });
  });

  group('composeVendorRelativityLines — wage (acceptance item H)', () {
    // Wage class mappings come from
    // `lib/services/integration/labor_wage_source_class.dart` (Lane .2's
    // 2026-05-05 binding sidecar). Per the corrections:
    //   * QBT + 7shifts -> perEmployeeWithRates (rate × duration).
    //   * Humanity + Agendrix -> perPositionWithRates.
    //   * ADP + Push Operations -> hoursOnly.
    // No Wave B vendor currently qualifies as perEmployeeWithDollars.

    test('QuickBooks Time (perEmployeeWithRates) — copy mentions '
        'employee rates and rates and time', () {
      final lines = composeVendorRelativityLines(
        VendorRelativitySetting.wage,
        _bundle(labor: 'quickbooks_time'),
      );
      expect(
        _anyLineContains(lines, 'QuickBooks Time'),
        isTrue,
        reason: 'expected QuickBooks Time mentioned, got $lines',
      );
      expect(
        _anyLineContains(lines, 'employee rates'),
        isTrue,
        reason: 'expected employee rates copy, got $lines',
      );
      expect(
        _anyLineContains(lines, 'rates and time'),
        isTrue,
        reason: 'expected rates and time copy, got $lines',
      );
    });

    test('Humanity (perPositionWithRates) — copy mentions role rates', () {
      final lines = composeVendorRelativityLines(
        VendorRelativitySetting.wage,
        _bundle(labor: 'humanity'),
      );
      expect(
        _anyLineContains(lines, 'role rates'),
        isTrue,
        reason: 'expected role rates copy, got $lines',
      );
    });

    test('ADP (hoursOnly) — copy mentions hours only and target wage', () {
      final lines = composeVendorRelativityLines(
        VendorRelativitySetting.wage,
        _bundle(labor: 'adp'),
      );
      final hasTargetWage = _anyLineContains(lines, 'target wage');
      final hasHoursOnly = _anyLineContains(lines, 'hours only');
      expect(
        hasTargetWage && hasHoursOnly,
        isTrue,
        reason:
            'expected hoursOnly branch to mention hours only and '
            'target wage; got $lines',
      );
    });

    test('Unknown labor vendor says wage path is not mapped', () {
      // Toast is not in the LaborWageSourceClass sidecar (it is a POS
      // adapter). Wiring it as the labor row exercises the
      // null-wage-class fallback branch.
      final lines = composeVendorRelativityLines(
        VendorRelativitySetting.wage,
        _bundle(labor: 'toast'),
      );
      expect(
        _anyLineContains(lines, 'Toast'),
        isTrue,
        reason: 'expected Toast display name in fallback copy, got $lines',
      );
      expect(
        _anyLineContains(lines, 'wage path is not mapped'),
        isTrue,
        reason: 'expected unmapped wage-path copy, got $lines',
      );
    });
  });

  group('composeVendorRelativityLines — polling (acceptance item H)', () {
    test('QuickBooks Time connected (poll-only) — copy mentions QBT and '
        'F&F controls cadence', () {
      final lines = composeVendorRelativityLines(
        VendorRelativitySetting.polling,
        _bundle(labor: 'quickbooks_time'),
      );
      expect(
        _anyLineContains(lines, 'QuickBooks Time'),
        isTrue,
        reason: 'expected QuickBooks Time mentioned, got $lines',
      );
      // Tier-control copy was rewritten to plain English per the UX
      // writing standard. The line that used to say "F&F controls
      // cadence" now reads "Your tier sets how often." — same intent.
      expect(
        _anyLineContains(lines, 'Your tier sets'),
        isTrue,
        reason: 'expected tier-control copy, got $lines',
      );
    });

    test(
      'Toast connected (webhook) — copy mentions push updates and Toast',
      () {
        final lines = composeVendorRelativityLines(
          VendorRelativitySetting.polling,
          _bundle(pos: 'toast'),
        );
        expect(
          _anyLineContains(lines, 'push updates'),
          isTrue,
          reason: 'expected push-update copy, got $lines',
        );
        expect(
          _anyLineContains(lines, 'Toast'),
          isTrue,
          reason: 'expected Toast mentioned, got $lines',
        );
      },
    );

    test('null bundle — fallback explains when freshness applies', () {
      final lines = composeVendorRelativityLines(
        VendorRelativitySetting.polling,
        null,
      );
      expect(
        _anyLineContains(lines, 'needs scheduled checks'),
        isTrue,
        reason: 'expected compact freshness fallback, got $lines',
      );
    });
  });

  group('VendorRelativityLabel widget surface (acceptance item H)', () {
    testWidgets('widget renders the lines as Text widgets', (tester) async {
      final bundle = _bundle(pos: 'square');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VendorRelativityLabel(
              setting: VendorRelativitySetting.covers,
              bundle: bundle,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('vendor_relativity_label_covers')),
        findsOneWidget,
      );

      // At least one Text descendant of the label must contain the
      // dynamic Square copy.
      final Iterable<Text> texts = tester.widgetList<Text>(
        find.descendant(
          of: find.byKey(const Key('vendor_relativity_label_covers')),
          matching: find.byType(Text),
        ),
      );
      final hasSquareCopy = texts.any(
        (t) => (t.data ?? '').contains('Square does not expose'),
      );
      expect(
        hasSquareCopy,
        isTrue,
        reason:
            'expected at least one Text descendant containing the '
            'dynamic Square copy under the label widget',
      );
    });
  });
}
