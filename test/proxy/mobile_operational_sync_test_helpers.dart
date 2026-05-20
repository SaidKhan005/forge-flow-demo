// Shared test helpers for the mobile_operational_sync_*_test.dart split.
//
// Bucket 5i of the 2026-05-20 test-suite tightening audit: extracted out of
// `test/proxy/mobile_operational_sync_routes_test.dart` (2,067 lines) when
// the original monolith was split into three focused files:
//   - mobile_operational_sync_shift_records_test.dart
//   - mobile_operational_sync_sync_and_idempotency_test.dart
//   - mobile_operational_sync_demo_and_error_paths_test.dart
//
// These helpers (the `spinUp()` harness wiring an in-process `HttpServer`
// + `ProxyRequestGuard` + route dispatcher, the `withRealHttp` HTTP-
// overrides escape hatch, the `_httpGet` / `_httpRequest` wrappers, and
// the four fake collaborators — `_SettableVerifier`,
// `_FakeAdminRequestIdempotencyStore`,
// `_FakeMobileOperationalSyncGateway`, and
// `_FakeDemoModeMasterSwitchGateway`) were file-private in the original
// monolith. They are promoted to library-public (leading `_` dropped) so
// the three split files can share them without duplication. Behaviour is
// byte-identical to the pre-split source.
//
// The public `MobileOperationalSyncTestContext` typedef captures the
// shape of `spinUp()`'s return record so callers can name it without
// reassembling the field list.

import 'dart:convert';
import 'dart:io';

import 'package:forge_and_flow/services/integration/demo_mode_state.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

/// Return type of [spinUp]. Made public so split test files can hold the
/// context in a typed local without re-stating the field list.
typedef MobileOperationalSyncTestContext =
    ({
      HttpServer server,
      HttpClient client,
      Uri baseUri,
      FakeMobileOperationalSyncGateway gateway,
      FakeDemoModeMasterSwitchGateway demoSwitchGateway,
      FakeAdminRequestIdempotencyStore idempotencyStore,
    });

/// Runs [body] with `HttpOverrides.global` cleared, restoring whatever was
/// installed beforehand once the body completes. Required because the
/// in-process test server is a real `HttpServer` and the Flutter test
/// harness installs an override that would otherwise intercept the loopback
/// request.
Future<T> withRealHttp<T>(Future<T> Function() body) async {
  final saved = HttpOverrides.current;
  HttpOverrides.global = null;
  try {
    return await body();
  } finally {
    HttpOverrides.global = saved;
  }
}

