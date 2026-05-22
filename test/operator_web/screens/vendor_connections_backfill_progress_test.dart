// Wave W2.D — widget tests for the per-connection backfill progress panel.
//
// Asserts the panel renders for each backfill state (setup / running /
// complete / failed / dead-lettered) with plain-English labels, retry
// visibility on failures, and an honest "not wired" body when the
// host shell did not pass a gateway.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/services/operator_web_connector_backfill_jobs_gateway.dart';
import 'package:forge_and_flow/operator_web/widgets/vendor_connections_backfill_progress_panel.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  group('VendorConnectionsBackfillProgressPanel', () {
    Widget wrap(Widget child) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: Scaffold(
          backgroundColor: AppColors.backgroundDeep,
          body: SingleChildScrollView(child: child),
        ),
      );
    }

    OperatorWebConnectorBackfillJob job({
      required String connectionId,
      required String vendorId,
      required String status,
      String category = 'pos',
      String? lastError,
      DateTime? lastModifiedSeen,
      int attemptCount = 1,
    }) {
      final windowEnd = DateTime.utc(2026, 5, 7);
      final windowStart = windowEnd.subtract(const Duration(days: 60));
      return OperatorWebConnectorBackfillJob(
        jobId: 'job-$connectionId',
        connectionId: connectionId,
        vendorId: vendorId,
        category: category,
        status: status,
        windowStart: windowStart,
        windowEnd: windowEnd,
        attemptCount: attemptCount,
        cursorToken: lastModifiedSeen?.toIso8601String(),
        lastModifiedSeen: lastModifiedSeen,
        workerId: 'worker-1',
        claimedAt: DateTime.utc(2026, 5, 5),
        completedAt: status == 'succeeded' ? DateTime.utc(2026, 5, 6) : null,
        lastError: lastError,
        createdAt: DateTime.utc(2026, 5, 4),
        updatedAt: DateTime.utc(2026, 5, 6),
      );
    }

    OperatorWebConnectorBackfillJobsGatewayInMemory gatewayWith(
      List<OperatorWebConnectorBackfillJob> jobs,
    ) {
      return OperatorWebConnectorBackfillJobsGatewayInMemory(
        operatorId: 'op-1',
        locationId: 'loc-1',
        jobs: jobs,
      );
    }

    testWidgets('renders honest "not wired" copy when no gateway is passed',
        (tester) async {
      await tester.pumpWidget(
        wrap(
          const VendorConnectionsBackfillProgressPanel(gateway: null),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(
          const Key('vendor_connections_backfill_progress_panel_not_wired'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('renders empty body when the gateway returns no jobs',
        (tester) async {
      await tester.pumpWidget(
        wrap(
          VendorConnectionsBackfillProgressPanel(
            gateway: gatewayWith(const <OperatorWebConnectorBackfillJob>[]),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(
          const Key('vendor_connections_backfill_progress_panel_empty'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('renders setup / running / complete / failed / dead-lettered '
        'with plain-English labels', (tester) async {
      final jobs = <OperatorWebConnectorBackfillJob>[
        job(
          connectionId: 'conn-setup',
          vendorId: 'toast',
          status: 'pending',
        ),
        job(
          connectionId: 'conn-running',
          vendorId: 'square',
          status: 'running',
          lastModifiedSeen: DateTime.utc(2026, 4, 1),
        ),
        job(
          connectionId: 'conn-complete',
          vendorId: 'seven_shifts',
          status: 'succeeded',
          category: 'labor',
          lastModifiedSeen: DateTime.utc(2026, 5, 6),
        ),
        job(
          connectionId: 'conn-failed',
          vendorId: 'opentable',
          status: 'failed',
          category: 'reservation',
          lastError: 'Vendor returned HTTP 500 on the third retry.',
        ),
        job(
          connectionId: 'conn-dead',
          vendorId: 'resy',
          status: 'dead_lettered',
          category: 'reservation',
          attemptCount: 5,
          lastError: 'Backfill exhausted retry budget.',
        ),
      ];
      await tester.pumpWidget(
        wrap(
          VendorConnectionsBackfillProgressPanel(gateway: gatewayWith(jobs)),
        ),
      );
      await tester.pump();
      await tester.pump();

      Text statusBadgeText(String connectionId) => tester.widget<Text>(
            find.byKey(
              ValueKey<String>(
                'vendor_connections_backfill_progress_status_$connectionId',
              ),
            ),
          );

      Finder progressBar(String connectionId) => find.byKey(
            ValueKey<String>(
              'vendor_connections_backfill_progress_bar_$connectionId',
            ),
          );

      // Each row renders.
      for (final connectionId in const <String>[
        'conn-setup',
        'conn-running',
        'conn-complete',
        'conn-failed',
        'conn-dead',
      ]) {
        expect(
          find.byKey(
            ValueKey<String>(
              'vendor_connections_backfill_progress_row_$connectionId',
            ),
          ),
          findsOneWidget,
          reason: 'row for $connectionId should render',
        );
        expect(
          progressBar(connectionId),
          findsOneWidget,
          reason: 'progress bar for $connectionId should render',
        );
      }

      // Plain-English status labels.
      expect(statusBadgeText('conn-setup').data, equals('Setting up'));
      expect(
        statusBadgeText('conn-running').data,
        equals('Backfill running'),
      );
      expect(
        statusBadgeText('conn-complete').data,
        equals('Backfill complete'),
      );
      expect(statusBadgeText('conn-failed').data, equals('Backfill failed'));
      expect(statusBadgeText('conn-dead').data, equals('Dead-lettered'));

      // Retry button renders for failed + dead-lettered states only,
      // and is disabled (planned follow-up).
      expect(
        find.byKey(
          const ValueKey<String>(
            'vendor_connections_backfill_progress_retry_conn-failed',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey<String>(
            'vendor_connections_backfill_progress_retry_conn-dead',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey<String>(
            'vendor_connections_backfill_progress_retry_conn-setup',
          ),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          const ValueKey<String>(
            'vendor_connections_backfill_progress_retry_conn-complete',
          ),
        ),
        findsNothing,
      );

      // Retry button is disabled (no onPressed) — onPressed: null
      // surfaces as a disabled FilledButton (operator-web button style).
      final retryButton = tester.widget<FilledButton>(
        find.byKey(
          const ValueKey<String>(
            'vendor_connections_backfill_progress_retry_conn-failed',
          ),
        ),
      );
      expect(retryButton.onPressed, isNull);

      // Failure error body surfaces verbatim.
      expect(
        find.text('Vendor returned HTTP 500 on the third retry.'),
        findsOneWidget,
      );
      expect(find.text('Backfill exhausted retry budget.'), findsOneWidget);
    });

    testWidgets('failure surface renders the gateway error message',
        (tester) async {
      final gateway = _ThrowingGateway(
        error: const OperatorWebConnectorBackfillJobsError(
          code: 'transport_error',
          message: 'Backfill progress is temporarily unavailable.',
        ),
      );
      await tester.pumpWidget(
        wrap(VendorConnectionsBackfillProgressPanel(gateway: gateway)),
      );
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(
          const Key('vendor_connections_backfill_progress_panel_failed'),
        ),
        findsOneWidget,
      );
      expect(
        find.text('Backfill progress is temporarily unavailable.'),
        findsOneWidget,
      );
    });
  });
}

class _ThrowingGateway implements OperatorWebConnectorBackfillJobsGateway {
  _ThrowingGateway({required this.error});

  final OperatorWebConnectorBackfillJobsError error;

  @override
  Future<OperatorWebConnectorBackfillJobsBundle> loadJobs({
    String? connectionId,
  }) async {
    throw error;
  }
}
