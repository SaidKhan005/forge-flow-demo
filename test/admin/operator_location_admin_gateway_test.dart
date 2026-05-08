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

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/admin/models/operator_location_admin_models.dart';
import 'package:forge_and_flow/admin/services/operator_location_admin_gateway.dart';
import 'package:http/http.dart' as http;

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
            idempotencyKey: 'k-onboard-1',
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
              idempotencyKey: 'k-onboard-tz',
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
            idempotencyKey: 'k-onboard-currency',
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
            idempotencyKey: 'k-onboard-rollover',
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
          idempotencyKey: 'k-onboard-suspend-test',
        ),
      );

      final suspended = await gateway.suspendOperator(
        bundle.operator.operatorId,
        idempotencyKey: 'k-suspend-1',
      );
      expect(suspended.isSuspended, isTrue);
      expect(suspended.suspendedAt, isNotNull);

      final reactivated = await gateway.reactivateOperator(
        bundle.operator.operatorId,
        idempotencyKey: 'k-reactivate-1',
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
          idempotencyKey: 'k-onboard-multi',
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
            parentOrgUnitId: 'org-unit-west',
            name: 'West Coast',
            timezone: 'America/Vancouver',
            businessDayRolloverHour: 5,
            idempotencyKey: 'k-add-loc-1',
          ),
        );
        expect(added.timezone, equals('America/Vancouver'));
        expect(added.parentOrgUnitId, equals('org-unit-west'));
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
            parentOrgUnitId: 'org-unit-test',
            name: 'Test',
            timezone: 'badzone',
            businessDayRolloverHour: 4,
            idempotencyKey: 'k-add-loc-bad',
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

    test('addLocation requires a selected parent org unit', () async {
      final gateway = InMemoryOperatorLocationAdminGateway();
      final bundle = await seededOperator(gateway);
      Object? thrown;
      try {
        await gateway.addLocation(
          LocationCreateCommand(
            operatorId: bundle.operator.operatorId,
            name: 'No Parent',
            timezone: 'America/Toronto',
            businessDayRolloverHour: 4,
            idempotencyKey: 'k-add-loc-no-parent',
          ),
        );
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<OperatorLocationAdminGatewayError>());
      expect(
        (thrown! as OperatorLocationAdminGatewayError).errorCode,
        equals('missing_parent_org_unit_id'),
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
          idempotencyKey: 'k-patch-loc-1',
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
          idempotencyKey: 'k-remove-primary',
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
          parentOrgUnitId: 'org-unit-west',
          name: 'West Coast',
          timezone: 'America/Vancouver',
          businessDayRolloverHour: 5,
          idempotencyKey: 'k-add-loc-remove-test',
        ),
      );
      await gateway.removeLocation(
        operatorId: bundle.operator.operatorId,
        locationId: added.locationId,
        idempotencyKey: 'k-remove-loc-1',
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
        idempotencyKey: 'k-json-onboard',
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
      // idempotency_key MUST stay out of body; it's a header-only
      // value so the proxy hashes a stable canonical body.
      expect(json.containsKey('idempotency_key'), isFalse);
    });

    test('OperatorPatchCommand omits unspecified fields from JSON', () {
      final command = const OperatorPatchCommand(
        operatorId: 'op-123',
        businessName: 'Renamed',
        idempotencyKey: 'k-json-patch',
      );
      final json = command.toJson();
      expect(json.keys, equals(<String>{'business_name'}));
    });

    test('LocationPatchCommand omits unspecified fields from JSON', () {
      final command = const LocationPatchCommand(
        locationId: 'loc-1',
        timezone: 'America/Vancouver',
        idempotencyKey: 'k-json-patch-loc',
      );
      final json = command.toJson();
      expect(json.keys, equals(<String>{'timezone'}));
    });

    test('LocationCreateCommand serializes parent_org_unit_id', () {
      final command = const LocationCreateCommand(
        operatorId: 'op-123',
        parentOrgUnitId: 'org-unit-east',
        name: 'East',
        timezone: 'America/Toronto',
        businessDayRolloverHour: 4,
        idempotencyKey: 'k-json-create-loc',
      );
      final json = command.toJson();
      expect(json['parent_org_unit_id'], equals('org-unit-east'));
      expect(json.containsKey('idempotency_key'), isFalse);
    });
  });

  // HARD-H — admin idempotency parcel. Mirrors the envelope cases in
  // `docs/contracts/hardening_feature_flag_idempotency_contract.md`
  // §"Test Surface", applied to the operator/location admin
  // surfaces. The InMemory gateway caches per-key like the proxy
  // does against `admin_request_idempotency`.
  group('InMemoryOperatorLocationAdminGateway — idempotency replay', () {
    test('second onboardOperator with same key returns cached bundle '
        'without creating a duplicate', () async {
      final gateway = InMemoryOperatorLocationAdminGateway();
      final command = const OperatorOnboardCommand(
        businessName: 'Idem Cafe',
        ownerEmail: 'a@b.c',
        subscriptionTier: 'launch',
        preferredCurrency: 'CAD',
        primaryLocationName: 'Main',
        primaryLocationTimezone: 'America/Toronto',
        primaryLocationRolloverHour: 4,
        adminUserEmail: 'admin@b.c',
        idempotencyKey: 'idem-onboard',
      );
      final first = await gateway.onboardOperator(command);
      final second = await gateway.onboardOperator(command);
      // Cached replay returns the same operator_id — not a fresh
      // one — so the in-memory ledger holds exactly one operator.
      expect(second.operator.operatorId, equals(first.operator.operatorId));
      final list = await gateway.listOperators();
      expect(list, hasLength(1));
    });

    test('second patchOperator with same key returns cached record', () async {
      final gateway = InMemoryOperatorLocationAdminGateway(
        now: () => DateTime.utc(2026, 5, 2, 12),
      );
      final bundle = await gateway.onboardOperator(
        const OperatorOnboardCommand(
          businessName: 'Original',
          ownerEmail: 'a@b.c',
          subscriptionTier: 'launch',
          preferredCurrency: 'CAD',
          primaryLocationName: 'Main',
          primaryLocationTimezone: 'America/Toronto',
          primaryLocationRolloverHour: 4,
          adminUserEmail: 'admin@b.c',
          idempotencyKey: 'idem-onboard-patch',
        ),
      );
      final patch = OperatorPatchCommand(
        operatorId: bundle.operator.operatorId,
        businessName: 'Renamed',
        idempotencyKey: 'idem-patch',
      );
      final first = await gateway.patchOperator(patch);
      // A retry that flips the businessName under the SAME key
      // would be a payload mismatch at the proxy. The in-memory
      // demo gateway returns the cached result regardless, so the
      // second call sees 'Renamed' (the first call's outcome) even
      // though the second call would have stamped something else.
      final second = await gateway.patchOperator(
        OperatorPatchCommand(
          operatorId: bundle.operator.operatorId,
          businessName: 'Different Name',
          idempotencyKey: 'idem-patch',
        ),
      );
      expect(first.businessName, equals('Renamed'));
      expect(second.businessName, equals('Renamed'));
    });

    test(
      'second suspendOperator with same key returns cached record',
      () async {
        final gateway = InMemoryOperatorLocationAdminGateway();
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
            idempotencyKey: 'idem-onboard-suspend',
          ),
        );
        final first = await gateway.suspendOperator(
          bundle.operator.operatorId,
          idempotencyKey: 'idem-suspend',
        );
        final second = await gateway.suspendOperator(
          bundle.operator.operatorId,
          idempotencyKey: 'idem-suspend',
        );
        expect(first.suspendedAt, equals(second.suspendedAt));
      },
    );

    test(
      'second removeLocation with same key is a no-op (cached void)',
      () async {
        final gateway = InMemoryOperatorLocationAdminGateway();
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
            idempotencyKey: 'idem-onboard-remove',
          ),
        );
        final added = await gateway.addLocation(
          LocationCreateCommand(
            operatorId: bundle.operator.operatorId,
            parentOrgUnitId: 'org-unit-branch',
            name: 'Branch',
            timezone: 'America/Vancouver',
            businessDayRolloverHour: 5,
            idempotencyKey: 'idem-add-loc',
          ),
        );
        await gateway.removeLocation(
          operatorId: bundle.operator.operatorId,
          locationId: added.locationId,
          idempotencyKey: 'idem-remove',
        );
        // Replay does not throw and does not re-attempt the delete.
        await gateway.removeLocation(
          operatorId: bundle.operator.operatorId,
          locationId: added.locationId,
          idempotencyKey: 'idem-remove',
        );
        final list = await gateway.listOperators();
        expect(list.single.locations, hasLength(1));
      },
    );
  });

  // HARD-H — Http variant sends the Idempotency-Key header on
  // mutating commands and threads the gateway-supplied key through
  // request headers without leaking it into the body. This pins the
  // wire shape the proxy's `admin_request_idempotency` lookup
  // relies on.
  group('HttpOperatorLocationAdminGateway — Idempotency-Key wiring', () {
    test('onboardOperator sends Idempotency-Key header and keeps key out '
        'of the JSON body', () async {
      final captured = <_CapturedAdminRequest>[];
      final client = _SingleResponseClient(
        captured: captured,
        response: _HttpFixture(
          statusCode: 201,
          body: <String, Object?>{
            'operator': <String, Object?>{
              'operator_id': 'op-new',
              'business_name': 'Cafe',
              'owner_email': 'a@b.c',
              'subscription_tier': 'launch',
              'preferred_currency': 'CAD',
              'primary_location_id': 'loc-new',
              'suspended_at': null,
              'created_at': '2026-05-02T12:00:00.000Z',
              'updated_at': '2026-05-02T12:00:00.000Z',
            },
            'locations': <Map<String, Object?>>[
              <String, Object?>{
                'location_id': 'loc-new',
                'operator_id': 'op-new',
                'name': 'Main',
                'address': '',
                'timezone': 'America/Toronto',
                'business_day_rollover_hour': 4,
                'created_at': '2026-05-02T12:00:00.000Z',
                'updated_at': '2026-05-02T12:00:00.000Z',
              },
            ],
          },
        ),
      );
      final gateway = HttpOperatorLocationAdminGateway(
        baseUri: Uri.parse('https://proxy.example.com'),
        bearerTokenProvider: () async => 'fake.token',
        httpClient: client,
      );
      await gateway.onboardOperator(
        const OperatorOnboardCommand(
          businessName: 'Cafe',
          ownerEmail: 'a@b.c',
          subscriptionTier: 'launch',
          preferredCurrency: 'CAD',
          primaryLocationName: 'Main',
          primaryLocationTimezone: 'America/Toronto',
          primaryLocationRolloverHour: 4,
          adminUserEmail: 'admin@b.c',
          idempotencyKey: 'idem-http-onboard',
        ),
      );
      expect(captured, hasLength(1));
      final req = captured.single;
      expect(req.method, equals('POST'));
      expect(req.uri.path, equals('/v1/admin/operators'));
      expect(
        req.headers['idempotency-key'] ?? req.headers['Idempotency-Key'],
        equals('idem-http-onboard'),
      );
      expect(req.body.containsKey('idempotency_key'), isFalse);
    });

    test(
      'suspendOperator forwards the gateway idempotencyKey as a header',
      () async {
        final captured = <_CapturedAdminRequest>[];
        final client = _SingleResponseClient(
          captured: captured,
          response: _HttpFixture(
            statusCode: 200,
            body: <String, Object?>{
              'operator': <String, Object?>{
                'operator_id': 'op-1',
                'business_name': 'Cafe',
                'owner_email': 'a@b.c',
                'subscription_tier': 'launch',
                'preferred_currency': 'CAD',
                'primary_location_id': 'loc-1',
                'suspended_at': '2026-05-02T12:00:00.000Z',
                'created_at': '2026-05-01T00:00:00.000Z',
                'updated_at': '2026-05-02T12:00:00.000Z',
              },
            },
          ),
        );
        final gateway = HttpOperatorLocationAdminGateway(
          baseUri: Uri.parse('https://proxy.example.com'),
          bearerTokenProvider: () async => 'fake.token',
          httpClient: client,
        );
        await gateway.suspendOperator(
          'op-1',
          idempotencyKey: 'idem-http-suspend',
        );
        final req = captured.single;
        expect(req.method, equals('POST'));
        expect(req.uri.path, equals('/v1/admin/operators/op-1/suspend'));
        expect(
          req.headers['idempotency-key'] ?? req.headers['Idempotency-Key'],
          equals('idem-http-suspend'),
        );
      },
    );

    test(
      'addLocation sends parent_org_unit_id with the create request',
      () async {
        final captured = <_CapturedAdminRequest>[];
        final client = _SingleResponseClient(
          captured: captured,
          response: _HttpFixture(
            statusCode: 201,
            body: <String, Object?>{
              'location': <String, Object?>{
                'location_id': 'loc-new',
                'operator_id': 'op-1',
                'parent_org_unit_id': 'org-unit-east',
                'name': 'East',
                'address': '',
                'timezone': 'America/Toronto',
                'business_day_rollover_hour': 4,
                'created_at': '2026-05-02T12:00:00.000Z',
                'updated_at': '2026-05-02T12:00:00.000Z',
              },
            },
          ),
        );
        final gateway = HttpOperatorLocationAdminGateway(
          baseUri: Uri.parse('https://proxy.example.com'),
          bearerTokenProvider: () async => 'fake.token',
          httpClient: client,
        );
        final added = await gateway.addLocation(
          const LocationCreateCommand(
            operatorId: 'op-1',
            parentOrgUnitId: 'org-unit-east',
            name: 'East',
            timezone: 'America/Toronto',
            businessDayRolloverHour: 4,
            idempotencyKey: 'idem-http-add-location',
          ),
        );
        expect(added.parentOrgUnitId, equals('org-unit-east'));
        final req = captured.single;
        expect(req.method, equals('POST'));
        expect(req.uri.path, equals('/v1/admin/locations'));
        expect(req.body['parent_org_unit_id'], equals('org-unit-east'));
        expect(
          req.headers['idempotency-key'] ?? req.headers['Idempotency-Key'],
          equals('idem-http-add-location'),
        );
      },
    );
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
            'parent_org_unit_id': 'org-unit-root',
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
      expect(bundle.locations.single.parentOrgUnitId, equals('org-unit-root'));
      expect(bundle.primaryLocation?.timezone, equals('America/Toronto'));
    });
  });
}

