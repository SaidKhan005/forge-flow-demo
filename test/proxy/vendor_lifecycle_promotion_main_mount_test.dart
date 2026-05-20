// Phase 8 V1.E - proves the vendor lifecycle promotion route is
// mounted in tool/advisor_proxy/main.dart's pre-check chain.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('vendor lifecycle promotion route main.dart mount wiring', () {
    String readMainSource() =>
        File('tool/advisor_proxy/main.dart').readAsStringSync();

    test('imports the route sibling file', () {
      expect(
        readMainSource(),
        contains(
          "import 'email_dispatch/vendor_lifecycle_promotion_routes.dart';",
        ),
      );
    });

    test('instantiates VendorLifecyclePromotionRouter at startup', () {
      final source = readMainSource();
      expect(
        source,
        contains(
          'final vendorLifecyclePromotionRouter = '
          'VendorLifecyclePromotionRouter(',
        ),
      );
      final mountRegion = source.substring(
        source.indexOf('vendorLifecyclePromotionRouter ='),
        source.indexOf('startup.vendor_lifecycle_promotion_router'),
      );
      expect(
        mountRegion,
        contains('productionBindings.vendorLifecycleNotificationDispatcher'),
      );
      expect(
        mountRegion,
        contains('productionBindings.vendorLifecyclePromotionIdempotencyStore'),
      );
      expect(mountRegion, contains('authGuard.requireVerifiedClaims'));
      expect(mountRegion, contains("claims.roles.contains('super_admin')"));
    });

    test('dispatch chain calls tryHandle before routeRequest fallback', () {
      final source = readMainSource();
      expect(
        source,
        contains('vendorLifecyclePromotionRouter.tryHandle(request)'),
      );
      final promotionIndex = source.indexOf(
        'vendorLifecyclePromotionRouter.tryHandle(request)',
      );
      final tierEmailIndex = source.indexOf(
        'operatorTierEmailRouter.tryHandle(request)',
      );
      final heapIndex = source.indexOf(
        'heapSnapshotCaptureRouter.tryHandle(request)',
      );
      final routeRequestIndex = source.indexOf('await routeRequest(');

      expect(promotionIndex, greaterThan(tierEmailIndex));
      expect(promotionIndex, lessThan(heapIndex));
      expect(promotionIndex, lessThan(routeRequestIndex));
    });

    test('startup log exposes route mount and idempotency binding', () {
      final source = readMainSource();
      expect(source, contains("'startup.vendor_lifecycle_promotion_router'"));
      expect(
        source,
        contains("'idempotency_store': 'admin_request_idempotency'"),
      );
      expect(source, contains('adminVendorLifecyclePromotionPathSuffix'));
    });
  });
}
