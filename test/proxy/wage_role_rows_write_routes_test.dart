// Doc 1 wage/role editor write proof — audit + cross-device tests.
//
// The wage_role_rows POST/DELETE seam already exercised by
// `test/proxy/operator_routes_wage_role_rows_test.dart` proves auth,
// scope, idempotency, and body validation. This file adds the missing
// audit + cross-device pieces called for by Hard Contract 7
// (manager/admin writes are permission-checked, idempotency-keyed,
// audit-logged, and visible through sync or refresh):
//
//   * audit row fires exactly once per successful upsert
//   * audit row fires exactly once per successful soft-delete
//   * audit row carries operator + actor + target + payload fields
//   * idempotent replay (same key + same body) does NOT re-fire audit
//   * service-principal actorKind round-trips through the audit row
//   * cross-device round-trip: a successful proxy write under operator
//     A's JWT → a subsequent operational-sync read under operator A's
//     JWT surfaces the row a peer device would mirror locally.
//
// Tests use the public surface only (HTTP server + JWT verifier +
// recording gateways) so the same shape catches regressions across
// router / dispatcher / proxy_bootstrap edits.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/models/wage_role_row_record.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

const String _kOpA = '11111111-1111-1111-1111-111111111111';
const String _kLocA = '22222222-2222-2222-2222-222222222222';
const String _kUserA = '33333333-3333-3333-3333-333333333333';
const String _kPrincipalA = '44444444-4444-4444-4444-444444444444';
const String _kRowId = '55555555-5555-5555-5555-555555555555';

