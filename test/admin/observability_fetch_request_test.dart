// Request-shape coverage for the admin observability fetch.
//
// The cost surfaces are backed by `usage_logs`, a MONTHLY rollup, so the
// only HONEST time selections are the current calendar month and the
// immediately preceding one. The request therefore carries an
// [ObservabilityMonth] (current | previous, default current) and emits it
// as `month=current|previous`. There is intentionally NO 24h / 7d /
// arbitrary-date control (Metric Honesty Doctrine).

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/admin/services/observability_admin_gateway.dart';

void main() {
  group('ObservabilityFetchRequest.toQueryParameters month', () {
    test('defaults to month=current', () {
      const request = ObservabilityFetchRequest();
      expect(request.month, ObservabilityMonth.current);
      expect(request.toQueryParameters()['month'], equals('current'));
    });

    test('emits month=previous when previous is selected', () {
      const request = ObservabilityFetchRequest(
        month: ObservabilityMonth.previous,
      );
      expect(request.toQueryParameters()['month'], equals('previous'));
    });

    test('month is always present (never omitted)', () {
      // Unlike the optional scope params, the month is a closed
      // enumeration with a default, so the wire request always names a
      // bucket — the proxy never has to guess.
      const current = ObservabilityFetchRequest(
        month: ObservabilityMonth.current,
      );
      const previous = ObservabilityFetchRequest(
        month: ObservabilityMonth.previous,
      );
      expect(current.toQueryParameters().containsKey('month'), isTrue);
      expect(previous.toQueryParameters().containsKey('month'), isTrue);
    });

    test('month wire values are exactly current/previous', () {
      expect(ObservabilityMonth.current.wireValue, equals('current'));
      expect(ObservabilityMonth.previous.wireValue, equals('previous'));
      // Guard against an honesty-breaking value sneaking in (e.g. a
      // rolling-window string). Only the two calendar-month values exist.
      expect(
        ObservabilityMonth.values.map((m) => m.wireValue).toSet(),
        equals(<String>{'current', 'previous'}),
      );
    });

    test('selecting a month leaves the other query params unchanged', () {
      const request = ObservabilityFetchRequest(
        costTelemetryLimit: 25,
        queryClassFilter: 'advisor_qa',
        operatorId: 'op-1',
        locationId: 'loc-1',
        month: ObservabilityMonth.previous,
      );
      final params = request.toQueryParameters();
      expect(params['month'], equals('previous'));
      expect(params['cost_telemetry_limit'], equals('25'));
      expect(params['query_class'], equals('advisor_qa'));
      expect(params['operator_id'], equals('op-1'));
      expect(params['location_id'], equals('loc-1'));
    });
  });
}
