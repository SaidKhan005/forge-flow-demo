// Fix #4 / S2 — tests for the admin/cross-tenant business-timing
// resolution route + the `withSystem` repository read it rides on.
//
// This is the admin analogue of S1's
// `test/proxy/operator_routes_get_routes_test.dart` resolution group.
// Coverage (per spec §4 + the slice prompt):
//
//   * Wire-shape: GET
//     `/v1/admin/operators/:op/locations/:loc/business-timing-resolution`
//     returns the FULL ordered candidate list in scope_depth order with
//     scope ancestry + full service-period fields + real timezone +
//     org-unit `path` carried as scope ancestry — nothing dropped.
//   * Isolation / role gate: the cross-tenant read is rejected for a
//     non-admin (operator) actor (403); an admin actor gets the
//     other-operator data; the gateway only ever receives the URL
//     scope + a non-blank audit reason.
//   * Parity: the same `(operatorId, locationId, businessDate)` run
//     through (a) the canonical projector path
//     (`SinkBusinessDateProjector` →
//     `BusinessTimingProfilesRepository.listCandidateProfilesForLocation`
//     → canonical resolver) and (b) the new admin route's candidate
//     list (`...ForSystemLocation`) run through the ONE canonical pure
//     `BusinessTimingProfileResolver` produces an identical
//     `EffectiveBusinessTimingProfile`.
//   * Cross-tenant isolation at the repository seam: the operator path
//     and the system path run BYTE-IDENTICAL SQL (the shared
//     `_candidateChainSql`); the system path additionally elevates the
//     transaction role to `forge_admin` and stamps the bypass audit
//     marker, and an operator actor never reaches that path.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/models/business_timing_profile.dart';
import 'package:forge_and_flow/domain/models/restaurant_timing_config.dart';
import 'package:forge_and_flow/domain/models/service_period_definition.dart';
import 'package:forge_and_flow/domain/services/business_timing_profile_resolver.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/business_timing_profiles_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/business_timing/business_timing_profile_validator.dart';
import 'package:forge_and_flow/services/business_timing/repository_operator_write_gateways.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

const String _kOpA = '11111111-1111-4111-8111-111111111111';
const String _kOpB = '22222222-2222-4222-8222-222222222222';
const String _kLocA = '33333333-3333-4333-8333-333333333333';
const String _kAdmin = '44444444-4444-4444-4444-444444444444';
const String _kOperatorUser = '55555555-5555-5555-5555-555555555555';

