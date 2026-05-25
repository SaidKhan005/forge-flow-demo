// Phase 8 spine-bridge .C live proxy route coverage.
//
// These tests pin the Data Accuracy / Polling & Pricing admin route
// family to the same fail-closed and read/write role posture used by
// the rest of the F&F operations console.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

void main() {
  group('Data Accuracy admin proxy routes', () {
    Future<T> withRealHttp<T>(Future<T> Function() body) async {
      final saved = HttpOverrides.current;
      HttpOverrides.global = null;
      try {
        return await body();
      } finally {
        HttpOverrides.global = saved;
      }
    }

    Future<
      ({
        HttpServer server,
        HttpClient client,
        Uri baseUri,
        _SettableVerifier verifier,
        _FakeDataAccuracyAdminGateway gateway,
        _FakeAdminRequestIdempotencyStore idempotencyStore,
      })
    >
    spinUp({
      ProxyJwtClaims? initialClaims,
      _FakeDataAccuracyAdminGateway? customGateway,
      bool gatewayConfigured = true,
    }) async {
      final verifier = _SettableVerifier();
      verifier.claims =
          initialClaims ??
          const ProxyJwtClaims(
            userId: 'user_admin',
            operatorId: null,
            locationId: null,
            roles: <String>['super_admin'],
          );
      final guard = ProxyRequestGuard(verifier: verifier);
      final gateway = customGateway ?? _FakeDataAccuracyAdminGateway();
      final idempotencyStore = _FakeAdminRequestIdempotencyStore();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // ignore: unawaited_futures
      server.listen((request) async {
        try {
          await routeRequest(
            request,
            guard,
            dataAccuracyAdminGateway: gatewayConfigured ? gateway : null,
            adminRequestIdempotencyStore: idempotencyStore,
            adminCorsAllowList: const <String>['https://admin.forgeflow.app'],
          );
        } catch (_) {
          try {
            request.response.statusCode = 500;
            await request.response.close();
          } catch (_) {}
        }
      });
      final client = HttpClient();
      final baseUri = Uri.parse('http://${server.address.host}:${server.port}');
      return (
        server: server,
        client: client,
        baseUri: baseUri,
        verifier: verifier,
        gateway: gateway,
        idempotencyStore: idempotencyStore,
      );
    }

    test('GET rows returns 503 when gateway is not configured', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(gatewayConfigured: false);
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(adminDataAccuracyRowsPath),
          );
          expect(response.statusCode, equals(503));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('data_accuracy_admin_not_configured'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('GET rows admits ff_support read-only callers', () async {
      await withRealHttp(() async {
        final gateway = _FakeDataAccuracyAdminGateway();
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: const ProxyJwtClaims(
            userId: 'user_support',
            operatorId: null,
            locationId: null,
            roles: <String>['ff_support'],
          ),
        );
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(adminDataAccuracyRowsPath),
          );
          expect(response.statusCode, equals(200));
          expect(gateway.lastActorUserId, equals('user_support'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'GET selected data accuracy row uses single-row admin helper',
      () async {
        await withRealHttp(() async {
          final gateway = _FakeDataAccuracyAdminGateway();
          final ctx = await spinUp(customGateway: gateway);
          try {
            final response = await _httpGet(
              ctx.client,
              ctx.baseUri.resolve(
                '${adminDataAccuracySettingsPrefix}op-1/loc-1',
              ),
            );
            expect(response.statusCode, equals(200));
            expect(gateway.loadDataAccuracyRowCalls, equals(1));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            final row = body['row'] as Map<String, Object?>;
            expect(row['operator_id'], equals('op-1'));
            expect(row['location_id'], equals('loc-1'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('PUT assignment rejects ff_support write callers', () async {
      await withRealHttp(() async {
        final gateway = _FakeDataAccuracyAdminGateway();
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: const ProxyJwtClaims(
            userId: 'user_support',
            operatorId: null,
            locationId: null,
            roles: <String>['ff_support'],
          ),
        );
        try {
          final response = await _httpJson(
            ctx.client,
            'PUT',
            ctx.baseUri.resolve(
              '${adminPollingPricingAssignmentsPrefix}op-1/loc-1',
            ),
            body: const <String, Object?>{'tier_key': 'premium'},
          );
          expect(response.statusCode, equals(403));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('permission_denied'));
          expect(body['required_roles'], contains('super_admin'));
          expect(body['required_roles'], isNot(contains('ff_support')));
          expect(gateway.assignTierCalls, equals(0));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'PUT scoped data accuracy writes through selected hierarchy scope',
      () async {
        await withRealHttp(() async {
          final gateway = _FakeDataAccuracyAdminGateway();
          final ctx = await spinUp(customGateway: gateway);
          try {
            final response = await _httpJson(
              ctx.client,
              'PUT',
              ctx.baseUri.resolve(adminDataAccuracyScopedSettingsPath),
              body: const <String, Object?>{
                'operator_id': 'op-1',
                'scope_type': 'org_unit',
                'org_unit_id': 'ou-1',
                'covers_source_per_service_period': <String, Object?>{
                  'breakfast': 'forecast',
                  'lunch': 'vendor',
                },
                'reason_note': 'Set lunch source for the region',
              },
              idempotencyKey: 'data-accuracy-scope-1',
            );
            expect(response.statusCode, equals(200));
            expect(gateway.scopeOverrideCalls, equals(1));
            expect(gateway.lastScopeType, equals('org_unit'));
            expect(
              gateway.lastCoversSourcePerServicePeriod,
              equals(<String, String>{
                'breakfast': 'forecast',
                'lunch': 'vendor',
              }),
            );
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['affected_location_count'], equals(0));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('PUT scoped data accuracy passes explicit clear fields', () async {
      await withRealHttp(() async {
        final gateway = _FakeDataAccuracyAdminGateway();
        final ctx = await spinUp(customGateway: gateway);
        try {
          final response = await _httpJson(
            ctx.client,
            'PUT',
            ctx.baseUri.resolve(adminDataAccuracyScopedSettingsPath),
            body: const <String, Object?>{
              'operator_id': 'op-1',
              'scope_type': 'location',
              'location_id': 'loc-1',
              'clear_covers_source_per_service_period': <String>['breakfast'],
              'clear_wage_source': true,
              'clear_walk_in_handling_mode': true,
              'reason_note': 'Let this location inherit data accuracy',
            },
            idempotencyKey: 'data-accuracy-scope-clear-1',
          );
          expect(response.statusCode, equals(200));
          expect(gateway.scopeOverrideCalls, equals(1));
          expect(gateway.lastScopeType, equals('location'));
          expect(
            gateway.lastClearCoversSourcePerServicePeriod,
            equals(<String>['breakfast']),
          );
          expect(gateway.lastClearWageSource, isTrue);
          expect(gateway.lastClearWalkInHandlingMode, isTrue);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'PATCH data accuracy passes keyed covers map to admin gateway',
      () async {
        await withRealHttp(() async {
          final gateway = _FakeDataAccuracyAdminGateway();
          final ctx = await spinUp(customGateway: gateway);
          try {
            final response = await _httpJson(
              ctx.client,
              'PATCH',
              ctx.baseUri.resolve(
                '${adminDataAccuracySettingsPrefix}op-1/loc-1',
              ),
              body: const <String, Object?>{
                'covers_source_per_service_period': <String, Object?>{
                  'breakfast': 'forecast',
                  'lunch': 'vendor',
                },
                'reason_note': 'Set breakfast source for launch',
              },
              idempotencyKey: 'data-accuracy-settings-1',
            );
            expect(response.statusCode, equals(200));
            expect(
              gateway.lastCoversSourcePerServicePeriod,
              equals(<String, String>{
                'breakfast': 'forecast',
                'lunch': 'vendor',
              }),
            );
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('PATCH full settings uses settings-save helper', () async {
      await withRealHttp(() async {
        final gateway = _FakeDataAccuracyAdminGateway();
        final ctx = await spinUp(customGateway: gateway);
        try {
          final response = await _httpJson(
            ctx.client,
            'PATCH',
            ctx.baseUri.resolve('${adminDataAccuracySettingsPrefix}op-1/loc-1'),
            body: const <String, Object?>{
              'covers_source_per_service_period': <String, Object?>{
                'breakfast': 'manual',
              },
              'covers_manual_entries': <String, Object?>{
                '2026-06-02': <String, Object?>{'breakfast': 12},
              },
              'wage_source': 'manual_mix',
              'walk_in_handling_mode': 'walk_ins_tracked_separately',
              'walk_in_manual_entries': <String, Object?>{
                '2026-06-02|breakfast': 7,
              },
              'reason_note': 'Save the selected row',
            },
            idempotencyKey: 'data-accuracy-settings-full-1',
          );
          expect(response.statusCode, equals(200));
          expect(gateway.settingsSaveCalls, equals(1));
          expect(gateway.settingsOverrideCalls, equals(0));
          expect(
            gateway.lastCoversManualEntries,
            equals(<String, Map<String, int>>{
              '2026-06-02': <String, int>{'breakfast': 12},
            }),
          );
          expect(
            gateway.lastWalkInManualEntries,
            equals(<String, int>{'2026-06-02|breakfast': 7}),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('PATCH data accuracy requires Idempotency-Key', () async {
      await withRealHttp(() async {
        final gateway = _FakeDataAccuracyAdminGateway();
        final ctx = await spinUp(customGateway: gateway);
        try {
          final response = await _httpJson(
            ctx.client,
            'PATCH',
            ctx.baseUri.resolve('${adminDataAccuracySettingsPrefix}op-1/loc-1'),
            body: const <String, Object?>{
              'covers_source_per_service_period': <String, Object?>{
                'lunch': 'manual',
              },
              'reason_note': 'Set lunch source for launch',
            },
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('idempotency_key_missing'));
          expect(gateway.settingsOverrideCalls, equals(0));
          expect(ctx.idempotencyStore.reserveCalls, equals(0));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'PATCH data accuracy replays same key and rejects conflicting body',
      () async {
        await withRealHttp(() async {
          final gateway = _FakeDataAccuracyAdminGateway();
          final ctx = await spinUp(customGateway: gateway);
          try {
            final uri = ctx.baseUri.resolve(
              '${adminDataAccuracySettingsPrefix}op-1/loc-1',
            );
            const firstBody = <String, Object?>{
              'covers_source_per_service_period': <String, Object?>{
                'lunch': 'manual',
              },
              'reason_note': 'Set lunch source for launch',
            };
            final first = await _httpJson(
              ctx.client,
              'PATCH',
              uri,
              body: firstBody,
              idempotencyKey: 'data-accuracy-replay-key',
            );
            final replay = await _httpJson(
              ctx.client,
              'PATCH',
              uri,
              body: firstBody,
              idempotencyKey: 'data-accuracy-replay-key',
            );
            final conflict = await _httpJson(
              ctx.client,
              'PATCH',
              uri,
              body: const <String, Object?>{
                'covers_source_per_service_period': <String, Object?>{
                  'lunch': 'forecast',
                },
                'reason_note': 'Different write under same key',
              },
              idempotencyKey: 'data-accuracy-replay-key',
            );

            expect(first.statusCode, equals(200));
            expect(replay.statusCode, equals(200));
            expect(jsonDecode(replay.body), equals(jsonDecode(first.body)));
            expect(conflict.statusCode, equals(409));
            final conflictBody =
                jsonDecode(conflict.body) as Map<String, Object?>;
            expect(conflictBody['error'], equals('idempotency_key_conflict'));
            expect(gateway.settingsOverrideCalls, equals(1));
            expect(ctx.idempotencyStore.reserveCalls, equals(1));
            expect(ctx.idempotencyStore.reserveActorUserIds, <String?>[
              'user_admin',
            ]);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'PATCH data accuracy rejects legacy covers-source write keys',
      () async {
        await withRealHttp(() async {
          final gateway = _FakeDataAccuracyAdminGateway();
          final ctx = await spinUp(customGateway: gateway);
          try {
            final response = await _httpJson(
              ctx.client,
              'PATCH',
              ctx.baseUri.resolve(
                '${adminDataAccuracySettingsPrefix}op-1/loc-1',
              ),
              body: const <String, Object?>{
                'covers_source_lunch': 'manual',
                'reason_note': 'Old client write',
              },
              idempotencyKey: 'data-accuracy-legacy-key',
            );
            expect(response.statusCode, equals(410));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(
              body['error'],
              equals('legacy_covers_source_write_keys_disabled'),
            );
            expect(gateway.settingsOverrideCalls, equals(0));
            expect(ctx.idempotencyStore.reserveCalls, equals(0));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'PATCH manual covers saves and clears through admin helpers',
      () async {
        await withRealHttp(() async {
          final gateway = _FakeDataAccuracyAdminGateway();
          final ctx = await spinUp(customGateway: gateway);
          try {
            final uri = ctx.baseUri.resolve(
              '${adminDataAccuracySettingsPrefix}op-1/loc-1/manual-covers',
            );
            final save = await _httpJson(
              ctx.client,
              'PATCH',
              uri,
              body: const <String, Object?>{
                'business_date': '2026-06-02',
                'service_period_key': 'breakfast',
                'covers': 18,
                'reason_note': 'Set breakfast covers',
              },
              idempotencyKey: 'data-accuracy-manual-covers-save-1',
            );
            final clear = await _httpJson(
              ctx.client,
              'PATCH',
              uri,
              body: const <String, Object?>{
                'business_date': '2026-06-02',
                'service_period_key': 'breakfast',
                'clear': true,
                'reason_note': 'Clear breakfast covers',
              },
              idempotencyKey: 'data-accuracy-manual-covers-clear-1',
            );
            expect(save.statusCode, equals(200));
            expect(clear.statusCode, equals(200));
            expect(gateway.manualCoversSaveCalls, equals(1));
            expect(gateway.manualCoversClearCalls, equals(1));
            expect(gateway.lastBusinessDate, equals('2026-06-02'));
            expect(gateway.lastServicePeriodKey, equals('breakfast'));
            expect(gateway.lastCovers, equals(18));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('GET service-period settings reads keyed admin rows', () async {
      await withRealHttp(() async {
        final gateway = _FakeDataAccuracyAdminGateway();
        final ctx = await spinUp(customGateway: gateway);
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              '$adminDataAccuracyServicePeriodSettingsPrefix'
              'op-1/loc-1',
            ),
          );
          expect(response.statusCode, equals(200));
          expect(gateway.servicePeriodListCalls, equals(1));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          final rows =
              body['data_accuracy_service_period_settings'] as List<Object?>;
          expect(rows, hasLength(1));
          final row = rows.single as Map<String, Object?>;
          expect(row['service_period_key'], equals('breakfast'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('PATCH service-period settings writes keyed admin row', () async {
      await withRealHttp(() async {
        final gateway = _FakeDataAccuracyAdminGateway();
        final ctx = await spinUp(customGateway: gateway);
        try {
          final response = await _httpJson(
            ctx.client,
            'PATCH',
            ctx.baseUri.resolve(
              '$adminDataAccuracyServicePeriodSettingsPrefix'
              'op-1/loc-1',
            ),
            body: const <String, Object?>{
              'service_period_key': 'breakfast',
              'covers_source': 'manual',
              'wage_source': 'target_substitution',
              'effective_at_business_date': '2026-06-01',
              'reason_note': 'Breakfast is now manual for launch week',
            },
            idempotencyKey: 'data-accuracy-service-period-1',
          );
          expect(response.statusCode, equals(200));
          expect(gateway.servicePeriodOverrideCalls, equals(1));
          expect(gateway.lastServicePeriodKey, equals('breakfast'));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          final row = body['data'] as Map<String, Object?>;
          expect(row['covers_source'], equals('manual'));
          expect(row['wage_source'], equals('target_substitution'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('PATCH service-period settings clears keyed admin rows', () async {
      await withRealHttp(() async {
        final gateway = _FakeDataAccuracyAdminGateway();
        final ctx = await spinUp(customGateway: gateway);
        try {
          final response = await _httpJson(
            ctx.client,
            'PATCH',
            ctx.baseUri.resolve(
              '$adminDataAccuracyServicePeriodSettingsPrefix'
              'op-1/loc-1',
            ),
            body: const <String, Object?>{
              'service_period_key': 'breakfast',
              'clear': true,
              'reason_note': 'Remove breakfast override',
            },
            idempotencyKey: 'data-accuracy-service-period-clear-1',
          );
          expect(response.statusCode, equals(200));
          expect(gateway.servicePeriodClearCalls, equals(1));
          expect(gateway.servicePeriodOverrideCalls, equals(0));
          expect(gateway.lastServicePeriodKey, equals('breakfast'));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['cleared_count'], equals(1));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('PATCH service-period settings rejects ff_support callers', () async {
      await withRealHttp(() async {
        final gateway = _FakeDataAccuracyAdminGateway();
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: const ProxyJwtClaims(
            userId: 'user_support',
            operatorId: null,
            locationId: null,
            roles: <String>['ff_support'],
          ),
        );
        try {
          final response = await _httpJson(
            ctx.client,
            'PATCH',
            ctx.baseUri.resolve(
              '$adminDataAccuracyServicePeriodSettingsPrefix'
              'op-1/loc-1',
            ),
            body: const <String, Object?>{
              'service_period_key': 'breakfast',
              'covers_source': 'manual',
              'wage_source': 'target_substitution',
              'effective_at_business_date': '2026-06-01',
              'reason_note': 'support cannot write',
            },
          );
          expect(response.statusCode, equals(403));
          expect(gateway.servicePeriodOverrideCalls, equals(0));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'PUT scoped polling assignment writes through selected hierarchy scope',
      () async {
        await withRealHttp(() async {
          final gateway = _FakeDataAccuracyAdminGateway();
          final ctx = await spinUp(customGateway: gateway);
          try {
            final response = await _httpJson(
              ctx.client,
              'PUT',
              ctx.baseUri.resolve(adminPollingPricingScopedAssignmentsPath),
              body: const <String, Object?>{
                'operator_id': 'op-1',
                'scope_type': 'business',
                'tier_key': 'premium',
                'reason_note': 'Move the business to premium polling',
              },
              idempotencyKey: 'polling-pricing-scope-1',
            );
            expect(response.statusCode, equals(200));
            expect(gateway.scopeAssignCalls, equals(1));
            expect(gateway.lastScopeType, equals('business'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'GET selected polling assignment uses single-assignment helper',
      () async {
        await withRealHttp(() async {
          final gateway = _FakeDataAccuracyAdminGateway();
          final ctx = await spinUp(customGateway: gateway);
          try {
            final response = await _httpGet(
              ctx.client,
              ctx.baseUri.resolve(
                '${adminPollingPricingAssignmentsPrefix}op-1/loc-1',
              ),
            );
            expect(response.statusCode, equals(200));
            expect(gateway.loadTierAssignmentCalls, equals(1));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            final assignment = body['assignment'] as Map<String, Object?>;
            expect(assignment['tier_key'], equals('premium'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('CORS preflight allows polling-pricing write methods', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final request = await ctx.client.openUrl(
            'OPTIONS',
            ctx.baseUri.resolve(adminPollingPricingMarginExportPath),
          );
          request.headers.set('Origin', 'https://admin.forgeflow.app');
          request.headers.set('Access-Control-Request-Method', 'POST');
          request.headers.set(
            'Access-Control-Request-Headers',
            'Authorization, Content-Type, Idempotency-Key',
          );
          final raw = await request.close();
          await utf8.decodeStream(raw);
          expect(raw.statusCode, equals(204));
          expect(
            raw.headers.value('access-control-allow-methods'),
            contains('POST'),
          );
          expect(
            raw.headers.value('access-control-allow-headers'),
            contains('Idempotency-Key'),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });
}

class _SettableVerifier implements ProxyJwtVerifier {
  ProxyJwtClaims? claims;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    final current = claims;
    if (current == null) {
      throw ProxyJwtVerificationError('missing test claims');
    }
    return current;
  }
}

class _FakeDataAccuracyAdminGateway implements DataAccuracyAdminProxyGateway {
  String? lastActorUserId;
  String? lastScopeType;
  String? lastServicePeriodKey;
  String? lastBusinessDate;
  int? lastCovers;
  Map<String, String>? lastCoversSourcePerServicePeriod;
  Map<String, Map<String, int>>? lastCoversManualEntries;
  Map<String, int>? lastWalkInManualEntries;
  List<String>? lastClearCoversSourcePerServicePeriod;
  bool lastClearWageSource = false;
  bool lastClearWalkInHandlingMode = false;
  int loadDataAccuracyRowCalls = 0;
  int assignTierCalls = 0;
  int loadTierAssignmentCalls = 0;
  int settingsSaveCalls = 0;
  int settingsOverrideCalls = 0;
  int manualCoversSaveCalls = 0;
  int manualCoversClearCalls = 0;
  int scopeOverrideCalls = 0;
  int scopeAssignCalls = 0;
  int servicePeriodListCalls = 0;
  int servicePeriodOverrideCalls = 0;
  int servicePeriodClearCalls = 0;

  @override
  Future<List<Map<String, Object?>>> listDataAccuracyRows({
    required String actorUserId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    return const <Map<String, Object?>>[];
  }

  @override
  Future<Map<String, Object?>?> loadDataAccuracyRow({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    loadDataAccuracyRowCalls += 1;
    return _dataAccuracyRow(operatorId: operatorId, locationId: locationId);
  }

  @override
  Future<List<Map<String, Object?>>> listAuditHistory({
    required String actorUserId,
    String? operatorId,
    String? locationId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    return const <Map<String, Object?>>[];
  }

  @override
  Future<Map<String, Object?>?> overrideDataAccuracy({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    Map<String, String>? coversSourcePerServicePeriod,
    String? wageSource,
    String? walkInHandlingMode,
    String? reasonNote,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastCoversSourcePerServicePeriod = coversSourcePerServicePeriod;
    settingsOverrideCalls += 1;
    return const <String, Object?>{'ok': true};
  }

  @override
  Future<Map<String, Object?>?> saveDataAccuracySettings({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    Map<String, String>? coversSourcePerServicePeriod,
    Map<String, Map<String, int>> coversManualEntries =
        const <String, Map<String, int>>{},
    String? wageSource,
    String? walkInHandlingMode,
    Map<String, int> walkInManualEntries = const <String, int>{},
    String? reasonNote,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastCoversSourcePerServicePeriod = coversSourcePerServicePeriod;
    lastCoversManualEntries = coversManualEntries;
    lastWalkInManualEntries = walkInManualEntries;
    settingsSaveCalls += 1;
    return <String, Object?>{
      'operator_ref': <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
      },
      'settings': _settingsRow(
        operatorId: operatorId,
        locationId: locationId,
        coversManualEntries: coversManualEntries,
        walkInManualEntries: walkInManualEntries,
      ),
    };
  }

  @override
  Future<Map<String, Object?>?> saveDataAccuracyManualCovers({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String businessDate,
    required String servicePeriodKey,
    required int covers,
    String? reasonNote,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastBusinessDate = businessDate;
    lastServicePeriodKey = servicePeriodKey;
    lastCovers = covers;
    manualCoversSaveCalls += 1;
    return <String, Object?>{
      'operator_ref': <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
      },
      'settings': _settingsRow(
        operatorId: operatorId,
        locationId: locationId,
        coversManualEntries: <String, Map<String, int>>{
          businessDate: <String, int>{servicePeriodKey: covers},
        },
      ),
    };
  }

  @override
  Future<Map<String, Object?>?> clearDataAccuracyManualCovers({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String businessDate,
    required String servicePeriodKey,
    String? reasonNote,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastBusinessDate = businessDate;
    lastServicePeriodKey = servicePeriodKey;
    manualCoversClearCalls += 1;
    return <String, Object?>{
      'operator_ref': <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
      },
      'settings': _settingsRow(operatorId: operatorId, locationId: locationId),
    };
  }

  @override
  Future<Map<String, Object?>> overrideDataAccuracyScope({
    required String actorUserId,
    required String operatorId,
    required String scopeType,
    String? orgUnitId,
    String? locationId,
    Map<String, String>? coversSourcePerServicePeriod,
    List<String>? clearCoversSourcePerServicePeriod,
    bool clearWageSource = false,
    bool clearWalkInHandlingMode = false,
    String? wageSource,
    String? walkInHandlingMode,
    String? reasonNote,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastScopeType = scopeType;
    lastCoversSourcePerServicePeriod = coversSourcePerServicePeriod;
    lastClearCoversSourcePerServicePeriod = clearCoversSourcePerServicePeriod;
    lastClearWageSource = clearWageSource;
    lastClearWalkInHandlingMode = clearWalkInHandlingMode;
    scopeOverrideCalls += 1;
    return <String, Object?>{
      'scope_type': scopeType,
      'operator_id': operatorId,
      if (orgUnitId != null) 'org_unit_id': orgUnitId,
      if (locationId != null) 'location_id': locationId,
      'affected_location_count': 0,
      'rows': const <Map<String, Object?>>[],
    };
  }

  @override
  Future<List<Map<String, Object?>>> listDataAccuracyServicePeriodRows({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    servicePeriodListCalls += 1;
    return <Map<String, Object?>>[
      _servicePeriodRow(operatorId: operatorId, locationId: locationId),
    ];
  }

  @override
  Future<Map<String, Object?>> overrideDataAccuracyServicePeriod({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String servicePeriodKey,
    required String coversSource,
    required String wageSource,
    required String effectiveAtBusinessDate,
    required String reasonNote,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastServicePeriodKey = servicePeriodKey;
    servicePeriodOverrideCalls += 1;
    return _servicePeriodRow(
      operatorId: operatorId,
      locationId: locationId,
      servicePeriodKey: servicePeriodKey,
      coversSource: coversSource,
      wageSource: wageSource,
      effectiveAtBusinessDate: effectiveAtBusinessDate,
    );
  }

  @override
  Future<Map<String, Object?>> clearDataAccuracyServicePeriod({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String servicePeriodKey,
    required String reasonNote,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastServicePeriodKey = servicePeriodKey;
    servicePeriodClearCalls += 1;
    return <String, Object?>{
      'operator_ref': <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
      },
      'cleared_count': 1,
      'data_accuracy_service_period_settings': const <Map<String, Object?>>[],
    };
  }

  @override
  Future<List<Map<String, Object?>>> listTierDefinitions({
    required String actorUserId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    return const <Map<String, Object?>>[];
  }

  @override
  Future<Map<String, Object?>> updateTierDefinition({
    required String actorUserId,
    required String tierKey,
    String? descriptionMd,
    Map<String, int>? pollingCadencePerVendorSeconds,
    int? defaultMonthlyPriceCents,
    int? vendorApiCostEstimateCentsMonthly,
    String? reasonNote,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    return const <String, Object?>{'tier_key': 'premium'};
  }

  @override
  Future<List<Map<String, Object?>>> listTierAssignments({
    required String actorUserId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    return const <Map<String, Object?>>[];
  }

  @override
  Future<Map<String, Object?>?> loadTierAssignment({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    loadTierAssignmentCalls += 1;
    return _assignment(operatorId: operatorId, locationId: locationId);
  }

  @override
  Future<Map<String, Object?>?> assignTier({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String tierKey,
    Map<String, int>? customCadencePerVendorSeconds,
    int? monthlyPriceCentsOverride,
    int? vendorApiCostEstimateCentsMonthlyOverride,
    String? adminNotes,
    String? reasonNote,
    required String adminReason,
  }) async {
    assignTierCalls += 1;
    lastActorUserId = actorUserId;
    return const <String, Object?>{'ok': true};
  }

  @override
  Future<Map<String, Object?>> assignTierScope({
    required String actorUserId,
    required String operatorId,
    required String scopeType,
    String? orgUnitId,
    String? locationId,
    required String tierKey,
    Map<String, int>? customCadencePerVendorSeconds,
    int? monthlyPriceCentsOverride,
    int? vendorApiCostEstimateCentsMonthlyOverride,
    String? adminNotes,
    String? reasonNote,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastScopeType = scopeType;
    scopeAssignCalls += 1;
    return <String, Object?>{
      'scope_type': scopeType,
      'operator_id': operatorId,
      if (orgUnitId != null) 'org_unit_id': orgUnitId,
      if (locationId != null) 'location_id': locationId,
      'affected_location_count': 0,
      'assignments': const <Map<String, Object?>>[],
    };
  }

  @override
  Future<Map<String, Object?>> summarizeMargin({
    required String actorUserId,
    String? tierKey,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    return const <String, Object?>{
      'total_monthly_price_cents': 0,
      'total_monthly_vendor_cost_cents': 0,
      'per_tier': <Map<String, Object?>>[],
      'per_vendor': <Map<String, Object?>>[],
    };
  }

  @override
  Future<String> exportMarginRollupCsv({
    required String actorUserId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    return 'section,key\n';
  }

  @override
  Future<List<Map<String, Object?>>> listTierChangeRequests({
    required String actorUserId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    return const <Map<String, Object?>>[];
  }

  @override
  Future<Map<String, Object?>?> resolveTierChangeRequest({
    required String actorUserId,
    required String requestId,
    required String status,
    String? reasonNote,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    return const <String, Object?>{'request_id': 'req-1'};
  }
}

Future<_HttpResponseData> _httpGet(HttpClient client, Uri uri) async {
  final request = await client.getUrl(uri);
  request.headers.set(HttpHeaders.authorizationHeader, 'Bearer fake.token');
  final raw = await request.close();
  final body = await utf8.decodeStream(raw);
  return _HttpResponseData(raw.statusCode, body);
}

Future<_HttpResponseData> _httpJson(
  HttpClient client,
  String method,
  Uri uri, {
  required Map<String, Object?> body,
  String? idempotencyKey,
}) async {
  final request = await client.openUrl(method, uri);
  request.headers.set(HttpHeaders.authorizationHeader, 'Bearer fake.token');
  if (idempotencyKey != null) {
    request.headers.set('Idempotency-Key', idempotencyKey);
  }
  request.headers.contentType = ContentType.json;
  final payload = utf8.encode(jsonEncode(body));
  request.contentLength = payload.length;
  request.add(payload);
  final raw = await request.close();
  final responseBody = await utf8.decodeStream(raw);
  return _HttpResponseData(raw.statusCode, responseBody);
}

Map<String, Object?> _dataAccuracyRow({
  required String operatorId,
  required String locationId,
}) {
  return <String, Object?>{
    'operator_id': operatorId,
    'business_name': 'Demo Diner',
    'location_id': locationId,
    'location_name': 'Downtown',
    'settings': _settingsRow(operatorId: operatorId, locationId: locationId),
  };
}

Map<String, Object?> _settingsRow({
  required String operatorId,
  required String locationId,
  Map<String, Map<String, int>> coversManualEntries =
      const <String, Map<String, int>>{},
  Map<String, int> walkInManualEntries = const <String, int>{},
}) {
  return <String, Object?>{
    'setting_id': 'setting-1',
    'operator_id': operatorId,
    'location_id': locationId,
    'covers_source_per_service_period': const <String, Object?>{
      'breakfast': 'manual',
    },
    'covers_manual_entries': <String, Object?>{
      for (final entry in coversManualEntries.entries)
        entry.key: <String, Object?>{
          for (final nested in entry.value.entries) nested.key: nested.value,
        },
    },
    'wage_source': 'manual_mix',
    'walk_in_handling_mode': 'walk_ins_tracked_separately',
    'walk_in_manual_entries': <String, Object?>{
      for (final entry in walkInManualEntries.entries) entry.key: entry.value,
    },
    'created_at': '2026-05-01T00:00:00.000Z',
    'updated_at': '2026-05-01T00:00:00.000Z',
    'updated_by': 'user_admin',
  };
}

Map<String, Object?> _servicePeriodRow({
  required String operatorId,
  required String locationId,
  String servicePeriodKey = 'breakfast',
  String coversSource = 'vendor',
  String wageSource = 'vendor_per_employee',
  String effectiveAtBusinessDate = '2026-06-01',
}) {
  return <String, Object?>{
    'id': 'sp-$servicePeriodKey',
    'operator_id': operatorId,
    'location_id': locationId,
    'service_period_key': servicePeriodKey,
    'covers_source': coversSource,
    'wage_source': wageSource,
    'effective_at_business_date': effectiveAtBusinessDate,
    'created_at': '2026-05-01T00:00:00.000Z',
    'updated_at': '2026-05-01T00:00:00.000Z',
    'updated_by': 'user_admin',
  };
}

Map<String, Object?> _assignment({
  required String operatorId,
  required String locationId,
}) {
  return <String, Object?>{
    'assignment_id': 'assignment-1',
    'operator_id': operatorId,
    'location_id': locationId,
    'tier_key': 'premium',
    'polling_cadence_per_vendor_seconds': const <String, Object?>{
      'quickbooks_time': 60,
    },
    'monthly_price_cents': 19900,
    'vendor_api_cost_estimate_cents_monthly': 4800,
    'effective_at': '2026-05-01T00:00:00.000Z',
    'effective_until': null,
    'assigned_by_admin_user_id': 'user_admin',
    'created_at': '2026-05-01T00:00:00.000Z',
  };
}

class _FakeAdminRequestIdempotencyStore
    implements AdminRequestIdempotencyStore {
  final Map<String, _FakeAdminRequestIdempotencyRow> _rows =
      <String, _FakeAdminRequestIdempotencyRow>{};
  final List<String?> reserveActorUserIds = <String?>[];
  int reserveCalls = 0;

  @override
  Future<AdminRequestIdempotencyEntry?> lookup({
    required String idempotencyKey,
    required String requestType,
    required String requestBodyHash,
  }) async {
    final row = _rows[idempotencyKey];
    if (row == null) return null;
    if (row.requestType != requestType ||
        row.requestBodyHash != requestBodyHash) {
      throw const AdminIdempotencyKeyConflict(
        message: 'Idempotency-Key was already used for another request',
      );
    }
    return AdminRequestIdempotencyEntry(
      idempotencyKey: idempotencyKey,
      requestType: row.requestType,
      responseStatus: row.responseStatus,
      responsePayload: row.responsePayload,
      completedAt: row.completedAt,
      expiresAt: row.expiresAt,
    );
  }

  @override
  Future<bool> reserve({
    required String idempotencyKey,
    required String requestType,
    required String? actorUserId,
    required String requestBodyHash,
  }) async {
    reserveCalls += 1;
    reserveActorUserIds.add(actorUserId);
    if (_rows.containsKey(idempotencyKey)) return false;
    _rows[idempotencyKey] = _FakeAdminRequestIdempotencyRow(
      requestType: requestType,
      requestBodyHash: requestBodyHash,
      expiresAt: DateTime.utc(2026, 5, 19, 12, 15),
    );
    return true;
  }

  @override
  Future<void> completeReservation({
    required String idempotencyKey,
    required int responseStatus,
    required Map<String, Object?> responsePayload,
  }) async {
    final row = _rows[idempotencyKey];
    if (row == null) return;
    _rows[idempotencyKey] = row.copyWith(
      responseStatus: responseStatus,
      responsePayload: responsePayload,
      completedAt: DateTime.utc(2026, 5, 19, 12, 1),
    );
  }

  @override
  Future<bool> tryReclaimOrphan({required String idempotencyKey}) async {
    return false;
  }

  @override
  Future<int> sweepExpiredOrphans() async {
    return 0;
  }
}

class _FakeAdminRequestIdempotencyRow {
  const _FakeAdminRequestIdempotencyRow({
    required this.requestType,
    required this.requestBodyHash,
    required this.expiresAt,
    this.responseStatus,
    this.responsePayload,
    this.completedAt,
  });

  final String requestType;
  final String requestBodyHash;
  final DateTime? expiresAt;
  final int? responseStatus;
  final Map<String, Object?>? responsePayload;
  final DateTime? completedAt;

  _FakeAdminRequestIdempotencyRow copyWith({
    int? responseStatus,
    Map<String, Object?>? responsePayload,
    DateTime? completedAt,
  }) {
    return _FakeAdminRequestIdempotencyRow(
      requestType: requestType,
      requestBodyHash: requestBodyHash,
      expiresAt: expiresAt,
      responseStatus: responseStatus ?? this.responseStatus,
      responsePayload: responsePayload ?? this.responsePayload,
      completedAt: completedAt ?? this.completedAt,
    );
  }
}

class _HttpResponseData {
  const _HttpResponseData(this.statusCode, this.body);

  final int statusCode;
  final String body;
}
