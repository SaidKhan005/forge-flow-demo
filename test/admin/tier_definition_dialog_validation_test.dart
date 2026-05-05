// Phase 8 spine-bridge Lane .C — supplemental coverage for the
// `tier_definition_edit_dialog` cadence-empty validation. Standard
// and premium tiers ship with cadence presets baked in code per the
// contract; the dialog must refuse to save those tiers with an empty
// cadence map (silently turning off polling for every operator
// assigned to that tier would be a real regression).

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/services/data_accuracy_admin_gateway.dart';
import 'package:forge_and_flow/admin/widgets/tier_definition_edit_dialog.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: Scaffold(body: child),
      );

  group('8.spine-bridge.C — Tier definition edit dialog validation', () {
    testWidgets(
        'standard tier with empty cadence map refuses to submit and '
        'surfaces inline error', (tester) async {
      tester.view.physicalSize = const Size(1600, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final FlutterExceptionHandler? prior = FlutterError.onError;
      FlutterError.onError = (details) {
        final s = details.exceptionAsString();
        if (s.contains('A RenderFlex overflowed')) return;
        prior?.call(details);
      };
      addTearDown(() => FlutterError.onError = prior);

      // Use the demo standard tier as the seed.
      final initial = kDemoStandardTierDefinition();
      TierDefinitionEditResult? returned;

      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  returned = await TierDefinitionEditDialog.show(ctx, initial);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('admin_tier_definition_dialog')),
          findsOneWidget);

      // Clear every cadence field — leaves the cadence map empty.
      for (final id in kPollOnlyVendorIds) {
        await tester.enterText(
          find.byKey(Key('admin_cadence_field_$id')),
          '',
        );
        await tester.pump();
      }

      // Provide a reason so the only validation error is the cadence one.
      await tester.enterText(
        find.byKey(const Key('admin_tier_definition_dialog_reason')),
        'attempt to clear cadence',
      );
      await tester.pump();

      // Submit — dialog must stay open + render the cadence error.
      await tester.tap(find.byKey(const Key('admin_tier_definition_dialog_submit')));
      await tester.pump();

      // Dialog still on screen.
      expect(find.byKey(const Key('admin_tier_definition_dialog')),
          findsOneWidget);
      // Inline error rendered. Match on the prefix so the wording can
      // tighten without breaking the test.
      expect(
        find.textContaining(
          'Standard / premium tiers require at least one vendor cadence',
        ),
        findsOneWidget,
        reason: 'dialog must surface the cadence-empty error and refuse '
            'to pop with a result',
      );
      // No result returned through the awaited future.
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(returned, isNull);
    });

    testWidgets(
        'custom tier with empty cadence map IS allowed (admin sets per '
        'assignment)', (tester) async {
      tester.view.physicalSize = const Size(1600, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final FlutterExceptionHandler? prior = FlutterError.onError;
      FlutterError.onError = (details) {
        final s = details.exceptionAsString();
        if (s.contains('A RenderFlex overflowed')) return;
        prior?.call(details);
      };
      addTearDown(() => FlutterError.onError = prior);

      final initial = kDemoCustomTierDefinition();
      TierDefinitionEditResult? returned;

      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  returned = await TierDefinitionEditDialog.show(ctx, initial);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Custom seed already has empty cadence; just supply price + cost +
      // reason.
      await tester.enterText(
        find.byKey(const Key('admin_tier_definition_dialog_price')),
        '100.00',
      );
      await tester.enterText(
        find.byKey(const Key('admin_tier_definition_dialog_cost')),
        '20.00',
      );
      await tester.enterText(
        find.byKey(const Key('admin_tier_definition_dialog_reason')),
        'set custom defaults',
      );
      await tester.pump();

      await tester.tap(
        find.byKey(const Key('admin_tier_definition_dialog_submit')),
      );
      await tester.pumpAndSettle();

      // Dialog popped + result returned with empty cadence map.
      expect(find.byKey(const Key('admin_tier_definition_dialog')),
          findsNothing);
      expect(returned, isNotNull);
      expect(returned!.pollingCadencePerVendorSeconds, isEmpty);
      expect(returned!.defaultMonthlyPriceCents, equals(10000));
      expect(returned!.vendorApiCostEstimateCentsMonthly, equals(2000));
    });
  });
}