void main() {
  group('GET admin business-timing-resolution (HTTP route)', () {
    Future<T> withRealHttp<T>(Future<T> Function() body) async {
      final saved = HttpOverrides.current;
      HttpOverrides.global = null;
      try {
        return await body();
      } finally {
        HttpOverrides.global = saved;
      }
    }

    Future<({
      HttpServer server,
      HttpClient client,
      Uri baseUri,
      _RecordingAdminTimingGateway gateway,
      _SettableVerifier verifier,
    })> spinUp({
      ProxyJwtClaims? initialClaims,
      bool routerConfigured = true,
      bool seedChain = true,
    }) async {
      final verifier = _SettableVerifier();
      verifier.claims = initialClaims ??
          const ProxyJwtClaims(
            userId: _kAdmin,
            operatorId: '',
            locationId: '',
            roles: <String>['super_admin'],
          );
      final guard = ProxyRequestGuard(verifier: verifier);
      final gateway = _RecordingAdminTimingGateway();
      if (seedChain) gateway.seedSystemChain(_threeLevelChain());
      final router = AdminBusinessTimingRouter(
        businessTimingGateway: gateway,
        auditSink: _NoopAuditSink(),
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // ignore: unawaited_futures
      server.listen((request) async {
        try {
          await routeRequest(
            request,
            guard,
            adminBusinessTimingRouter: routerConfigured ? router : null,
          );
        } catch (_) {
          try {
            request.response.statusCode = 500;
            await request.response.close();
          } catch (_) {}
        }
      });
      final client = HttpClient();
      final baseUri =
          Uri.parse('http://${server.address.host}:${server.port}');
      return (
        server: server,
        client: client,
        baseUri: baseUri,
        gateway: gateway,
        verifier: verifier,
      );
    }

    Uri resolutionUri(
      Uri baseUri,
      String operatorId,
      String locationId, {
      String? businessDate,
    }) {
      final path = '/v1/admin/operators/$operatorId'
          '/locations/$locationId/business-timing-resolution';
      final base = baseUri.resolve(path);
      if (businessDate == null) return base;
      return base.replace(
        queryParameters: <String, String>{'business_date': businessDate},
      );
    }

    test('200 returns the 3-level chain in scope_depth order with full '
        'period fields + timezone (wire-shape)', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpGet(
            ctx.client,
            resolutionUri(ctx.baseUri, _kOpB, _kLocA,
                businessDate: '2026-05-10'),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          // Scope is the URL operator/location, never a JWT (admin
          // token carries no tenant).
          expect(body['operatorId'], equals(_kOpB));
          expect(body['locationId'], equals(_kLocA));
          expect(body['businessDate'], equals('2026-05-10'));
          expect(body['ianaTimezone'], equals('America/Toronto'));
          final candidates = body['candidates'] as List<Object?>;
          expect(candidates, hasLength(3));
          final scopeTypes = <Object?>[
            for (final c in candidates)
              (c as Map<Object?, Object?>)['scopeType'],
          ];
          expect(scopeTypes,
              equals(<String>['operator', 'org_unit', 'location']));
          final ranks = <Object?>[
            for (final c in candidates)
              (c as Map<Object?, Object?>)['scopeDepthRank'],
          ];
          expect(ranks, equals(<int>[0, 1, 2]));
          final location = Map<Object?, Object?>.from(
            candidates.last as Map<Object?, Object?>,
          );
          expect(location['scopeLabel'], equals('Flagship'));
          final periods = location['servicePeriods'] as List<Object?>;
          final brunch = Map<Object?, Object?>.from(
            periods.single as Map<Object?, Object?>,
          );
          // Day-restricted period round-trips: Sat + Sun, short label,
          // sort order — nothing dropped on the wire.
          expect(brunch['applicableDays'], equals(<int>[6, 7]));
          expect(brunch['shortLabel'], equals('Brn'));
          expect(brunch['sortOrder'], equals(1));
          // Gateway only ever saw the URL scope + a non-blank reason.
          expect(ctx.gateway.resolveAsSystemCalls, equals(1));
          expect(ctx.gateway.lastOperatorId, equals(_kOpB));
          expect(ctx.gateway.lastLocationId, equals(_kLocA));
          expect(ctx.gateway.lastBusinessDate, equals('2026-05-10'));
          expect(
            (ctx.gateway.lastReason ?? '').trim().isNotEmpty,
            isTrue,
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('200 empty candidate list + null timezone when none seeded',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp(seedChain: false);
        try {
          final response = await _httpGet(
            ctx.client,
            resolutionUri(ctx.baseUri, _kOpB, _kLocA),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['candidates'], isEmpty);
          expect(body['ianaTimezone'], isNull);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('403 — a non-admin (operator) actor cannot reach the '
        'cross-tenant read (isolation)', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(
          initialClaims: const ProxyJwtClaims(
            userId: _kOperatorUser,
            operatorId: _kOpA,
            locationId: _kLocA,
            roles: <String>['operator_owner'],
          ),
        );
        try {
          // Operator A tries to read operator B's chain via the admin
          // path. Must be rejected before the gateway runs.
          final response = await _httpGet(
            ctx.client,
            resolutionUri(ctx.baseUri, _kOpB, _kLocA),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(403));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('permission_denied'));
          expect(ctx.gateway.resolveAsSystemCalls, equals(0));

          // Even reading "their own" operator via the admin path is
          // denied — the admin route is admin-gated, full stop.
          final ownResponse = await _httpGet(
            ctx.client,
            resolutionUri(ctx.baseUri, _kOpA, _kLocA),
            authorization: 'Bearer fake.token',
          );
          expect(ownResponse.statusCode, equals(403));
          expect(ctx.gateway.resolveAsSystemCalls, equals(0));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('ff_support admin gets the other-operator data', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(
          initialClaims: const ProxyJwtClaims(
            userId: _kAdmin,
            operatorId: '',
            locationId: '',
            roles: <String>['ff_support'],
          ),
        );
        try {
          final response = await _httpGet(
            ctx.client,
            resolutionUri(ctx.baseUri, _kOpB, _kLocA),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(200));
          expect(ctx.gateway.resolveAsSystemCalls, equals(1));
          expect(ctx.gateway.lastOperatorId, equals(_kOpB));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('400 invalid_business_date on a malformed query param', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpGet(
            ctx.client,
            resolutionUri(ctx.baseUri, _kOpB, _kLocA,
                businessDate: 'May-10'),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('invalid_business_date'));
          expect(ctx.gateway.resolveAsSystemCalls, equals(0));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('503 when the admin business-timing router is not configured',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp(routerConfigured: false);
        try {
          final response = await _httpGet(
            ctx.client,
            resolutionUri(ctx.baseUri, _kOpB, _kLocA),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(503));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('path parser is disjoint from the admin profile route',
        () async {
      // The resolution path must NOT be parsed as a profile path and
      // vice versa, so the two dispatcher blocks never collide.
      expect(
        isAdminBusinessTimingResolutionPath(
          '/v1/admin/operators/$_kOpB/locations/$_kLocA'
          '/business-timing-resolution',
        ),
        isTrue,
      );
      expect(
        isAdminBusinessTimingResolutionPath(
          '/v1/admin/operators/$_kOpB/business-timing-profiles',
        ),
        isFalse,
      );
      expect(
        AdminBusinessTimingRouter.matches(
          '/v1/admin/operators/$_kOpB/locations/$_kLocA'
          '/business-timing-resolution',
          'GET',
        ),
        isFalse,
      );
    });
  });

  // ─── Parity + repository cross-tenant isolation ──────────────────
  //
  // Exercises the REAL `BusinessTimingProfilesRepository` over a fake
  // `PostgresPool` so the operator-scoped read and the admin
  // system-scoped read run their actual SQL dispatch. The fake pool
  // returns canned rows keyed by the `from public.business_timing_profiles p`
  // SQL header — identical for both paths because S2 extracted the
  // canonical chain into ONE shared SQL constant.
  group('parity + repository isolation', () {
    test('parity: projector path == admin system path → identical '
        'EffectiveBusinessTimingProfile', () async {
      final pool = _FakeProfilesPool();
      pool.seed(
        operatorId: _kOpB,
        locationId: _kLocA,
        timezone: 'America/Toronto',
        rows: _canonicalRows(),
      );
      final repo = BusinessTimingProfilesRepository(
        TenantTransactionWrapper(pool),
      );

      // (a) Canonical projector path: operator-scoped read → blessed
      //     row→profile mapping → canonical resolver.
      final operatorRows = await repo.listCandidateProfilesForLocation(
        operatorId: _kOpB,
        locationId: _kLocA,
        businessDate: '2026-05-10',
      );
      final effectiveA = BusinessTimingProfileResolver.resolve(
        <BusinessTimingProfile>[
          for (final row in operatorRows) _rowToProfile(row),
        ],
      );

      // (b) Admin system path: cross-tenant read via the S2 gateway →
      //     wire JSON → admin client parse → canonical resolver.
      final gateway = RepositoryOperatorBusinessTimingWriteGateway(
        repository: repo,
      );
      final result = await gateway.resolveForLocationAsSystem(
        operatorId: _kOpB,
        locationId: _kLocA,
        businessDate: '2026-05-10',
        reason: 'admin.business_timing.resolution_read',
      );
      final wire = jsonDecode(jsonEncode(result.toJson()))
          as Map<String, Object?>;
      final effectiveB = BusinessTimingProfileResolver.resolve(
        _candidatesFromWire(wire),
      );

      expect(effectiveB.businessTimezone,
          equals(effectiveA.businessTimezone));
      expect(effectiveB.businessDayStartLocalTime,
          equals(effectiveA.businessDayStartLocalTime));
      expect(effectiveB.weekStartDay, equals(effectiveA.weekStartDay));
      expect(effectiveB.resolvedScope, equals(effectiveA.resolvedScope));
      expect(effectiveB.resolvedScopeId,
          equals(effectiveA.resolvedScopeId));
      expect(
        effectiveB.shiftCloseAuthority,
        equals(effectiveA.shiftCloseAuthority),
      );
      expect(
        effectiveB.servicePeriodDefinitions.length,
        equals(effectiveA.servicePeriodDefinitions.length),
      );
      for (var i = 0;
          i < effectiveA.servicePeriodDefinitions.length;
          i++) {
        final a = effectiveA.servicePeriodDefinitions[i];
        final b = effectiveB.servicePeriodDefinitions[i];
        expect(b.id, equals(a.id));
        expect(b.label, equals(a.label));
        expect(b.shortLabel, equals(a.shortLabel));
        expect(b.sortOrder, equals(a.sortOrder));
        expect(b.startLocalTime, equals(a.startLocalTime));
        expect(b.endLocalTime, equals(a.endLocalTime));
        expect(b.rollsPastMidnight, equals(a.rollsPastMidnight));
        expect(b.applicableDays, equals(a.applicableDays));
      }
    });

    test('repository isolation: system path elevates role + stamps the '
        'bypass audit marker; operator path does not', () async {
      final pool = _FakeProfilesPool();
      pool.seed(
        operatorId: _kOpB,
        locationId: _kLocA,
        timezone: 'America/Toronto',
        rows: _canonicalRows(),
      );
      final repo = BusinessTimingProfilesRepository(
        TenantTransactionWrapper(pool),
      );

      await repo.listCandidateProfilesForLocation(
        operatorId: _kOpB,
        locationId: _kLocA,
        businessDate: '2026-05-10',
      );
      // Operator path: tenant SET LOCAL on `app.operator_id`, the
      // audit marker pinned to the literal `'tenant'` (NOT a bound
      // `system:` value), and NEVER the `forge_admin` role escalation.
      expect(
        pool.executedSql.any((s) => s.contains('set local role forge_admin')),
        isFalse,
        reason: 'operator path must never escalate to forge_admin',
      );
      expect(
        pool.executedSql.any((s) => s.contains('app.operator_id')),
        isTrue,
        reason: 'operator path is tenant-scoped via SET LOCAL',
      );
      // The tenant path stamps the literal `'tenant'` audit marker
      // inline (no bind param), so it never lands in the bound-value
      // capture the system path uses.
      expect(pool.bypassAuditValues, isEmpty);

      pool.executedSql.clear();
      pool.bypassAuditValues.clear();

      await repo.listCandidateProfilesForSystemLocation(
        operatorId: _kOpB,
        locationId: _kLocA,
        businessDate: '2026-05-10',
        reason: 'admin.business_timing.resolution_read',
      );
      // System path: the sanctioned admin bypass — role escalation +
      // audit marker carrying the reason. No tenant SET LOCAL.
      expect(
        pool.executedSql.any((s) => s.contains('set local role forge_admin')),
        isTrue,
      );
      expect(
        pool.executedSql.any((s) => s.contains('app.bypass_rls_audit')),
        isTrue,
      );
      expect(
        pool.bypassAuditValues.single,
        equals('system:admin.business_timing.resolution_read'),
      );
      expect(
        pool.executedSql.any((s) => s.contains('app.operator_id')),
        isFalse,
      );
    });

    test('repository isolation: both paths run BYTE-IDENTICAL '
        'candidate-chain SQL', () async {
      final pool = _FakeProfilesPool();
      pool.seed(
        operatorId: _kOpB,
        locationId: _kLocA,
        timezone: 'America/Toronto',
        rows: _canonicalRows(),
      );
      final repo = BusinessTimingProfilesRepository(
        TenantTransactionWrapper(pool),
      );

      await repo.listCandidateProfilesForLocation(
        operatorId: _kOpB,
        locationId: _kLocA,
        businessDate: '2026-05-10',
      );
      final operatorSql = pool.candidateChainSql.single;
      pool.candidateChainSql.clear();

      await repo.listCandidateProfilesForSystemLocation(
        operatorId: _kOpB,
        locationId: _kLocA,
        businessDate: '2026-05-10',
        reason: 'admin.business_timing.resolution_read',
      );
      final systemSql = pool.candidateChainSql.single;

      expect(systemSql, equals(operatorSql));
    });
  });
}

// ─── Canonical fixtures ─────────────────────────────────────────────

List<_CannedRow> _canonicalRows() => <_CannedRow>[
      _CannedRow(
        scopeType: 'operator',
        scopeId: _kOpB,
        businessDayStartLocalTime: '04:00',
        weekStartDay: 1,
        periods: const <Map<String, Object?>>[
          <String, Object?>{
            'service_period_key': 'all_day',
            'label': 'All day',
            'short_label': 'All',
            'sort_order': 1,
            'start_local_time': '06:00',
            'end_local_time': '22:00',
            'rolls_past_midnight': false,
            'applicable_weekdays': <int>[1, 2, 3, 4, 5, 6, 7],
          },
        ],
      ),
      _CannedRow(
        scopeType: 'org_unit',
        scopeId: '66666666-6666-4666-8666-666666666666',
        businessDayStartLocalTime: '04:00',
        weekStartDay: 1,
        periods: const <Map<String, Object?>>[
          <String, Object?>{
            'service_period_key': 'lunch',
            'label': 'Lunch',
            'short_label': 'Lun',
            'sort_order': 1,
            'start_local_time': '11:00',
            'end_local_time': '15:00',
            'rolls_past_midnight': false,
            'applicable_weekdays': <int>[1, 2, 3, 4, 5, 6, 7],
          },
        ],
      ),
      _CannedRow(
        scopeType: 'location',
        scopeId: _kLocA,
        businessDayStartLocalTime: '05:00',
        weekStartDay: 1,
        periods: const <Map<String, Object?>>[
          <String, Object?>{
            'service_period_key': 'brunch',
            'label': 'Weekend Brunch',
            'short_label': 'Brn',
            'sort_order': 1,
            'start_local_time': '09:00',
            'end_local_time': '14:00',
            'rolls_past_midnight': false,
            'applicable_weekdays': <int>[6, 7],
          },
        ],
      ),
    ];

List<OperatorBusinessTimingResolutionCandidate> _threeLevelChain() {
  return <OperatorBusinessTimingResolutionCandidate>[
    OperatorBusinessTimingResolutionCandidate(
      profileId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      scopeType: 'operator',
      scopeId: _kOpB,
      scopeLabel: 'Operator default',
      scopeDepthRank: 0,
      ianaTimezone: 'America/Toronto',
      effectiveAtBusinessDate: '2026-01-01',
      weekStartDay: 'monday',
      businessDayStartLocal: '04:00',
      servicePeriods: const <OperatorBusinessTimingServicePeriodRecord>[
        OperatorBusinessTimingServicePeriodRecord(
          key: 'all_day',
          label: 'All day',
          startLocal: '06:00',
          endLocal: '22:00',
          rollsPastMidnight: false,
          shortLabel: 'All',
          sortOrder: 1,
          applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
        ),
      ],
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    ),
    OperatorBusinessTimingResolutionCandidate(
      profileId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      scopeType: 'org_unit',
      scopeId: '66666666-6666-4666-8666-666666666666',
      scopeLabel: 'East region',
      scopeDepthRank: 1,
      ianaTimezone: 'America/Toronto',
      effectiveAtBusinessDate: '2026-02-01',
      weekStartDay: 'monday',
      businessDayStartLocal: '04:00',
      servicePeriods: const <OperatorBusinessTimingServicePeriodRecord>[
        OperatorBusinessTimingServicePeriodRecord(
          key: 'lunch',
          label: 'Lunch',
          startLocal: '11:00',
          endLocal: '15:00',
          rollsPastMidnight: false,
          shortLabel: 'Lun',
          sortOrder: 1,
          applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
        ),
      ],
      createdAt: DateTime.utc(2026, 2, 1),
      updatedAt: DateTime.utc(2026, 2, 1),
    ),
    OperatorBusinessTimingResolutionCandidate(
      profileId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      scopeType: 'location',
      scopeId: _kLocA,
      scopeLabel: 'Flagship',
      scopeDepthRank: 2,
      ianaTimezone: 'America/Toronto',
      effectiveAtBusinessDate: '2026-03-01',
      weekStartDay: 'monday',
      businessDayStartLocal: '05:00',
      servicePeriods: const <OperatorBusinessTimingServicePeriodRecord>[
        OperatorBusinessTimingServicePeriodRecord(
          key: 'brunch',
          label: 'Weekend Brunch',
          startLocal: '09:00',
          endLocal: '14:00',
          rollsPastMidnight: false,
          shortLabel: 'Brn',
          sortOrder: 1,
          applicableDays: <int>[6, 7],
        ),
      ],
      createdAt: DateTime.utc(2026, 3, 1),
      updatedAt: DateTime.utc(2026, 3, 1),
    ),
  ];
}

/// Blessed row→profile mapping (mirrors
/// `sink_business_date_projector.dart` byte-for-byte in shape) so the
/// parity test compares against the canonical projector semantics.
BusinessTimingProfile _rowToProfile(BusinessTimingProfileRow row) {
  return BusinessTimingProfile(
    profileId: row.profileId,
    scope: BusinessTimingScope.fromValue(row.scopeType),
    scopeId: row.scopeId,
    businessTimezone: row.locationTimezone,
    businessDayStartLocalTime: row.businessDayStartLocalTime,
    weekStartDay: row.weekStartDay,
    servicePeriodDefinitions: row.servicePeriods.isEmpty
        ? null
        : <ServicePeriodDefinition>[
            for (final period in row.servicePeriods)
              ServicePeriodDefinition(
                id: period.servicePeriodKey,
                label: period.label,
                shortLabel: period.shortLabel,
                sortOrder: period.sortOrder,
                startLocalTime: period.startLocalTime,
                endLocalTime: period.endLocalTime,
                rollsPastMidnight: period.rollsPastMidnight,
                applicableDays: period.applicableWeekdays,
              ),
          ],
    shiftCloseAuthority: ShiftCloseAuthority.fromValue(row.closeAuthority),
    localCloseFallback: row.localCloseFallbackTime,
  );
}

List<BusinessTimingProfile> _candidatesFromWire(Map<String, Object?> wire) {
  final candidates = (wire['candidates'] as List).cast<Object?>();
  final topTimezone = wire['ianaTimezone'] as String?;
  return <BusinessTimingProfile>[
    for (final raw in candidates)
      () {
        final c = (raw as Map).cast<String, Object?>();
        final periods = (c['servicePeriods'] as List).cast<Object?>();
        return BusinessTimingProfile(
          profileId: c['profileId'] as String,
          scope: BusinessTimingScope.fromValue(c['scopeType'] as String),
          scopeId: c['scopeId'] as String,
          businessTimezone:
              (c['ianaTimezone'] as String?) ?? topTimezone,
          businessDayStartLocalTime: c['businessDayStartLocal'] as String,
          weekStartDay: _weekStartToInt(c['weekStartDay'] as String),
          servicePeriodDefinitions: periods.isEmpty
              ? null
              : <ServicePeriodDefinition>[
                  for (final p in periods)
                    () {
                      final m = (p as Map).cast<String, Object?>();
                      return ServicePeriodDefinition(
                        id: m['key'] as String,
                        label: m['label'] as String,
                        shortLabel: m['shortLabel'] as String,
                        sortOrder: (m['sortOrder'] as num).toInt(),
                        startLocalTime: m['startLocal'] as String,
                        endLocalTime: m['endLocal'] as String,
                        rollsPastMidnight: m['rollsPastMidnight'] as bool,
                        applicableDays: <int>[
                          for (final d in (m['applicableDays'] as List))
                            (d as num).toInt(),
                        ],
                      );
                    }(),
                ],
          shiftCloseAuthority: ShiftCloseAuthority.appLocalCutoffFallback,
          localCloseFallback: null,
        );
      }(),
  ];
}

int _weekStartToInt(String value) {
  switch (value) {
    case 'monday':
      return 1;
    case 'tuesday':
      return 2;
    case 'wednesday':
      return 3;
    case 'thursday':
      return 4;
    case 'friday':
      return 5;
    case 'saturday':
      return 6;
    case 'sunday':
      return 7;
  }
  return 1;
}

// ─── Test doubles ───────────────────────────────────────────────────

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

class _NoopAuditSink implements OperatorWriteAuditSink {
  @override
  Future<void> record({
    required String operatorId,
    required String actorUserId,
    required String actorKind,
    required String eventKind,
    required Map<String, Object?> payload,
    required DateTime occurredAt,
  }) async {}
}

class _RecordingAdminTimingGateway
    implements OperatorBusinessTimingWriteGateway {
  int resolveAsSystemCalls = 0;
  String? lastOperatorId;
  String? lastLocationId;
  String? lastBusinessDate;
  String? lastReason;
  List<OperatorBusinessTimingResolutionCandidate>? _chain;

  void seedSystemChain(
    List<OperatorBusinessTimingResolutionCandidate> chain,
  ) {
    _chain = chain;
  }

  @override
  Future<OperatorBusinessTimingResolutionResult> resolveForLocationAsSystem({
    required String operatorId,
    required String locationId,
    required String businessDate,
    required String reason,
  }) async {
    resolveAsSystemCalls += 1;
    lastOperatorId = operatorId;
    lastLocationId = locationId;
    lastBusinessDate = businessDate;
    lastReason = reason;
    final chain =
        _chain ?? const <OperatorBusinessTimingResolutionCandidate>[];
    return OperatorBusinessTimingResolutionResult(
      operatorId: operatorId,
      locationId: locationId,
      businessDate: businessDate,
      ianaTimezone: chain.isEmpty ? null : chain.first.ianaTimezone,
      candidates: chain,
    );
  }

  @override
  Future<OperatorBusinessTimingResolutionResult> resolveForLocation({
    required String operatorId,
    required String locationId,
    required String businessDate,
    String? actorUserId,
  }) async {
    return OperatorBusinessTimingResolutionResult(
      operatorId: operatorId,
      locationId: locationId,
      businessDate: businessDate,
      ianaTimezone: null,
      candidates: const <OperatorBusinessTimingResolutionCandidate>[],
    );
  }

  @override
  Future<OperatorBusinessTimingProfileRecord> createProfile({
    required String operatorId,
    required String actorUserId,
    required String idempotencyKey,
    required ValidatedBusinessTimingProfile validated,
    required String adminReason,
  }) async =>
      throw UnimplementedError();

  @override
  Future<OperatorBusinessTimingProfileRecord?> loadProfile({
    required String operatorId,
    required String profileId,
  }) async =>
      null;

  @override
  Future<List<OperatorBusinessTimingProfileRecord>> listProfiles({
    required String operatorId,
  }) async =>
      const <OperatorBusinessTimingProfileRecord>[];

  @override
  Future<OperatorBusinessTimingProfileRecord> replaceServicePeriodSet({
    required String operatorId,
    required String actorUserId,
    required String idempotencyKey,
    required String profileId,
    required List<ValidatedServicePeriod> mergedSet,
    required String eventKind,
    required Map<String, Object?> auditPayload,
    required String adminReason,
  }) async =>
      throw UnimplementedError();

  @override
  Future<OperatorBusinessTimingProfileRecord> updateProfile({
    required String operatorId,
    required String actorUserId,
    required String idempotencyKey,
    required String profileId,
    required ValidatedBusinessTimingProfile validated,
    required String adminReason,
  }) async =>
      throw UnimplementedError();
}

class _CannedRow {
  _CannedRow({
    required this.scopeType,
    required this.scopeId,
    required this.businessDayStartLocalTime,
    required this.weekStartDay,
    required this.periods,
  });

  final String scopeType;
  final String scopeId;
  final String businessDayStartLocalTime;
  final int weekStartDay;
  final List<Map<String, Object?>> periods;

  PostgresRow toRow({required String locationTimezone}) {
    final pid = '00000000-0000-4000-8000-'
        '${scopeId.substring(scopeId.length - 12)}';
    return <String, Object?>{
      'profile_id': pid,
      'operator_id': _kOpB,
      'scope_type': scopeType,
      'scope_id': scopeId,
      'display_name': null,
      'business_day_start_local_time': businessDayStartLocalTime,
      'week_start_day': weekStartDay,
      'close_authority': 'app_local_cutoff_fallback',
      'local_close_fallback_time': null,
      'effective_from_business_date': '2026-01-01',
      'effective_until_business_date': null,
      'supersedes_profile_id': null,
      'created_by': null,
      'updated_by': null,
      'created_at': DateTime.utc(2026, 1, 1),
      'updated_at': DateTime.utc(2026, 1, 1),
      'location_timezone': locationTimezone,
      'service_periods': <Map<String, Object?>>[
        for (final p in periods)
          <String, Object?>{
            'service_period_id':
                '99999999-9999-4999-8999-999999999999',
            'operator_id': _kOpB,
            'profile_id': pid,
            ...p,
          },
      ],
    };
  }
}

class _FakeProfilesPool implements PostgresPool {
  final Map<String, List<_CannedRow>> _byKey = <String, List<_CannedRow>>{};
  final Map<String, String> _tz = <String, String>{};
  final List<String> executedSql = <String>[];
  final List<String> candidateChainSql = <String>[];
  final List<String> bypassAuditValues = <String>[];

  void seed({
    required String operatorId,
    required String locationId,
    required String timezone,
    required List<_CannedRow> rows,
  }) {
    final key = '$operatorId|$locationId';
    _byKey[key] = rows;
    _tz[key] = timezone;
  }

  @override
  Future<PostgresTransaction> beginTransaction() async => _FakeTx(this);
}

class _FakeTx implements PostgresTransaction {
  _FakeTx(this.pool);

  final _FakeProfilesPool pool;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (sql.contains('select set_config')) {
      return const <PostgresRow>[];
    }
    if (sql.contains('from public.business_timing_profiles p')) {
      pool.candidateChainSql.add(sql);
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final key = '$operatorId|$locationId';
      final tz = pool._tz[key] ?? 'UTC';
      final rows = pool._byKey[key] ?? const <_CannedRow>[];
      return <PostgresRow>[
        for (final row in rows) row.toRow(locationTimezone: tz),
      ];
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    pool.executedSql.add(sql);
    // The system path binds the audit value via `@value`
    // (`system:<reason>`); the tenant path inlines the literal
    // `'tenant'` with no bind parameter. Only the bound system value
    // is interesting for the isolation assertion.
    if (sql.contains('app.bypass_rls_audit')) {
      final value = parameters['value'];
      if (value is String) pool.bypassAuditValues.add(value);
    }
    if (sql.contains('app.operator_id')) {
      // Record the canonical tenant SET LOCAL marker so the isolation
      // test can assert the operator path used it.
      pool.executedSql.add('app.operator_id');
    }
    return 0;
  }

  @override
  Future<void> commit() async {}

  @override
  Future<void> rollback() async {}
}

class _HttpResponseSnapshot {
  const _HttpResponseSnapshot({required this.statusCode, required this.body});
  final int statusCode;
  final String body;
}

Future<_HttpResponseSnapshot> _httpGet(
  HttpClient client,
  Uri uri, {
  required String authorization,
}) async {
  final request = await client.openUrl('GET', uri);
  request.persistentConnection = false;
  request.headers.set(HttpHeaders.authorizationHeader, authorization);
  final response = await request.close();
  final responseBody = await response.transform(utf8.decoder).join();
  return _HttpResponseSnapshot(
    statusCode: response.statusCode,
    body: responseBody,
  );
}
