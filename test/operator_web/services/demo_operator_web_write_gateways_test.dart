import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/services/demo_operator_web_write_gateways.dart';
import 'package:forge_and_flow/operator_web/services/http_business_timing_read_gateway.dart';
import 'package:forge_and_flow/operator_web/services/web_account_gateway.dart';
import 'package:forge_and_flow/operator_web/services/web_business_timing_gateway.dart';

void main() {
  group('DemoOperatorWebBusinessTimingWriteGateway', () {
    test('creates temporary timing profiles without a proxy', () async {
      final gateway = DemoOperatorWebBusinessTimingWriteGateway();

      final created = await gateway.createProfile(
        const BusinessTimingProfileCreate(
          scopeKind: 'location',
          scopeId: 'demo-location',
          effectiveAtBusinessDate: '2026-05-20',
          ianaTimezone: 'America/Toronto',
          weekStartDay: 'monday',
          businessDayStartLocal: '04:00',
          servicePeriods: <ServicePeriodCreate>[
            ServicePeriodCreate(
              key: 'breakfast',
              label: 'Breakfast',
              startLocal: '07:00',
              endLocal: '10:30',
              shortLabel: 'B',
              sortOrder: 1,
            ),
          ],
        ),
      );

      expect(created.profileId, startsWith('demo-timing-'));
      expect(created.scopeKind, 'location');
      expect(created.servicePeriods.single.label, 'Breakfast');

      final profiles = await gateway.listProfiles();
      expect(profiles.any((p) => p.profileId == created.profileId), isTrue);
    });

    test(
      'backs the demo read surface and editor with the same memory',
      () async {
        final writeGateway = DemoOperatorWebBusinessTimingWriteGateway();
        final readGateway = HttpBusinessTimingReadGateway(
          gateway: writeGateway,
        );

        final initial = await readGateway.loadTiming(
          operatorId: 'demo-operator',
          locationId: 'demo-location',
        );
        expect(initial.writesAvailable, isTrue);
        expect(initial.servicePeriods.map((p) => p.name), contains('Lunch'));

        await writeGateway.createProfile(
          const BusinessTimingProfileCreate(
            scopeKind: 'location',
            scopeId: 'demo-location',
            effectiveAtBusinessDate: '2026-05-20',
            ianaTimezone: 'America/St_Johns',
            weekStartDay: 'sunday',
            businessDayStartLocal: '03:30',
            servicePeriods: <ServicePeriodCreate>[
              ServicePeriodCreate(
                key: 'walk_in_late',
                label: 'Walk-in late',
                startLocal: '21:00',
                endLocal: '01:30',
                shortLabel: 'WL',
                sortOrder: 1,
              ),
            ],
          ),
        );

        final updated = await readGateway.loadTiming(
          operatorId: 'demo-operator',
          locationId: 'demo-location',
        );
        expect(updated.effectiveFields.map((f) => f.value), contains('03:30'));
        expect(
          updated.servicePeriods.map((p) => p.name),
          contains('Walk-in late'),
        );
        expect(
          readGateway.selectProfileForLocation('demo-location')?.scopeKind,
          'location',
        );
      },
    );
  });

  group('DemoOperatorWebAccountGateway', () {
    test('saves timezone and account edits in memory only', () async {
      final gateway = DemoOperatorWebAccountGateway();

      final timezone = await gateway.patchLocationTimezone(
        const AccountLocationTimezonePatch(ianaTimezone: 'America/St_Johns'),
      );
      expect(timezone.ianaTimezone, 'America/St_Johns');

      final identity = await gateway.patchAccount(
        const AccountIdentityPatch(businessName: 'Demo Visual Audit Group'),
      );
      expect(identity.businessName, 'Demo Visual Audit Group');

      final overrides = await gateway.getLocationAccountOverrides(
        locationId: 'demo-location',
      );
      expect(overrides.effective.ianaTimezone, 'America/St_Johns');
    });
  });
}