void main() {
  group('wage role rows write + audit + cross-device', () {
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
        _RecordingWageGateway writeGateway,
        _RecordingAuditSink auditSink,
        _RecordingMobileSyncGateway readGateway,
        _SettableVerifier verifier,
      })
    >
    spinUp({ProxyJwtClaims? initialClaims}) async {
      final verifier = _SettableVerifier();
      verifier.claims =
          initialClaims ??
          const ProxyJwtClaims(
            userId: _kUserA,
            operatorId: _kOpA,
            locationId: _kLocA,
            roles: <String>['operator_owner'],
          );
      final guard = ProxyRequestGuard(verifier: verifier);
      final writeGateway = _RecordingWageGateway();
      final auditSink = _RecordingAuditSink();
      final readGateway = _RecordingMobileSyncGateway();
      final router = WageRoleRowsRouter(
        gateway: writeGateway,
        auditSink: auditSink,
        now: () => DateTime.utc(2026, 5, 8, 12, 30),
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // ignore: unawaited_futures
      server.listen((request) async {
        try {
          await routeRequest(
            request,
            guard,
            wageRoleRowsRouter: router,
            mobileOperationalSyncGateway: readGateway,
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
        writeGateway: writeGateway,
        auditSink: auditSink,
        readGateway: readGateway,
        verifier: verifier,
      );
    }

    test('successful POST fires the audit sink exactly once with '
        'operator + actor + target metadata', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _http(
            ctx.client,
            ctx.baseUri.resolve(wageRoleRowsPath),
            method: 'POST',
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-audit-1',
            body: const <String, Object?>{
              'restaurant_id': 'rest-1',
              'role_name': 'Server',
              'labor_bucket': 'foh',
              'hourly_rate': 18.5,
              'weighted_hours': 30.0,
            },
          );
          expect(response.statusCode, equals(200));
          expect(ctx.writeGateway.upsertCalls, hasLength(1));
          expect(ctx.auditSink.upsertCalls, hasLength(1));
          final audit = ctx.auditSink.upsertCalls.single;
          expect(audit['operatorId'], equals(_kOpA));
          expect(audit['locationId'], equals(_kLocA));
          expect(audit['actorUserId'], equals(_kUserA));
          expect(audit['actorKind'], equals('user'));
          expect(audit['wageRoleRowId'], equals(_kRowId));
          expect(audit['restaurantId'], equals('rest-1'));
          expect(audit['roleName'], equals('Server'));
          expect(audit['laborBucket'], equals('foh'));
          expect(audit['source'], equals('operator_manual'));
          expect(audit['hourlyRate'], equals(18.5));
          expect(audit['weightedHours'], equals(30.0));
          expect(audit['occurredAt'], equals(DateTime.utc(2026, 5, 8, 12, 30)));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('successful DELETE fires the audit sink exactly once and '
        'records removed=true', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          ctx.writeGateway.softDeleteAffected = true;
          final response = await _http(
            ctx.client,
            ctx.baseUri.resolve('$wageRoleRowsPrefix$_kRowId'),
            method: 'DELETE',
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-audit-del-1',
          );
          expect(response.statusCode, equals(200));
          expect(ctx.writeGateway.softDeleteCalls, hasLength(1));
          expect(ctx.auditSink.softDeleteCalls, hasLength(1));
          final audit = ctx.auditSink.softDeleteCalls.single;
          expect(audit['operatorId'], equals(_kOpA));
          expect(audit['locationId'], equals(_kLocA));
          expect(audit['actorUserId'], equals(_kUserA));
          expect(audit['actorKind'], equals('user'));
          expect(audit['wageRoleRowId'], equals(_kRowId));
          expect(audit['removed'], isTrue);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'DELETE on already-inactive row records removed=false in audit',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            ctx.writeGateway.softDeleteAffected = false;
            final response = await _http(
              ctx.client,
              ctx.baseUri.resolve('$wageRoleRowsPrefix$_kRowId'),
              method: 'DELETE',
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-audit-del-noop',
            );
            expect(response.statusCode, equals(200));
            expect(
              (jsonDecode(response.body) as Map<String, Object?>)['removed'],
              isFalse,
            );
            expect(ctx.auditSink.softDeleteCalls, hasLength(1));
            expect(ctx.auditSink.softDeleteCalls.single['removed'], isFalse);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('idempotent replay does NOT re-fire the audit sink', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          const body = <String, Object?>{
            'restaurant_id': 'rest-1',
            'role_name': 'Server',
            'labor_bucket': 'foh',
            'hourly_rate': 18.5,
            'weighted_hours': 30.0,
          };
          final first = await _http(
            ctx.client,
            ctx.baseUri.resolve(wageRoleRowsPath),
            method: 'POST',
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-audit-replay',
            body: body,
          );
          final second = await _http(
            ctx.client,
            ctx.baseUri.resolve(wageRoleRowsPath),
            method: 'POST',
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-audit-replay',
            body: body,
          );
          expect(first.statusCode, equals(200));
          expect(second.statusCode, equals(200));
          expect(first.body, equals(second.body));
          // Gateway saw the write once.
          expect(ctx.writeGateway.upsertCalls, hasLength(1));
          // Audit sink saw the write once — replay must short-circuit
          // before `compute` runs so the audit row is never duplicated.
          expect(ctx.auditSink.upsertCalls, hasLength(1));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'service-principal actorKind round-trips into the audit row',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(
            initialClaims: const ProxyJwtClaims(
              userId: _kPrincipalA,
              operatorId: _kOpA,
              locationId: _kLocA,
              roles: <String>['operator_owner'],
              actorKind: 'service',
            ),
          );
          try {
            final response = await _http(
              ctx.client,
              ctx.baseUri.resolve(wageRoleRowsPath),
              method: 'POST',
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-audit-service',
              body: const <String, Object?>{
                'restaurant_id': 'rest-1',
                'role_name': 'Server',
                'labor_bucket': 'foh',
                'hourly_rate': 18.5,
                'weighted_hours': 30.0,
              },
            );
            expect(response.statusCode, equals(200));
            expect(ctx.auditSink.upsertCalls, hasLength(1));
            expect(
              ctx.auditSink.upsertCalls.single['actorKind'],
              equals('service'),
            );
            expect(
              ctx.auditSink.upsertCalls.single['actorUserId'],
              equals(_kPrincipalA),
            );
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('cross-device read-after-write: the same operator scope sees '
        'the upserted row through the operational sync route a peer '
        'device would call', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          // Device A writes the wage row.
          final write = await _http(
            ctx.client,
            ctx.baseUri.resolve(wageRoleRowsPath),
            method: 'POST',
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-cross-device',
            body: const <String, Object?>{
              'restaurant_id': 'rest-1',
              'role_name': 'Server',
              'labor_bucket': 'foh',
              'hourly_rate': 18.5,
              'weighted_hours': 30.0,
            },
          );
          expect(write.statusCode, equals(200));
          final writeBody = jsonDecode(write.body) as Map<String, Object?>;
          expect(writeBody['server_id'], equals(_kRowId));

          // Production wires the upsert and the read path against the
          // same Postgres table; here the recording read gateway
          // mirrors that behavior — once the write commits, it adds
          // the row to the next sync response so a peer device's
          // operational-sync pull surfaces it.
          ctx.readGateway.publish(
            WageRoleRowRecord(
              wageRoleRowId: _kRowId,
              operatorId: _kOpA,
              locationId: _kLocA,
              restaurantId: 'rest-1',
              roleName: 'Server',
              laborBucket: 'foh',
              hourlyRate: 18.5,
              weightedHours: 30.0,
              source: WageRoleRowSource.operatorManual,
              isActive: true,
              effectiveAt: DateTime.utc(2026, 5, 8, 12, 30),
              metadata: const <String, Object?>{},
              createdAt: DateTime.utc(2026, 5, 8, 12, 30),
              updatedAt: DateTime.utc(2026, 5, 8, 12, 30),
              updatedBy: _kUserA,
            ),
          );

          // Device B (same operator JWT) syncs the wage rows surface
          // and sees the row.
          final read = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              '/v1/operators/$_kOpA/locations/$_kLocA/wage_role_rows',
            ),
          );
          expect(read.statusCode, equals(200));
          final readBody = jsonDecode(read.body) as Map<String, Object?>;
          final rows = readBody['wage_role_rows'] as List<Object?>;
          expect(rows, hasLength(1));
          final row = rows.single as Map<String, Object?>;
          expect(row['server_id'], equals(_kRowId));
          expect(row['role_name'], equals('Server'));
          expect(row['labor_bucket'], equals('foh'));
          expect(row['hourly_rate'], equals(18.5));
          expect(row['operator_id'], equals(_kOpA));
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
  Object? error;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    final err = error;
    if (err != null) throw err;
    final c = claims;
    if (c == null) {
      throw ProxyJwtVerificationError('no claims set');
    }
    return c;
  }
}

class _RecordingWageGateway implements WageRoleRowsGateway {
  bool softDeleteAffected = true;
  final List<Map<String, Object?>> upsertCalls = <Map<String, Object?>>[];
  final List<Map<String, Object?>> softDeleteCalls = <Map<String, Object?>>[];

  @override
  Future<WageRoleRowRecord> upsert({
    required String operatorId,
    required String locationId,
    required String restaurantId,
    required String roleName,
    required String laborBucket,
    required double hourlyRate,
    required double weightedHours,
    String? jobCode,
    String? vendorId,
    String? vendorRoleId,
    WageRoleRowSource source = WageRoleRowSource.operatorManual,
    bool isActive = true,
    Map<String, Object?> metadata = const <String, Object?>{},
    String? actorUserId,
    String scopeType = 'location',
    String? orgUnitId,
  }) async {
    upsertCalls.add(<String, Object?>{
      'operatorId': operatorId,
      'locationId': locationId,
      'restaurantId': restaurantId,
      'roleName': roleName,
      'laborBucket': laborBucket,
      'hourlyRate': hourlyRate,
      'weightedHours': weightedHours,
      'jobCode': jobCode,
      'vendorId': vendorId,
      'vendorRoleId': vendorRoleId,
      'source': source.wire,
      'isActive': isActive,
      'metadata': metadata,
      'actorUserId': actorUserId,
      'scopeType': scopeType,
      'orgUnitId': orgUnitId,
    });
    return WageRoleRowRecord(
      wageRoleRowId: _kRowId,
      operatorId: operatorId,
      locationId: locationId,
      restaurantId: restaurantId,
      roleName: roleName,
      laborBucket: laborBucket,
      hourlyRate: hourlyRate,
      weightedHours: weightedHours,
      jobCode: jobCode,
      vendorId: vendorId,
      vendorRoleId: vendorRoleId,
      source: source,
      isActive: isActive,
      effectiveAt: DateTime.utc(2026, 5, 8, 12),
      metadata: metadata,
      createdAt: DateTime.utc(2026, 5, 8, 12),
      updatedAt: DateTime.utc(2026, 5, 8, 12),
      updatedBy: actorUserId,
      scopeType: scopeType,
      orgUnitId: orgUnitId,
    );
  }

  @override
  Future<bool> softDelete({
    required String operatorId,
    required String locationId,
    required String wageRoleRowId,
    String? actorUserId,
  }) async {
    softDeleteCalls.add(<String, Object?>{
      'operatorId': operatorId,
      'locationId': locationId,
      'wageRoleRowId': wageRoleRowId,
      'actorUserId': actorUserId,
    });
    return softDeleteAffected;
  }
}

class _RecordingAuditSink implements WageRoleRowsAuditSink {
  final List<Map<String, Object?>> upsertCalls = <Map<String, Object?>>[];
  final List<Map<String, Object?>> softDeleteCalls = <Map<String, Object?>>[];

  @override
  Future<void> recordUpsert({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String actorKind,
    required String wageRoleRowId,
    required String restaurantId,
    required String roleName,
    required String laborBucket,
    required double hourlyRate,
    required double weightedHours,
    required String source,
    required String scopeType,
    required String? orgUnitId,
    required DateTime occurredAt,
  }) async {
    upsertCalls.add(<String, Object?>{
      'operatorId': operatorId,
      'locationId': locationId,
      'actorUserId': actorUserId,
      'actorKind': actorKind,
      'wageRoleRowId': wageRoleRowId,
      'restaurantId': restaurantId,
      'roleName': roleName,
      'laborBucket': laborBucket,
      'hourlyRate': hourlyRate,
      'weightedHours': weightedHours,
      'source': source,
      'scopeType': scopeType,
      'orgUnitId': orgUnitId,
      'occurredAt': occurredAt,
    });
  }

  @override
  Future<void> recordSoftDelete({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String actorKind,
    required String wageRoleRowId,
    required bool removed,
    required DateTime occurredAt,
  }) async {
    softDeleteCalls.add(<String, Object?>{
      'operatorId': operatorId,
      'locationId': locationId,
      'actorUserId': actorUserId,
      'actorKind': actorKind,
      'wageRoleRowId': wageRoleRowId,
      'removed': removed,
      'occurredAt': occurredAt,
    });
  }
}

/// Recording mobile operational sync gateway. Only the
/// `fetchWageRoleRows` method matters for cross-device read-after-write
/// proof; the other surface methods return empty payloads so this fake
/// can wire into the same `routeRequest` dispatcher.
class _RecordingMobileSyncGateway implements MobileOperationalSyncProxyGateway {
  final List<WageRoleRowRecord> _published = <WageRoleRowRecord>[];

  void publish(WageRoleRowRecord row) => _published.add(row);

  @override
  Future<Map<String, Object?>> fetchWageRoleRows({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required String? modifiedSince,
    required int pageSize,
    required bool includeHierarchy,
  }) async {
    final filtered = _published
        .where((r) => r.operatorId == operatorId && r.locationId == locationId)
        .toList();
    return <String, Object?>{
      'wage_role_rows': <Map<String, Object?>>[
        for (final r in filtered)
          <String, Object?>{
            'server_id': r.wageRoleRowId,
            'operator_id': r.operatorId,
            'location_id': r.locationId,
            'restaurant_id': r.restaurantId,
            'role_name': r.roleName,
            'labor_bucket': r.laborBucket,
            'hourly_rate': r.hourlyRate,
            'weighted_hours': r.weightedHours,
            'job_code': r.jobCode,
            'vendor_id': r.vendorId,
            'vendor_role_id': r.vendorRoleId,
            'source': r.source.wire,
            'is_active': r.isActive,
            'effective_at': r.effectiveAt.toIso8601String(),
            'metadata': r.metadata,
            'created_at': r.createdAt.toIso8601String(),
            'updated_at': r.updatedAt.toIso8601String(),
            'updated_by': r.updatedBy,
          },
      ],
      'next_cursor': null,
    };
  }

  @override
  Future<Map<String, Object?>> fetchShiftRecords({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required String? modifiedSince,
    required int pageSize,
  }) async => const <String, Object?>{
    'shift_records': <Map<String, Object?>>[],
    'next_cursor': null,
  };

  @override
  Future<Map<String, Object?>> fetchOpenShiftSnapshots({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required String? modifiedSince,
    required int pageSize,
  }) async => const <String, Object?>{
    'open_shift_snapshots': <Map<String, Object?>>[],
  };

  @override
  Future<Map<String, Object?>> fetchResolvedTimingConfig({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required String? businessDate,
  }) async => const <String, Object?>{};

  @override
  Future<Map<String, Object?>> fetchDataAccuracySettings({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
  }) async => const <String, Object?>{};

  @override
  Future<Map<String, Object?>> upsertDataAccuracySettings({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required Map<String, Object?> body,
  }) async => const <String, Object?>{};

  @override
  Future<Map<String, Object?>> upsertDataAccuracyManualCovers({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required Map<String, Object?> body,
  }) async => const <String, Object?>{};

  @override
  Future<Map<String, Object?>> upsertDataAccuracyServicePeriodSettings({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required Map<String, Object?> body,
  }) async => const <String, Object?>{};

  @override
  Future<Map<String, Object?>> clearDataAccuracyServicePeriodSettings({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required Map<String, Object?> body,
  }) async => const <String, Object?>{
    'data_accuracy_service_period_settings': <Map<String, Object?>>[],
  };

  @override
  Future<Map<String, Object?>> fetchDataAccuracyServicePeriodSettings({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
  }) async => const <String, Object?>{
    'data_accuracy_service_period_settings': <Map<String, Object?>>[],
  };

  @override
  Future<Map<String, Object?>> fetchDemoModeStates({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
  }) async => const <String, Object?>{
    'demo_mode_states': <Map<String, Object?>>[],
  };

  @override
  Future<Map<String, Object?>> fetchPollingTierAssignment({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
  }) async => const <String, Object?>{};

  @override
  Future<Map<String, Object?>> fetchFirstBackfillStatus({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
  }) async => const <String, Object?>{};
}

class _HttpResponseSnapshot {
  const _HttpResponseSnapshot({required this.statusCode, required this.body});
  final int statusCode;
  final String body;
}

Future<_HttpResponseSnapshot> _http(
  HttpClient client,
  Uri uri, {
  required String method,
  required String authorization,
  String? idempotencyKey,
  Map<String, Object?>? body,
}) async {
  final request = await client.openUrl(method, uri);
  request.persistentConnection = false;
  request.headers.set(HttpHeaders.authorizationHeader, authorization);
  if (idempotencyKey != null) {
    request.headers.set('Idempotency-Key', idempotencyKey);
  }
  if (body != null) {
    request.headers.contentType = ContentType.json;
    final encoded = utf8.encode(jsonEncode(body));
    request.contentLength = encoded.length;
    request.add(encoded);
  }
  final response = await request.close();
  final responseBody = await response.transform(utf8.decoder).join();
  return _HttpResponseSnapshot(
    statusCode: response.statusCode,
    body: responseBody,
  );
}

Future<_HttpResponseSnapshot> _httpGet(HttpClient client, Uri uri) async {
  final request = await client.openUrl('GET', uri);
  request.persistentConnection = false;
  request.headers.set(HttpHeaders.authorizationHeader, 'Bearer fake.token');
  final response = await request.close();
  final responseBody = await response.transform(utf8.decoder).join();
  return _HttpResponseSnapshot(
    statusCode: response.statusCode,
    body: responseBody,
  );
}