// ─── Test helpers ─────────────────────────────────────────────────

class _CapturedAdminRequest {
  _CapturedAdminRequest({
    required this.method,
    required this.uri,
    required this.headers,
    required this.body,
  });
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final Map<String, Object?> body;
}

class _HttpFixture {
  _HttpFixture({required this.statusCode, required this.body});
  final int statusCode;
  final Map<String, Object?> body;
}

/// Minimal `http.Client` impl that captures every outgoing request and
/// replays a single canned response. Mirrors the harness shape from
/// `test/proxy/anthropic_http_complete_fn_test.dart` so the gateway's
/// `Idempotency-Key` header threading can be asserted without spinning
/// up a real `HttpServer`.
class _SingleResponseClient extends http.BaseClient {
  _SingleResponseClient({required this.captured, required this.response});

  final List<_CapturedAdminRequest> captured;
  final _HttpFixture response;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bodyBytes = await request.finalize().toBytes();
    Map<String, Object?> body = const <String, Object?>{};
    if (bodyBytes.isNotEmpty) {
      final decoded = jsonDecode(utf8.decode(bodyBytes));
      if (decoded is Map) body = decoded.cast<String, Object?>();
    }
    captured.add(
      _CapturedAdminRequest(
        method: request.method,
        uri: request.url,
        headers: Map<String, String>.from(request.headers),
        body: body,
      ),
    );
    final encoded = utf8.encode(jsonEncode(response.body));
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(<List<int>>[encoded]),
      response.statusCode,
      contentLength: encoded.length,
      headers: const <String, String>{'content-type': 'application/json'},
    );
  }
}
