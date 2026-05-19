import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/connector_backfill_jobs_routes.dart';
import '../../tool/advisor_proxy/operator_benchmark_override_cap.dart';
import '../../tool/advisor_proxy/operator_benchmark_overrides_routes.dart';
import '../../tool/advisor_proxy/operator_routes.dart';
import '../../tool/advisor_proxy/vendor_lifecycle_recently_available_routes.dart';

void main() {
  group('operator proxy role allow-lists', () {
    test('owner-only writes do not admit phantom operator_admin', () {
      expect(kOperatorWriteRoles, equals(<String>{'operator_owner'}));
      expect(kOperatorWriteRoles, isNot(contains('operator_admin')));
    });

    test('vendor read/status routes use current v2 screen roles', () {
      expect(
        kOperatorConnectorBackfillJobsReadRoles,
        equals(<String>{'operator_owner', 'location_manager'}),
      );
      expect(
        kOperatorVendorLifecycleRecentlyAvailableReadRoles,
        equals(<String>{'operator_owner', 'location_manager'}),
      );
      expect(
        kOperatorConnectorBackfillJobsReadRoles,
        isNot(contains('operator_admin')),
      );
      expect(
        kOperatorVendorLifecycleRecentlyAvailableReadRoles,
        isNot(contains('operator_admin')),
      );
    });

    test('benchmark override status/read roles use current v2 tiers', () {
      expect(
        kOperatorBenchmarkOverrideWriteRoles,
        equals(<String>{
          'operator_owner',
          'operator_general_manager',
          'location_manager',
          'supervisor',
        }),
      );
      expect(
        BenchmarkOverrideCapPolicy.adminTierRoles,
        equals(<String>{
          'operator_owner',
          'operator_general_manager',
          'super_admin',
        }),
      );
      expect(
        kOperatorBenchmarkOverrideWriteRoles,
        isNot(contains('operator_admin')),
      );
      expect(
        BenchmarkOverrideCapPolicy.adminTierRoles,
        isNot(contains('operator_admin')),
      );
    });
  });
}
