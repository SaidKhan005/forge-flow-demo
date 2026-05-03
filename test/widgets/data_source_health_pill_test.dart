// Phase 8.0 (V1 lean cut 2) — DataSourceHealthPill widget tests.
//
// Asserts the contract:
//   * empty entries => SizedBox.shrink (no "All live" pill).
//   * non-empty entries => pill renders the most-impactful summary
//     line (severity ordering: unavailable > fallback > partial).
//   * tap opens a detail sheet listing every entry.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/metric_provenance.dart';
import 'package:forge_and_flow/widgets/data_source_health_pill.dart';

void main() {
  testWidgets('renders nothing when entry list is empty', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: DataSourceHealthPill(entries: <DataSourceHealthEntry>[]),
      ),
    ));
    expect(
      find.byKey(const Key('data_source_health_pill_absent')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('data_source_health_pill_present')),
      findsNothing,
    );
  });

  testWidgets(
      'renders a single line summarising the most-impactful entry '
      '(unavailable beats fallback beats partial)',
      (tester) async {
    final entries = <DataSourceHealthEntry>[
      const DataSourceHealthEntry(
        metricLabel: 'PPA',
        state: MetricState.fallback,
        provenance: 'vendor_square_with_forecast_covers',
        summaryLine: 'PPA: covers via forecast',
      ),
      const DataSourceHealthEntry(
        metricLabel: 'CPLH',
        state: MetricState.unavailable,
        provenance: 'none',
        summaryLine: 'Labor: not yet connected',
      ),
    ];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: DataSourceHealthPill(entries: entries)),
    ));
    expect(
      find.byKey(const Key('data_source_health_pill_present')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('data_source_health_pill_headline')),
      findsOneWidget,
    );
    expect(find.text('Labor: not yet connected'), findsOneWidget);
    expect(find.text('PPA: covers via forecast'), findsNothing);
  });

  testWidgets('tap opens detail sheet listing every entry', (tester) async {
    final entries = <DataSourceHealthEntry>[
      const DataSourceHealthEntry(
        metricLabel: 'CPLH',
        state: MetricState.unavailable,
        provenance: 'none',
        summaryLine: 'Labor: not yet connected',
      ),
      const DataSourceHealthEntry(
        metricLabel: 'PPA',
        state: MetricState.fallback,
        provenance: 'vendor_square_with_forecast_covers',
        summaryLine: 'PPA: covers via forecast',
      ),
    ];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: DataSourceHealthPill(entries: entries)),
    ));
    await tester.tap(find.byKey(const Key('data_source_health_pill_present')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('data_source_health_pill_sheet')),
        findsOneWidget);
    // The headline pill ALSO carries "Labor: not yet connected" so
    // we expect at least 2 occurrences of that string (one in the
    // pill, one in the sheet entry). The sheet entry alone is keyed.
    expect(find.byKey(const Key('data_source_health_pill_sheet_CPLH')),
        findsOneWidget);
    expect(find.byKey(const Key('data_source_health_pill_sheet_PPA')),
        findsOneWidget);
    expect(find.text('PPA: covers via forecast'), findsOneWidget);
  });
}