/// Stands up a loopback `HttpServer` wired to the proxy `routeRequest`
/// dispatcher with a [FakeMobileOperationalSyncGateway], a
/// [FakeDemoModeMasterSwitchGateway], and a
/// [FakeAdminRequestIdempotencyStore]. Returns a record carrying every
/// handle a test needs to drive and assert against the harness.
///
/// The default `claims` is `operator_owner` for `op-1` / `loc-1`. Pass
/// `gatewayConfigured: false` to assert the 503 path when the production
/// gateway is not installed. Pass an explicit `demoSwitchGateway` or
/// `idempotencyStore` to share state across multiple `spinUp` invocations
/// inside a single test (used by the demo-mode replay test that restarts
/// the server while keeping the durable idempotency ledger).
Future<MobileOperationalSyncTestContext> spinUp({
  ProxyJwtClaims? claims,
  bool gatewayConfigured = true,
  bool demoSwitchConfigured = true,
  FakeDemoModeMasterSwitchGateway? demoSwitchGateway,
  FakeAdminRequestIdempotencyStore? idempotencyStore,
}) async {
  final verifier = SettableVerifier(
    claims ??
        const ProxyJwtClaims(
          userId: 'user-1',
          operatorId: 'op-1',
          locationId: 'loc-1',
          roles: <String>['operator_owner'],
        ),
  );
  final guard = ProxyRequestGuard(verifier: verifier);
  final gateway = FakeMobileOperationalSyncGateway();
  final switchGateway =
      demoSwitchGateway ?? FakeDemoModeMasterSwitchGateway();
  final adminIdempotencyStore =
      idempotencyStore ?? FakeAdminRequestIdempotencyStore();
  final demoSwitchRouter = DemoModeMasterSwitchRouter(
    gateway: switchGateway,
    now: () => DateTime.utc(2026, 5, 13, 12),
  );
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  // ignore: unawaited_futures
  server.listen((request) async {
    try {
      await routeRequest(
        request,
        guard,
        mobileOperationalSyncGateway: gatewayConfigured ? gateway : null,
        demoModeMasterSwitchRouter: demoSwitchConfigured
            ? demoSwitchRouter
            : null,
        adminRequestIdempotencyStore: adminIdempotencyStore,
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
    gateway: gateway,
    demoSwitchGateway: switchGateway,
    idempotencyStore: adminIdempotencyStore,
  );
}

/// Minimal `ProxyJwtVerifier` double that returns the [ProxyJwtClaims] it
/// was constructed with on every `verify()` call.
class SettableVerifier implements ProxyJwtVerifier {
  SettableVerifier(this.claims);

  final ProxyJwtClaims claims;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async => claims;
}

/// In-memory [AdminRequestIdempotencyStore] double. Records every
/// `reserve()` call so tests can pin the reserve count and the
/// idempotency-key strings that the proxy generated for them. Returns
/// `false` from `reserve()` on a second call with the same key,
/// matching the production "already taken" semantics, and throws
/// [AdminIdempotencyKeyConflict] from `lookup()` when the body hash for
/// the same key drifts.
class FakeAdminRequestIdempotencyStore
    implements AdminRequestIdempotencyStore {
  final Map<String, _FakeAdminRequestIdempotencyRow> _rows =
      <String, _FakeAdminRequestIdempotencyRow>{};
  final List<String?> reserveActorUserIds = <String?>[];
  final List<String> reserveIdempotencyKeys = <String>[];
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
    reserveIdempotencyKeys.add(idempotencyKey);
    reserveActorUserIds.add(actorUserId);
    if (_rows.containsKey(idempotencyKey)) return false;
    _rows[idempotencyKey] = _FakeAdminRequestIdempotencyRow(
      requestType: requestType,
      requestBodyHash: requestBodyHash,
      expiresAt: DateTime.utc(2026, 5, 6, 12, 15),
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
      completedAt: DateTime.utc(2026, 5, 6, 12, 1),
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

/// Recording [MobileOperationalSyncProxyGateway] double. Every GET-path
/// method records a deterministic call string into [calls]; PATCH-path
/// methods record a tagged write string. Tests assert against the
/// recorded calls (often `isEmpty` for negative paths). Setting
/// [throwOnNextShift] makes the next `fetchShiftRecords` rethrow it
/// once — used to verify the proxy's 503 wrapper around upstream
/// faults.
class FakeMobileOperationalSyncGateway
    implements MobileOperationalSyncProxyGateway {
  final List<String> calls = <String>[];
  Object? throwOnNextShift;

  @override
  Future<Map<String, Object?>> fetchShiftRecords({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required String? modifiedSince,
    required int pageSize,
  }) async {
    final thrown = throwOnNextShift;
    if (thrown != null) {
      throwOnNextShift = null;
      throw thrown;
    }
    calls.add('shift_records:$operatorId:$locationId:$modifiedSince:$pageSize');
    return const <String, Object?>{
      'shift_records': <Map<String, Object?>>[
        <String, Object?>{
          'restaurant_id': 'loc-1',
          'week_id': '2026-W18',
          'day_label': 'Tue',
          'daypart': 'dinner',
          'status': 'closed',
          'business_date': '2026-05-05',
          // V1.A: closed shift_records carry the same timing triplet
          // as open snapshots so mobile's ClosedTimingLabelResolver
          // never falls back to mutable `daypart` when the operator
          // changes service-period boundaries later.
          'business_timing_profile_id': '11111111-1111-1111-1111-111111111111',
          'business_timing_profile_version_id':
              '11111111-1111-1111-1111-111111111111',
          'service_period_key': 'dinner',
          'covers': 120,
          'forecast_covers': 110,
          'ppa': 42.0,
          'cplh': 13.5,
          'splh': 160.0,
          'foh_hours': 8,
          'boh_hours': 5,
          'theoretical_labor_pct': 24.0,
          'primary_lever': 'ON_MODEL',
        },
      ],
      'next_cursor': '2026-05-06T12:30:00.000Z',
    };
  }

  @override
  Future<Map<String, Object?>> fetchOpenShiftSnapshots({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required String? modifiedSince,
    required int pageSize,
  }) async {
    calls.add(
      'open_shift_snapshots:$operatorId:$locationId:$modifiedSince:$pageSize',
    );
    return const <String, Object?>{
      'open_shift_snapshots': <Map<String, Object?>>[
        <String, Object?>{
          'restaurant_id': 'loc-1',
          'week_id': '2026-W18',
          'day_label': 'Tue',
          'daypart': 'lunch',
          'status': 'open',
          'business_date': '2026-05-06',
          'business_timing_profile_id': '11111111-1111-1111-1111-111111111111',
          'business_timing_profile_version_id':
              '11111111-1111-1111-1111-111111111111',
          'service_period_key': 'lunch',
        },
      ],
      'next_cursor': null,
    };
  }

  @override
  Future<Map<String, Object?>> fetchResolvedTimingConfig({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required String? businessDate,
  }) async {
    calls.add('timing/resolved:$operatorId:$locationId:$businessDate');
    return const <String, Object?>{
      'timing_config': <String, Object?>{
        'restaurant_id': 'loc-1',
        'business_timezone': 'America/St_Johns',
        'business_day_start_local_time': '04:00',
        'week_start_day': 1,
        'shift_close_authority': 'vendor_finalization',
        'service_period_definitions': <Map<String, Object?>>[],
      },
    };
  }

  @override
  Future<Map<String, Object?>> fetchDemoModeStates({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
  }) async {
    calls.add('demo_mode_states:$operatorId:$locationId');
    return const <String, Object?>{
      'demo_mode_states': <Map<String, Object?>>[
        <String, Object?>{
          'operator_id': 'op-1',
          'location_id': 'loc-1',
          'category': 'pos',
          'is_demo': false,
        },
      ],
    };
  }

  @override
  Future<Map<String, Object?>> fetchDataAccuracySettings({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
  }) async {
    calls.add('data_accuracy_settings:$operatorId:$locationId');
    return const <String, Object?>{
      'data': <String, Object?>{
        'operator_id': 'op-1',
        'location_id': 'loc-1',
        'covers_source_lunch': 'vendor',
        'covers_source_dinner': 'manual',
        'covers_source_late_night': 'vendor',
        'covers_manual_entries': <String, Object?>{},
        'wage_source': 'manual_mix',
        'walk_in_handling_mode': 'walk_ins_added_to_reservations',
        'walk_in_manual_entries': <String, Object?>{'2026-05-06': 8},
        'updated_at': '2026-05-06T12:00:00Z',
      },
    };
  }

  @override
  Future<Map<String, Object?>> upsertDataAccuracySettings({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required Map<String, Object?> body,
  }) async {
    final covers = Map<String, Object?>.from(
      (body['covers_source_per_service_period'] as Map?) ??
          const <String, Object?>{},
    );
    calls.add(
      'data_accuracy_settings_write:$operatorId:$locationId:'
      '${covers['lunch'] ?? 'vendor'}:${body['wage_source']}',
    );
    return <String, Object?>{
      'data': <String, Object?>{
        'setting_id': 'setting-1',
        'operator_id': operatorId,
        'location_id': locationId,
        'covers_source_lunch': covers['lunch'] ?? 'vendor',
        'covers_source_dinner': covers['dinner'] ?? 'vendor',
        'covers_source_late_night': covers['late_night'] ?? 'vendor',
        'covers_source_per_service_period': covers,
        'covers_manual_entries':
            body['covers_manual_entries'] ?? const <String, Object?>{},
        'wage_source': body['wage_source'] ?? 'vendor',
        'walk_in_handling_mode':
            body['walk_in_handling_mode'] ?? 'reservations_only',
        'walk_in_manual_entries':
            body['walk_in_manual_entries'] ?? const <String, Object?>{},
        'created_at': '2026-05-06T12:00:00Z',
        'updated_at': '2026-05-06T12:01:00Z',
        'updated_by': scope.userId,
      },
    };
  }

  @override
  Future<Map<String, Object?>> upsertDataAccuracyManualCovers({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required Map<String, Object?> body,
  }) async {
    final businessDate = body['business_date']! as String;
    final servicePeriodKey = body['service_period_key']! as String;
    calls.add(
      'manual_covers_write:$operatorId:$locationId:'
      '$businessDate:$servicePeriodKey:'
      '${body['covers']}',
    );
    return <String, Object?>{
      'data': <String, Object?>{
        'setting_id': 'setting-1',
        'operator_id': operatorId,
        'location_id': locationId,
        'covers_source_lunch': 'vendor',
        'covers_source_dinner': 'manual',
        'covers_source_late_night': 'vendor',
        'covers_manual_entries': <String, Object?>{
          businessDate: <String, Object?>{servicePeriodKey: body['covers']},
        },
        'wage_source': 'manual_mix',
        'walk_in_handling_mode': 'walk_ins_added_to_reservations',
        'walk_in_manual_entries': <String, Object?>{'2026-05-06': 8},
        'created_at': '2026-05-06T12:00:00Z',
        'updated_at': '2026-05-06T12:01:00Z',
        'updated_by': scope.userId,
      },
    };
  }

  @override
  Future<Map<String, Object?>> upsertDataAccuracyServicePeriodSettings({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required Map<String, Object?> body,
  }) async {
    calls.add(
      'data_accuracy_service_period_settings_write:$operatorId:$locationId:'
      '${body['service_period_key']}:${body['covers_source']}:'
      '${body['wage_source']}:${body['effective_at_business_date']}',
    );
    return <String, Object?>{
      'data': <String, Object?>{
        'id': 'period-setting-1',
        'operator_id': operatorId,
        'location_id': locationId,
        'service_period_key': body['service_period_key'] ?? 'breakfast',
        'covers_source': body['covers_source'] ?? 'vendor',
        'wage_source': body['wage_source'] ?? 'vendor_per_employee',
        'effective_at_business_date':
            body['effective_at_business_date'] ?? '2026-05-07',
        'created_at': '2026-05-07T12:00:00Z',
        'updated_at': '2026-05-07T12:01:00Z',
        'updated_by': scope.userId,
      },
    };
  }

  @override
  Future<Map<String, Object?>> clearDataAccuracyServicePeriodSettings({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required Map<String, Object?> body,
  }) async {
    calls.add(
      'data_accuracy_service_period_settings_clear:$operatorId:$locationId:'
      '${body['service_period_key']}',
    );
    return const <String, Object?>{
      'data_accuracy_service_period_settings': <Map<String, Object?>>[],
    };
  }

  @override
  Future<Map<String, Object?>> fetchDataAccuracyServicePeriodSettings({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
  }) async {
    calls.add('data_accuracy_service_period_settings:$operatorId:$locationId');
    return const <String, Object?>{
      'data_accuracy_service_period_settings': <Map<String, Object?>>[
        <String, Object?>{
          'id': 'setting-1',
          'operator_id': 'op-1',
          'location_id': 'loc-1',
          'service_period_key': 'dinner',
          'effective_at_business_date': '2026-05-06',
          'covers_source': 'manual',
          'wage_source': 'manual_mix',
          'created_at': '2026-05-06T12:00:00Z',
          'updated_at': '2026-05-06T12:00:00Z',
          'updated_by': 'user-1',
        },
      ],
    };
  }

  @override
  Future<Map<String, Object?>> fetchWageRoleRows({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required String? modifiedSince,
    required int pageSize,
    required bool includeHierarchy,
  }) async {
    calls.add(
      'wage_role_rows:$operatorId:$locationId:$modifiedSince:$pageSize:'
      '$includeHierarchy',
    );
    return const <String, Object?>{
      'wage_role_rows': <Map<String, Object?>>[
        <String, Object?>{
          'server_id': 'wage-row-1',
          'operator_id': 'op-1',
          'location_id': 'loc-1',
          'restaurant_id': 'loc-1',
          'role_name': 'Server',
          'labor_bucket': 'foh',
          'hourly_rate': 22.5,
          'weighted_hours': 32.0,
          'job_code': '5001',
          'vendor_id': 'quickbooks_time',
          'vendor_role_id': '5001',
          'source': 'operator_manual',
          'is_active': true,
          'effective_at': '2026-05-06T12:00:00Z',
          'metadata': <String, Object?>{'source_label': 'manual mix'},
          'created_at': '2026-05-06T12:00:00Z',
          'updated_at': '2026-05-06T12:30:00Z',
          'updated_by': 'user-1',
        },
      ],
      'next_cursor': '2026-05-06T12:30:00.000Z',
    };
  }

  @override
  Future<Map<String, Object?>> fetchPollingTierAssignment({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
  }) async {
    calls.add('polling_tier_assignment:$operatorId:$locationId');
    return const <String, Object?>{
      'assignment': <String, Object?>{
        'operator_id': 'op-1',
        'location_id': 'loc-1',
        'tier_key': 'premium',
        'polling_cadence_per_vendor_seconds': <String, Object?>{'toast': 300},
        'monthly_price_cents': 9900,
        'effective_at': '2026-05-06T12:00:00Z',
      },
    };
  }

  @override
  Future<Map<String, Object?>> fetchFirstBackfillStatus({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
  }) async {
    calls.add('first_backfill_status:$operatorId:$locationId');
    return const <String, Object?>{
      'first_backfill_status': <String, Object?>{
        'job_id': 'job-1',
        'operator_id': 'op-1',
        'location_id': 'loc-1',
        'connection_id': 'conn-1',
        'vendor_id': 'toast',
        'category': 'pos',
        'status': 'running',
        'window_start': '2026-03-07T00:00:00Z',
        'window_end': '2026-05-06T00:00:00Z',
        'created_at': '2026-05-06T12:00:00Z',
        'updated_at': '2026-05-06T12:01:00Z',
      },
    };
  }
}

/// Recording [DemoModeMasterSwitchGateway] double. Returns a 2-record
/// `flipped_count: 2` payload on first call; subsequent calls with the
/// same `(operator, location, idempotency-key)` triple return the cached
/// result without re-recording, and a same-key call with a drifted body
/// hash throws an idempotency-key conflict. Tests assert against [calls]
/// to pin the single durable write path through the route.
class FakeDemoModeMasterSwitchGateway implements DemoModeMasterSwitchGateway {
  final List<String> calls = <String>[];
  final Map<String, DemoModeMasterSwitchResult> _responses =
      <String, DemoModeMasterSwitchResult>{};
  final Map<String, String> _hashes = <String, String>{};
  bool alreadyLive = false;

  @override
  Future<DemoModeMasterSwitchResult> flipAllDemoRowsToLive({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required DateTime flippedAt,
    required String idempotencyKey,
    required String requestBodyHash,
  }) async {
    final key = '$operatorId|$locationId|$idempotencyKey';
    final storedHash = _hashes[key];
    if (storedHash != null && storedHash != requestBodyHash) {
      throw const DemoModeMasterSwitchRejected(
        code: 'idempotency_key_conflict',
        message: 'Idempotency-Key was already used for another request',
        statusCode: 409,
      );
    }
    final stored = _responses[key];
    if (stored != null) return stored;
    calls.add(
      'flip:$operatorId:$locationId:$actorUserId:'
      '${flippedAt.toUtc().toIso8601String()}',
    );
    if (alreadyLive) {
      return const DemoModeMasterSwitchResult(
        flippedCount: 0,
        records: <DemoModeRecord>[
          DemoModeRecord(
            operatorId: 'op-1',
            locationId: 'loc-1',
            category: IntegrationCategory.pos,
            isDemo: false,
          ),
        ],
      );
    }
    alreadyLive = true;
    final result = DemoModeMasterSwitchResult(
      flippedCount: 2,
      records: <DemoModeRecord>[
        DemoModeRecord(
          operatorId: operatorId,
          locationId: locationId,
          category: IntegrationCategory.labor,
          isDemo: false,
          flippedToLiveAt: flippedAt,
        ),
        DemoModeRecord(
          operatorId: operatorId,
          locationId: locationId,
          category: IntegrationCategory.pos,
          isDemo: false,
          flippedToLiveAt: flippedAt,
        ),
      ],
    );
    _hashes[key] = requestBodyHash;
    _responses[key] = result;
    return result;
  }
}

/// Issues a real-HTTP GET to [uri] on [client] with a `Bearer token` (or
/// caller-supplied) authorization header, drains the response, and returns
/// the captured status + body.
Future<HttpResult> httpGet(
  HttpClient client,
  Uri uri, {
  String authorization = 'Bearer token',
}) async {
  final request = await client.getUrl(uri);
  request.headers.set(HttpHeaders.authorizationHeader, authorization);
  final response = await request.close();
  final responseBody = await utf8.decodeStream(response);
  return HttpResult(response.statusCode, responseBody);
}

/// Issues a real-HTTP request of [method] to [uri] with an optional JSON
/// body and `Idempotency-Key` header. Encodes [body] as `application/json`
/// and sets `Content-Length`; an empty body is sent header-only so route
/// handlers see the same shape as a no-body PATCH/POST.
Future<HttpResult> httpRequest(
  HttpClient client,
  String method,
  Uri uri, {
  String authorization = 'Bearer token',
  Map<String, Object?> body = const <String, Object?>{},
  String? idempotencyKey,
}) async {
  final request = await client.openUrl(method, uri);
  request.headers.set(HttpHeaders.authorizationHeader, authorization);
  if (idempotencyKey != null) {
    request.headers.set('Idempotency-Key', idempotencyKey);
  }
  if (body.isNotEmpty) {
    final encoded = utf8.encode(jsonEncode(body));
    request.headers.contentType = ContentType.json;
    request.contentLength = encoded.length;
    request.add(encoded);
  }
  final response = await request.close();
  final responseBody = await utf8.decodeStream(response);
  return HttpResult(response.statusCode, responseBody);
}

/// Captured `(statusCode, body)` pair returned by [httpGet] and
/// [httpRequest]. Body is the raw response string — tests `jsonDecode`
/// it themselves when they need structured access.
class HttpResult {
  const HttpResult(this.statusCode, this.body);

  final int statusCode;
  final String body;
}
