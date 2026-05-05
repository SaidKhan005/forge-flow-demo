// Phase 8 spine-bridge Lane .B — WageSourceToggle widget tests.
//
// Covers walkthrough acceptance item D — vendor → manual_mix
// round-trips with no state leak, and the dynamic vendor relativity
// label that names the connected labor vendor's wage class.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/models/data_accuracy_settings.dart';
import 'package:forge_and_flow/integrations/ui/vendor_connections/vendor_connections_models.dart';
import 'package:forge_and_flow/operator_web/widgets/wage_source_toggle.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: Scaffold(body: child),
      );

  Future<void> sizeViewport(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  VendorConnectionsBundle bundleWithLabor(String vendorId, String displayName) {
    return VendorConnectionsBundle(
      operatorId: 'brio-operator',
      locationId: 'brio-chicago-loop',
      locationName: 'Brio - Chicago Loop',
      posConnection: null,
      laborConnection: VendorConnectionRow(
        connectionId: '$vendorId-conn',
        vendorId: vendorId,
        displayName: displayName,
        category: VendorCategory.labor,
        status: VendorConnectionStatus.connected,
        metadata: const <String, Object?>{},
      ),
      reservationConnection: null,
      demoFlags: const <VendorCategory, bool>{},
    );
  }

  bool anyTextContains(String needle) {
    final elements = find.byType(Text).evaluate();
    for (final element in elements) {
      final widget = element.widget as Text;
      final data = widget.data;
      if (data == null) continue;
      if (data.contains(needle)) return true;
    }
    return false;
  }

  testWidgets('WageSourceToggle renders both radios', (tester) async {
    await sizeViewport(tester, const Size(1024, 800));

    await tester.pumpWidget(
      wrap(
        WageSourceToggle(
          value: WageSource.vendor,
          onChanged: (_) {},
          bundle: null,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('data_accuracy_wage_source_card')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('wage_source_radio_vendor')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('wage_source_radio_manual_mix')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('vendor_relativity_label_wage')),
      findsOneWidget,
    );
  });

  testWidgets(
    'tapping manual mix calls onChanged with WageSource.manualMix',
    (tester) async {
      await sizeViewport(tester, const Size(1024, 800));
      WageSource? captured;

      await tester.pumpWidget(
        wrap(
          WageSourceToggle(
            value: WageSource.vendor,
            onChanged: (value) => captured = value,
            bundle: null,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('wage_source_radio_manual_mix')));
      await tester.pumpAndSettle();

      expect(captured, equals(WageSource.manualMix));
    },
  );

  testWidgets(
    'round-trip: vendor → manual_mix → vendor',
    (tester) async {
      await sizeViewport(tester, const Size(1024, 800));
      WageSource current = WageSource.vendor;

      await tester.pumpWidget(
        wrap(
          StatefulBuilder(
            builder: (context, setState) {
              return WageSourceToggle(
                value: current,
                onChanged: (value) => setState(() => current = value),
                bundle: null,
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // vendor → manual_mix
      await tester.tap(find.byKey(const Key('wage_source_radio_manual_mix')));
      await tester.pumpAndSettle();
      expect(current, equals(WageSource.manualMix));

      // manual_mix → vendor
      await tester.tap(find.byKey(const Key('wage_source_radio_vendor')));
      await tester.pumpAndSettle();
      expect(current, equals(WageSource.vendor));
    },
  );

  testWidgets(
    'wage class label updates with connected labor vendor',
    (tester) async {
      await sizeViewport(tester, const Size(1024, 800));

      // QuickBooks Time → perEmployeeWithRates per Lane .2's
      // 2026-05-05 binding sidecar (rate × duration).
      await tester.pumpWidget(
        wrap(
          WageSourceToggle(
            value: WageSource.vendor,
            onChanged: (_) {},
            bundle: bundleWithLabor('quickbooks_time', 'QuickBooks Time'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(anyTextContains('QuickBooks Time'), isTrue);
      expect(anyTextContains('per-employee hourly rates'), isTrue);

      // Humanity → per-position pay rates.
      await tester.pumpWidget(
        wrap(
          WageSourceToggle(
            value: WageSource.vendor,
            onChanged: (_) {},
            bundle: bundleWithLabor('humanity', 'Humanity'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(anyTextContains('Humanity'), isTrue);
      expect(anyTextContains('per-position pay rates'), isTrue);
    },
  );
}
