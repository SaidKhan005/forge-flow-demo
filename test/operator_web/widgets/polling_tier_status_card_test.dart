// Phase 8 spine-bridge Lane .B — PollingTierStatusCard widget tests.
//
// Covers acceptance item G: renders tier name + per-vendor cadence
// list (poll-only vendors only); webhook vendors absent; "Request
// tier change" button opens ticket creation; NO cadence picker
// exists on the operator surface.
//
// Authority:
//   docs/contracts/data_accuracy_settings_contract.md
//   "Polling cadence — F&F-controlled tier model" section.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/widgets/polling_tier_status_card.dart';

PollingTierStatus standardStatus({Map<String, int>? cadences}) =>
    PollingTierStatus(
      tier: PollingTierLabel.standard,
      tierDisplayLabel: 'Standard',
      monthlyPriceLabel: 'Bundled with subscription',
      perVendorCadenceSeconds: cadences ??
          const <String, int>{
            'oracle_micros_simphony': 300,
            'quickbooks_time': 300,
          },
    );

Widget _wrap(Widget child) {
  return MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

void main() {
  group('PollingTierStatusCard — acceptance item G', () {
    testWidgets('card renders title + status pill + monthly price',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          PollingTierStatusCard(
            status: standardStatus(),
            bundle: null,
            onRequestTierChange: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('data_accuracy_polling_tier_status_card')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('polling_tier_status_pill')),
        findsOneWidget,
      );
      expect(find.text('Standard'), findsWidgets);
      expect(find.text('Bundled with subscription'), findsOneWidget);
    });

    testWidgets(
        'per-vendor cadence list renders one row per poll-only vendor',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          PollingTierStatusCard(
            status: standardStatus(
              cadences: const <String, int>{
                'oracle_micros_simphony': 300,
                'quickbooks_time': 60,
              },
            ),
            bundle: null,
            onRequestTierChange: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('polling_tier_vendor_row_oracle_micros_simphony')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('polling_tier_vendor_row_quickbooks_time')),
        findsOneWidget,
      );
      // 300 seconds → "5 minutes"; 60 seconds → "1 minute".
      expect(
        find.textContaining('5 minute'),
        findsOneWidget,
      );
      expect(
        find.textContaining('1 minute'),
        findsOneWidget,
      );
    });

    testWidgets('webhook vendors are NOT in the cadence list',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          PollingTierStatusCard(
            status: standardStatus(
              cadences: const <String, int>{
                'oracle_micros_simphony': 300,
                'quickbooks_time': 300,
              },
            ),
            bundle: null,
            onRequestTierChange: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('polling_tier_vendor_row_toast')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('polling_tier_vendor_row_square')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('polling_tier_vendor_row_clover')),
        findsNothing,
      );
    });

    testWidgets('no cadence picker / dropdown / slider in widget tree',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          PollingTierStatusCard(
            status: standardStatus(),
            bundle: null,
            onRequestTierChange: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(Slider), findsNothing);
      expect(
        find.byWidgetPredicate((w) => w is DropdownButton),
        findsNothing,
      );
      expect(
        find.byWidgetPredicate((w) => w is DropdownMenu),
        findsNothing,
      );
      expect(find.text('Confirm and apply'), findsNothing);
    });

    testWidgets('request tier change button is present and enabled',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          PollingTierStatusCard(
            status: standardStatus(),
            bundle: null,
            onRequestTierChange: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final buttonFinder =
          find.byKey(const Key('polling_tier_request_change_button'));
      expect(buttonFinder, findsOneWidget);

      final OutlinedButton button = tester.widget<OutlinedButton>(buttonFinder);
      expect(button.onPressed, isNotNull);
    });

    testWidgets('request tier change button calls onRequestTierChange',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _wrap(
          PollingTierStatusCard(
            status: standardStatus(),
            bundle: null,
            onRequestTierChange: () {
              taps += 1;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('polling_tier_request_change_button')),
      );
      await tester.pumpAndSettle();
      expect(taps, 1);
    });

    testWidgets(
        'empty cadences map renders a plain-English real-time confirmation line',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          PollingTierStatusCard(
            status: standardStatus(cadences: const <String, int>{}),
            bundle: null,
            onRequestTierChange: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('pushes updates to Forge & Flow'),
        findsOneWidget,
      );
    });
  });

  group(
      'showPollingTierChangeRequestDialog — dialog flow (acceptance item G)',
      () {
    Future<void> openDialog(
      WidgetTester tester, {
      required void Function(Future<String?> future) onResult,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext ctx) {
                return ElevatedButton(
                  onPressed: () {
                    onResult(showPollingTierChangeRequestDialog(ctx));
                  },
                  child: const Text('Open'),
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
    }

    testWidgets(
        'showPollingTierChangeRequestDialog opens with reason field + '
        'submit + cancel', (tester) async {
      await openDialog(tester, onResult: (_) {});

      expect(
        find.byKey(const Key('polling_tier_change_request_dialog')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('polling_tier_change_request_reason_field')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('polling_tier_change_request_submit')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('polling_tier_change_request_cancel')),
        findsOneWidget,
      );
    });

    testWidgets('dialog submit returns trimmed text', (tester) async {
      Future<String?>? captured;
      await openDialog(
        tester,
        onResult: (Future<String?> future) {
          captured = future;
        },
      );

      await tester.enterText(
        find.byKey(const Key('polling_tier_change_request_reason_field')),
        '  please switch to premium  ',
      );
      await tester.pumpAndSettle();

      final submitFinder =
          find.byKey(const Key('polling_tier_change_request_submit'));
      final FilledButton submit = tester.widget<FilledButton>(submitFinder);
      expect(submit.onPressed, isNotNull);

      await tester.tap(submitFinder);
      await tester.pumpAndSettle();

      expect(captured, isNotNull);
      final result = await captured!;
      expect(result, 'please switch to premium');
    });

    testWidgets('dialog submit disabled when reason empty', (tester) async {
      await openDialog(tester, onResult: (_) {});

      final submitFinder =
          find.byKey(const Key('polling_tier_change_request_submit'));
      final FilledButton submit = tester.widget<FilledButton>(submitFinder);
      expect(submit.onPressed, isNull);
    });

    testWidgets('dialog cancel returns null', (tester) async {
      Future<String?>? captured;
      await openDialog(
        tester,
        onResult: (Future<String?> future) {
          captured = future;
        },
      );

      await tester
          .tap(find.byKey(const Key('polling_tier_change_request_cancel')));
      await tester.pumpAndSettle();

      expect(captured, isNotNull);
      final result = await captured!;
      expect(result, isNull);
    });
  });
}
