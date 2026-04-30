// Phase 11A.1 — Operator/location admin gateway tests.
//
// Two coverage groups:
//
//   * `InMemoryOperatorLocationAdminGateway` — exercises the demo
//     gateway's command/response shapes and validation rules. The
//     screen widget tests run against this same gateway, so anything
//     it accepts must mirror the production validators in the proxy.
//
//   * `OperatorLocationAdminGatewayError` shape + JSON payloads —
//     pins the wire format the screen branches on.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/admin/models/operator_location_admin_models.dart';
import 'package:forge_and_flow/admin/services/operator_location_admin_gateway.dart';

void main() {
  group('isLikelyIanaTimezone', () {
    test('accepts canonical Region/City names', () {
      expect(isLikelyIanaTimezone('America/Toronto'), isTrue);
      expect(isLikelyIanaTimezone('Europe/London'), isTrue);
      expect(isLikelyIanaTimezone('Asia/Hong_Kong'), isTrue);
      expect(isLikelyIanaTimezone('America/Argentina/Buenos_Aires'), isTrue);
    });

    test('accepts UTC and GMT shorthand', () {
      expect(isLikelyIanaTimezone('UTC'), isTrue);
      expect(isLikelyIanaTimezone('GMT'), isTrue);
    });

    test('rejects empty / whitespace / single-token / spaced names', () {
      expect(isLikelyIanaTimezone(''), isFalse);
      expect(isLikelyIanaTimezone('   '), isFalse);
      expect(isLikelyIanaTimezone('Toronto'), isFalse);
      expect(isLikelyIanaTimezone('America Toronto'), isFalse);
      expect(isLikelyIanaTimezone('America/Toronto Eastern'), isFalse);
    });

    test('rejects names with disallowed characters or empty segments', () {
      expect(isLikelyIanaTimezone('America//Toronto'), isFalse);
      expect(isLikelyIanaTimezone('America/Toronto!'), isFalse);
      expect(isLikelyIanaTimezone('/America/Toronto'), isFalse);
    });

    test('rejects catalog-shaped names that are not real IANA zones', () {
      expect(isLikelyIanaTimezone('Mars/Olympus'), isFalse);
      expect(isLikelyIanaTimezone('America/Not_A_Zone'), isFalse);
    });
  });

  group('InMemoryOperatorLocationAdminGateway — onboarding', () {
    test(
      'onboard creates operator + primary location and renders in list',
      () async {
        final gateway = InMemoryOperatorLocationAdminGateway(
          now: () => DateTime.utc(2026, 4, 29, 10),
        );
        final bundle = await gateway.onboardOperator(
          const OperatorOnboardCommand(
            businessName: 'Test Cafe',
            ownerEmail: 'owner@test.cafe',
            subscriptionTier: 'launch',
            preferredCurrency: 'CAD',
            primaryLocationName: 'Main',
            primaryLocationTimezone: 'America/Toronto',
            primaryLocationRolloverHour: 4,
            adminUserEmail: 'admin@test.cafe',
          ),
        );

        expect(bundle.operator.businessName, equals('Test Cafe'));
        expect(bundle.operator.preferredCurrency, equals('CAD'));
        expect(bundle.operator.primaryLocationId, isNotNull);
        expect(bundle.locations, hasLength(1));
        expect(bundle.primaryLocation?.name, equals('Main'));

        final list = await gateway.listOperators();
        expect(list, hasLength(1));
        expect(
          list.single.operator.operatorId,
          equals(bundle.operator.operatorId),
        );
      },
    );

    test(
      'onboard rejects an invalid IANA timezone with a typed error',
      () async {
        final gateway = InMemoryOperatorLocationAdminGateway();
        Object? thrown;
        try {
          await gateway.onboardOperator(
            const OperatorOnboardCommand(
              businessName: 'Test',
              ownerEmail: 'a@b.c',
              subscriptionTier: 'launch',
              preferredCurrency: 'CAD',
              primaryLocationName: 'Main',
              primaryLocationTimezone: 'Toronto Eastern',
              primaryLocationRolloverHour: 4,
              adminUserEmail: 'admin@b.c',
            ),
          );
        } catch (error) {
          thrown = error;
        }
        expect(thrown, isA<OperatorLocationAdminGatewayError>());
        final err = thrown! as OperatorLocationAdminGatewayError;
        expect(err.statusCode, equals(400));
        expect(err.errorCode, equals('invalid_timezone'));
      },
    );

    test('onboard rejects a non-ISO currency', () async {
      final gateway = InMemoryOperatorLocationAdminGateway();
      Object? thrown;
      try {
        await gateway.onboardOperator(
          const OperatorOnboardCommand(
            businessName: 'Test',
            ownerEmail: 'a@b.c',
            subscriptionTier: 'launch',
            preferredCurrency: 'CADD',
            primaryLocationName: 'Main',
            primaryLocationTimezone: 'America/Toronto',
            primaryLocationRolloverHour: 4,
            adminUserEmail: 'admin@b.c',
          ),
        );
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<OperatorLocationAdminGatewayError>());
      expect(
        (thrown! as OperatorLocationAdminGatewayError).errorCode,
        equals('invalid_preferred_currency'),
      );
    });

    test('onboard rejects rollover hour outside 0-23', () async {
      final gateway = InMemoryOperatorLocationAdminGateway();
      Object? thrown;
      try {
        await gateway.onboardOperator(
          const OperatorOnboardCommand(
            businessName: 'Test',
            ownerEmail: 'a@b.c',
            subscriptionTier: 'launch',
            preferredCurrency: 'CAD',
            primaryLocationName: 'Main',
            primaryLocationTimezone: 'America/Toronto',
            primaryLocationRolloverHour: 24,
            adminUserEmail: 'admin@b.c',
          ),
        );
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<OperatorLocationAdminGatewayError>());
      expect(
        (thrown! as OperatorLocationAdminGatewayError).errorCode,
        equals('invalid_rollover_hour'),
      );
    });
  });

  group('InMemoryOperatorLocationAdminGateway — suspend / reactivate', () {
    test('suspend then reactivate flips suspended_at and back', () async {
      final gateway = InMemoryOperatorLocationAdminGateway(
        now: () => DateTime.utc(2026, 4, 29, 10),
      );
      final bundle = await gateway.onboardOperator(
        const OperatorOnboardCommand(
          businessName: 'Test',
          ownerEmail: 'a@b.c',
          subscriptionTier: 'launch',
          preferredCurrency: 'CAD',
          primaryLocationName: 'Main',
          primaryLocationTimezone: 'America/Toronto',
          primaryLocationRolloverHour: 4,
          adminUserEmail: 'admin@b.c',
        ),
      );

      final suspended = await gateway.suspendOperator(
        bundle.operator.operatorId,
      );
      expect(suspended.isSuspended, isTrue);
      expect(suspended.suspendedAt, isNotNull);

      final reactivated = await gateway.reactivateOperator(
        bundle.operator.operatorId,
      );
      expect(reactivated.isSuspended, isFalse);
      expect(reactivated.suspendedAt, isNull);
    });
  });

  group('InMemoryOperatorLocationAdminGateway — locations', () {
    Future<OperatorAdminBundle> seededOperator(
      OperatorLocationAdminGateway gateway,
    ) {
      return gateway.onboardOperator(
        const OperatorOnboardCommand(
          businessName: 'Multi Location Co',
          ownerEmail: 'owner@multi.test',
          subscriptionTier: 'launch',
          preferredCurrency: 'CAD',
          primaryLocationName: 'HQ',
          primaryLocationTimezone: 'America/Toronto',
          primaryLocationRolloverHour: 4,
          adminUserEmail: 'admin@multi.test',
        ),
      );
    }

    test(
      'addLocation accepts a second location with a different timezone',
      () async {
        final gateway = InMemoryOperatorLocationAdminGateway();
        final bundle = await seededOperator(gateway);
        final added = await gateway.addLocation(
          LocationCreateCommand(
            operatorId: bundle.operator.operatorId,
            name: 'West Coast',
            timezone: 'America/Vancouver',
            businessDayRolloverHour: 5,
          ),
        );
        expect(added.timezone, equals('America/Vancouver'));
        expect(added.businessDayRolloverHour, equals(5));

        final refreshed = (await gateway.listOperators()).single;
        expect(refreshed.locations, hasLength(2));
      },
    );

    test('addLocation rejects a malformed IANA timezone', () async {
      final gateway = InMemoryOperatorLocationAdminGateway();
      final bundle = await seededOperator(gateway);
      Object? thrown;
      try {
        await gateway.addLocation(
          LocationCreateCommand(
            operatorId: bundle.operator.operatorId,
            name: 'Test',
            timezone: 'badzone',
            businessDayRolloverHour: 4,
          ),
        );
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<OperatorLocationAdminGatewayError>());
      expect(
        (thrown! as OperatorLocationAdminGatewayError).errorCode,
        equals('invalid_timezone'),
      );
    });

    test('patchLocation updates timezone and rollover hour', () async {
      final gateway = InMemoryOperatorLocationAdminGateway();
      final bundle = await seededOperator(gateway);
      final primary = bundle.primaryLocation!;
      final patched = await gateway.patchLocation(
        LocationPatchCommand(
          locationId: primary.locationId,
          timezone: 'America/Vancouver',
          businessDayRolloverHour: 6,
        ),
      );
      expect(patched.timezone, equals('America/Vancouver'));
      expect(patched.businessDayRolloverHour, equals(6));
    });

    test('removeLocation refuses to remove primary location', () async {
      final gateway = InMemoryOperatorLocationAdminGateway();
      final bundle = await seededOperator(gateway);
      Object? thrown;
      try {
        await gateway.removeLocation(
          operatorId: bundle.operator.operatorId,
          locationId: bundle.operator.primaryLocationId!,
        );
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<OperatorLocationAdminGatewayError>());
      expect(
        (thrown! as OperatorLocationAdminGatewayError).errorCode,
        equals('cannot_remove_primary_location'),
      );
    });

    test('removeLocation removes a non-primary location', () async {
      final gateway = InMemoryOperatorLocationAdminGateway();
      final bundle = await seededOperator(gateway);
      final added = await gateway.addLocation(
        LocationCreateCommand(
          operatorId: bundle.operator.operatorId,
          name: 'West Coast',
          timezone: 'America/Vancouver',
          businessDayRolloverHour: 5,
        ),
      );
      await gateway.removeLocation(
        operatorId: bundle.operator.operatorId,
        locationId: added.locationId,
      );
      final refreshed = (await gateway.listOperators()).single;
      expect(refreshed.locations, hasLength(1));
      expect(
        refreshed.locations.single.locationId,
        equals(bundle.operator.primaryLocationId),
      );
    });
  });

  group('Command JSON payload shapes', () {
    test('OperatorOnboardCommand.toJson nests primary_location object', () {
      final command = const OperatorOnboardCommand(
        businessName: 'Cafe',
        ownerEmail: 'a@b.c',
        subscriptionTier: 'pilot',
        preferredCurrency: 'USD',
        primaryLocationName: 'Main',
        primaryLocationTimezone: 'America/Toronto',
        primaryLocationRolloverHour: 4,
        adminUserEmail: 'admin@b.c',
      );
      final json = command.toJson();
      expect(json['business_name'], equals('Cafe'));
      expect(json['preferred_currency'], equals('USD'));
      expect(json['primary_location'], isA<Map<String, Object?>>());
      final primary = (json['primary_location']! as Map)
          .cast<String, Object?>();
      expect(primary['name'], equals('Main'));
      expect(primary['timezone'], equals('America/Toronto'));
      expect(primary['business_day_rollover_hour'], equals(4));
    });

    test('OperatorPatchCommand omits unspecified fields from JSON', () {
      final command = const OperatorPatchCommand(
        operatorId: 'op-123',
        businessName: 'Renamed',
      );
      final json = command.toJson();
      expect(json.keys, equals(<String>{'business_name'}));
    });

    test('LocationPatchCommand omits unspecified fields from JSON', () {
      final command = const LocationPatchCommand(
        locationId: 'loc-1',
        timezone: 'America/Vancouver',
      );
      final json = command.toJson();
      expect(json.keys, equals(<String>{'timezone'}));
    });
  });

  group('Model fromJson round trips', () {
    test('OperatorAdminRecord round-trips through toJson/fromJson', () {
      final record = OperatorAdminRecord(
        operatorId: 'op-1',
        businessName: 'Cafe',
        ownerEmail: 'a@b.c',
        subscriptionTier: 'launch',
        preferredCurrency: 'CAD',
        primaryLocationId: 'loc-1',
        suspendedAt: DateTime.utc(2026, 4, 1),
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 4, 5),
      );
      final json = record.toJson();
      final parsed = OperatorAdminRecord.fromJson(json);
      expect(parsed.operatorId, equals(record.operatorId));
      expect(parsed.businessName, equals(record.businessName));
      expect(parsed.preferredCurrency, equals(record.preferredCurrency));
      expect(parsed.primaryLocationId, equals(record.primaryLocationId));
      expect(parsed.suspendedAt, equals(record.suspendedAt));
    });

    test('OperatorAdminBundle.fromJson reads operator + locations', () {
      final json = <String, Object?>{
        'operator': <String, Object?>{
          'operator_id': 'op-1',
          'business_name': 'Cafe',
          'owner_email': 'a@b.c',
          'subscription_tier': 'launch',
          'preferred_currency': 'CAD',
          'primary_location_id': 'loc-1',
          'suspended_at': null,
          'created_at': '2026-01-01T00:00:00.000Z',
          'updated_at': '2026-04-05T00:00:00.000Z',
        },
        'locations': <Map<String, Object?>>[
          <String, Object?>{
            'location_id': 'loc-1',
            'operator_id': 'op-1',
            'name': 'Main',
            'address': '',
            'timezone': 'America/Toronto',
            'business_day_rollover_hour': 4,
            'created_at': '2026-01-01T00:00:00.000Z',
            'updated_at': '2026-01-01T00:00:00.000Z',
          },
        ],
      };
      final bundle = OperatorAdminBundle.fromJson(json);
      expect(bundle.operator.businessName, equals('Cafe'));
      expect(bundle.locations, hasLength(1));
      expect(bundle.primaryLocation?.timezone, equals('America/Toronto'));
    });
  });
}
