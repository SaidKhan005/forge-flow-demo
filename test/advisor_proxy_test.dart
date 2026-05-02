// 11a.10a — Advisor proxy scaffold unit + smoke tests.
//
// Coverage matrix:
//   - ProxyConfig: required-secret validation, loaded-name diagnostics,
//     no value leakage in toString or exception messages.
//   - extractBearerToken: null / blank / non-bearer / valid.
//   - ProxyRequestGuard: missing auth (401), bad bearer (401), verifier
//     failure (401), missing operator/location scope (403), happy path.
//   - ScaffoldRejectingJwtVerifier: hard-fail-closed default.
//   - HTTP scaffold: spins up a local HttpServer on port 0 and sends
//     real loopback requests through `routeRequest`. No external
//     network, no provider/DB calls.
//
// Test placeholder values are obviously synthetic ("placeholder-...")
// and are never written to test stdout — assertions only check shape.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/services/advisor_response_cache.dart';
import 'package:forge_and_flow/domain/services/circuit_breaker.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/auth/auth_session_ledger_writer.dart';
import 'package:forge_and_flow/services/auth/firebase_admin_auth_client.dart';
import 'package:pointycastle/pointycastle.dart' as pc;

import '../tool/advisor_proxy/advisor_proxy.dart';

void main() {
  group('ProxyConfig.fromEnvironment', () {
    Map<String, String> environmentWithAllSecrets({String? port}) {
      return <String, String>{
        ProxySecretNames.anthropicApiKey: 'placeholder-anthropic',
        ProxySecretNames.voyageApiKey: 'placeholder-voyage',
        ProxySecretNames.postgresUrl: 'placeholder-postgres-url',
        ProxySecretNames.postgresAdminUrl: 'placeholder-postgres-admin-url',
        ProxySecretNames.firebaseWebApiKey: 'placeholder-firebase-web-api-key',
        ProxySecretNames.servicePrincipalJwtSecret:
            'placeholder-service-principal-jwt-secret',
        if (port != null) 'PORT': port,
      };
    }

    test('loads all required secrets and reports their names only', () {
      final config = ProxyConfig.fromEnvironment(
        environmentWithAllSecrets(port: '9090'),
      );

      expect(config.port, equals(9090));
      expect(
        config.loadedSecretNames,
        containsAll(<String>[
          ProxySecretNames.anthropicApiKey,
          ProxySecretNames.voyageApiKey,
          ProxySecretNames.postgresUrl,
          ProxySecretNames.postgresAdminUrl,
          ProxySecretNames.firebaseWebApiKey,
          ProxySecretNames.servicePrincipalJwtSecret,
        ]),
      );
      expect(config.hasSecretFor(ProxySecretNames.anthropicApiKey), isTrue);
    });

    test('defaults port to 8080 when PORT is missing or invalid', () {
      final missing = ProxyConfig.fromEnvironment(environmentWithAllSecrets());
      final blank = ProxyConfig.fromEnvironment(
        environmentWithAllSecrets(port: '   '),
      );
      final negative = ProxyConfig.fromEnvironment(
        environmentWithAllSecrets(port: '-7'),
      );
      final huge = ProxyConfig.fromEnvironment(
        environmentWithAllSecrets(port: '70000'),
      );
      final notNumeric = ProxyConfig.fromEnvironment(
        environmentWithAllSecrets(port: 'eighty'),
      );

      for (final config in <ProxyConfig>[
        missing,
        blank,
        negative,
        huge,
        notNumeric,
      ]) {
        expect(config.port, equals(8080));
      }
    });

    test('throws ProxyConfigError listing missing secret names', () {
      final partial = <String, String>{
        ProxySecretNames.anthropicApiKey: 'placeholder-anthropic',
        // VOYAGE_API_KEY missing
        ProxySecretNames.postgresUrl: 'placeholder-url',
        ProxySecretNames.postgresAdminUrl: '   ', // blank counts
        // FIREBASE_WEB_API_KEY missing
        // SERVICE_PRINCIPAL_JWT_SECRET missing
      };

      Object? thrown;
      try {
        ProxyConfig.fromEnvironment(partial);
      } catch (error) {
        thrown = error;
      }

      expect(thrown, isA<ProxyConfigError>());
      final error = thrown! as ProxyConfigError;
      expect(
        error.missingSecretNames,
        containsAll(<String>[
          ProxySecretNames.voyageApiKey,
          ProxySecretNames.postgresAdminUrl,
          ProxySecretNames.firebaseWebApiKey,
          ProxySecretNames.servicePrincipalJwtSecret,
        ]),
      );
      expect(
        error.missingSecretNames,
        isNot(contains(ProxySecretNames.anthropicApiKey)),
      );
      expect(error.message, contains('missing'));
      expect(error.message, contains(ProxySecretNames.voyageApiKey));
    });

    test('toString and ProxyConfigError never echo secret values', () {
      // Marker token chosen so the assertion catches any accidental
      // echo even in partial/derived forms.
      const marker = 'do-not-leak-this-marker-token';
      final environment = <String, String>{
        ProxySecretNames.anthropicApiKey: marker,
        ProxySecretNames.voyageApiKey: marker,
        ProxySecretNames.postgresUrl: marker,
        ProxySecretNames.postgresAdminUrl: marker,
        ProxySecretNames.firebaseWebApiKey: marker,
        ProxySecretNames.servicePrincipalJwtSecret: marker,
      };

      final config = ProxyConfig.fromEnvironment(environment);
      expect(config.toString(), isNot(contains(marker)));
      expect(config.toString(), contains(ProxySecretNames.anthropicApiKey));

      // Missing-secret exception path also must not leak partial values.
      Object? thrown;
      try {
        ProxyConfig.fromEnvironment(<String, String>{
          ProxySecretNames.anthropicApiKey: marker,
          // others missing
        });
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<ProxyConfigError>());
      expect(thrown.toString(), isNot(contains(marker)));
    });

    test('secretFor returns the loaded value but is the only accessor that '
        'returns it (callers must not log it)', () {
      final config = ProxyConfig.fromEnvironment(environmentWithAllSecrets());

      // Smoke: the value comes back through the explicit accessor —
      // no toString / no JSON / no iteration. Test reads it once and
      // does not write it anywhere.
      final value = config.secretFor(ProxySecretNames.anthropicApiKey);
      expect(value.isNotEmpty, isTrue);

      expect(
        () => config.secretFor('NEVER_REGISTERED_SECRET'),
        throwsStateError,
      );
    });

    group('Phase 11A.4c — GCP / Cloud Run config is all-or-nothing', () {
      test('all three unset → boots cleanly (dev / scaffold path)', () {
        final config = ProxyConfig.fromEnvironment(environmentWithAllSecrets());
        expect(config.gcpProjectId, isNull);
        expect(config.cloudRunRegion, isNull);
        expect(config.cloudRunServiceName, isNull);
      });

      test('all three set → boots cleanly with the values trimmed', () {
        final env = environmentWithAllSecrets()
          ..[ProxyConfigNames.gcpProjectId] = 'forge-flow-prod'
          ..[ProxyConfigNames.cloudRunRegion] = 'northamerica-northeast2'
          ..[ProxyConfigNames.cloudRunServiceName] = 'forge-flow-advisor-proxy';

        final config = ProxyConfig.fromEnvironment(env);

        expect(config.gcpProjectId, equals('forge-flow-prod'));
        expect(config.cloudRunRegion, equals('northamerica-northeast2'));
        expect(
          config.cloudRunServiceName,
          equals('forge-flow-advisor-proxy'),
        );
      });

      test('only GCP_PROJECT_ID set → throws ProxyConfigError listing the '
          'two missing names (would silently skip Cloud Run restarts)', () {
        final env = environmentWithAllSecrets()
          ..[ProxyConfigNames.gcpProjectId] = 'forge-flow-prod';

        Object? thrown;
        try {
          ProxyConfig.fromEnvironment(env);
        } catch (error) {
          thrown = error;
        }
        expect(thrown, isA<ProxyConfigError>());
        final error = thrown! as ProxyConfigError;
        expect(
          error.missingSecretNames,
          containsAll(<String>[
            ProxyConfigNames.cloudRunRegion,
            ProxyConfigNames.cloudRunServiceName,
          ]),
        );
        expect(error.missingSecretNames, hasLength(2));
        expect(error.message, contains('GCP / Cloud Run config is partial'));
      });

      test('CLOUD_RUN_REGION set without GCP_PROJECT_ID → throws', () {
        final env = environmentWithAllSecrets()
          ..[ProxyConfigNames.cloudRunRegion] = 'northamerica-northeast2';

        expect(
          () => ProxyConfig.fromEnvironment(env),
          throwsA(isA<ProxyConfigError>()),
        );
      });

      test('two of three set → still throws, names the missing one', () {
        final env = environmentWithAllSecrets()
          ..[ProxyConfigNames.gcpProjectId] = 'p'
          ..[ProxyConfigNames.cloudRunRegion] = 'r';
        // CLOUD_RUN_SERVICE_NAME deliberately missing.

        Object? thrown;
        try {
          ProxyConfig.fromEnvironment(env);
        } catch (error) {
          thrown = error;
        }
        expect(thrown, isA<ProxyConfigError>());
        final error = thrown! as ProxyConfigError;
        expect(
          error.missingSecretNames,
          equals(<String>[ProxyConfigNames.cloudRunServiceName]),
        );
      });

      test('blank-string values count as unset', () {
        final env = environmentWithAllSecrets()
          ..[ProxyConfigNames.gcpProjectId] = '   '
          ..[ProxyConfigNames.cloudRunRegion] = 'r'
          ..[ProxyConfigNames.cloudRunServiceName] = 's';

        Object? thrown;
        try {
          ProxyConfig.fromEnvironment(env);
        } catch (error) {
          thrown = error;
        }
        expect(thrown, isA<ProxyConfigError>());
        final error = thrown! as ProxyConfigError;
        expect(
          error.missingSecretNames,
          equals(<String>[ProxyConfigNames.gcpProjectId]),
        );
      });
    });
  });

  group('extractBearerToken', () {
    test('returns null for missing / blank / non-bearer headers', () {
      expect(extractBearerToken(null), isNull);
      expect(extractBearerToken(''), isNull);
      expect(extractBearerToken('Basic dXNlcjpwYXNz'), isNull);
      // Case-sensitive per RFC 6750.
      expect(extractBearerToken('bearer abcd'), isNull);
      // Empty token after the prefix.
      expect(extractBearerToken('Bearer '), isNull);
      expect(extractBearerToken('Bearer    '), isNull);
    });

    test('extracts and trims the bearer token portion', () {
      expect(extractBearerToken('Bearer abc.def.ghi'), equals('abc.def.ghi'));
      expect(
        extractBearerToken('Bearer   token-with-trailing-spaces   '),
        equals('token-with-trailing-spaces'),
      );
    });
  });

  group('ProxyRequestGuard.requireOperatorContext', () {
    test('rejects missing Authorization with 401', () async {
      final guard = ProxyRequestGuard(verifier: _AlwaysOkVerifier());

      ProxyAuthError? thrown;
      try {
        await guard.requireOperatorContext(authorizationHeader: null);
      } on ProxyAuthError catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      expect(thrown!.statusCode, equals(401));
      expect(thrown.message, contains('Authorization'));
    });

    test('rejects malformed bearer with 401', () async {
      final guard = ProxyRequestGuard(verifier: _AlwaysOkVerifier());

      ProxyAuthError? thrown;
      try {
        await guard.requireOperatorContext(
          authorizationHeader: 'Basic dXNlcjpwYXNz',
        );
      } on ProxyAuthError catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      expect(thrown!.statusCode, equals(401));
    });

    test('translates verifier failure into 401', () async {
      final guard = ProxyRequestGuard(
        verifier: _RaisingVerifier('signature mismatch'),
      );

      ProxyAuthError? thrown;
      try {
        await guard.requireOperatorContext(
          authorizationHeader: 'Bearer fake.token.value',
        );
      } on ProxyAuthError catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      expect(thrown!.statusCode, equals(401));
      expect(thrown.message, contains('verification failed'));
      expect(thrown.message, contains('signature mismatch'));
    });

    test('rejects verified token without operator scope (403)', () async {
      final guard = ProxyRequestGuard(
        verifier: _FixedClaimsVerifier(
          const ProxyJwtClaims(
            userId: 'user_123',
            operatorId: null,
            locationId: 'loc_999',
            roles: <String>[],
          ),
        ),
      );

      ProxyAuthError? thrown;
      try {
        await guard.requireOperatorContext(
          authorizationHeader: 'Bearer fake.token.value',
        );
      } on ProxyAuthError catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      expect(thrown!.statusCode, equals(403));
      expect(thrown.message, contains('operator'));
    });

    test('rejects verified token without location scope (403)', () async {
      final guard = ProxyRequestGuard(
        verifier: _FixedClaimsVerifier(
          const ProxyJwtClaims(
            userId: 'user_123',
            operatorId: 'op_777',
            locationId: '',
            roles: <String>['advisor.read'],
          ),
        ),
      );

      ProxyAuthError? thrown;
      try {
        await guard.requireOperatorContext(
          authorizationHeader: 'Bearer fake.token.value',
        );
      } on ProxyAuthError catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      expect(thrown!.statusCode, equals(403));
    });

    test('happy path returns scoped OperatorContext with userId / operator / '
        'location / roles', () async {
      final guard = ProxyRequestGuard(
        verifier: _FixedClaimsVerifier(
          const ProxyJwtClaims(
            userId: 'user_123',
            operatorId: 'op_777',
            locationId: 'loc_999',
            roles: <String>['advisor.read', 'methodology.read'],
          ),
        ),
      );

      final context = await guard.requireOperatorContext(
        authorizationHeader: 'Bearer fake.token.value',
      );

      expect(context.userId, equals('user_123'));
      expect(context.operatorId, equals('op_777'));
      expect(context.locationId, equals('loc_999'));
      expect(
        context.roles,
        equals(<String>['advisor.read', 'methodology.read']),
      );
      expect(context.hasRole('advisor.read'), isTrue);
      expect(context.hasRole('admin.write'), isFalse);
    });

    test(
      'verified claims path allows global admin tokens without tenant scope',
      () async {
        final guard = ProxyRequestGuard(
          verifier: _FixedClaimsVerifier(
            const ProxyJwtClaims(
              userId: 'admin_user',
              operatorId: null,
              locationId: null,
              roles: <String>['super_admin'],
            ),
          ),
        );

        final claims = await guard.requireVerifiedClaims(
          authorizationHeader: 'Bearer fake.token.value',
        );

        expect(claims.userId, equals('admin_user'));
        expect(claims.operatorId, isNull);
        expect(claims.locationId, isNull);
        expect(claims.roles, contains('super_admin'));
      },
    );
  });

  group('ProxyUsageGuard (11a.10b)', () {
    OperatorContext operatorScope() => const OperatorContext(
      userId: 'user_x',
      operatorId: 'op_777',
      locationId: 'loc_999',
      roles: <String>['advisor.read'],
    );

    test('PolicyTier.launch defaults are non-zero and machine-usable', () {
      const tier = PolicyTier.launch;
      expect(tier.id, isNotEmpty);
      expect(tier.maxRequestTokens, greaterThan(0));
      expect(tier.maxRequestsPerMinute, greaterThan(0));
      expect(tier.maxMonthlyCostCents, greaterThan(0));
      expect(tier.requestTimeoutSeconds, greaterThan(0));
      expect(tier.maxOutputTokens, greaterThan(0));
    });

    test('over-token request refuses BEFORE the store is queried', () async {
      final store = _RecordingStore();
      final guard = ProxyUsageGuard(
        store: store,
        tierResolver: const FixedLaunchTierResolver(),
      );

      UsageRefusal? thrown;
      try {
        await guard.requireAllowed(
          operator: operatorScope(),
          estimate: UsageEstimate(
            requestTokens: PolicyTier.launch.maxRequestTokens + 1,
          ),
        );
      } on UsageRefusal catch (refusal) {
        thrown = refusal;
      }

      expect(thrown, isNotNull);
      expect(thrown!.code, equals('request_too_large'));
      expect(thrown.statusCode, equals(413));
      expect(thrown.details['tier_id'], equals('launch'));
      expect(
        thrown.details['cap_request_tokens'],
        equals(PolicyTier.launch.maxRequestTokens),
      );
      // Acceptance: refuse before any store/provider work.
      expect(store.currentUsageCalls, equals(0));
    });

    test(
      'per-minute cap surfaces 429 rate_limited with machine-readable JSON',
      () async {
        final store = _FixedSnapshotStore(
          snapshot: UsageSnapshot(
            requestsThisMinute: PolicyTier.launch.maxRequestsPerMinute,
            costCentsThisMonth: 0,
            minuteBucketStart: DateTime.utc(2026, 4, 25, 12, 0),
            monthBucketStart: DateTime.utc(2026, 4, 1),
          ),
        );
        final guard = ProxyUsageGuard(
          store: store,
          tierResolver: const FixedLaunchTierResolver(),
        );

        UsageRefusal? thrown;
        try {
          await guard.requireAllowed(
            operator: operatorScope(),
            estimate: const UsageEstimate(requestTokens: 100),
          );
        } on UsageRefusal catch (refusal) {
          thrown = refusal;
        }

        expect(thrown, isNotNull);
        expect(thrown!.code, equals('rate_limited'));
        expect(thrown.statusCode, equals(429));
        final json = thrown.toJson();
        expect(json['error'], equals('rate_limited'));
        expect(
          json['cap_requests_per_minute'],
          equals(PolicyTier.launch.maxRequestsPerMinute),
        );
        expect(json['tier_id'], equals('launch'));
      },
    );

    test('monthly cost cap surfaces 402 monthly_cap_reached', () async {
      final store = _FixedSnapshotStore(
        snapshot: UsageSnapshot(
          requestsThisMinute: 0,
          costCentsThisMonth: PolicyTier.launch.maxMonthlyCostCents,
          minuteBucketStart: DateTime.utc(2026, 4, 25, 12, 0),
          monthBucketStart: DateTime.utc(2026, 4, 1),
        ),
      );
      final guard = ProxyUsageGuard(
        store: store,
        tierResolver: const FixedLaunchTierResolver(),
      );

      UsageRefusal? thrown;
      try {
        await guard.requireAllowed(
          operator: operatorScope(),
          estimate: const UsageEstimate(requestTokens: 100),
        );
      } on UsageRefusal catch (refusal) {
        thrown = refusal;
      }

      expect(thrown, isNotNull);
      expect(thrown!.code, equals('monthly_cap_reached'));
      expect(thrown.statusCode, equals(402));
      expect(
        thrown.details['cap_monthly_cost_cents'],
        equals(PolicyTier.launch.maxMonthlyCostCents),
      );
    });

    test('happy path returns tier + remaining budget', () async {
      final store = _FixedSnapshotStore(
        snapshot: UsageSnapshot(
          requestsThisMinute: 5,
          costCentsThisMonth: 250,
          minuteBucketStart: DateTime.utc(2026, 4, 25, 12, 0),
          monthBucketStart: DateTime.utc(2026, 4, 1),
        ),
      );
      final guard = ProxyUsageGuard(
        store: store,
        tierResolver: const FixedLaunchTierResolver(),
      );

      final decision = await guard.requireAllowed(
        operator: operatorScope(),
        estimate: const UsageEstimate(requestTokens: 100),
      );

      expect(decision.tier.id, equals('launch'));
      expect(
        decision.remainingRequestsThisMinute,
        equals(PolicyTier.launch.maxRequestsPerMinute - 5),
      );
      expect(
        decision.remainingCostCentsThisMonth,
        equals(PolicyTier.launch.maxMonthlyCostCents - 250),
      );
    });

    test(
      'ScaffoldFailingUsageCounterStore makes the guard fail closed (503)',
      () async {
        final guard = ProxyUsageGuard(
          store: const ScaffoldFailingUsageCounterStore(),
          tierResolver: const FixedLaunchTierResolver(),
        );

        UsageRefusal? thrown;
        try {
          await guard.requireAllowed(
            operator: operatorScope(),
            estimate: const UsageEstimate(requestTokens: 100),
          );
        } on UsageRefusal catch (refusal) {
          thrown = refusal;
        }

        expect(thrown, isNotNull);
        expect(thrown!.code, equals('usage_store_unavailable'));
        expect(thrown.statusCode, equals(503));
        expect(thrown.details['tier_id'], equals('launch'));
        // StateError reason is preserved (scaffold message is curated).
        expect(thrown.details['reason'], contains('11a.10b scaffold'));
      },
    );

    test('non-StateError store failures also fail closed (503) with a '
        'generic reason that does not leak raw error contents', () async {
      final guard = ProxyUsageGuard(
        store: _BoomStore(
          error: const FormatException(
            'pretend-secret-bearing-detail '
            'postgres://user:password@host:5432/db',
          ),
        ),
        tierResolver: const FixedLaunchTierResolver(),
      );

      UsageRefusal? thrown;
      try {
        await guard.requireAllowed(
          operator: operatorScope(),
          estimate: const UsageEstimate(requestTokens: 100),
        );
      } on UsageRefusal catch (refusal) {
        thrown = refusal;
      }

      expect(thrown, isNotNull);
      expect(thrown!.code, equals('usage_store_unavailable'));
      expect(thrown.statusCode, equals(503));
      expect(thrown.details['tier_id'], equals('launch'));
      expect(thrown.details['reason'], equals('unexpected store failure'));
      // The raw exception payload (which would carry connection
      // strings / secrets in real failures) must not be echoed.
      final reasonText = thrown.details['reason'].toString();
      expect(reasonText, isNot(contains('pretend-secret')));
      expect(reasonText, isNot(contains('postgres://')));
    });
  });

  group('Proxy accounting + cost levers (11a.11d)', () {
    test('usage log SQL is an atomic telemetry-aware UPSERT that writes '
        'the Phase 9.0Σ.g two-slot identity (B33)', () {
      final sql = ProxyUsageLogSql.atomicUpsert.toLowerCase();

      // Shape that survived the B33 follow-up.
      expect(sql, contains('insert into public.usage_logs'));
      expect(sql, contains('on conflict'));
      expect(sql, contains('do update set'));

      // Telemetry tail from 202604250006 — the rollup identity must
      // still split a Haiku cache hit from a Sonnet fallback miss.
      for (final column in <String>[
        'query_class',
        'cache_hit',
        'llm_tier',
        'model_used',
        'batch_mode',
        'circuit_state',
        'fallback_used',
      ]) {
        expect(sql, contains(column));
      }

      // location_id is preserved (cap-shape includes it; lock 6).
      expect(sql, contains('location_id'));
      // period_start is still computed locally as the month bucket
      // so callers do not have to pre-truncate.
      expect(sql, contains("date_trunc('month', @request_time::timestamptz)"));

      // Two-slot org-unit axes — the B33 acceptance criterion. These
      // four columns must appear in the INSERT column list and the
      // operator-root org_units fallback must be present so a caller
      // with no narrower scope still writes a non-NULL billing/scoped
      // pair (matching the 202604280006_b backfill of legacy rows).
      for (final column in <String>[
        'billing_owner_org_unit_id',
        'scoped_org_unit_id',
        'staff_id',
        'workflow_id',
      ]) {
        expect(
          sql,
          contains(column),
          reason:
              'B33 writer must include $column in the two-slot rollup '
              'identity (matches usage_logs_two_slot_rollup_uq from '
              '202604280006_c)',
        );
      }
      expect(
        sql,
        contains('coalesce(\n    @billing_owner_org_unit_id::uuid'),
        reason:
            'B33 writer must default billing_owner_org_unit_id to the '
            'operator root org_units row when the caller has no '
            'narrower scope',
      );
      expect(
        sql,
        contains('coalesce(\n    @scoped_org_unit_id::uuid'),
        reason:
            'B33 writer must default scoped_org_unit_id to the '
            'operator root org_units row when the caller has no '
            'narrower scope',
      );
      expect(
        sql,
        contains(
          'select id\n'
          '       from public.org_units\n'
          '      where operator_id = @operator_id\n'
          '        and parent_id is null\n'
          '      limit 1',
        ),
        reason:
            'B33 writer must resolve the operator root via the same '
            'shape that 202604280002 enforces uniqueness on '
            '(parent_id is null + operator_id)',
      );
      expect(
        sql,
        contains('@staff_id::uuid'),
        reason:
            'B33 writer must thread nullable staff_id through to the '
            'rollup identity (NULL = "covers all staff")',
      );
      expect(
        sql,
        contains('@workflow_id::uuid'),
        reason:
            'B33 writer must thread nullable workflow_id through to '
            'the rollup identity (NULL = "covers all workflows")',
      );

      // ON CONFLICT must target the named NULLS NOT DISTINCT
      // constraint (PG's column-list inference assumes NULLS
      // DISTINCT, which would not match the constraint and would
      // cause every NULL-staff row to insert as a duplicate).
      expect(
        sql,
        contains('on conflict on constraint usage_logs_two_slot_rollup_uq'),
        reason:
            'ON CONFLICT must target usage_logs_two_slot_rollup_uq by '
            'name so the NULLS NOT DISTINCT constraint matches '
            'NULL-staff / NULL-workflow rows correctly',
      );
      // The legacy 11-column inference target must be gone; if it
      // were still present a single-slot writer would silently keep
      // working alongside the new constraint and the cap-vs-actual
      // join would no longer be 1:1.
      expect(
        sql,
        isNot(
          contains(
            'on conflict (\n'
            '  operator_id,\n'
            '  location_id,\n'
            '  usage_class,\n'
            '  period_start,\n'
            '  query_class,',
          ),
        ),
        reason:
            'B33 must remove the legacy 11-column ON CONFLICT '
            'inference target — that key was dropped in '
            '202604280006_c',
      );

      // Increment-on-conflict semantics unchanged.
      expect(
        sql,
        contains(
          'token_count = public.usage_logs.token_count + '
          'excluded.token_count',
        ),
      );

      // Idempotency insert — unchanged shape.
      expect(
        ProxyUsageLogSql.idempotencyInsert.toLowerCase(),
        contains('insert into public.proxy_requests'),
      );
      expect(
        ProxyUsageLogSql.idempotencyInsert.toLowerCase(),
        contains(
          'on conflict (operator_id, location_id, idempotency_key) '
          'do nothing',
        ),
      );

      final capSql = ProxyUsageLogSql.capStatusSelect.toLowerCase();
      expect(capSql, contains('from public.usage_caps c, cap_scope s'));
      expect(
        capSql,
        contains('c.billing_owner_org_unit_id = s.billing_owner_org_unit_id'),
        reason:
            'B33 cap lookups must qualify shared org-unit column names '
            'so Postgres does not reject the cap_scope join as ambiguous',
      );
      expect(capSql, contains('c.scoped_org_unit_id = s.scoped_org_unit_id'));
      expect(capSql, contains('from public.usage_logs l, cap_scope s'));
      expect(
        capSql,
        contains('l.billing_owner_org_unit_id = s.billing_owner_org_unit_id'),
      );
      expect(capSql, contains('l.scoped_org_unit_id = s.scoped_org_unit_id'));
    });

    test('tier routing keeps Basic on Haiku and allows Premium+ nuanced '
        'queries to Sonnet', () {
      const router = SubscriptionLlmTierRouter();

      expect(
        router.tierFor(subscriptionTier: 'basic', queryClass: 'recommendation'),
        equals(ProxyLlmTier.haiku),
      );
      expect(
        router.tierFor(
          subscriptionTier: 'premium',
          queryClass: 'recommendation',
        ),
        equals(ProxyLlmTier.sonnet),
      );
      expect(
        router.tierFor(
          subscriptionTier: 'enterprise',
          queryClass: 'methodology_lookup',
        ),
        equals(ProxyLlmTier.haiku),
      );
    });

    test(
      'prompt cache builder marks stable blocks and keys by corpus version',
      () {
        const builder = AdvisorPromptCacheBuilder();
        final blocks = builder.build(
          corpusVersion: 'launch_v1',
          methodologyContext: 'stable corpus context',
          toolDefinitions: 'stable tool definitions',
          operatorContext: 'operator-specific context',
        );

        final cachedIds = <String>[
          for (final block in blocks)
            if (block.cacheBreakpoint) block.id,
        ];
        expect(
          cachedIds,
          equals(<String>[
            'system_prompt',
            'tool_definitions',
            'corpus_context:launch_v1',
          ]),
        );
        expect(
          blocks.singleWhere((b) => b.id == 'operator_context').cacheBreakpoint,
          isFalse,
        );
        expect(
          builder.cacheKeyForCorpusVersion('launch_v1'),
          isNot(equals(builder.cacheKeyForCorpusVersion('launch_v2'))),
        );
      },
    );

    test('request logging is meta-only by default and full-content only on '
        'explicit opt-in', () {
      const operator = OperatorContext(
        userId: 'user_1',
        operatorId: 'op_1',
        locationId: 'loc_1',
        roles: <String>['advisor.read'],
      );
      final metaOnly = const ProxyRequestLogPolicy.metaOnly().buildEntry(
        operator: operator,
        usageClass: 'advisor_qa',
        queryClass: 'methodology_lookup',
        tokenCount: 120,
        costCents: 2,
        statusCode: 200,
        question: 'sensitive question',
        answer: 'sensitive answer',
      );
      expect(metaOnly['content_logging'], equals('meta_only'));
      expect(metaOnly, isNot(containsPair('question', anything)));
      expect(metaOnly, isNot(containsPair('answer', anything)));

      final full = const ProxyRequestLogPolicy(fullContentLoggingEnabled: true)
          .buildEntry(
            operator: operator,
            usageClass: 'advisor_qa',
            queryClass: 'methodology_lookup',
            tokenCount: 120,
            costCents: 2,
            statusCode: 200,
            question: 'operator opted in question',
            answer: 'operator opted in answer',
          );
      expect(full['content_logging'], equals('full'));
      expect(full['question'], equals('operator opted in question'));
      expect(full['answer'], equals('operator opted in answer'));
    });

    test(
      'accounting fake reserves atomically under concurrent requests',
      () async {
        final store = _InMemoryAccountingStore(
          capStatus: const ProxyCapStatus(
            usageClass: 'advisor_qa',
            monthlyCapCents: 1,
            monthlyUsedCents: 0,
            perInvocationCapCents: 1,
            estimatedCostCents: 1,
          ),
        );
        final operator = _operatorContext();
        final starts = await Future.wait(<Future<ProxyAccountingStartResult>>[
          store.startRequest(
            idempotencyKey: 'idem_a',
            requestType: 'advisor_smoke',
            operator: operator,
            usageClass: 'advisor_qa',
            telemetry: _telemetry(),
            estimate: const ProxyUsageChargeEstimate(
              tokenCount: 10,
              costCents: 1,
            ),
            now: DateTime.utc(2026, 4, 26),
          ),
          store.startRequest(
            idempotencyKey: 'idem_b',
            requestType: 'advisor_smoke',
            operator: operator,
            usageClass: 'advisor_qa',
            telemetry: _telemetry(),
            estimate: const ProxyUsageChargeEstimate(
              tokenCount: 10,
              costCents: 1,
            ),
            now: DateTime.utc(2026, 4, 26),
          ),
        ]);

        expect(starts.whereType<ProxyAccountingReserved>(), hasLength(1));
        expect(starts.whereType<ProxyAccountingRefused>(), hasLength(1));
        expect(store.monthlyUsedCents, equals(1));
      },
    );

    test('Postgres accounting store executes B33 usage-log upsert with '
        'the four two-slot bind parameters inside tenant scope', () async {
      final pool = _AccountingPostgresPool();
      final store = PostgresProxyAccountingStore(
        wrapper: TenantTransactionWrapper(pool),
      );
      final operator = _uuidOperatorContext();
      const billingOwner = '55555555-5555-4555-8555-555555555555';
      const workflowId = '66666666-6666-4666-8666-666666666666';

      final start = await store.startRequest(
        idempotencyKey: 'idem-b33',
        requestType: 'advisor_smoke',
        operator: operator,
        usageClass: 'advisor_qa',
        telemetry: const ProxyUsageTelemetry(
          queryClass: 'methodology_lookup',
          cacheHit: false,
          llmTier: 'haiku',
          modelUsed: 'claude-haiku-4-5',
          billingOwnerOrgUnitId: billingOwner,
          workflowId: workflowId,
        ),
        estimate: const ProxyUsageChargeEstimate(
          tokenCount: 123,
          costCents: 25,
        ),
        now: DateTime.utc(2026, 4, 26, 12),
      );

      expect(start, isA<ProxyAccountingReserved>());
      expect(pool.transactions, hasLength(1));

      // Block 2 (Lock 7 v1): startRequest is the pre-flight (replay
      // lookup + cap-check + idempotency reservation). The usage_logs
      // upsert moved to commitUsageLog so the row reflects the
      // post-chain (circuit_state, fallback_used).
      await store.commitUsageLog(
        operator: operator,
        usageClass: 'advisor_qa',
        telemetry: const ProxyUsageTelemetry(
          queryClass: 'methodology_lookup',
          cacheHit: false,
          llmTier: 'haiku',
          modelUsed: 'claude-haiku-4-5',
          billingOwnerOrgUnitId: billingOwner,
          workflowId: workflowId,
          circuitState: 'closed',
          fallbackUsed: 'none',
        ),
        estimate: const ProxyUsageChargeEstimate(
          tokenCount: 123,
          costCents: 25,
        ),
        now: DateTime.utc(2026, 4, 26, 12),
      );

      expect(pool.transactions, hasLength(2));
      final preflightTx = pool.transactions.first;
      final commitTx = pool.transactions[1];
      expect(preflightTx.committed, isTrue);
      expect(commitTx.committed, isTrue);
      expect(commitTx.rolledBack, isFalse);
      expect(
        commitTx.executedSql,
        containsAll(<String>[
          "select set_config('app.operator_id', @value, true)",
          "select set_config('app.location_id', @value, true)",
          "select set_config('app.user_id', @value, true)",
          "select set_config('app.bypass_rls_audit', 'tenant', true)",
        ]),
      );
      final usageCall = commitTx.queryCalls.singleWhere(
        (call) => call.sql.contains('insert into public.usage_logs'),
      );
      expect(
        usageCall.sql,
        contains('on conflict on constraint usage_logs_two_slot_rollup_uq'),
      );
      expect(
        usageCall.parameters,
        containsPair('billing_owner_org_unit_id', billingOwner),
      );
      expect(usageCall.parameters, containsPair('scoped_org_unit_id', isNull));
      expect(usageCall.parameters, containsPair('staff_id', isNull));
      expect(usageCall.parameters, containsPair('workflow_id', workflowId));
      expect(usageCall.parameters, containsPair('token_count', 123));
      expect(usageCall.parameters, containsPair('cost_usd', '0.2500'));
      expect(usageCall.parameters, containsPair('circuit_state', 'closed'));
      expect(usageCall.parameters, containsPair('fallback_used', 'none'));
    });

    test('Postgres accounting completion updates the idempotency row with '
        'operator-scoped tenant context', () async {
      final pool = _AccountingPostgresPool();
      final store = PostgresProxyAccountingStore(
        wrapper: TenantTransactionWrapper(pool),
      );
      final operator = _uuidOperatorContext();

      await store.completeRequest(
        operator: operator,
        idempotencyKey: 'idem-b33',
        responsePayload: const <String, Object?>{
          'status': 'ok',
          'answer': 'fake',
        },
        now: DateTime.utc(2026, 4, 26, 12, 1),
      );

      expect(pool.transactions, hasLength(1));
      final tx = pool.transactions.single;
      expect(tx.committed, isTrue);
      final completionCall = tx.executeCalls.singleWhere(
        (call) => call.sql.contains('update public.proxy_requests'),
      );
      expect(
        completionCall.parameters['operator_id'],
        equals(operator.operatorId),
      );
      expect(
        completionCall.parameters['location_id'],
        equals(operator.locationId),
      );
      expect(completionCall.parameters['idempotency_key'], equals('idem-b33'));
      expect(
        completionCall.parameters['response_payload'],
        equals('{"status":"ok","answer":"fake"}'),
      );
    });
  });

  group('Advisor proxy usage counters migration (11a.10b)', () {
    test('creates the counter table with RLS, service-role policy, and '
        'operator/location/tier/minute uniqueness', () {
      final migration = File(
        'db/migrations/202604250004_advisor_proxy_usage_counters.sql',
      ).readAsStringSync().replaceAll('\r\n', '\n');

      // Table + columns.
      expect(
        migration,
        contains(
          'create table if not exists public.advisor_proxy_usage_counters',
        ),
      );
      expect(migration, contains('operator_id uuid not null'));
      expect(migration, contains('location_id uuid not null'));
      expect(migration, contains('tier_id text not null'));
      expect(migration, contains('minute_bucket timestamptz not null'));
      expect(migration, contains('month_bucket date not null'));
      expect(migration, contains('request_count integer not null default 0'));
      expect(migration, contains('token_count bigint not null default 0'));
      expect(migration, contains('cost_cents bigint not null default 0'));

      // Uniqueness over (operator, location, tier, period).
      expect(
        migration,
        contains('unique (operator_id, location_id, tier_id, minute_bucket)'),
      );

      // Indexes for read paths.
      expect(migration, contains('advisor_proxy_usage_counters_minute_idx'));
      expect(migration, contains('advisor_proxy_usage_counters_month_idx'));

      // Comments documenting bucket semantics.
      expect(migration, contains('comment on table'));
      expect(migration, contains('comment on column'));
      expect(migration, contains('UTC minute'));

      // RLS + service-role policy scaffold.
      expect(
        migration,
        contains(
          'alter table public.advisor_proxy_usage_counters enable row level security',
        ),
      );
      expect(
        migration,
        contains('advisor_proxy_usage_counters_service_role_all'),
      );
      expect(migration, contains('to service_role'));
    });
  });

  group('Advisor cloud foundation migration (11a.11c.1)', () {
    late String migration;

    setUpAll(() {
      migration = File(
        'db/migrations/'
        '202604250005_advisor_cloud_foundation.sql',
      ).readAsStringSync().replaceAll('\r\n', '\n');
    });

    test('creates the four foundational identity tables', () {
      expect(
        migration,
        contains('create table if not exists public.operators'),
      );
      expect(
        migration,
        contains('create table if not exists public.locations'),
      );
      expect(migration, contains('create table if not exists public.users'));
      expect(
        migration,
        contains('create table if not exists public.operator_admins'),
      );
    });

    test(
      'operators carries preferred_currency CAD default and a deferred '
      'composite primary_location_id FK that pins same-operator ownership',
      () {
        expect(
          migration,
          contains("preferred_currency char(3) not null default 'CAD'"),
        );
        expect(migration, contains('primary_location_id uuid null'));
        // FK is added after locations exists to break the cycle, and is
        // composite on (operator_id, primary_location_id) so an
        // operator's primary_location_id cannot point at another
        // operator's location.
        expect(migration, contains('alter table public.operators'));
        expect(
          migration,
          contains('add constraint operators_primary_location_fk'),
        );
        expect(
          migration,
          contains('foreign key (operator_id, primary_location_id)'),
        );
        expect(
          migration,
          contains('references public.locations(operator_id, location_id)'),
        );
        // ON DELETE SET NULL with a column list (PG15+) preserves
        // operator_id (NOT NULL on operators) when the referenced
        // location is deleted.
        expect(migration, contains('on delete set null (primary_location_id)'));
      },
    );

    test('locations carries timezone NOT NULL and '
        'business_day_rollover_hour with a 0-23 check', () {
      expect(migration, contains('timezone text not null'));
      expect(migration, contains('business_day_rollover_hour integer'));
      expect(
        migration,
        contains('check (business_day_rollover_hour between 0 and 23)'),
      );
    });

    test('users + operator_admins reference operators with cascade and use '
        'a composite PK on operator_admins', () {
      expect(
        migration,
        contains(
          'operator_id uuid not null references public.operators(operator_id)',
        ),
      );
      // operator_admins composite PK so a user can admin multiple operators.
      expect(migration, contains('primary key (user_id, operator_id)'));
      expect(
        migration,
        contains('is_super_admin boolean not null default false'),
      );
    });

    test('usage_logs is partitioned by period_start with composite PK and '
        'non-negative checks', () {
      expect(
        migration,
        contains('create table if not exists public.usage_logs'),
      );
      expect(migration, contains('partition by range (period_start)'));
      expect(
        migration,
        contains(
          'primary key (operator_id, location_id, usage_class, period_start)',
        ),
      );
      expect(migration, contains('check (token_count >= 0)'));
      expect(migration, contains('check (cost_usd >= 0)'));
      expect(migration, contains('check (request_count >= 0)'));
      // At least a default partition catches writes outside any
      // explicit month-specific partition.
      expect(
        migration,
        contains('create table if not exists public.usage_logs_default'),
      );
      expect(migration, contains('partition of public.usage_logs default'));
    });

    test('usage_caps is keyed on (operator_id, location_id, usage_class) '
        'with non-negative cap checks and nullable created_by/updated_by', () {
      expect(
        migration,
        contains('create table if not exists public.usage_caps'),
      );
      expect(
        migration,
        contains('primary key (operator_id, location_id, usage_class)'),
      );
      expect(migration, contains('check (monthly_cap_usd >= 0)'));
      expect(migration, contains('check (per_invocation_cap_usd >= 0)'));
      expect(migration, contains('created_by uuid null'));
      expect(migration, contains('updated_by uuid null'));
    });

    test('proxy_requests has unique idempotency_key, request_type, and '
        'nullable response_payload jsonb', () {
      expect(
        migration,
        contains('create table if not exists public.proxy_requests'),
      );
      expect(migration, contains('idempotency_key text not null unique'));
      expect(migration, contains('request_type text not null'));
      expect(migration, contains('response_payload jsonb null'));
    });

    test('feature_flags supports global / operator / location scopes via '
        'three partial unique indexes (no duplicates per logical scope)', () {
      expect(
        migration,
        contains('create table if not exists public.feature_flags'),
      );
      // Three partial unique indexes cover the three logical scopes.
      expect(migration, contains('feature_flags_global_scope_idx'));
      expect(migration, contains('feature_flags_operator_scope_idx'));
      expect(migration, contains('feature_flags_location_scope_idx'));
      expect(
        migration,
        contains('where operator_id is null and location_id is null'),
      );
    });

    test('fx_rates is keyed on (base_currency, quote_currency, '
        'as_of_date) with positive rate and currency-format checks', () {
      expect(migration, contains('create table if not exists public.fx_rates'));
      expect(
        migration,
        contains('primary key (base_currency, quote_currency, as_of_date)'),
      );
      expect(migration, contains('check (rate > 0)'));
      // Currency code shape check.
      expect(migration, contains(r"check (base_currency ~ '^[A-Z]{3}$')"));
      expect(migration, contains(r"check (quote_currency ~ '^[A-Z]{3}$')"));
    });

    test('every new table has RLS enabled and a service-role-only policy '
        'stub', () {
      const expectedTables = <String>[
        'operators',
        'locations',
        'users',
        'operator_admins',
        'usage_logs',
        'usage_logs_default',
        'usage_caps',
        'proxy_requests',
        'feature_flags',
        'fx_rates',
      ];
      for (final table in expectedTables) {
        expect(
          migration,
          contains('alter table public.$table enable row level security'),
          reason: 'RLS must be enabled on $table',
        );
        expect(
          migration,
          contains('${table}_service_role_all'),
          reason: 'service-role policy stub must exist for $table',
        );
      }
      // Every policy stub targets the service_role role.
      expect(migration, contains('to service_role'));
    });

    test('migration uses TIMESTAMPTZ throughout — no `timestamp without '
        'time zone` (operator-scoped silent-DST hazard banned)', () {
      expect(
        migration.toLowerCase().contains('timestamp without time zone'),
        isFalse,
        reason:
            'TIMESTAMP WITHOUT TIME ZONE is banned in operator-scoped '
            'tables — silent DST corruption is unrecoverable.',
      );
    });

    test('locations carries an explicit `unique (operator_id, location_id)` '
        'so composite FKs from operator-scoped tables have a target', () {
      expect(migration, contains('unique (operator_id, location_id)'));
    });

    test('every operator/location-scoped table references locations on '
        'the (operator_id, location_id) pair — rejects (operator_a, '
        'location_b) cross-tenant mismatches at the DB layer', () {
      // Composite FK clause: present once on each of usage_logs,
      // usage_caps, proxy_requests, and feature_flags — at least
      // four occurrences. Multi-line tolerant so layout changes
      // don't make this brittle.
      final composite = RegExp(
        r'foreign key \(operator_id, location_id\)\s+'
        r'references public\.locations\(operator_id, location_id\)',
        multiLine: true,
      );
      expect(
        composite.allMatches(migration).length,
        greaterThanOrEqualTo(4),
        reason:
            'usage_logs / usage_caps / proxy_requests / feature_flags '
            'must each declare the composite FK to locations.',
      );
    });

    test('feature_flags rejects the malformed (location set, operator '
        'NULL) shape via a CHECK constraint', () {
      expect(
        migration,
        contains('check (location_id is null or operator_id is not null)'),
      );
    });

    test('feature_flags_location_scope_idx requires both operator_id and '
        'location_id to be present (so duplicates of the malformed '
        'shape cannot slip through)', () {
      expect(
        migration,
        contains('where operator_id is not null and location_id is not null'),
      );
    });
  });

  group('Advisor schema hardening migration (11a.11c.6a)', () {
    late String migration;
    late String normalizedMigration;
    late String auditSql;
    late List<String> migrationNames;

    setUpAll(() {
      migrationNames =
          Directory('db/migrations')
              .listSync()
              .whereType<File>()
              .map((file) => file.uri.pathSegments.last)
              .where((name) => name.endsWith('.sql'))
              .toList()
            ..sort();
      migration = File(
        'db/migrations/'
        '202604250006_advisor_contextual_retrieval_telemetry.sql',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      normalizedMigration = migration.replaceAll(RegExp(r'\s+'), ' ');
      auditSql = File(
        'db/verification/'
        '202604250006_advisor_schema_hardening_audits.sql',
      ).readAsStringSync().replaceAll('\r\n', '\n');
    });

    test('migration file is next in deterministic order', () {
      expect(
        migrationNames,
        contains('202604250006_advisor_contextual_retrieval_telemetry.sql'),
      );
      expect(
        migrationNames.indexOf(
          '202604250006_advisor_contextual_retrieval_telemetry.sql',
        ),
        equals(
          migrationNames.indexOf('202604250005_advisor_cloud_foundation.sql') +
              1,
        ),
      );
    });

    test('adds Contextual Retrieval chunk columns and BM25 GIN index', () {
      expect(migration, contains('alter table public.advisor_source_chunks'));
      expect(
        migration,
        contains('add column if not exists chunk_context text'),
      );
      expect(
        migration,
        contains(
          "add column if not exists corpus_version text not null default 'launch_v1'",
        ),
      );
      expect(migration, contains('add column if not exists bm25_tsv tsvector'));
      expect(migration, isNot(contains('generated always as')));
      expect(
        migration,
        contains(
          'Populated by deterministic load/update SQL because Postgres '
          'generated columns require immutable expressions',
        ),
      );
      expect(
        normalizedMigration,
        contains(
          'create index if not exists advisor_source_chunks_bm25_tsv_idx '
          'on public.advisor_source_chunks using gin (bm25_tsv) '
          'where active = true',
        ),
      );
      expect(
        migration,
        contains(
          'comment on column public.advisor_source_chunks.chunk_context',
        ),
      );
      expect(
        migration,
        contains(
          'comment on column public.advisor_source_chunks.corpus_version',
        ),
      );
      expect(
        migration,
        contains('comment on column public.advisor_source_chunks.bm25_tsv'),
      );
      expect(migration, contains('Anthropic Contextual Retrieval'));
      expect(migration, contains('cache keys'));
    });

    test('usage telemetry columns are rollup dimensions, not loose fields', () {
      const telemetryColumns = <String>[
        'query_class',
        'cache_hit',
        'llm_tier',
        'model_used',
        'batch_mode',
        'circuit_state',
        'fallback_used',
      ];
      for (final column in telemetryColumns) {
        expect(
          migration,
          contains('add column if not exists $column'),
          reason: 'missing usage_logs telemetry column $column',
        );
        expect(
          normalizedMigration,
          contains('comment on column public.usage_logs.$column'),
          reason: 'missing usage_logs telemetry comment for $column',
        );
      }
      expect(
        migration,
        contains("query_class text not null default 'unknown'"),
      );
      expect(migration, contains('cache_hit boolean not null default false'));
      expect(migration, contains("llm_tier text not null default 'unknown'"));
      expect(migration, contains("model_used text not null default 'unknown'"));
      expect(migration, contains('batch_mode boolean not null default false'));
      expect(
        migration,
        contains("circuit_state text not null default 'closed'"),
      );
      expect(migration, contains("fallback_used text not null default 'none'"));
      expect(
        migration,
        contains(
          "check (circuit_state in ('closed', 'open', 'half_open', 'unknown'))",
        ),
      );
      expect(
        normalizedMigration,
        contains('drop constraint if exists usage_logs_pkey'),
      );
      expect(
        normalizedMigration,
        contains(
          'add primary key ( operator_id, location_id, usage_class, '
          'period_start, query_class, cache_hit, llm_tier, model_used, '
          'batch_mode, circuit_state, fallback_used )',
        ),
        reason:
            'usage_logs rollup key must include telemetry dimensions so '
            'mixed model/cache/fallback rows do not collapse.',
      );
    });

    test('pg_partman maintenance scaffold is represented safely', () {
      expect(auditSql, contains('public.create_parent'));
      expect(auditSql, contains("p_parent_table := 'public.usage_logs'"));
      expect(auditSql, contains("p_control := 'period_start'"));
      expect(auditSql, contains("p_interval := '1 month'"));
      expect(auditSql, contains('p_default_table := false'));
      expect(auditSql, contains('p_jobmon := false'));
      expect(auditSql, contains('cron.schedule'));
      expect(auditSql, contains('partman_maintenance'));
      expect(auditSql, contains("0 * * * *"));
      expect(auditSql, contains('public.run_maintenance'));
      expect(auditSql, contains('p_analyze := true'));
    });

    test('RLS-leading-column index audit SQL exists', () {
      expect(auditSql, contains('pg_index'));
      expect(auditSql, contains('att.attname::text'));
      expect(auditSql, contains('unnest(ix.indkey) with ordinality'));
      expect(auditSql, contains("key_columns[1] = 'operator_id'"));
      expect(
        auditSql,
        contains("key_columns[1:2] = array['operator_id', 'location_id']"),
      );
      expect(auditSql, contains("'usage_logs'"));
      expect(auditSql, contains("'usage_caps'"));
      expect(auditSql, contains("'proxy_requests'"));
      expect(auditSql, contains("'advisor_proxy_usage_counters'"));
      expect(auditSql, contains('violations'));
    });

    test('migration avoids pgmq and unzoned timestamps', () {
      expect(migration.toLowerCase(), isNot(contains('pgmq')));
      expect(
        migration.toLowerCase(),
        isNot(contains('timestamp without time zone')),
      );
    });
  });

  group('Advisor RLS index hardening migration (11a.11c.6 live fix)', () {
    late String migration;
    late String normalizedMigration;
    late List<String> migrationNames;

    setUpAll(() {
      migrationNames =
          Directory('db/migrations')
              .listSync()
              .whereType<File>()
              .map((file) => file.uri.pathSegments.last)
              .where((name) => name.endsWith('.sql'))
              .toList()
            ..sort();
      migration = File(
        'db/migrations/202604250007_advisor_rls_index_hardening.sql',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      normalizedMigration = migration.replaceAll(RegExp(r'\s+'), ' ');
    });

    test(
      'migration file follows the Contextual Retrieval telemetry migration',
      () {
        expect(
          migrationNames,
          contains('202604250007_advisor_rls_index_hardening.sql'),
        );
        expect(
          migrationNames.indexOf(
            '202604250007_advisor_rls_index_hardening.sql',
          ),
          equals(
            migrationNames.indexOf(
                  '202604250006_advisor_contextual_retrieval_telemetry.sql',
                ) +
                1,
          ),
        );
      },
    );

    test(
      'advisor_proxy_usage_counters final primary key is tenant-leading',
      () {
        expect(
          normalizedMigration,
          contains(
            'alter table public.advisor_proxy_usage_counters drop constraint '
            'if exists advisor_proxy_usage_counters_pkey',
          ),
        );
        expect(
          normalizedMigration,
          contains(
            'add constraint advisor_proxy_usage_counters_pkey primary key '
            '(operator_id, location_id, tier_id, minute_bucket)',
          ),
        );
        expect(
          normalizedMigration,
          contains(
            'advisor_proxy_usage_counters_counter_lookup_idx on '
            'public.advisor_proxy_usage_counters (operator_id, location_id, '
            'counter_id)',
          ),
        );
      },
    );

    test(
      'proxy_requests final primary and idempotency keys are tenant-leading',
      () {
        expect(
          normalizedMigration,
          contains(
            'alter table public.proxy_requests drop constraint if exists '
            'proxy_requests_idempotency_key_key',
          ),
        );
        expect(
          normalizedMigration,
          contains(
            'add constraint proxy_requests_pkey primary key '
            '(operator_id, location_id, request_id)',
          ),
        );
        expect(
          normalizedMigration,
          contains(
            'add constraint proxy_requests_operator_location_idempotency_key_key '
            'unique (operator_id, location_id, idempotency_key)',
          ),
        );
        expect(
          normalizedMigration,
          contains(
            'proxy_requests_operator_location_created_idx on '
            'public.proxy_requests (operator_id, location_id, created_at)',
          ),
        );
      },
    );
  });

  group('Phase 9 auth schema foundation migration (9.0)', () {
    late String migration;
    late String normalizedMigration;
    late List<String> migrationNames;
    late String permissionKeysSource;
    late String catalogContract;

    const newAuthTables = <String>[
      'permission_keys',
      'roles',
      'role_permissions',
      'user_roles',
      'auth_sessions',
      'mfa_factors',
      'tncs_acceptances',
      'password_history',
      'auth_invites',
      'auth_events_audit',
      'role_audit_log',
      'external_identity_links',
    ];

    const baselineRoleKeys = <String>[
      'super_admin',
      'ff_support',
      'operator_owner',
      'operator_manager',
      'operator_supervisor',
      'operator_staff',
    ];

    setUpAll(() {
      migrationNames =
          Directory('db/migrations')
              .listSync()
              .whereType<File>()
              .map((file) => file.uri.pathSegments.last)
              .where((name) => name.endsWith('.sql'))
              .toList()
            ..sort();
      migration = File(
        'db/migrations/202604250008_auth_schema_foundation.sql',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      normalizedMigration = migration.replaceAll(RegExp(r'\s+'), ' ');
      permissionKeysSource = File(
        'lib/auth/permission_keys.dart',
      ).readAsStringSync();
      catalogContract = File(
        'docs/contracts/auth_permission_key_catalog.md',
      ).readAsStringSync();
    });

    test(
      'migration is the next deterministic file after 11a.11c.6 hardening',
      () {
        expect(
          migrationNames,
          contains('202604250008_auth_schema_foundation.sql'),
        );
        expect(
          migrationNames.indexOf('202604250008_auth_schema_foundation.sql'),
          equals(
            migrationNames.indexOf(
                  '202604250007_advisor_rls_index_hardening.sql',
                ) +
                1,
          ),
        );
      },
    );

    test('every new auth table is created with `if not exists`', () {
      for (final table in newAuthTables) {
        expect(
          migration,
          contains('create table if not exists public.$table'),
          reason: 'missing create table for $table',
        );
      }
    });

    test('users table is extended with the 9.0 auth + identity columns', () {
      const expectedColumns = <String>[
        'firebase_uid text not null default gen_random_uuid()::text',
        'external_id text null',
        "status text not null default 'invited'",
        'deleted_at timestamptz null',
        'roles_version integer not null default 0',
        'mfa_required boolean not null default false',
        'last_login_at timestamptz null',
        'last_active_at timestamptz null',
        'password_set_at timestamptz null',
        'email_verified_at timestamptz null',
        'first_name text null',
        'last_name text null',
        'display_name text null',
        'primary_role_id uuid null',
        'preferred_locale text null',
        'avatar_url text null',
      ];
      for (final column in expectedColumns) {
        expect(
          migration,
          contains('add column if not exists $column'),
          reason: 'missing users column $column',
        );
      }
      // status check covers the documented lifecycle states.
      for (final state in <String>[
        'invited',
        'active',
        'suspended',
        'dormant_30',
        'dormant_60',
        'dormant_90',
        'deleted',
      ]) {
        expect(
          migration,
          contains("'$state'"),
          reason: 'missing users.status state $state',
        );
      }
      // firebase_uid uniqueness + primary_role_id FK to roles.
      expect(
        migration,
        contains('add constraint users_firebase_uid_key unique (firebase_uid)'),
      );
      expect(
        migration,
        contains('add constraint users_external_id_key unique (external_id)'),
      );
      expect(
        normalizedMigration,
        contains(
          'add constraint users_primary_role_fk foreign key '
          '(primary_role_id) references public.roles(role_id) '
          'on delete set null',
        ),
      );
    });

    test(
      'operator_admins is extended and gets a composite scope-location FK',
      () {
        expect(migration, contains('add column if not exists scope_type text'));
        // scope_type is added nullable, backfilled, then SET NOT NULL so
        // existing rows do not violate NOT NULL on first apply.
        expect(
          normalizedMigration,
          contains('alter column scope_type set not null'),
        );
        for (final scope in <String>[
          'super_admin',
          'ff_support',
          'operator_owner',
          'operator_manager',
        ]) {
          expect(
            migration,
            contains("'$scope'"),
            reason: 'missing operator_admins.scope_type value $scope',
          );
        }
        expect(
          migration,
          contains('add column if not exists scope_location_id uuid null'),
        );
        expect(
          migration,
          contains(
            'add column if not exists valid_from timestamptz not null '
            'default now()',
          ),
        );
        expect(
          migration,
          contains('add column if not exists valid_until timestamptz null'),
        );
        // Composite FK rejects (operator_a, location_b) cross-tenant
        // mismatches at the DB layer.
        expect(
          normalizedMigration,
          contains(
            'add constraint operator_admins_scope_location_fk foreign key '
            '(operator_id, scope_location_id) references '
            'public.locations(operator_id, location_id) on delete cascade',
          ),
        );
      },
    );

    test(
      'legacy users.role column is migrated into user_roles and dropped',
      () {
        // The DO block guards the backfill on column existence so re-runs
        // after the column was already dropped are safe.
        expect(
          normalizedMigration,
          contains(
            "where table_schema = 'public' and table_name = 'users' "
            "and column_name = 'role'",
          ),
        );
        expect(migration, contains('insert into public.user_roles'));
        expect(
          migration,
          contains('alter table public.users drop column role'),
        );
      },
    );

    test('roles uses partial unique indexes to handle null operator_id', () {
      // Plain UNIQUE treats NULL as distinct, so global (operator_id IS
      // NULL) seeded roles need a separate partial unique index from
      // operator-scoped custom roles.
      expect(
        normalizedMigration,
        contains(
          'create unique index if not exists roles_operator_role_key_idx '
          'on public.roles (operator_id, role_key) where operator_id '
          'is not null',
        ),
      );
      expect(
        normalizedMigration,
        contains(
          'create unique index if not exists roles_global_role_key_idx '
          'on public.roles (role_key) where operator_id is null',
        ),
      );
    });

    test('user_roles_active_grant_idx is tenant-leading and supports the same '
        'user holding the same role across different operators', () {
      // Tenant-leading composite blocks duplicate active grants within
      // one (operator, user, role, location) scope while permitting
      // the same user to hold the same role across different
      // operators. COALESCE collapses NULL location_id (operator-wide
      // grant) into a single uniqueness slot.
      expect(
        normalizedMigration,
        contains(
          'create unique index if not exists user_roles_active_grant_idx '
          'on public.user_roles ( operator_id, user_id, role_id, '
          "coalesce(location_id, '00000000-0000-0000-0000-000000000000'"
          '::uuid) ) where revoked_at is null',
        ),
      );
      // The drop-then-create pattern is required so a re-apply over the
      // pre-fix shape (where the index led with user_id) replaces it
      // rather than skipping via `if not exists`.
      expect(
        normalizedMigration,
        contains('drop index if exists public.user_roles_active_grant_idx'),
      );
      // Regression guard: the old user_id-leading composite must not
      // resurface. A revert to the pre-fix shape would fail this check
      // because operator_id would no longer be the first column.
      expect(
        normalizedMigration,
        isNot(
          contains(
            'user_roles_active_grant_idx on public.user_roles '
            '( user_id, role_id,',
          ),
        ),
      );
    });

    test(
      'auth_events_audit actor/target lookup indexes lead with operator_id',
      () {
        // Tenant-leading actor lookup. The pre-fix shape led with
        // actor_user_id and ignored operator_id, which forced RLS to
        // re-filter on every probe.
        expect(
          normalizedMigration,
          contains(
            'create index if not exists auth_events_audit_actor_occurred_idx '
            'on public.auth_events_audit '
            '(operator_id, actor_user_id, occurred_at desc) '
            'where operator_id is not null and actor_user_id is not null',
          ),
        );
        // Tenant-leading target lookup, same shape contract.
        expect(
          normalizedMigration,
          contains(
            'create index if not exists auth_events_audit_target_occurred_idx '
            'on public.auth_events_audit '
            '(operator_id, target_user_id, occurred_at desc) '
            'where operator_id is not null and target_user_id is not null',
          ),
        );
        // Regression guards: the pre-fix user_id-leading shapes must
        // not resurface. Reverting either index to leading with the
        // user-id column alone would fail these checks.
        expect(
          normalizedMigration,
          isNot(
            contains(
              'auth_events_audit_actor_occurred_idx on '
              'public.auth_events_audit (actor_user_id, occurred_at desc)',
            ),
          ),
        );
        expect(
          normalizedMigration,
          isNot(
            contains(
              'auth_events_audit_target_occurred_idx on '
              'public.auth_events_audit (target_user_id, occurred_at desc)',
            ),
          ),
        );
        // The global `operator_id is null` partial index must remain so
        // system-wide events (Firebase JWKS rotations, etc.) stay
        // queryable by occurred_at without leaking into the
        // per-operator lookup indexes.
        expect(
          normalizedMigration,
          contains(
            'create index if not exists auth_events_audit_global_occurred_idx '
            'on public.auth_events_audit (occurred_at desc) '
            'where operator_id is null',
          ),
        );
      },
    );

    test('operator-scoped tables carry tenant-leading indexes per RLS '
        'performance discipline', () {
      const tenantLeadingIndexes = <String>[
        'user_roles_tenant_lookup_idx on public.user_roles (operator_id, location_id, user_id)',
        'tncs_acceptances_operator_user_idx on public.tncs_acceptances (operator_id, user_id, accepted_at)',
        'auth_invites_operator_expires_idx on public.auth_invites (operator_id, expires_at)',
        'auth_events_audit_operator_occurred_idx on public.auth_events_audit (operator_id, occurred_at desc) where operator_id is not null',
        'external_identity_links_operator_user_idx on public.external_identity_links (operator_id, user_id)',
        'users_operator_status_idx on public.users (operator_id, status) where deleted_at is null',
      ];
      for (final fragment in tenantLeadingIndexes) {
        expect(
          normalizedMigration,
          contains(fragment),
          reason: 'missing tenant-leading index fragment: $fragment',
        );
      }
    });

    test('external_identity_links carries vendor-scoped composite UNIQUE '
        'partials (NOT auth source-of-truth, but per-vendor identity is '
        'unique within an operator)', () {
      expect(
        normalizedMigration,
        contains(
          'create unique index if not exists external_identity_links_labor_idx '
          'on public.external_identity_links '
          '(operator_id, vendor, labor_employee_id) where '
          'labor_employee_id is not null',
        ),
      );
      expect(
        normalizedMigration,
        contains(
          'create unique index if not exists external_identity_links_pos_idx '
          'on public.external_identity_links '
          '(operator_id, vendor, pos_employee_id) where '
          'pos_employee_id is not null',
        ),
      );
    });

    test(
      'every new auth table has RLS enabled and a service-role policy stub',
      () {
        for (final table in newAuthTables) {
          expect(
            migration,
            contains('alter table public.$table enable row level security'),
            reason: 'RLS must be enabled on $table',
          );
          // Either a `*_service_role_all` stub (writable) or the
          // append-only INSERT/SELECT split for audit tables. Both
          // forms include the table name as a policy-name prefix.
          expect(
            migration,
            contains('${table}_service_role_'),
            reason: 'service-role policy stub must exist for $table',
          );
        }
        // Every policy stub targets the service_role role.
        expect(migration, contains('to service_role'));
      },
    );

    test('audit tables are append-only by grant shape', () {
      // auth_events_audit: REVOKE UPDATE, DELETE FROM PUBLIC + service_role;
      // GRANT INSERT, SELECT TO service_role.
      expect(
        normalizedMigration,
        contains(
          'revoke update, delete on public.auth_events_audit from public',
        ),
      );
      expect(
        normalizedMigration,
        contains(
          'revoke update, delete on public.auth_events_audit from service_role',
        ),
      );
      expect(
        normalizedMigration,
        contains(
          'grant insert, select on public.auth_events_audit to service_role',
        ),
      );
      // role_audit_log: same grant shape.
      expect(
        normalizedMigration,
        contains('revoke update, delete on public.role_audit_log from public'),
      );
      expect(
        normalizedMigration,
        contains(
          'revoke update, delete on public.role_audit_log from service_role',
        ),
      );
      expect(
        normalizedMigration,
        contains(
          'grant insert, select on public.role_audit_log to service_role',
        ),
      );
      // The RLS policy stubs for the audit tables are SELECT/INSERT
      // only — no FOR ALL stub that would tempt a future change to
      // also grant UPDATE / DELETE.
      expect(migration, contains('auth_events_audit_service_role_append_only'));
      expect(migration, contains('auth_events_audit_service_role_select'));
      expect(migration, contains('role_audit_log_service_role_append_only'));
      expect(migration, contains('role_audit_log_service_role_select'));
    });

    test('six baseline roles are seeded with deterministic UUIDs', () {
      expect(migration, contains('insert into public.roles'));
      for (final key in baselineRoleKeys) {
        expect(
          migration,
          contains("'$key'"),
          reason: 'baseline role $key must be seeded',
        );
      }
      // is_seeded = true; super_admin and ff_support are not editable.
      expect(migration, contains('true, false'));
      expect(migration, contains("'F&F Super Admin'"));
      expect(migration, contains("'F&F Support'"));
    });

    test('permission catalog seed is a single insert into permission_keys '
        'and includes one key per documented category', () {
      expect(migration, contains('insert into public.permission_keys'));
      // Sample one key per category to confirm coverage.
      const samplePerCategory = <String, String>{
        'product': 'product.forgeflow.access',
        'forgeflow': 'forgeflow.shift.view',
        'barrio': 'barrio.handbook.view',
        'admin': 'admin.users.view',
        'billing': 'billing.invoice.view',
        'integration': 'integration.toast.view',
        'workflow': 'workflow.catalog.view',
      };
      samplePerCategory.forEach((category, key) {
        expect(
          migration,
          contains("'$key'"),
          reason: 'category $category sample key $key not seeded',
        );
      });
    });

    test(
      'every key from PermissionKeys.all is seeded into permission_keys',
      () {
        // Pull `'literal'` strings out of the constants file. The
        // PermissionKeys class is constants-only so every quoted literal
        // is a permission key (or a baseline role key). Filtering on
        // the catalog category prefixes keeps role-key strings out.
        final keyPattern = RegExp(r"'([a-z][a-z0-9_]*\.[a-z0-9_.]+)'");
        final keys = keyPattern
            .allMatches(permissionKeysSource)
            .map((m) => m.group(1)!)
            .where(
              (key) =>
                  key.startsWith('product.') ||
                  key.startsWith('forgeflow.') ||
                  key.startsWith('barrio.') ||
                  key.startsWith('admin.') ||
                  key.startsWith('team.') ||
                  key.startsWith('billing.') ||
                  key.startsWith('integration.') ||
                  key.startsWith('workflow.'),
            )
            .toSet();
        // Sanity floor — the constants file must declare at least the
        // ~80 keys the plan calls for. If this trips, the constants
        // file lost coverage somewhere.
        expect(
          keys.length,
          greaterThanOrEqualTo(75),
          reason:
              'PermissionKeys.dart should declare ~80 permission keys; '
              'found ${keys.length}',
        );
        // Some catalog keys are seeded by follow-up migrations rather
        // than by the 9.0 foundation seed (so the foundation migration
        // stays a fixed-shape historical record). The h2 slice
        // (2026-04-28) added `admin.audit_privacy.read` via
        // `202604280014_phase_9_0sigma_h2_audit_privacy_role.sql`;
        // the assertion below scans every migration in `db/migrations/`
        // so a follow-up seed counts as "seeded into permission_keys"
        // for the purposes of this contract test.
        final allMigrations = StringBuffer();
        for (final entry in Directory('db/migrations').listSync()) {
          if (entry is File && entry.path.endsWith('.sql')) {
            allMigrations.write(
              entry.readAsStringSync().replaceAll('\r\n', '\n'),
            );
            allMigrations.write('\n');
          }
        }
        final allMigrationsContent = allMigrations.toString();
        // Every key declared in constants must be seeded by some
        // migration in db/migrations/.
        for (final key in keys) {
          expect(
            allMigrationsContent,
            contains("'$key'"),
            reason:
                'PermissionKeys constant $key not seeded by any '
                'db/migrations/*.sql file',
          );
        }
      },
    );

    test('MFA-required keys are flagged in the migration with requires_mfa '
        'true and documented in the catalog contract', () {
      const mfaRequiredKeys = <String>[
        'admin.users.erase_pii',
        'admin.roles.edit_seeded',
        'admin.pricing_tier.edit',
        'admin.service_principal.issue_token',
        'billing.subscription.manage',
        'billing.payment_method.manage',
        'billing.usage_caps.edit',
        'integration.key_rotate',
      ];
      for (final key in mfaRequiredKeys) {
        // The seed row for an MFA-required key carries `true, true` at
        // the (requires_mfa, frozen) tail of the values tuple.
        final escapedKey = RegExp.escape(key);
        final pattern = RegExp("'$escapedKey',[\\s\\S]*?true,\\s*true\\b");
        expect(
          pattern.hasMatch(migration),
          isTrue,
          reason: 'MFA-required key $key not flagged with requires_mfa=true',
        );
        expect(
          catalogContract,
          contains(key),
          reason: 'MFA-required key $key missing from catalog contract doc',
        );
      }
    });

    test('role grants seed super_admin with every key and other roles with '
        'enumerated key lists', () {
      // super_admin gets every key via cross join + role_key filter.
      expect(
        normalizedMigration,
        contains(
          'insert into public.role_permissions (role_id, permission_key, '
          "effect) select r.role_id, pk.key, 'allow' from public.roles r "
          'cross join public.permission_keys pk where r.role_key = '
          "'super_admin' and r.operator_id is null",
        ),
      );
      // Other roles have an enumerated `pk.key in (...)` list.
      for (final roleKey in <String>[
        'ff_support',
        'operator_owner',
        'operator_manager',
        'operator_supervisor',
        'operator_staff',
      ]) {
        expect(
          migration,
          contains("where r.role_key = '$roleKey'"),
          reason: 'role-permission seed missing for $roleKey',
        );
      }
    });

    test('migration uses TIMESTAMPTZ throughout — no `timestamp without '
        'time zone` (operator-scoped silent-DST hazard banned)', () {
      expect(
        migration.toLowerCase().contains('timestamp without time zone'),
        isFalse,
        reason:
            'TIMESTAMP WITHOUT TIME ZONE is banned in operator-scoped '
            'tables — silent DST corruption is unrecoverable.',
      );
    });

    test(
      'migration does not introduce pgmq, Firebase config, or live calls',
      () {
        // pgmq is not exposed by Azure flexible server; the queue-provider
        // choice is locked to FOR UPDATE SKIP LOCKED + Cloud Tasks (see
        // CLAUDE.md). The 9.0 schema must not reintroduce it.
        expect(migration.toLowerCase(), isNot(contains('pgmq')));
        // 9.0 is schema-only/local-first. Firebase wiring belongs to 9.1.
        expect(migration.toLowerCase(), isNot(contains('firebase_admin')));
        expect(migration.toLowerCase(), isNot(contains('http://')));
        expect(migration.toLowerCase(), isNot(contains('https://')));
      },
    );
  });

  group('ScaffoldRejectingJwtVerifier (hard-fail-closed default)', () {
    test('rejects every token with a verification error', () {
      const verifier = ScaffoldRejectingJwtVerifier();
      expect(
        verifier.verify('any.token.value'),
        throwsA(isA<ProxyJwtVerificationError>()),
      );
    });

    test('used by ProxyRequestGuard, surfaces as 401', () async {
      final guard = ProxyRequestGuard(
        verifier: const ScaffoldRejectingJwtVerifier(),
      );

      ProxyAuthError? thrown;
      try {
        await guard.requireOperatorContext(
          authorizationHeader: 'Bearer any.token.value',
        );
      } on ProxyAuthError catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      expect(thrown!.statusCode, equals(401));
      expect(thrown.message, contains('11a.10a scaffold'));
    });
  });

  group('ProxyConfig.firebaseProjectId (9.1)', () {
    Map<String, String> environmentWithAllSecrets({String? projectId}) {
      return <String, String>{
        ProxySecretNames.anthropicApiKey: 'placeholder-anthropic',
        ProxySecretNames.voyageApiKey: 'placeholder-voyage',
        ProxySecretNames.postgresUrl: 'placeholder-postgres-url',
        ProxySecretNames.postgresAdminUrl: 'placeholder-postgres-admin-url',
        ProxySecretNames.firebaseWebApiKey: 'placeholder-firebase-web-api-key',
        ProxySecretNames.servicePrincipalJwtSecret:
            'placeholder-service-principal-jwt-secret',
        if (projectId != null) ProxyConfigNames.firebaseProjectId: projectId,
      };
    }

    test('FIREBASE_PROJECT_ID absent -> null and proxy config still loads', () {
      final config = ProxyConfig.fromEnvironment(environmentWithAllSecrets());
      expect(config.firebaseProjectId, isNull);
      // Required secrets still validated; project ID is optional.
      expect(
        config.loadedSecretNames,
        containsAll(<String>[
          ProxySecretNames.anthropicApiKey,
          ProxySecretNames.voyageApiKey,
          ProxySecretNames.postgresUrl,
          ProxySecretNames.postgresAdminUrl,
          ProxySecretNames.firebaseWebApiKey,
          ProxySecretNames.servicePrincipalJwtSecret,
        ]),
      );
    });

    test('FIREBASE_PROJECT_ID blank -> null (treated like absent)', () {
      final config = ProxyConfig.fromEnvironment(
        environmentWithAllSecrets(projectId: '   '),
      );
      expect(config.firebaseProjectId, isNull);
    });

    test('FIREBASE_PROJECT_ID present -> loaded and trimmed', () {
      final config = ProxyConfig.fromEnvironment(
        environmentWithAllSecrets(projectId: '  forge-flow-staging  '),
      );
      expect(config.firebaseProjectId, equals('forge-flow-staging'));
    });

    test('toString reports firebase_project_id by SET/UNSET marker only', () {
      const projectId = 'forge-flow-staging';
      final unset = ProxyConfig.fromEnvironment(environmentWithAllSecrets());
      final set = ProxyConfig.fromEnvironment(
        environmentWithAllSecrets(projectId: projectId),
      );
      expect(unset.toString(), contains('firebase_project_id: unset'));
      expect(set.toString(), contains('firebase_project_id: set'));
      // Even though the project ID is a public identifier we keep the
      // toString convention to "names-only" so log audit grep stays
      // simple — no value should appear in toString.
      expect(set.toString(), isNot(contains(projectId)));
    });
  });

  group('ScaffoldFailingRs256SignatureValidator (9.1 fail-closed default)', () {
    test('throws StateError on every call so production fails closed', () {
      const validator = ScaffoldFailingRs256SignatureValidator();
      expect(
        () => validator.verify(
          signedInput: Uint8List.fromList(<int>[1, 2, 3]),
          signature: Uint8List.fromList(<int>[4, 5, 6]),
          keyMaterial: const JwtKeyMaterial(
            pemX509Certificate: 'placeholder-cert',
            kid: 'kid-x',
          ),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test(
      'integrated with FirebaseProxyJwtVerifier surfaces as 401 path',
      () async {
        // The verifier catches StateError from the validator and
        // re-throws as ProxyJwtVerificationError so the request guard
        // returns 401 instead of bubbling up as a 500. This is the
        // fail-closed contract: a misconfigured RSA backend must never
        // turn into a silent allow OR a leaky 500.
        final verifier = FirebaseProxyJwtVerifier(
          projectId: 'forge-flow-staging',
          keySource: _FixedJwksKeySource(<String, JwtKeyMaterial>{
            'kid-x': const JwtKeyMaterial(
              pemX509Certificate: 'placeholder',
              kid: 'kid-x',
            ),
          }),
          signatureValidator: const ScaffoldFailingRs256SignatureValidator(),
          now: () => DateTime.utc(2026, 4, 26, 12),
        );
        final token = _firebaseTestToken(
          kid: 'kid-x',
          projectId: 'forge-flow-staging',
          sub: 'user_abc',
          issuedAt: DateTime.utc(2026, 4, 26, 11, 59),
          expiresAt: DateTime.utc(2026, 4, 26, 13),
        );

        ProxyJwtVerificationError? thrown;
        try {
          await verifier.verify(token);
        } on ProxyJwtVerificationError catch (error) {
          thrown = error;
        }
        expect(thrown, isNotNull);
        expect(thrown!.message, contains('signature verification unavailable'));
      },
    );
  });

  group('PointyCastleRs256SignatureValidator (9.1 live crypto)', () {
    test(
      'verifies a real RS256 signature from x509 certificate key material',
      () {
        const validator = PointyCastleRs256SignatureValidator();
        final signedInput = Uint8List.fromList(utf8.encode('header.payload'));
        final signature = _signRs256(signedInput, _rsaFixturePrivateKey());

        expect(
          validator.verify(
            signedInput: signedInput,
            signature: signature,
            keyMaterial: JwtKeyMaterial(
              pemX509Certificate: _rsaFixtureCertificatePem(),
              kid: 'fixture-kid',
            ),
          ),
          isTrue,
        );
      },
    );

    test('returns false for a tampered RS256 signature', () {
      const validator = PointyCastleRs256SignatureValidator();
      final signedInput = Uint8List.fromList(utf8.encode('header.payload'));
      final signature = _signRs256(signedInput, _rsaFixturePrivateKey());
      signature[signature.length - 1] ^= 0x01;

      expect(
        validator.verify(
          signedInput: signedInput,
          signature: signature,
          keyMaterial: JwtKeyMaterial(
            pemX509Certificate: _rsaFixtureCertificatePem(),
            kid: 'fixture-kid',
          ),
        ),
        isFalse,
      );
    });

    test('throws a non-State error for malformed PEM so verifier returns '
        'generic signature failure', () {
      const validator = PointyCastleRs256SignatureValidator();
      expect(
        () => validator.verify(
          signedInput: Uint8List.fromList(<int>[1, 2, 3]),
          signature: Uint8List.fromList(<int>[4, 5, 6]),
          keyMaterial: const JwtKeyMaterial(
            pemX509Certificate: 'not a pem block',
            kid: 'bad-kid',
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('FirebaseProxyJwtVerifier (9.1 local Firebase ID-token verifier)', () {
    const projectId = 'forge-flow-staging';
    final fixedNow = DateTime.utc(2026, 4, 26, 12);
    const goodKid = 'kid-good';
    final keySource = _FixedJwksKeySource(<String, JwtKeyMaterial>{
      goodKid: const JwtKeyMaterial(
        pemX509Certificate: 'placeholder-cert',
        kid: goodKid,
      ),
    });

    FirebaseProxyJwtVerifier buildVerifier({
      JwtRs256SignatureValidator? signatureValidator,
      JwksKeySource? overrideKeySource,
      DateTime? now,
    }) {
      return FirebaseProxyJwtVerifier(
        projectId: projectId,
        keySource: overrideKeySource ?? keySource,
        signatureValidator:
            signatureValidator ?? const _AlwaysAcceptRs256Validator(),
        now: () => now ?? fixedNow,
      );
    }

    test(
      'happy path returns ProxyJwtClaims projected from custom claims',
      () async {
        final verifier = buildVerifier();
        final token = _firebaseTestToken(
          kid: goodKid,
          projectId: projectId,
          sub: 'user_abc',
          operatorId: 'op_777',
          locationId: 'loc_999',
          isSuperAdmin: false,
          isFfSupport: false,
          rolesVersion: 7,
          issuedAt: fixedNow.subtract(const Duration(minutes: 1)),
          expiresAt: fixedNow.add(const Duration(hours: 1)),
          authTime: fixedNow.subtract(const Duration(minutes: 2)),
        );

        final claims = await verifier.verify(token);
        expect(claims.userId, equals('user_abc'));
        expect(claims.operatorId, equals('op_777'));
        expect(claims.locationId, equals('loc_999'));
        expect(claims.roles, equals(<String>['roles_version:7']));
      },
    );

    test(
      'happy path resolves super_admin + ff_support flags into roles',
      () async {
        final verifier = buildVerifier();
        final token = _firebaseTestToken(
          kid: goodKid,
          projectId: projectId,
          sub: 'user_admin',
          operatorId: 'op_777',
          locationId: 'loc_999',
          isSuperAdmin: true,
          isFfSupport: true,
          rolesVersion: 1,
          issuedAt: fixedNow.subtract(const Duration(minutes: 1)),
          expiresAt: fixedNow.add(const Duration(hours: 1)),
        );

        final claims = await verifier.verify(token);
        expect(claims.roles, contains('super_admin'));
        expect(claims.roles, contains('ff_support'));
        expect(claims.roles, contains('roles_version:1'));
      },
    );

    test('rejects malformed JWT with fewer than 3 segments', () async {
      final verifier = buildVerifier();
      await _expectVerifierError(
        verifier.verify('not.a-jwt'),
        contains('malformed JWT'),
      );
    });

    test('rejects unsupported alg (HS256)', () async {
      final verifier = buildVerifier();
      final token = _firebaseTestToken(
        kid: goodKid,
        projectId: projectId,
        algOverride: 'HS256',
        sub: 'user_abc',
        issuedAt: fixedNow.subtract(const Duration(minutes: 1)),
        expiresAt: fixedNow.add(const Duration(hours: 1)),
      );
      await _expectVerifierError(
        verifier.verify(token),
        contains('unsupported JWT alg'),
      );
    });

    test('rejects token with missing kid header', () async {
      final verifier = buildVerifier();
      final token = _firebaseTestToken(
        kid: '',
        projectId: projectId,
        sub: 'user_abc',
        issuedAt: fixedNow.subtract(const Duration(minutes: 1)),
        expiresAt: fixedNow.add(const Duration(hours: 1)),
      );
      await _expectVerifierError(
        verifier.verify(token),
        contains('missing kid'),
      );
    });

    test('rejects wrong issuer', () async {
      final verifier = buildVerifier();
      final token = _firebaseTestToken(
        kid: goodKid,
        projectId: projectId,
        issuerOverride: 'https://securetoken.google.com/wrong-project',
        sub: 'user_abc',
        issuedAt: fixedNow.subtract(const Duration(minutes: 1)),
        expiresAt: fixedNow.add(const Duration(hours: 1)),
      );
      await _expectVerifierError(
        verifier.verify(token),
        contains('unexpected issuer'),
      );
    });

    test('rejects wrong audience', () async {
      final verifier = buildVerifier();
      final token = _firebaseTestToken(
        kid: goodKid,
        projectId: projectId,
        audienceOverride: 'wrong-audience',
        sub: 'user_abc',
        issuedAt: fixedNow.subtract(const Duration(minutes: 1)),
        expiresAt: fixedNow.add(const Duration(hours: 1)),
      );
      await _expectVerifierError(
        verifier.verify(token),
        contains('unexpected audience'),
      );
    });

    test('rejects expired token (exp before now beyond leeway)', () async {
      final verifier = buildVerifier();
      final token = _firebaseTestToken(
        kid: goodKid,
        projectId: projectId,
        sub: 'user_abc',
        issuedAt: fixedNow.subtract(const Duration(hours: 2)),
        expiresAt: fixedNow.subtract(const Duration(hours: 1)),
      );
      await _expectVerifierError(
        verifier.verify(token),
        contains('JWT expired'),
      );
    });

    test('rejects future iat (iat ahead of now beyond leeway)', () async {
      final verifier = buildVerifier();
      final token = _firebaseTestToken(
        kid: goodKid,
        projectId: projectId,
        sub: 'user_abc',
        issuedAt: fixedNow.add(const Duration(hours: 1)),
        expiresAt: fixedNow.add(const Duration(hours: 2)),
      );
      await _expectVerifierError(
        verifier.verify(token),
        contains('iat is in the future'),
      );
    });

    test('rejects future auth_time when present', () async {
      final verifier = buildVerifier();
      final token = _firebaseTestToken(
        kid: goodKid,
        projectId: projectId,
        sub: 'user_abc',
        issuedAt: fixedNow.subtract(const Duration(minutes: 1)),
        expiresAt: fixedNow.add(const Duration(hours: 1)),
        authTime: fixedNow.add(const Duration(hours: 1)),
      );
      await _expectVerifierError(
        verifier.verify(token),
        contains('auth_time is in the future'),
      );
    });

    test('rejects missing sub', () async {
      final verifier = buildVerifier();
      final token = _firebaseTestToken(
        kid: goodKid,
        projectId: projectId,
        sub: '',
        issuedAt: fixedNow.subtract(const Duration(minutes: 1)),
        expiresAt: fixedNow.add(const Duration(hours: 1)),
      );
      await _expectVerifierError(verifier.verify(token), contains('sub'));
    });

    test('rejects unknown kid (no JWK in source for given kid)', () async {
      final verifier = buildVerifier();
      final token = _firebaseTestToken(
        kid: 'kid-unknown',
        projectId: projectId,
        sub: 'user_abc',
        issuedAt: fixedNow.subtract(const Duration(minutes: 1)),
        expiresAt: fixedNow.add(const Duration(hours: 1)),
      );
      await _expectVerifierError(
        verifier.verify(token),
        contains('no matching JWK'),
      );
    });

    test('rejects invalid signature (validator returns false)', () async {
      final verifier = buildVerifier(
        signatureValidator: const _AlwaysRejectRs256Validator(),
      );
      final token = _firebaseTestToken(
        kid: goodKid,
        projectId: projectId,
        sub: 'user_abc',
        issuedAt: fixedNow.subtract(const Duration(minutes: 1)),
        expiresAt: fixedNow.add(const Duration(hours: 1)),
      );
      await _expectVerifierError(
        verifier.verify(token),
        contains('signature did not verify'),
      );
    });

    test(
      'rejects invalid signature (validator throws non-State error)',
      () async {
        // Real RSA backends may surface format/parse failures as
        // arbitrary exceptions. The verifier must NOT propagate the
        // raw exception (could carry internal state); it surfaces a
        // generic "signature verification failed" reason instead.
        final verifier = buildVerifier(
          signatureValidator: const _BoomRs256Validator(),
        );
        final token = _firebaseTestToken(
          kid: goodKid,
          projectId: projectId,
          sub: 'user_abc',
          issuedAt: fixedNow.subtract(const Duration(minutes: 1)),
          expiresAt: fixedNow.add(const Duration(hours: 1)),
        );
        await _expectVerifierError(
          verifier.verify(token),
          contains('signature verification failed'),
        );
      },
    );

    test('rejects header that is not valid base64url', () async {
      final verifier = buildVerifier();
      const badToken = 'not-base64!!.payload.signature';
      await _expectVerifierError(
        verifier.verify(badToken),
        contains('header is not valid base64url'),
      );
    });

    test('verified token without operator scope still surfaces as 403 via '
        'request guard', () async {
      // The verifier returns claims with operator_id NULL when the
      // custom claim is absent. ProxyRequestGuard then rejects as
      // 403 because the scope contract requires both operator and
      // location. Cross-tenant denial happens at the scope/RLS layer
      // (9.2+); the verifier itself is scope-agnostic.
      final verifier = buildVerifier();
      final token = _firebaseTestToken(
        kid: goodKid,
        projectId: projectId,
        sub: 'user_abc',
        issuedAt: fixedNow.subtract(const Duration(minutes: 1)),
        expiresAt: fixedNow.add(const Duration(hours: 1)),
        operatorId: null,
        locationId: null,
      );
      final guard = ProxyRequestGuard(verifier: verifier);

      ProxyAuthError? thrown;
      try {
        await guard.requireOperatorContext(
          authorizationHeader: 'Bearer $token',
        );
      } on ProxyAuthError catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      expect(thrown!.statusCode, equals(403));
    });
  });

  group('HTTP scaffold (routeRequest via local HttpServer)', () {
    // Flutter's test environment installs a global HttpOverrides that
    // returns 400 for any real HTTP call. Temporarily clear it for
    // each scaffold test so we can exercise routeRequest end-to-end
    // against a localhost server. Restored after the test body.
    Future<T> withRealHttp<T>(Future<T> Function() body) async {
      final saved = HttpOverrides.current;
      HttpOverrides.global = null;
      try {
        return await body();
      } finally {
        HttpOverrides.global = saved;
      }
    }

    late HttpServer server;
    late HttpClient client;
    late _SettableVerifier verifier;
    late Uri baseUri;

    Future<void> spinUpServer({
      ProxyUsageGuard? usageGuard,
      ProxyAccountingStore? accountingStore,
      ProxyHealthCheckStore? healthCheckStore,
      ProxyLlmProvider? llmProvider,
      AdvisorRequestPipeline? advisorRequestPipeline,
      AuthSessionLedgerWriter? authSessionLedgerWriter,
      FirebaseAdminAuthClient? firebaseAdminAuthClient,
      bool trustProxyAuditHeaders = false,
      ProxyRequestLogPolicy requestLogPolicy =
          const ProxyRequestLogPolicy.metaOnly(),
    }) async {
      verifier = _SettableVerifier();
      final guard = ProxyRequestGuard(verifier: verifier);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // ignore: unawaited_futures
      server.listen((request) async {
        try {
          await routeRequest(
            request,
            guard,
            usageGuard: usageGuard,
            accountingStore: accountingStore,
            healthCheckStore: healthCheckStore,
            llmProvider: llmProvider,
            advisorRequestPipeline: advisorRequestPipeline,
            authSessionLedgerWriter: authSessionLedgerWriter,
            firebaseAdminAuthClient: firebaseAdminAuthClient,
            trustProxyAuditHeaders: trustProxyAuditHeaders,
            requestLogPolicy: requestLogPolicy,
            now: () => DateTime.utc(2026, 4, 26, 12),
          );
        } catch (_) {
          try {
            request.response.statusCode = 500;
            await request.response.close();
          } catch (_) {
            /* ignore */
          }
        }
      });
      client = HttpClient();
      baseUri = Uri.parse('http://${server.address.host}:${server.port}');
    }

    Future<void> shutDown() async {
      client.close(force: true);
      await server.close(force: true);
    }

    test('GET /healthz and /readyz return 200 ok unauthenticated', () async {
      await withRealHttp(() async {
        await spinUpServer();
        try {
          for (final path in <String>[healthPath, readinessPath]) {
            final response = await _httpGet(client, baseUri.resolve(path));
            expect(response.statusCode, equals(200));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['status'], equals('ok'));
          }
        } finally {
          await shutDown();
        }
      });
    });

    test('GET /health without a health store returns 503', () async {
      await withRealHttp(() async {
        await spinUpServer();
        try {
          final response = await _httpGet(
            client,
            baseUri.resolve(deepHealthPath),
          );
          expect(response.statusCode, equals(503));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['status'], equals('unavailable'));
          expect(body['severity'], equals('red'));
          expect(body['contract'], equals('proxy_health.v1'));
          expect(body['error'], equals('health_check_not_configured'));
        } finally {
          await shutDown();
        }
      });
    });

    test(
      'GET /health returns 200 only when Postgres, AGE, and pgvector pass',
      () async {
        await withRealHttp(() async {
          await spinUpServer(
            healthCheckStore: const _FixedHealthStore(
              ProxyHealthStatus(
                postgresOk: true,
                ageOk: true,
                pgvectorOk: true,
              ),
            ),
          );
          try {
            final response = await _httpGet(
              client,
              baseUri.resolve(deepHealthPath),
            );
            expect(response.statusCode, equals(200));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['status'], equals('ok'));
            expect(body['severity'], equals('green'));
            expect(body['contract'], equals('proxy_health.v1'));
            expect(body['schema_version'], equals(1));
            expect(body['checked_at'], equals('2026-04-26T12:00:00.000Z'));
            expect(body['postgres_select_1'], equals('ok'));
            expect(body['age_cypher_match'], equals('ok'));
            expect(body['pgvector_similarity'], equals('ok'));
            final dependencies = body['dependencies']! as Map<String, Object?>;
            expect(
              (dependencies['postgres']! as Map<String, Object?>)['status'],
              equals('green'),
            );
            expect(
              (dependencies['age']! as Map<String, Object?>)['legacy_key'],
              equals('age_cypher_match'),
            );
            final metrics = body['metrics']! as Map<String, Object?>;
            expect(metrics.keys, contains('audit_chain_lag_seconds'));
            expect(metrics.keys, contains('event_outbox_undelivered_count'));
            expect(metrics.keys, contains('event_outbox_lag_seconds'));
            expect(metrics.keys, contains('usage_caps_breach_count'));
            expect(metrics.keys, contains('graph_node_count'));
            expect(metrics.keys, contains('graph_edge_count'));
            expect(metrics.keys, contains('graph_traversal_latency_ms'));
            expect(metrics.keys, contains('vector_index_size_per_corpus'));
            expect(metrics.keys, contains('vector_query_latency_ms'));
            expect(metrics.keys, contains('vector_recall'));
            expect(metrics.keys, contains('rollup_freshness_per_grain'));
            expect(
              (metrics['graph_edge_count']! as Map<String, Object?>)['status'],
              equals('unknown'),
            );
            expect(
              (metrics['graph_edge_count']! as Map<String, Object?>)['value'],
              isNull,
            );
            final surfaces = body['surfaces']! as Map<String, Object?>;
            expect(
              surfaces.keys,
              containsAll(<String>[
                'audit_chain',
                'event_outbox',
                'usage_caps',
                'graph',
                'vector',
                'rollups',
              ]),
            );
            expect(
              (surfaces['graph']! as Map<String, Object?>)['metrics'],
              containsAll(<String>[
                'graph_node_count',
                'graph_edge_count',
                'graph_traversal_latency_ms',
              ]),
            );
          } finally {
            await shutDown();
          }
        });
      },
    );

    test('GET /health returns 503 when one dependency check fails', () async {
      await withRealHttp(() async {
        await spinUpServer(
          healthCheckStore: const _FixedHealthStore(
            ProxyHealthStatus(postgresOk: true, ageOk: false, pgvectorOk: true),
          ),
        );
        try {
          final response = await _httpGet(
            client,
            baseUri.resolve(deepHealthPath),
          );
          expect(response.statusCode, equals(503));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['status'], equals('unavailable'));
          expect(body['severity'], equals('red'));
          expect(body['age_cypher_match'], equals('failed'));
          final dependencies = body['dependencies']! as Map<String, Object?>;
          expect(
            (dependencies['age']! as Map<String, Object?>)['status'],
            equals('red'),
          );
        } finally {
          await shutDown();
        }
      });
    });

    test('GET /health degrades for populated non-blocking metrics', () async {
      await withRealHttp(() async {
        await spinUpServer(
          healthCheckStore: const _FixedHealthStore(
            ProxyHealthStatus(
              postgresOk: true,
              ageOk: true,
              pgvectorOk: true,
              metrics: <String, ProxyHealthMetric>{
                'usage_caps_breach_count': ProxyHealthMetric(
                  status: 'yellow',
                  value: 1,
                  unit: 'count',
                  description:
                      'Requests refused because usage caps were reached.',
                  owner: 'B33',
                  thresholds: <String, Object?>{'yellow': 1, 'red': 10},
                ),
              },
            ),
          ),
        );
        try {
          final response = await _httpGet(
            client,
            baseUri.resolve(deepHealthPath),
          );
          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['status'], equals('degraded'));
          expect(body['severity'], equals('yellow'));
          final metrics = body['metrics']! as Map<String, Object?>;
          expect(
            (metrics['usage_caps_breach_count']!
                as Map<String, Object?>)['status'],
            equals('yellow'),
          );
        } finally {
          await shutDown();
        }
      });
    });

    test('GET /v1/scope without Authorization returns 401', () async {
      await withRealHttp(() async {
        await spinUpServer();
        try {
          final response = await _httpGet(
            client,
            baseUri.resolve(scopeSmokePath),
          );
          expect(response.statusCode, equals(401));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], isA<String>());
        } finally {
          await shutDown();
        }
      });
    });

    test('GET /v1/scope with verifier failure returns 401', () async {
      await withRealHttp(() async {
        await spinUpServer();
        try {
          verifier.errorMessage = 'expired token';
          final response = await _httpGet(
            client,
            baseUri.resolve(scopeSmokePath),
            authorization: 'Bearer some.fake.token',
          );
          expect(response.statusCode, equals(401));
        } finally {
          await shutDown();
        }
      });
    });

    test(
      'GET /v1/scope with verified-but-unscoped token returns 403',
      () async {
        await withRealHttp(() async {
          await spinUpServer();
          try {
            verifier.claims = const ProxyJwtClaims(
              userId: 'user_x',
              operatorId: null,
              locationId: 'loc_y',
              roles: <String>[],
            );
            final response = await _httpGet(
              client,
              baseUri.resolve(scopeSmokePath),
              authorization: 'Bearer some.fake.token',
            );
            expect(response.statusCode, equals(403));
          } finally {
            await shutDown();
          }
        });
      },
    );

    test('GET /v1/scope happy path returns 200 with operator/location echo '
        'and notes the slice does not call providers', () async {
      await withRealHttp(() async {
        await spinUpServer();
        try {
          verifier.claims = const ProxyJwtClaims(
            userId: 'user_x',
            operatorId: 'op_777',
            locationId: 'loc_999',
            roles: <String>['advisor.read'],
          );

          final response = await _httpGet(
            client,
            baseUri.resolve(scopeSmokePath),
            authorization: 'Bearer some.fake.token',
          );

          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['user_id'], equals('user_x'));
          expect(body['operator_id'], equals('op_777'));
          expect(body['location_id'], equals('loc_999'));
          expect(body['roles'], equals(<String>['advisor.read']));
          expect(body['note'], contains('11a.10a'));
          expect(body['note'], contains('No provider call performed'));
        } finally {
          await shutDown();
        }
      });
    });

    test('unknown route returns 404', () async {
      await withRealHttp(() async {
        await spinUpServer();
        try {
          final response = await _httpGet(
            client,
            baseUri.resolve('/no-such-route'),
          );
          expect(response.statusCode, equals(404));
        } finally {
          await shutDown();
        }
      });
    });

    // ── /v1/usage-smoke (11a.10b) ────────────────────────────────────────

    test('GET /v1/usage-smoke without a usage guard returns 503', () async {
      await withRealHttp(() async {
        await spinUpServer();
        try {
          final response = await _httpGet(
            client,
            baseUri.resolve(usageSmokePath),
          );
          expect(response.statusCode, equals(503));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('usage_guard_not_configured'));
        } finally {
          await shutDown();
        }
      });
    });

    test('GET /v1/usage-smoke without Authorization returns 401 even with '
        'a configured usage guard', () async {
      await withRealHttp(() async {
        await spinUpServer(
          usageGuard: ProxyUsageGuard(
            store: _FixedSnapshotStore(
              snapshot: UsageSnapshot(
                requestsThisMinute: 0,
                costCentsThisMonth: 0,
                minuteBucketStart: DateTime.utc(2026, 4, 25, 12, 0),
                monthBucketStart: DateTime.utc(2026, 4, 1),
              ),
            ),
            tierResolver: const FixedLaunchTierResolver(),
          ),
        );
        try {
          final response = await _httpGet(
            client,
            baseUri.resolve(usageSmokePath),
          );
          expect(response.statusCode, equals(401));
        } finally {
          await shutDown();
        }
      });
    });

    test('GET /v1/usage-smoke with a non-StateError store failure returns 503 '
        'usage_store_unavailable without leaking raw error text', () async {
      await withRealHttp(() async {
        await spinUpServer(
          usageGuard: ProxyUsageGuard(
            store: _BoomStore(
              error: const FormatException(
                'pretend-secret-bearing-detail '
                'postgres://user:password@host:5432/db',
              ),
            ),
            tierResolver: const FixedLaunchTierResolver(),
          ),
        );
        try {
          verifier.claims = const ProxyJwtClaims(
            userId: 'user_x',
            operatorId: 'op_777',
            locationId: 'loc_999',
            roles: <String>['advisor.read'],
          );
          final response = await _httpGet(
            client,
            baseUri.resolve(usageSmokePath),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(503));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('usage_store_unavailable'));
          expect(body['tier_id'], equals('launch'));
          expect(body['reason'], equals('unexpected store failure'));
          expect(response.body, isNot(contains('pretend-secret')));
          expect(response.body, isNot(contains('postgres://')));
        } finally {
          await shutDown();
        }
      });
    });

    test(
      'GET /v1/usage-smoke with the scaffold-failing store returns 503',
      () async {
        await withRealHttp(() async {
          await spinUpServer(
            usageGuard: ProxyUsageGuard(
              store: const ScaffoldFailingUsageCounterStore(),
              tierResolver: const FixedLaunchTierResolver(),
            ),
          );
          try {
            verifier.claims = const ProxyJwtClaims(
              userId: 'user_x',
              operatorId: 'op_777',
              locationId: 'loc_999',
              roles: <String>['advisor.read'],
            );
            final response = await _httpGet(
              client,
              baseUri.resolve(usageSmokePath),
              authorization: 'Bearer fake.token',
            );
            expect(response.statusCode, equals(503));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('usage_store_unavailable'));
            expect(body['tier_id'], equals('launch'));
          } finally {
            await shutDown();
          }
        });
      },
    );

    test(
      'GET /v1/usage-smoke with an over-token estimate returns 413',
      () async {
        await withRealHttp(() async {
          // Counter store should never be called on this path.
          final store = _RecordingStore();
          await spinUpServer(
            usageGuard: ProxyUsageGuard(
              store: store,
              tierResolver: const FixedLaunchTierResolver(),
            ),
          );
          try {
            verifier.claims = const ProxyJwtClaims(
              userId: 'user_x',
              operatorId: 'op_777',
              locationId: 'loc_999',
              roles: <String>['advisor.read'],
            );
            final overTokens = PolicyTier.launch.maxRequestTokens + 1;
            final response = await _httpGet(
              client,
              baseUri
                  .resolve(usageSmokePath)
                  .replace(
                    queryParameters: <String, String>{
                      'est_tokens': overTokens.toString(),
                    },
                  ),
              authorization: 'Bearer fake.token',
            );
            expect(response.statusCode, equals(413));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('request_too_large'));
            expect(body['tier_id'], equals('launch'));
            expect(store.currentUsageCalls, equals(0));
          } finally {
            await shutDown();
          }
        });
      },
    );

    test('GET /v1/usage-smoke at the per-minute cap returns 429', () async {
      await withRealHttp(() async {
        await spinUpServer(
          usageGuard: ProxyUsageGuard(
            store: _FixedSnapshotStore(
              snapshot: UsageSnapshot(
                requestsThisMinute: PolicyTier.launch.maxRequestsPerMinute,
                costCentsThisMonth: 0,
                minuteBucketStart: DateTime.utc(2026, 4, 25, 12, 0),
                monthBucketStart: DateTime.utc(2026, 4, 1),
              ),
            ),
            tierResolver: const FixedLaunchTierResolver(),
          ),
        );
        try {
          verifier.claims = const ProxyJwtClaims(
            userId: 'user_x',
            operatorId: 'op_777',
            locationId: 'loc_999',
            roles: <String>['advisor.read'],
          );
          final response = await _httpGet(
            client,
            baseUri.resolve(usageSmokePath),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(429));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('rate_limited'));
        } finally {
          await shutDown();
        }
      });
    });

    test('GET /v1/usage-smoke at the monthly cost cap returns 402', () async {
      await withRealHttp(() async {
        await spinUpServer(
          usageGuard: ProxyUsageGuard(
            store: _FixedSnapshotStore(
              snapshot: UsageSnapshot(
                requestsThisMinute: 0,
                costCentsThisMonth: PolicyTier.launch.maxMonthlyCostCents,
                minuteBucketStart: DateTime.utc(2026, 4, 25, 12, 0),
                monthBucketStart: DateTime.utc(2026, 4, 1),
              ),
            ),
            tierResolver: const FixedLaunchTierResolver(),
          ),
        );
        try {
          verifier.claims = const ProxyJwtClaims(
            userId: 'user_x',
            operatorId: 'op_777',
            locationId: 'loc_999',
            roles: <String>['advisor.read'],
          );
          final response = await _httpGet(
            client,
            baseUri.resolve(usageSmokePath),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(402));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('monthly_cap_reached'));
        } finally {
          await shutDown();
        }
      });
    });

    test('GET /v1/usage-smoke happy path returns the contracted '
        '{tier, minute_remaining, month_remaining} envelope', () async {
      await withRealHttp(() async {
        await spinUpServer(
          usageGuard: ProxyUsageGuard(
            store: _FixedSnapshotStore(
              snapshot: UsageSnapshot(
                requestsThisMinute: 5,
                costCentsThisMonth: 250,
                minuteBucketStart: DateTime.utc(2026, 4, 25, 12, 0),
                monthBucketStart: DateTime.utc(2026, 4, 1),
              ),
            ),
            tierResolver: const FixedLaunchTierResolver(),
          ),
        );
        try {
          verifier.claims = const ProxyJwtClaims(
            userId: 'user_x',
            operatorId: 'op_777',
            locationId: 'loc_999',
            roles: <String>['advisor.read'],
          );

          final response = await _httpGet(
            client,
            baseUri
                .resolve(usageSmokePath)
                .replace(
                  queryParameters: <String, String>{'est_tokens': '256'},
                ),
            authorization: 'Bearer fake.token',
          );

          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          // HARD-A: contracted envelope is `{tier, minute_remaining,
          // month_remaining}`. Tenant identifiers MUST NOT appear in
          // the response.
          expect(body['tier'], equals('launch'));
          expect(
            body['minute_remaining'],
            equals(PolicyTier.launch.maxRequestsPerMinute - 5),
          );
          expect(
            body['month_remaining'],
            equals(PolicyTier.launch.maxMonthlyCostCents - 250),
          );
          expect(body.containsKey('user_id'), isFalse);
          expect(body.containsKey('operator_id'), isFalse);
          expect(body.containsKey('location_id'), isFalse);
          // Tier policy metadata is still echoed for caller convenience.
          expect(
            body['request_timeout_seconds'],
            equals(PolicyTier.launch.requestTimeoutSeconds),
          );
          expect(
            body['max_output_tokens'],
            equals(PolicyTier.launch.maxOutputTokens),
          );
          expect(body['estimate_request_tokens'], equals(256));
        } finally {
          await shutDown();
        }
      });
    });

    // -- /v1/advisor-smoke (11a.11d) ---------------------------------------

    test('GET /v1/advisor-smoke requires an idempotency key', () async {
      await withRealHttp(() async {
        await spinUpServer(
          accountingStore: _InMemoryAccountingStore.open(),
          llmProvider: _RecordingLlmProvider(),
        );
        try {
          verifier.claims = _claims();
          final response = await _httpGet(
            client,
            baseUri.resolve(advisorSmokePath),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('missing_idempotency_key'));
        } finally {
          await shutDown();
        }
      });
    });

    test(
      'GET /v1/advisor-smoke refuses over-cap before provider call',
      () async {
        await withRealHttp(() async {
          final llm = _RecordingLlmProvider();
          await spinUpServer(
            accountingStore: _InMemoryAccountingStore(
              capStatus: const ProxyCapStatus(
                usageClass: 'advisor_qa',
                monthlyCapCents: 1,
                monthlyUsedCents: 1,
                perInvocationCapCents: 1,
                estimatedCostCents: 1,
              ),
            ),
            llmProvider: llm,
          );
          try {
            verifier.claims = _claims();
            final response = await _httpGet(
              client,
              baseUri.resolve(advisorSmokePath),
              authorization: 'Bearer fake.token',
              headers: const <String, String>{
                'Idempotency-Key': 'idem-overcap',
              },
            );
            expect(response.statusCode, equals(402));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('usage_cap_reached'));
            expect(body['cap_status'], isA<Map<String, Object?>>());
            expect(llm.completeCalls, equals(0));
          } finally {
            await shutDown();
          }
        });
      },
    );

    test('GET /v1/advisor-smoke happy path routes tier, caches stable prompt '
        'blocks, writes accounting, and logs meta-only by default', () async {
      await withRealHttp(() async {
        final store = _InMemoryAccountingStore.open();
        final llm = _RecordingLlmProvider();
        await spinUpServer(accountingStore: store, llmProvider: llm);
        try {
          verifier.claims = _claims();
          final response = await _httpGet(
            client,
            baseUri
                .resolve(advisorSmokePath)
                .replace(
                  queryParameters: <String, String>{
                    'subscription_tier': 'premium',
                    'query_class': 'recommendation',
                    'corpus_version': 'launch_v2',
                    'q': 'private operator question',
                  },
                ),
            authorization: 'Bearer fake.token',
            headers: const <String, String>{'Idempotency-Key': 'idem-happy'},
          );

          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['llm_tier'], equals('sonnet'));
          expect(body['model_used'], equals('claude-sonnet-4-6'));
          expect(body['cache_key'], equals('advisor-corpus:launch_v2'));
          expect(
            body['prompt_cache_breakpoints'],
            equals(<Object?>[
              'system_prompt',
              'tool_definitions',
              'corpus_context:launch_v2',
            ]),
          );
          expect(store.completeCalls, equals(1));
          expect(llm.completeCalls, equals(1));
          expect(llm.lastRequest!.tier, equals(ProxyLlmTier.sonnet));
          final log = body['request_log_preview'] as Map<String, Object?>;
          expect(log['content_logging'], equals('meta_only'));
          expect(log, isNot(containsPair('question', anything)));
          expect(log, isNot(containsPair('answer', anything)));
        } finally {
          await shutDown();
        }
      });
    });

    test('GET /v1/advisor-smoke idempotent retry replays stored response '
        'without a second provider call', () async {
      await withRealHttp(() async {
        final store = _InMemoryAccountingStore.open();
        final llm = _RecordingLlmProvider();
        await spinUpServer(accountingStore: store, llmProvider: llm);
        try {
          verifier.claims = _claims();
          final uri = baseUri.resolve(advisorSmokePath);
          final first = await _httpGet(
            client,
            uri,
            authorization: 'Bearer fake.token',
            headers: const <String, String>{'Idempotency-Key': 'idem-retry'},
          );
          final second = await _httpGet(
            client,
            uri,
            authorization: 'Bearer fake.token',
            headers: const <String, String>{'Idempotency-Key': 'idem-retry'},
          );

          expect(first.statusCode, equals(200));
          expect(second.statusCode, equals(200));
          final replay = jsonDecode(second.body) as Map<String, Object?>;
          expect(replay['idempotent_replay'], isTrue);
          expect(llm.completeCalls, equals(1));
          expect(store.completeCalls, equals(1));
        } finally {
          await shutDown();
        }
      });
    });

    test('GET /v1/advisor-smoke can include full content only when the '
        'operator logging policy opts in', () async {
      await withRealHttp(() async {
        await spinUpServer(
          accountingStore: _InMemoryAccountingStore.open(),
          llmProvider: _RecordingLlmProvider(),
          requestLogPolicy: const ProxyRequestLogPolicy(
            fullContentLoggingEnabled: true,
          ),
        );
        try {
          verifier.claims = _claims();
          final response = await _httpGet(
            client,
            baseUri
                .resolve(advisorSmokePath)
                .replace(
                  queryParameters: const <String, String>{
                    'q': 'operator opted into content logging',
                  },
                ),
            authorization: 'Bearer fake.token',
            headers: const <String, String>{'Idempotency-Key': 'idem-full-log'},
          );

          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          final log = body['request_log_preview'] as Map<String, Object?>;
          expect(log['content_logging'], equals('full'));
          expect(
            log['question'],
            equals('operator opted into content logging'),
          );
          expect(log['answer'], equals('fake advisor answer'));
        } finally {
          await shutDown();
        }
      });
    });

    test('GET /v1/advisor-smoke pipeline path: primary success commits '
        'final estimate (input + output) with circuit_state=closed', () async {
      await withRealHttp(() async {
        final store = _InMemoryAccountingStore.open();
        final llm = _RecordingLlmProvider();
        final breaker = CircuitBreaker(providerId: 'anthropic');
        final pipeline = AdvisorRequestPipeline(
          breaker: breaker,
          cache: const AlwaysMissAdvisorResponseCache(),
        );
        await spinUpServer(
          accountingStore: store,
          llmProvider: llm,
          advisorRequestPipeline: pipeline,
        );
        try {
          verifier.claims = _claims();
          final response = await _httpGet(
            client,
            baseUri.resolve(advisorSmokePath).replace(
              queryParameters: const <String, String>{
                'tokens': '50',
                'cost_cents': '10',
              },
            ),
            authorization: 'Bearer fake.token',
            headers: const <String, String>{'Idempotency-Key': 'idem-pipe-ok'},
          );
          expect(response.statusCode, equals(200));
          expect(store.commitCalls, equals(1));
          final committed = store.lastCommittedTelemetry!;
          expect(committed.circuitState, equals('closed'));
          expect(committed.fallbackUsed, equals('none'));
          expect(committed.cacheHit, isFalse);
          // _RecordingLlmProvider returns outputTokens=12, costCents=1.
          expect(store.lastCommittedTokenCount, equals(50 + 12));
          expect(store.lastCommittedCostCents, equals(10 + 1));
        } finally {
          await shutDown();
        }
      });
    });

    test('GET /v1/advisor-smoke pipeline path: breaker-open + cache miss '
        'commits cacheHit=false, fallback_used=refusal, zero usage', () async {
      await withRealHttp(() async {
        final store = _InMemoryAccountingStore.open();
        final llm = _RecordingLlmProvider();
        final breaker = CircuitBreaker(providerId: 'anthropic')
          ..recordFailure(FailureKind.unknown)
          ..recordFailure(FailureKind.unknown)
          ..recordFailure(FailureKind.unknown);
        expect(breaker.state, equals(CircuitState.open));
        final pipeline = AdvisorRequestPipeline(
          breaker: breaker,
          cache: const AlwaysMissAdvisorResponseCache(),
        );
        await spinUpServer(
          accountingStore: store,
          llmProvider: llm,
          advisorRequestPipeline: pipeline,
        );
        try {
          verifier.claims = _claims();
          final response = await _httpGet(
            client,
            baseUri.resolve(advisorSmokePath),
            authorization: 'Bearer fake.token',
            headers: const <String, String>{
              'Idempotency-Key': 'idem-pipe-refusal',
            },
          );
          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('service_degraded'));
          final degraded = body['degraded'] as Map<String, Object?>;
          expect(degraded['circuit_state'], equals('open'));
          expect(degraded['cached_answer'], isNull);

          final committed = store.lastCommittedTelemetry!;
          expect(committed.circuitState, equals('open'));
          expect(committed.fallbackUsed, equals('refusal'));
          expect(committed.cacheHit, isFalse);
          expect(store.lastCommittedTokenCount, equals(0));
          expect(store.lastCommittedCostCents, equals(0));
          expect(llm.completeCalls, equals(0));
        } finally {
          await shutDown();
        }
      });
    });

    test('GET /v1/advisor-smoke pipeline path: breaker-open + cache hit '
        'commits cacheHit=true, fallback_used=cache, zero usage', () async {
      await withRealHttp(() async {
        final store = _InMemoryAccountingStore.open();
        final llm = _RecordingLlmProvider();
        final breaker = CircuitBreaker(providerId: 'anthropic')
          ..recordFailure(FailureKind.unknown)
          ..recordFailure(FailureKind.unknown)
          ..recordFailure(FailureKind.unknown);
        final pipeline = AdvisorRequestPipeline(
          breaker: breaker,
          cache: const _StaticHitAdvisorCache('previous cached answer'),
        );
        await spinUpServer(
          accountingStore: store,
          llmProvider: llm,
          advisorRequestPipeline: pipeline,
        );
        try {
          verifier.claims = _claims();
          final response = await _httpGet(
            client,
            baseUri.resolve(advisorSmokePath),
            authorization: 'Bearer fake.token',
            headers: const <String, String>{
              'Idempotency-Key': 'idem-pipe-cache',
            },
          );
          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          final degraded = body['degraded'] as Map<String, Object?>;
          expect(degraded['cached_answer'], equals('previous cached answer'));

          final committed = store.lastCommittedTelemetry!;
          expect(committed.circuitState, equals('open'));
          expect(committed.fallbackUsed, equals('cache'));
          expect(committed.cacheHit, isTrue);
          expect(store.lastCommittedTokenCount, equals(0));
          expect(store.lastCommittedCostCents, equals(0));
        } finally {
          await shutDown();
        }
      });
    });

    test(
      'GET /readyz still 200 unauthenticated when usage guard is installed',
      () async {
        await withRealHttp(() async {
          await spinUpServer(
            usageGuard: ProxyUsageGuard(
              store: const ScaffoldFailingUsageCounterStore(),
              tierResolver: const FixedLaunchTierResolver(),
            ),
          );
          try {
            final response = await _httpGet(
              client,
              baseUri.resolve(readinessPath),
            );
            expect(response.statusCode, equals(200));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['status'], equals('ok'));
          } finally {
            await shutDown();
          }
        });
      },
    );

    // ─── Phase 9 B6 — auth-session ledger endpoints ───────────────────
    //
    // Coverage matrix (per route):
    //   * happy path: writer received the right scope + body fields,
    //     response carries the documented narrow JSON shape.
    //   * 503 when no writer is wired (route was reached but ledger
    //     dependency is missing — analogous to /v1/usage-smoke 503).
    //   * 503 when the writer throws (no error stack leaks past the
    //     proxy boundary).
    //   * 401 / 403 / 400 for missing auth / bad scope / malformed
    //     body (covered by the cross-route guard tests above plus
    //     dedicated body-validation cases here).
    //   * verifies the request never echoes the bearer token or the
    //     `token_hash` value through the response body.

    test(
      'POST /v1/auth/session/login without writer wired returns 503',
      () async {
        await withRealHttp(() async {
          await spinUpServer();
          try {
            // Verifier returns a valid scope so the route reaches the
            // writer-not-wired branch instead of failing on auth.
            verifier.claims = const ProxyJwtClaims(
              userId: 'u',
              operatorId: 'op',
              locationId: 'loc',
              roles: <String>[],
            );
            final response = await _httpPost(
              client,
              baseUri.resolve(authSessionLoginPath),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{'token_hash': 'h'},
            );
            expect(response.statusCode, equals(503));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('auth_session_ledger_not_configured'));
          } finally {
            await shutDown();
          }
        });
      },
    );

    test(
      'POST /v1/auth/session/login without Authorization returns 401',
      () async {
        await withRealHttp(() async {
          await spinUpServer(
            authSessionLedgerWriter: _RecordingAuthSessionLedger(),
          );
          try {
            final response = await _httpPost(
              client,
              baseUri.resolve(authSessionLoginPath),
              body: const <String, Object?>{'token_hash': 'h'},
            );
            expect(response.statusCode, equals(401));
          } finally {
            await shutDown();
          }
        });
      },
    );

    test('POST /v1/auth/session/login with verified-but-unscoped token '
        'returns 403', () async {
      await withRealHttp(() async {
        await spinUpServer(
          authSessionLedgerWriter: _RecordingAuthSessionLedger(),
        );
        try {
          // operator/location scope absent — request guard rejects 403.
          verifier.claims = const ProxyJwtClaims(
            userId: 'u',
            operatorId: null,
            locationId: 'loc',
            roles: <String>[],
          );
          final response = await _httpPost(
            client,
            baseUri.resolve(authSessionLoginPath),
            authorization: 'Bearer fake.token',
            body: const <String, Object?>{'token_hash': 'h'},
          );
          expect(response.statusCode, equals(403));
        } finally {
          await shutDown();
        }
      });
    });

    test('POST /v1/auth/session/login rejects empty body with 400 '
        'malformed_json_body', () async {
      await withRealHttp(() async {
        await spinUpServer(
          authSessionLedgerWriter: _RecordingAuthSessionLedger(),
        );
        try {
          verifier.claims = const ProxyJwtClaims(
            userId: 'u',
            operatorId: 'op',
            locationId: 'loc',
            roles: <String>[],
          );
          final response = await _httpPost(
            client,
            baseUri.resolve(authSessionLoginPath),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('malformed_json_body'));
        } finally {
          await shutDown();
        }
      });
    });

    test('POST /v1/auth/session/login rejects body without token_hash '
        'with 400 missing_token_hash', () async {
      await withRealHttp(() async {
        await spinUpServer(
          authSessionLedgerWriter: _RecordingAuthSessionLedger(),
        );
        try {
          verifier.claims = const ProxyJwtClaims(
            userId: 'u',
            operatorId: 'op',
            locationId: 'loc',
            roles: <String>[],
          );
          final response = await _httpPost(
            client,
            baseUri.resolve(authSessionLoginPath),
            authorization: 'Bearer fake.token',
            body: const <String, Object?>{'wrong': 'field'},
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('missing_token_hash'));
        } finally {
          await shutDown();
        }
      });
    });

    test('POST /v1/auth/session/login trusted-ingress mode: writer receives '
        'operator/location/user from claims + IP/UA/geo from headers, '
        'response carries session_id + scope, no token leak', () async {
      await withRealHttp(() async {
        final ledger = _RecordingAuthSessionLedger(
          loginSessionIds: <String>['session-from-proxy'],
        );
        await spinUpServer(
          authSessionLedgerWriter: ledger,
          trustProxyAuditHeaders: true,
        );
        try {
          verifier.claims = const ProxyJwtClaims(
            userId: 'user-uuid',
            operatorId: 'operator-uuid',
            locationId: 'location-uuid',
            roles: <String>['operator_owner'],
          );
          final response = await _httpPost(
            client,
            baseUri.resolve(authSessionLoginPath),
            authorization: 'Bearer placeholder.id.token',
            body: const <String, Object?>{'token_hash': 'sha256-hex-hash'},
            headers: const <String, String>{
              'X-Forwarded-For': '203.0.113.7, 10.0.0.1',
              'User-Agent': 'forge-and-flow-test/1.0',
              'X-Country': 'ca',
            },
          );

          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['session_id'], equals('session-from-proxy'));
          expect(body['user_id'], equals('user-uuid'));
          expect(body['operator_id'], equals('operator-uuid'));
          expect(body['location_id'], equals('location-uuid'));
          // Acceptance: response body NEVER echoes the bearer token
          // or the token_hash value (no leak through the proxy
          // boundary even when the client accidentally logs the
          // response body).
          final bodyJson = response.body;
          expect(bodyJson.contains('placeholder.id.token'), isFalse);
          expect(bodyJson.contains('sha256-hex-hash'), isFalse);

          // Acceptance: writer received the right login row.
          expect(ledger.logins, hasLength(1));
          final login = ledger.logins.single;
          expect(login.userId, equals('user-uuid'));
          expect(login.operatorId, equals('operator-uuid'));
          expect(login.locationId, equals('location-uuid'));
          expect(login.tokenHash, equals('sha256-hex-hash'));
          // Acceptance: enrichment context resolved server-side from
          // request headers — leftmost X-Forwarded-For entry is the
          // client IP, X-Country is uppercased to 2-char ISO code.
          expect(login.context.ip, equals('203.0.113.7'));
          expect(login.context.userAgent, equals('forge-and-flow-test/1.0'));
          expect(login.context.geoCountry, equals('CA'));
        } finally {
          await shutDown();
        }
      });
    });

    test('POST /v1/auth/session/login default mode ignores spoofable '
        'forwarded IP and geo headers', () async {
      await withRealHttp(() async {
        final ledger = _RecordingAuthSessionLedger(
          loginSessionIds: <String>['session-from-proxy'],
        );
        await spinUpServer(authSessionLedgerWriter: ledger);
        try {
          verifier.claims = const ProxyJwtClaims(
            userId: 'user-uuid',
            operatorId: 'operator-uuid',
            locationId: 'location-uuid',
            roles: <String>['operator_owner'],
          );
          final response = await _httpPost(
            client,
            baseUri.resolve(authSessionLoginPath),
            authorization: 'Bearer placeholder.id.token',
            body: const <String, Object?>{'token_hash': 'sha256-hex-hash'},
            headers: const <String, String>{
              'X-Forwarded-For': '203.0.113.7, 10.0.0.1',
              'User-Agent': 'forge-and-flow-test/1.0',
              'X-Country': 'ca',
            },
          );

          expect(response.statusCode, equals(200));
          expect(ledger.logins, hasLength(1));
          final context = ledger.logins.single.context;
          expect(context.userAgent, equals('forge-and-flow-test/1.0'));
          expect(context.ip, isNot(equals('203.0.113.7')));
          expect(context.geoCountry, isNull);
        } finally {
          await shutDown();
        }
      });
    });

    test('POST /v1/auth/session/login: writer error becomes 503 '
        'auth_session_ledger_unavailable with no stack leak', () async {
      await withRealHttp(() async {
        final ledger = _ThrowingAuthSessionLedger(
          error: StateError('postgres connection refused: secret://blob'),
        );
        await spinUpServer(authSessionLedgerWriter: ledger);
        try {
          verifier.claims = const ProxyJwtClaims(
            userId: 'u',
            operatorId: 'op',
            locationId: 'loc',
            roles: <String>[],
          );
          final response = await _httpPost(
            client,
            baseUri.resolve(authSessionLoginPath),
            authorization: 'Bearer fake.token',
            body: const <String, Object?>{'token_hash': 'h'},
          );
          expect(response.statusCode, equals(503));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('auth_session_ledger_unavailable'));
          // Acceptance: the underlying StateError message (which
          // could carry connection strings or secrets) does NOT
          // surface in the HTTP body.
          expect(response.body.contains('secret://blob'), isFalse);
          expect(
            response.body.contains('postgres connection refused'),
            isFalse,
          );
        } finally {
          await shutDown();
        }
      });
    });

    test('POST /v1/auth/session/refresh happy path: writer receives '
        'sessionId from body and scope from token', () async {
      await withRealHttp(() async {
        final ledger = _RecordingAuthSessionLedger();
        await spinUpServer(authSessionLedgerWriter: ledger);
        try {
          verifier.claims = const ProxyJwtClaims(
            userId: 'user-uuid',
            operatorId: 'operator-uuid',
            locationId: 'location-uuid',
            roles: <String>[],
          );
          final response = await _httpPost(
            client,
            baseUri.resolve(authSessionRefreshPath),
            authorization: 'Bearer fake.token',
            body: const <String, Object?>{'session_id': 'session-uuid'},
          );

          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['ok'], isTrue);
          expect(ledger.refreshes, hasLength(1));
          expect(ledger.refreshes.single.sessionId, equals('session-uuid'));
          expect(ledger.refreshes.single.userId, equals('user-uuid'));
          expect(ledger.refreshes.single.operatorId, equals('operator-uuid'));
          expect(ledger.refreshes.single.locationId, equals('location-uuid'));
        } finally {
          await shutDown();
        }
      });
    });

    test(
      'POST /v1/auth/session/refresh rejects body without session_id',
      () async {
        await withRealHttp(() async {
          await spinUpServer(
            authSessionLedgerWriter: _RecordingAuthSessionLedger(),
          );
          try {
            verifier.claims = const ProxyJwtClaims(
              userId: 'u',
              operatorId: 'op',
              locationId: 'loc',
              roles: <String>[],
            );
            final response = await _httpPost(
              client,
              baseUri.resolve(authSessionRefreshPath),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{},
            );
            expect(response.statusCode, equals(400));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('missing_session_id'));
          } finally {
            await shutDown();
          }
        });
      },
    );

    test('POST /v1/auth/session/revoke happy path: writer receives '
        'sessionId + reason', () async {
      await withRealHttp(() async {
        final ledger = _RecordingAuthSessionLedger();
        await spinUpServer(authSessionLedgerWriter: ledger);
        try {
          verifier.claims = const ProxyJwtClaims(
            userId: 'user-uuid',
            operatorId: 'operator-uuid',
            locationId: 'location-uuid',
            roles: <String>[],
          );
          final response = await _httpPost(
            client,
            baseUri.resolve(authSessionRevokePath),
            authorization: 'Bearer fake.token',
            body: const <String, Object?>{
              'session_id': 'session-uuid',
              'reason': 'user_signed_out_this_session',
            },
          );
          expect(response.statusCode, equals(200));
          expect(ledger.revokes, hasLength(1));
          expect(ledger.revokes.single.sessionId, equals('session-uuid'));
          expect(
            ledger.revokes.single.reason,
            equals('user_signed_out_this_session'),
          );
        } finally {
          await shutDown();
        }
      });
    });

    test('POST /v1/auth/session/revoke without reason defaults to '
        'user_signed_out_this_session', () async {
      await withRealHttp(() async {
        final ledger = _RecordingAuthSessionLedger();
        await spinUpServer(authSessionLedgerWriter: ledger);
        try {
          verifier.claims = const ProxyJwtClaims(
            userId: 'u',
            operatorId: 'op',
            locationId: 'loc',
            roles: <String>[],
          );
          final response = await _httpPost(
            client,
            baseUri.resolve(authSessionRevokePath),
            authorization: 'Bearer fake.token',
            body: const <String, Object?>{'session_id': 'session-uuid'},
          );
          expect(response.statusCode, equals(200));
          expect(
            ledger.revokes.single.reason,
            equals('user_signed_out_this_session'),
          );
        } finally {
          await shutDown();
        }
      });
    });

    test('POST /v1/auth/session/revoke-all happy path: writer revokes for '
        'verified user, response carries revoked_count', () async {
      await withRealHttp(() async {
        final ledger = _RecordingAuthSessionLedger(revokeAllReturnCount: 3);
        await spinUpServer(authSessionLedgerWriter: ledger);
        try {
          verifier.claims = const ProxyJwtClaims(
            userId: 'user-uuid',
            operatorId: 'operator-uuid',
            locationId: 'location-uuid',
            roles: <String>[],
          );
          final response = await _httpPost(
            client,
            baseUri.resolve(authSessionRevokeAllPath),
            authorization: 'Bearer fake.token',
            body: const <String, Object?>{
              'reason': 'user_signed_out_all_sessions',
            },
          );
          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['ok'], isTrue);
          expect(body['revoked_count'], equals(3));
          expect(ledger.revokeAlls, hasLength(1));
          expect(ledger.revokeAlls.single.userId, equals('user-uuid'));
          expect(
            ledger.revokeAlls.single.reason,
            equals('user_signed_out_all_sessions'),
          );
        } finally {
          await shutDown();
        }
      });
    });

    test('POST /v1/auth/session/revoke-all tolerates empty body and '
        'defaults reason to user_signed_out_all_sessions', () async {
      await withRealHttp(() async {
        final ledger = _RecordingAuthSessionLedger();
        await spinUpServer(authSessionLedgerWriter: ledger);
        try {
          verifier.claims = const ProxyJwtClaims(
            userId: 'u',
            operatorId: 'op',
            locationId: 'loc',
            roles: <String>[],
          );
          // No body sent — exercises the allowEmpty: true branch in
          // _readJsonBody.
          final response = await _httpPost(
            client,
            baseUri.resolve(authSessionRevokeAllPath),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(200));
          expect(
            ledger.revokeAlls.single.reason,
            equals('user_signed_out_all_sessions'),
          );
        } finally {
          await shutDown();
        }
      });
    });

    test(
      'POST /v1/auth/refresh-tokens/revoke-all revokes Firebase UID',
      () async {
        await withRealHttp(() async {
          final firebaseAdmin = _RecordingFirebaseAdminAuthClient();
          await spinUpServer(firebaseAdminAuthClient: firebaseAdmin);
          try {
            verifier.claims = const ProxyJwtClaims(
              userId: 'postgres-user-uuid',
              firebaseUid: 'firebase-uid',
              operatorId: 'operator-uuid',
              locationId: 'location-uuid',
              roles: <String>[],
            );
            final response = await _httpPost(
              client,
              baseUri.resolve(authRefreshTokensRevokeAllPath),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{},
            );
            expect(response.statusCode, equals(200));
            expect(
              firebaseAdmin.revokedRefreshTokenUids,
              equals(['firebase-uid']),
            );
          } finally {
            await shutDown();
          }
        });
      },
    );
  });

  group('Phase 9.0Σ.g usage_caps two-slot key migration (B28 / item 6)', () {
    // Migration/schema-only assertions — the deep coverage of the
    // ADD / BACKFILL / CONSTRAINT FLIP shape lives in
    // `test/phase_9_0sigma_g_usage_caps_two_slot_test.dart`. The
    // assertions in this group exist so that a regression in the
    // proxy hot-zone (this test file's primary subject) cannot land
    // a sibling regression in the migration order or accidentally
    // re-introduce the legacy usage_caps PK in a later migration.
    late List<String> migrationNames;
    late String addSql;
    late String flipSql;
    late String cloudFoundationSql;

    setUpAll(() {
      migrationNames =
          Directory('db/migrations')
              .listSync()
              .whereType<File>()
              .map((file) => file.uri.pathSegments.last)
              .where((name) => name.endsWith('.sql'))
              .toList()
            ..sort();
      addSql = File(
        'db/migrations/'
        '202604280006_a_phase_9_0sigma_g_usage_caps_two_slot_add.sql',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      flipSql = File(
        'db/migrations/'
        '202604280006_c_phase_9_0sigma_g_'
        'usage_caps_two_slot_constraint_flip.sql',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      cloudFoundationSql = File(
        'db/migrations/202604250005_advisor_cloud_foundation.sql',
      ).readAsStringSync().replaceAll('\r\n', '\n');
    });

    test('three migration files exist with the locked filenames', () {
      // ignore: lines_longer_than_80_chars
      const flipName =
          '202604280006_c_phase_9_0sigma_g_usage_caps_two_slot_constraint_flip.sql';
      const expected = <String>[
        '202604280006_a_phase_9_0sigma_g_usage_caps_two_slot_add.sql',
        '202604280006_b_phase_9_0sigma_g_usage_caps_two_slot_backfill.sql',
        flipName,
      ];
      for (final name in expected) {
        expect(
          migrationNames,
          contains(name),
          reason: 'Phase 9.0Σ.g requires migration $name',
        );
      }
    });

    test('migration files are ordered ADD → BACKFILL → CONSTRAINT FLIP', () {
      final addIdx = migrationNames.indexOf(
        '202604280006_a_phase_9_0sigma_g_usage_caps_two_slot_add.sql',
      );
      final backfillIdx = migrationNames.indexOf(
        '202604280006_b_phase_9_0sigma_g_'
        'usage_caps_two_slot_backfill.sql',
      );
      final flipIdx = migrationNames.indexOf(
        '202604280006_c_phase_9_0sigma_g_'
        'usage_caps_two_slot_constraint_flip.sql',
      );
      expect(addIdx, greaterThanOrEqualTo(0));
      expect(backfillIdx, greaterThan(addIdx));
      expect(flipIdx, greaterThan(backfillIdx));
    });

    test('legacy 202604250005 usage_caps PK is unchanged — the flip '
        'lives only in 9.0Σ.g step c', () {
      // Tripwire: if a hand edited the cloud-foundation migration to
      // bake the new key shape directly into the legacy file (which
      // the slice constraint forbids), this assertion would catch it.
      expect(
        cloudFoundationSql,
        contains('primary key (operator_id, location_id, usage_class)'),
      );
      expect(cloudFoundationSql.contains('billing_owner_org_unit_id'), isFalse);
      expect(cloudFoundationSql.contains('scoped_org_unit_id'), isFalse);
    });

    test('add migration introduces the four cap-shape columns on usage_caps '
        'and usage_logs as nullable', () {
      for (final table in <String>['usage_caps', 'usage_logs']) {
        for (final column in <String>[
          'billing_owner_org_unit_id uuid;',
          'scoped_org_unit_id uuid;',
          'staff_id uuid null;',
          'workflow_id uuid null;',
        ]) {
          expect(
            addSql,
            contains(
              'alter table public.$table\n'
              '  add column if not exists $column',
            ),
            reason: '$table.$column must be added by the ADD migration',
          );
        }
      }
    });

    test('flip migration drops legacy PKs and attaches tenant-leading '
        'surrogate PKs', () {
      expect(flipSql, contains('drop constraint if exists usage_caps_pkey'));
      expect(
        flipSql,
        contains(
          'add constraint usage_caps_pkey\n'
          '  primary key (operator_id, cap_id);',
        ),
      );
      expect(flipSql, contains('drop constraint if exists usage_logs_pkey'));
      expect(
        flipSql,
        contains(
          'add constraint usage_logs_pkey\n'
          '  primary key (operator_id, log_id, period_start);',
        ),
      );
    });

    test('flip migration encodes the lock 6 logical key as UNIQUE NULLS '
        'NOT DISTINCT on usage_caps and the matching reconciliation '
        'key on usage_logs', () {
      // Cap-side: lock 6 shape, tenant-leading.
      expect(flipSql, contains('usage_caps_two_slot_uq'));
      expect(flipSql, contains('unique nulls not distinct ('));
      expect(
        flipSql,
        contains(
          '    operator_id,\n'
          '    billing_owner_org_unit_id,\n'
          '    scoped_org_unit_id,\n'
          '    location_id,\n'
          '    staff_id,\n'
          '    workflow_id,\n'
          '    usage_class\n'
          '  );',
        ),
      );
      // Log-side: cap-shape prefix + period_start + telemetry tail.
      expect(flipSql, contains('usage_logs_two_slot_rollup_uq'));
      expect(flipSql, contains('    period_start,'));
      expect(flipSql, contains('    query_class,'));
      expect(flipSql, contains('    cache_hit,'));
      expect(flipSql, contains('    llm_tier,'));
      expect(flipSql, contains('    model_used,'));
      expect(flipSql, contains('    batch_mode,'));
      expect(flipSql, contains('    circuit_state,'));
      expect(flipSql, contains('    fallback_used'));
    });

    test('flip migration attaches composite FKs to '
        'org_units(operator_id, id) for both billing-owner and '
        'scoped-org slots on both tables', () {
      const fkConstraints = <String>[
        'usage_caps_billing_owner_org_unit_fk',
        'usage_caps_scoped_org_unit_fk',
        'usage_logs_billing_owner_org_unit_fk',
        'usage_logs_scoped_org_unit_fk',
      ];
      for (final name in fkConstraints) {
        expect(
          flipSql,
          contains('add constraint $name'),
          reason: 'composite FK $name must be attached in the flip',
        );
      }
      expect(flipSql, contains('references public.org_units(operator_id, id)'));
    });

    test('flip migration adds tenant-leading reconciliation index on '
        'usage_logs (cap-shape only, no telemetry tail)', () {
      expect(
        flipSql,
        contains(
          'create index if not exists '
          'usage_logs_cap_reconciliation_idx\n'
          '  on public.usage_logs (\n'
          '    operator_id,\n'
          '    billing_owner_org_unit_id,\n'
          '    scoped_org_unit_id,\n'
          '    location_id,\n'
          '    staff_id,\n'
          '    workflow_id,\n'
          '    usage_class\n'
          '  );',
        ),
      );
    });

    test('flip migration grants service_role + forge_admin DML and adds '
        'no forge_admin RLS policy', () {
      for (final table in <String>[
        'usage_caps',
        'usage_logs',
        'usage_logs_default',
      ]) {
        for (final role in <String>['service_role', 'forge_admin']) {
          expect(
            flipSql,
            contains(
              'grant select, insert, update, delete on public.$table '
              'to $role',
            ),
            reason: '$table must grant DML to $role',
          );
        }
      }
      // No CREATE POLICY ... TO forge_admin in this slice (lock).
      final forgeAdminPolicy = RegExp(
        r'create policy [^;]*to forge_admin',
        caseSensitive: false,
      );
      expect(forgeAdminPolicy.hasMatch(flipSql), isFalse);
    });

    test('the slice introduces no DDL for actor_kind, sp:-prefixed '
        'JWT, audit_logs, or service_principals (those belong to '
        'disjoint slices)', () {
      // DDL-pattern guards rather than prose substrings — a comment
      // that names the out-of-scope term ("does not touch
      // actor_kind") is allowed; an actual column declaration is not.
      for (final sql in <String>[addSql, flipSql]) {
        final actorKindDdl = RegExp(
          r'\b(?:add column[^;]*\bactor_kind|actor_kind\s+text)\b',
          caseSensitive: false,
        );
        expect(actorKindDdl.hasMatch(sql), isFalse);

        final servicePrincipalsTable = RegExp(
          r'\b(?:create table|references)[^;]*\bservice_principals\b',
          caseSensitive: false,
        );
        expect(servicePrincipalsTable.hasMatch(sql), isFalse);

        final spPrefix = RegExp(r'''['"]sp:''', caseSensitive: false);
        expect(spPrefix.hasMatch(sql), isFalse);

        final auditLogDdl = RegExp(
          r'\b(?:create table|alter table|references)[^;]*'
          r'\b(?:audit_logs|auth_events_audit)\b',
          caseSensitive: false,
        );
        expect(auditLogDdl.hasMatch(sql), isFalse);
      }
    });

    test('the slice did not invent lib/services/advisor/usage_*.dart', () {
      final advisorDir = Directory('lib/services/advisor');
      if (!advisorDir.existsSync()) return;
      final usageFiles = advisorDir
          .listSync(recursive: true)
          .whereType<File>()
          .map((file) => file.uri.pathSegments.last)
          .where((name) => name.startsWith('usage_') && name.endsWith('.dart'))
          .toList();
      expect(
        usageFiles,
        isEmpty,
        reason:
            'Block 3 task 4 forbids inventing usage_*.dart in this '
            'slice; the missing seam is a documented follow-up. '
            'Found: $usageFiles',
      );
    });
  });

  group('11A.1 admin operator/location routes', () {
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
        _FakeAdminGateway gateway,
      })
    >
    spinUp({
      ProxyJwtClaims? initialClaims,
      _FakeAdminGateway? customGateway,
      bool gatewayConfigured = true,
    }) async {
      final verifier = _SettableVerifier();
      verifier.claims = initialClaims;
      final guard = ProxyRequestGuard(verifier: verifier);
      final gateway = customGateway ?? _FakeAdminGateway();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // ignore: unawaited_futures
      server.listen((request) async {
        try {
          await routeRequest(
            request,
            guard,
            operatorLocationAdminGateway: gatewayConfigured ? gateway : null,
            now: () => DateTime.utc(2026, 4, 29, 12),
            adminCorsAllowList: const <String>[
              'https://admin.forgeflow.app',
            ],
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
      );
    }

    test('11A.1 OPTIONS preflight returns CORS headers without auth', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final request = await ctx.client.openUrl(
            'OPTIONS',
            ctx.baseUri.resolve(adminOperatorsPath),
          );
          request.persistentConnection = false;
          request.headers.set('Origin', 'https://admin.forgeflow.app');
          request.headers.set('Access-Control-Request-Method', 'POST');
          request.headers.set(
            'Access-Control-Request-Headers',
            'authorization,content-type',
          );
          request.contentLength = 0;

          final response = await request.close();
          await response.drain<void>();

          expect(response.statusCode, equals(HttpStatus.noContent));
          // HARD-C — exact-origin echo, never `*`. The allow-list
          // wired through spinUp contains the origin we send below,
          // so the proxy responds with that exact string.
          expect(
            response.headers.value('access-control-allow-origin'),
            equals('https://admin.forgeflow.app'),
          );
          expect(
            response.headers.value('access-control-allow-methods'),
            contains('OPTIONS'),
          );
          expect(
            response.headers
                .value('access-control-allow-headers')
                ?.toLowerCase(),
            contains('authorization'),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      '11A.1 GET /v1/admin/operators returns 503 without a gateway',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(gatewayConfigured: false);
          try {
            final response = await _httpGet(
              ctx.client,
              ctx.baseUri.resolve(adminOperatorsPath),
              authorization: 'Bearer fake.token',
            );
            expect(response.statusCode, equals(503));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(
              body['error'],
              equals('operator_location_admin_not_configured'),
            );
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.1 GET /v1/admin/operators rejects a non-admin caller with 403',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(
            initialClaims: const ProxyJwtClaims(
              userId: 'user_x',
              operatorId: 'op_x',
              locationId: 'loc_x',
              roles: <String>['operator_owner'],
            ),
          );
          try {
            final response = await _httpGet(
              ctx.client,
              ctx.baseUri.resolve(adminOperatorsPath),
              authorization: 'Bearer fake.token',
            );
            expect(response.statusCode, equals(403));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('permission_denied'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.1 POST /v1/admin/operators rejects ff_support with 403',
      () async {
        await withRealHttp(() async {
          final gateway = _FakeAdminGateway();
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: const ProxyJwtClaims(
              userId: 'user_support',
              operatorId: 'op_support',
              locationId: 'loc_support',
              roles: <String>['ff_support'],
            ),
          );
          try {
            final response = await _httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(adminOperatorsPath),
              authorization: 'Bearer fake.token',
              body: <String, Object?>{
                'business_name': 'Cafe',
                'owner_email': 'a@b.c',
                'subscription_tier': 'launch',
                'preferred_currency': 'CAD',
                'admin_user_email': 'admin@b.c',
                'primary_location': <String, Object?>{
                  'name': 'Main',
                  'timezone': 'America/Toronto',
                  'business_day_rollover_hour': 4,
                },
              },
            );
            expect(response.statusCode, equals(403));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('permission_denied'));
            expect(body['required_roles'], contains('super_admin'));
            expect(gateway.lastOnboardCommand, isNull);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.1 GET /v1/admin/operators returns the gateway list as 200',
      () async {
        await withRealHttp(() async {
          final gateway = _FakeAdminGateway();
          gateway.listResult = <Map<String, Object?>>[
            <String, Object?>{
              'operator': <String, Object?>{
                'operator_id': 'op-1',
                'business_name': 'Cafe One',
              },
              'locations': <Map<String, Object?>>[],
            },
          ];
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await _httpGet(
              ctx.client,
              ctx.baseUri.resolve(adminOperatorsPath),
              authorization: 'Bearer fake.token',
            );
            expect(response.statusCode, equals(200));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            final operators = (body['operators']! as List)
                .cast<Map<String, Object?>>();
            expect(operators, hasLength(1));
            final firstOperator = (operators.first['operator']! as Map)
                .cast<String, Object?>();
            expect(firstOperator['business_name'], equals('Cafe One'));
            expect(gateway.lastReason, contains('admin.operator_location.GET'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.1 GET /v1/admin/operators accepts global super_admin token',
      () async {
        await withRealHttp(() async {
          final gateway = _FakeAdminGateway();
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: null,
              locationId: null,
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await _httpGet(
              ctx.client,
              ctx.baseUri.resolve(adminOperatorsPath),
              authorization: 'Bearer fake.token',
            );
            expect(response.statusCode, equals(200));
            expect(gateway.lastActorUserId, equals('user_admin'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.1 POST /v1/admin/operators rejects missing primary_location with 400',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await _httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(adminOperatorsPath),
              authorization: 'Bearer fake.token',
              body: <String, Object?>{
                'business_name': 'Cafe',
                'owner_email': 'a@b.c',
                'subscription_tier': 'launch',
                'preferred_currency': 'CAD',
                'admin_user_email': 'admin@b.c',
              },
            );
            expect(response.statusCode, equals(400));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('missing_primary_location'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.1 POST /v1/admin/operators rejects an invalid IANA timezone with 400',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await _httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(adminOperatorsPath),
              authorization: 'Bearer fake.token',
              body: <String, Object?>{
                'business_name': 'Cafe',
                'owner_email': 'a@b.c',
                'subscription_tier': 'launch',
                'preferred_currency': 'CAD',
                'admin_user_email': 'admin@b.c',
                'primary_location': <String, Object?>{
                  'name': 'Main',
                  'timezone': 'Mars/Olympus',
                  'business_day_rollover_hour': 4,
                },
              },
            );
            expect(response.statusCode, equals(400));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('invalid_timezone'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.1 POST /v1/admin/operators returns 201 with bundle on success',
      () async {
        await withRealHttp(() async {
          final gateway = _FakeAdminGateway();
          gateway.onboardResult = <String, Object?>{
            'operator': <String, Object?>{
              'operator_id': 'op-new',
              'business_name': 'Cafe New',
            },
            'locations': <Map<String, Object?>>[
              <String, Object?>{
                'location_id': 'loc-new',
                'operator_id': 'op-new',
              },
            ],
            'admin_user_id': 'user-new',
          };
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await _httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(adminOperatorsPath),
              authorization: 'Bearer fake.token',
              body: <String, Object?>{
                'business_name': 'Cafe New',
                'owner_email': 'a@b.c',
                'subscription_tier': 'launch',
                'preferred_currency': 'CAD',
                'admin_user_email': 'admin@b.c',
                'primary_location': <String, Object?>{
                  'name': 'Main',
                  'timezone': 'America/Toronto',
                  'business_day_rollover_hour': 4,
                },
              },
            );
            expect(response.statusCode, equals(201));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            final operatorJson = (body['operator'] as Map)
                .cast<String, Object?>();
            expect(operatorJson['operator_id'], equals('op-new'));
            expect(
              gateway.lastOnboardCommand?['business_name'],
              equals('Cafe New'),
            );
            expect(
              gateway.lastOnboardCommand?['preferred_currency'],
              equals('CAD'),
            );
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('11A.1 POST /v1/admin/operators/{id}/suspend returns 200', () async {
      await withRealHttp(() async {
        final gateway = _FakeAdminGateway();
        gateway.suspendResult = <String, Object?>{
          'operator_id': 'op-1',
          'business_name': 'Cafe',
          'suspended_at': '2026-04-29T12:00:00.000Z',
        };
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: const ProxyJwtClaims(
            userId: 'user_admin',
            operatorId: 'op_admin',
            locationId: 'loc_admin',
            roles: <String>['super_admin'],
          ),
        );
        try {
          final response = await _httpJson(
            ctx.client,
            'POST',
            ctx.baseUri.resolve('$adminOperatorsPath/op-1/suspend'),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(200));
          expect(gateway.suspendOperatorId, equals('op-1'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      '11A.1 POST /v1/admin/operators/{id}/reactivate returns 200',
      () async {
        await withRealHttp(() async {
          final gateway = _FakeAdminGateway();
          gateway.reactivateResult = <String, Object?>{
            'operator_id': 'op-1',
            'suspended_at': null,
          };
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await _httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve('$adminOperatorsPath/op-1/reactivate'),
              authorization: 'Bearer fake.token',
            );
            expect(response.statusCode, equals(200));
            expect(gateway.reactivateOperatorId, equals('op-1'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.1 PATCH /v1/admin/operators/{id} returns 404 when not found',
      () async {
        await withRealHttp(() async {
          final gateway = _FakeAdminGateway();
          gateway.patchResult = null;
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await _httpJson(
              ctx.client,
              'PATCH',
              ctx.baseUri.resolve('$adminOperatorsPath/missing'),
              authorization: 'Bearer fake.token',
              body: <String, Object?>{'business_name': 'Renamed'},
            );
            expect(response.statusCode, equals(404));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('unknown_operator'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('11A.1 POST /v1/admin/locations returns 201 on success', () async {
      await withRealHttp(() async {
        final gateway = _FakeAdminGateway();
        gateway.addLocationResult = <String, Object?>{
          'location_id': 'loc-new',
          'operator_id': 'op-1',
          'name': 'West Coast',
          'timezone': 'America/Vancouver',
        };
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: const ProxyJwtClaims(
            userId: 'user_admin',
            operatorId: 'op_admin',
            locationId: 'loc_admin',
            roles: <String>['super_admin'],
          ),
        );
        try {
          final response = await _httpJson(
            ctx.client,
            'POST',
            ctx.baseUri.resolve(adminLocationsPath),
            authorization: 'Bearer fake.token',
            body: <String, Object?>{
              'operator_id': 'op-1',
              'name': 'West Coast',
              'timezone': 'America/Vancouver',
              'business_day_rollover_hour': 5,
            },
          );
          expect(response.statusCode, equals(201));
          expect(gateway.lastAddLocationOperatorId, equals('op-1'));
          expect(gateway.lastAddLocationTimezone, equals('America/Vancouver'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      '11A.1 DELETE /v1/admin/locations/{id} primary-protected returns 400',
      () async {
        await withRealHttp(() async {
          final gateway = _FakeAdminGateway();
          gateway.removeLocationResult =
              AdminLocationRemovalResult.primaryLocationProtected;
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await _httpJson(
              ctx.client,
              'DELETE',
              ctx.baseUri.resolve('$adminLocationsPath/loc-1'),
              authorization: 'Bearer fake.token',
              body: <String, Object?>{'operator_id': 'op-1'},
            );
            expect(response.statusCode, equals(400));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('cannot_remove_primary_location'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.1 DELETE /v1/admin/locations/{id} returns 200 on success',
      () async {
        await withRealHttp(() async {
          final gateway = _FakeAdminGateway();
          gateway.removeLocationResult = AdminLocationRemovalResult.removed;
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await _httpJson(
              ctx.client,
              'DELETE',
              ctx.baseUri.resolve('$adminLocationsPath/loc-1'),
              authorization: 'Bearer fake.token',
              body: <String, Object?>{'operator_id': 'op-1'},
            );
            expect(response.statusCode, equals(200));
            expect(gateway.removeLocationId, equals('loc-1'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.1 GET /v1/admin/operators without Authorization returns 401',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            final response = await _httpGet(
              ctx.client,
              ctx.baseUri.resolve(adminOperatorsPath),
            );
            expect(response.statusCode, equals(401));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );
  });

  group('11A.2 admin pricing tier routes', () {
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
        _FakePricingAdminGateway gateway,
      })
    >
    spinUp({
      ProxyJwtClaims? initialClaims,
      _FakePricingAdminGateway? customGateway,
      bool gatewayConfigured = true,
    }) async {
      final verifier = _SettableVerifier();
      verifier.claims = initialClaims;
      final guard = ProxyRequestGuard(verifier: verifier);
      final gateway = customGateway ?? _FakePricingAdminGateway();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // ignore: unawaited_futures
      server.listen((request) async {
        try {
          await routeRequest(
            request,
            guard,
            pricingTierAdminGateway: gatewayConfigured ? gateway : null,
            now: () => DateTime.utc(2026, 4, 30, 12),
            adminCorsAllowList: const <String>[
              'https://admin.forgeflow.app',
            ],
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
        verifier: verifier,
        gateway: gateway,
      );
    }

    test(
      '11A.2 GET /v1/admin/pricing/operators returns 503 without a gateway',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(gatewayConfigured: false);
          try {
            final response = await _httpGet(
              ctx.client,
              ctx.baseUri.resolve(adminPricingOperatorsPath),
              authorization: 'Bearer fake.token',
            );
            expect(response.statusCode, equals(503));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(
              body['error'],
              equals('pricing_tier_admin_not_configured'),
            );
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.2 GET /v1/admin/pricing/operators rejects operator_owner (403)',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(
            initialClaims: const ProxyJwtClaims(
              userId: 'user_x',
              operatorId: 'op_x',
              locationId: 'loc_x',
              roles: <String>['operator_owner'],
            ),
          );
          try {
            final response = await _httpGet(
              ctx.client,
              ctx.baseUri.resolve(adminPricingOperatorsPath),
              authorization: 'Bearer fake.token',
            );
            expect(response.statusCode, equals(403));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('permission_denied'));
            // GET rejection lists the read set (super_admin +
            // ff_support); the caller carries neither.
            final required =
                (body['required_roles']! as List).cast<String>();
            expect(required, contains('super_admin'));
            expect(required, contains('ff_support'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.2 GET /v1/admin/pricing/operators admits ff_support (read-only)',
      () async {
        await withRealHttp(() async {
          final gateway = _FakePricingAdminGateway();
          gateway.listResult = const <Map<String, Object?>>[];
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
              ctx.baseUri.resolve(adminPricingOperatorsPath),
              authorization: 'Bearer fake.token',
            );
            expect(response.statusCode, equals(200));
            expect(gateway.lastActorUserId, equals('user_support'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.2 PUT /v1/admin/pricing/usage-caps rejects ff_support with 403',
      () async {
        await withRealHttp(() async {
          final gateway = _FakePricingAdminGateway();
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
              ctx.baseUri.resolve(adminPricingUsageCapsPath),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{
                'operator_id': 'op-1',
                'location_id': 'loc-1',
                'usage_class': 'advisor_qa',
                'monthly_cap_usd': 50.0,
                'per_invocation_cap_usd': 0.10,
              },
            );
            expect(response.statusCode, equals(403));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('permission_denied'));
            expect(body['required_roles'], contains('super_admin'));
            expect(body['required_roles'], isNot(contains('ff_support')));
            expect(gateway.lastCapOperatorId, isNull);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.2 POST .../apply-template rejects ff_support with 403',
      () async {
        await withRealHttp(() async {
          final gateway = _FakePricingAdminGateway();
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
              'POST',
              ctx.baseUri.resolve(
                '${adminPricingOperatorsPrefix}op-1/apply-template',
              ),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{'tier_key': 'premium'},
            );
            expect(response.statusCode, equals(403));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('permission_denied'));
            expect(gateway.lastApplyTemplateOperatorId, isNull);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.2 PATCH .../operators/{id} rejects ff_support with 403',
      () async {
        await withRealHttp(() async {
          final gateway = _FakePricingAdminGateway();
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: const ProxyJwtClaims(
              userId: 'user_support',
              operatorId: 'op_support',
              locationId: 'loc_support',
              roles: <String>['ff_support'],
            ),
          );
          try {
            final response = await _httpJson(
              ctx.client,
              'PATCH',
              ctx.baseUri.resolve('${adminPricingOperatorsPrefix}op-1'),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{
                'subscription_tier': 'premium',
              },
            );
            expect(response.statusCode, equals(403));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('permission_denied'));
            expect(body['required_roles'], contains('super_admin'));
            expect(gateway.lastTierUpdateOperatorId, isNull);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('11A.2 GET /v1/admin/pricing/operators returns the gateway list',
        () async {
      await withRealHttp(() async {
        final gateway = _FakePricingAdminGateway();
        gateway.listResult = <Map<String, Object?>>[
          <String, Object?>{
            'operator': <String, Object?>{
              'operator_id': 'op-1',
              'business_name': 'Cafe One',
              'subscription_tier': 'starter',
              'preferred_currency': 'CAD',
              'primary_location_id': 'loc-1',
              'suspended': false,
            },
            'caps': <Map<String, Object?>>[],
          },
        ];
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: const ProxyJwtClaims(
            userId: 'user_admin',
            operatorId: 'op_admin',
            locationId: 'loc_admin',
            roles: <String>['super_admin'],
          ),
        );
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(adminPricingOperatorsPath),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          final operators =
              (body['operators']! as List).cast<Map<String, Object?>>();
          expect(operators, hasLength(1));
          expect(gateway.lastReason, contains('admin.pricing.GET'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('11A.2 PATCH .../operators/{id} validates subscription_tier value',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp(
          initialClaims: const ProxyJwtClaims(
            userId: 'user_admin',
            operatorId: 'op_admin',
            locationId: 'loc_admin',
            roles: <String>['super_admin'],
          ),
        );
        try {
          final response = await _httpJson(
            ctx.client,
            'PATCH',
            ctx.baseUri.resolve('${adminPricingOperatorsPrefix}op-1'),
            authorization: 'Bearer fake.token',
            body: const <String, Object?>{
              'subscription_tier': 'megapremium',
            },
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('invalid_subscription_tier'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('11A.2 PATCH .../operators/{id} forwards to gateway as super_admin',
        () async {
      await withRealHttp(() async {
        final gateway = _FakePricingAdminGateway();
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: const ProxyJwtClaims(
            userId: 'user_admin',
            operatorId: 'op_admin',
            locationId: 'loc_admin',
            roles: <String>['super_admin'],
          ),
        );
        try {
          final response = await _httpJson(
            ctx.client,
            'PATCH',
            ctx.baseUri.resolve('${adminPricingOperatorsPrefix}op-1'),
            authorization: 'Bearer fake.token',
            body: const <String, Object?>{'subscription_tier': 'premium'},
          );
          expect(response.statusCode, equals(200));
          expect(gateway.lastTierUpdateOperatorId, equals('op-1'));
          expect(gateway.lastTierUpdateValue, equals('premium'));
          expect(gateway.lastActorUserId, equals('user_admin'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('11A.2 PUT /v1/admin/pricing/usage-caps upserts a cap row',
        () async {
      await withRealHttp(() async {
        final gateway = _FakePricingAdminGateway();
        gateway.capUpsertResult = const <String, Object?>{
          'operator_id': 'op-1',
          'location_id': 'loc-1',
          'usage_class': 'advisor_qa',
          'monthly_cap_usd': 50.0,
          'per_invocation_cap_usd': 0.10,
        };
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: const ProxyJwtClaims(
            userId: 'user_admin',
            operatorId: 'op_admin',
            locationId: 'loc_admin',
            roles: <String>['super_admin'],
          ),
        );
        try {
          final response = await _httpJson(
            ctx.client,
            'PUT',
            ctx.baseUri.resolve(adminPricingUsageCapsPath),
            authorization: 'Bearer fake.token',
            body: const <String, Object?>{
              'operator_id': 'op-1',
              'location_id': 'loc-1',
              'usage_class': 'advisor_qa',
              'monthly_cap_usd': 50.0,
              'per_invocation_cap_usd': 0.10,
            },
          );
          expect(response.statusCode, equals(200));
          expect(gateway.lastCapOperatorId, equals('op-1'));
          expect(gateway.lastCapUsageClass, equals('advisor_qa'));
          expect(gateway.lastCapMonthly, equals(50.0));
          expect(gateway.lastReason, contains('admin.pricing.PUT'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      '11A.2 PUT /v1/admin/pricing/usage-caps rejects negative monthly_cap_usd',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await _httpJson(
              ctx.client,
              'PUT',
              ctx.baseUri.resolve(adminPricingUsageCapsPath),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{
                'operator_id': 'op-1',
                'location_id': 'loc-1',
                'usage_class': 'advisor_qa',
                'monthly_cap_usd': -5.0,
                'per_invocation_cap_usd': 0.10,
              },
            );
            expect(response.statusCode, equals(400));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('invalid_monthly_cap_usd'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.2 POST .../operators/{id}/apply-template forwards tier_key',
      () async {
        await withRealHttp(() async {
          final gateway = _FakePricingAdminGateway();
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await _httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(
                '${adminPricingOperatorsPrefix}op-1/apply-template',
              ),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{'tier_key': 'pro'},
            );
            expect(response.statusCode, equals(200));
            expect(gateway.lastApplyTemplateOperatorId, equals('op-1'));
            expect(gateway.lastApplyTemplateTierKey, equals('pro'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.2 POST .../apply-template rejects an unknown tier_key (400)',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await _httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(
                '${adminPricingOperatorsPrefix}op-1/apply-template',
              ),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{'tier_key': 'megapremium'},
            );
            expect(response.statusCode, equals(400));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('unknown_tier_template'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.2 POST .../apply-template surfaces no_primary_location as 400',
      () async {
        await withRealHttp(() async {
          final gateway = _FakePricingAdminGateway()
            ..raiseOnApplyTemplate =
                const PricingTierAdminGatewayValidationError(
              statusCode: 400,
              code: 'no_primary_location',
              message: 'set a primary location first',
            );
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await _httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(
                '${adminPricingOperatorsPrefix}op-1/apply-template',
              ),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{'tier_key': 'premium'},
            );
            expect(response.statusCode, equals(400));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('no_primary_location'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('11A.2 OPTIONS preflight allows PUT for usage-caps', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final request = await ctx.client.openUrl(
            'OPTIONS',
            ctx.baseUri.resolve(adminPricingUsageCapsPath),
          );
          request.persistentConnection = false;
          request.headers.set('Origin', 'https://admin.forgeflow.app');
          request.headers.set('Access-Control-Request-Method', 'PUT');
          request.headers.set(
            'Access-Control-Request-Headers',
            'authorization,content-type',
          );
          request.contentLength = 0;
          final response = await request.close();
          await response.drain<void>();
          expect(response.statusCode, equals(HttpStatus.noContent));
          final allowMethods =
              response.headers.value('access-control-allow-methods') ?? '';
          expect(allowMethods.toUpperCase(), contains('PUT'));
          expect(allowMethods.toUpperCase(), contains('OPTIONS'));
          // HARD-C — exact-origin echo, never `*`.
          expect(
            response.headers.value('access-control-allow-origin'),
            equals('https://admin.forgeflow.app'),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      '11A.2 GET /v1/admin/pricing/operators without Authorization is 401',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            final response = await _httpGet(
              ctx.client,
              ctx.baseUri.resolve(adminPricingOperatorsPath),
            );
            expect(response.statusCode, equals(401));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );
  });
}

class _FakePricingAdminGateway implements PricingTierAdminProxyGateway {
  List<Map<String, Object?>> listResult = const <Map<String, Object?>>[];
  Map<String, Object?>? tierUpdateResult = <String, Object?>{
    'operator': <String, Object?>{},
    'caps': <Map<String, Object?>>[],
  };
  Map<String, Object?> capUpsertResult = <String, Object?>{};
  Map<String, Object?>? applyTemplateResult = <String, Object?>{
    'operator': <String, Object?>{},
    'caps': <Map<String, Object?>>[],
  };

  String? lastReason;
  String? lastActorUserId;
  String? lastTierUpdateOperatorId;
  String? lastTierUpdateValue;
  String? lastCapOperatorId;
  String? lastCapLocationId;
  String? lastCapUsageClass;
  double? lastCapMonthly;
  String? lastApplyTemplateOperatorId;
  String? lastApplyTemplateTierKey;
  Object? raiseOnApplyTemplate;

  @override
  Future<List<Map<String, Object?>>> listOperatorsWithCaps({
    required String actorUserId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastReason = adminReason;
    return listResult;
  }

  @override
  Future<Map<String, Object?>?> updateOperatorTier({
    required String actorUserId,
    required String operatorId,
    required String subscriptionTier,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastReason = adminReason;
    lastTierUpdateOperatorId = operatorId;
    lastTierUpdateValue = subscriptionTier;
    return tierUpdateResult;
  }

  @override
  Future<Map<String, Object?>> upsertUsageCap({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String usageClass,
    required double monthlyCapUsd,
    required double perInvocationCapUsd,
    String? staffId,
    String? workflowId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastReason = adminReason;
    lastCapOperatorId = operatorId;
    lastCapLocationId = locationId;
    lastCapUsageClass = usageClass;
    lastCapMonthly = monthlyCapUsd;
    return capUpsertResult;
  }

  @override
  Future<Map<String, Object?>?> applyTierTemplate({
    required String actorUserId,
    required String operatorId,
    required String tierKey,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastReason = adminReason;
    lastApplyTemplateOperatorId = operatorId;
    lastApplyTemplateTierKey = tierKey;
    final raise = raiseOnApplyTemplate;
    if (raise != null) throw raise;
    return applyTemplateResult;
  }
}

class _FakeAdminGateway implements OperatorLocationAdminProxyGateway {
  List<Map<String, Object?>> listResult = const <Map<String, Object?>>[];
  Map<String, Object?> onboardResult = <String, Object?>{
    'operator': <String, Object?>{},
    'locations': <Map<String, Object?>>[],
  };
  Map<String, Object?>? patchResult = <String, Object?>{'operator_id': 'op'};
  Map<String, Object?>? suspendResult = <String, Object?>{};
  Map<String, Object?>? reactivateResult = <String, Object?>{};
  Map<String, Object?> addLocationResult = <String, Object?>{};
  Map<String, Object?>? patchLocationResult = <String, Object?>{};
  AdminLocationRemovalResult removeLocationResult =
      AdminLocationRemovalResult.removed;

  String? lastReason;
  String? lastActorUserId;
  Map<String, Object?>? lastOnboardCommand;
  String? suspendOperatorId;
  String? reactivateOperatorId;
  String? lastAddLocationOperatorId;
  String? lastAddLocationTimezone;
  String? removeLocationId;

  @override
  Future<List<Map<String, Object?>>> listOperatorsWithLocations({
    required String actorUserId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastReason = adminReason;
    return listResult;
  }

  @override
  Future<Map<String, Object?>> onboardOperator({
    required String actorUserId,
    required String businessName,
    required String ownerEmail,
    required String subscriptionTier,
    required String preferredCurrency,
    required String adminUserEmail,
    required String primaryLocationName,
    required String primaryLocationTimezone,
    required int primaryLocationRolloverHour,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastReason = adminReason;
    lastOnboardCommand = <String, Object?>{
      'business_name': businessName,
      'owner_email': ownerEmail,
      'subscription_tier': subscriptionTier,
      'preferred_currency': preferredCurrency,
      'admin_user_email': adminUserEmail,
      'primary_location_name': primaryLocationName,
      'primary_location_timezone': primaryLocationTimezone,
      'primary_location_rollover_hour': primaryLocationRolloverHour,
    };
    return onboardResult;
  }

  @override
  Future<Map<String, Object?>?> patchOperator({
    required String actorUserId,
    required String operatorId,
    String? businessName,
    String? ownerEmail,
    String? subscriptionTier,
    String? preferredCurrency,
    String? primaryLocationId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastReason = adminReason;
    return patchResult;
  }

  @override
  Future<Map<String, Object?>?> suspendOperator({
    required String actorUserId,
    required String operatorId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    suspendOperatorId = operatorId;
    lastReason = adminReason;
    return suspendResult;
  }

  @override
  Future<Map<String, Object?>?> reactivateOperator({
    required String actorUserId,
    required String operatorId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    reactivateOperatorId = operatorId;
    lastReason = adminReason;
    return reactivateResult;
  }

  @override
  Future<Map<String, Object?>> addLocation({
    required String actorUserId,
    required String operatorId,
    required String name,
    required String address,
    required String timezone,
    required int businessDayRolloverHour,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastAddLocationOperatorId = operatorId;
    lastAddLocationTimezone = timezone;
    lastReason = adminReason;
    return addLocationResult;
  }

  @override
  Future<Map<String, Object?>?> patchLocation({
    required String actorUserId,
    required String locationId,
    String? name,
    String? address,
    String? timezone,
    int? businessDayRolloverHour,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastReason = adminReason;
    return patchLocationResult;
  }

  @override
  Future<AdminLocationRemovalResult> removeLocation({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    removeLocationId = locationId;
    lastReason = adminReason;
    return removeLocationResult;
  }
}

// ─── Test helpers ────────────────────────────────────────────────────────────

class _AlwaysOkVerifier implements ProxyJwtVerifier {
  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    return const ProxyJwtClaims(
      userId: 'user_ok',
      operatorId: 'op_ok',
      locationId: 'loc_ok',
      roles: <String>[],
    );
  }
}

class _RaisingVerifier implements ProxyJwtVerifier {
  _RaisingVerifier(this.message);

  final String message;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    throw ProxyJwtVerificationError(message);
  }
}

class _FixedClaimsVerifier implements ProxyJwtVerifier {
  _FixedClaimsVerifier(this.claims);

  final ProxyJwtClaims claims;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async => claims;
}

/// Mutable verifier the HTTP scaffold tests reconfigure between calls.
class _SettableVerifier implements ProxyJwtVerifier {
  ProxyJwtClaims? claims;
  String? errorMessage;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    final error = errorMessage;
    if (error != null) {
      throw ProxyJwtVerificationError(error);
    }
    final value = claims;
    if (value != null) return value;
    throw ProxyJwtVerificationError('test verifier not configured');
  }
}

class _RecordingFirebaseAdminAuthClient implements FirebaseAdminAuthClient {
  final List<String> revokedRefreshTokenUids = <String>[];

  @override
  Future<void> createUser({
    required String uid,
    required String email,
    required Map<String, Object?> customClaims,
  }) async {}

  @override
  Future<void> setCustomClaims({
    required String uid,
    required Map<String, Object?> customClaims,
  }) async {}

  @override
  Future<void> setDisabled({
    required String uid,
    required bool disabled,
  }) async {}

  @override
  Future<void> sendPasswordResetEmail({
    required String email,
    String? continueUrl,
  }) async {}

  @override
  Future<bool> verifyPassword({
    required String email,
    required String password,
    required String expectedUid,
  }) async {
    return true;
  }

  @override
  Future<void> updatePassword({
    required String uid,
    required String password,
  }) async {}

  @override
  Future<FirebasePasswordResetCodeInfo> verifyPasswordResetCode({
    required String oobCode,
  }) async {
    return const FirebasePasswordResetCodeInfo(email: 'owner@example.com');
  }

  @override
  Future<void> confirmPasswordReset({
    required String oobCode,
    required String newPassword,
  }) async {}

  @override
  Future<void> revokeRefreshTokens({required String uid}) async {
    revokedRefreshTokenUids.add(uid);
  }

  @override
  Future<void> clearMfaEnrollments({required String uid}) async {}
}

/// Counter store fake that records read/write call counts so tests
/// can assert "refused before the store was queried."
class _RecordingStore implements ProxyUsageCounterStore {
  int currentUsageCalls = 0;
  int incrementCalls = 0;

  @override
  Future<UsageSnapshot> currentUsage({
    required String operatorId,
    required String locationId,
    required String tierId,
    required DateTime now,
  }) async {
    currentUsageCalls += 1;
    return UsageSnapshot(
      requestsThisMinute: 0,
      costCentsThisMonth: 0,
      minuteBucketStart: now,
      monthBucketStart: DateTime.utc(now.year, now.month),
    );
  }

  @override
  Future<void> incrementOnAllow({
    required String operatorId,
    required String locationId,
    required String tierId,
    required DateTime now,
    required int costCentsToAdd,
  }) async {
    incrementCalls += 1;
  }
}

/// Counter store fake that throws a non-StateError exception on
/// every read. Models real-world failure modes (timeout, network,
/// postgres exception, parse error) where the raw payload may carry
/// secrets / connection strings / stack-trace fragments that the
/// proxy must not surface through the HTTP response.
class _BoomStore implements ProxyUsageCounterStore {
  _BoomStore({required this.error});

  final Object error;

  @override
  Future<UsageSnapshot> currentUsage({
    required String operatorId,
    required String locationId,
    required String tierId,
    required DateTime now,
  }) async {
    throw error;
  }

  @override
  Future<void> incrementOnAllow({
    required String operatorId,
    required String locationId,
    required String tierId,
    required DateTime now,
    required int costCentsToAdd,
  }) async {
    throw error;
  }
}

/// Counter store fake that returns a fixed snapshot so tests can
/// pin the per-minute / monthly cap edges.
class _FixedSnapshotStore implements ProxyUsageCounterStore {
  _FixedSnapshotStore({required this.snapshot});

  final UsageSnapshot snapshot;

  @override
  Future<UsageSnapshot> currentUsage({
    required String operatorId,
    required String locationId,
    required String tierId,
    required DateTime now,
  }) async => snapshot;

  @override
  Future<void> incrementOnAllow({
    required String operatorId,
    required String locationId,
    required String tierId,
    required DateTime now,
    required int costCentsToAdd,
  }) async {
    /* no-op */
  }
}

class _FixedHealthStore implements ProxyHealthCheckStore {
  const _FixedHealthStore(this.status);

  final ProxyHealthStatus status;

  @override
  Future<ProxyHealthStatus> check() async => status;
}

class _RecordingLlmProvider implements ProxyLlmProvider {
  int completeCalls = 0;
  ProxyLlmRequest? lastRequest;

  @override
  Future<ProxyLlmCompletion> complete(ProxyLlmRequest request) async {
    completeCalls += 1;
    lastRequest = request;
    return ProxyLlmCompletion(
      text: 'fake advisor answer',
      modelId: request.modelId,
      tier: request.tier,
      outputTokens: 12,
      costCents: 1,
    );
  }
}

class _InMemoryAccountingStore implements ProxyAccountingStore {
  _InMemoryAccountingStore({required ProxyCapStatus capStatus})
    : _monthlyCapCents = capStatus.monthlyCapCents,
      _monthlyUsedCents = capStatus.monthlyUsedCents,
      _perInvocationCapCents = capStatus.perInvocationCapCents;

  factory _InMemoryAccountingStore.open() => _InMemoryAccountingStore(
    capStatus: const ProxyCapStatus(
      usageClass: 'advisor_qa',
      monthlyCapCents: 5000,
      monthlyUsedCents: 0,
      perInvocationCapCents: 500,
      estimatedCostCents: 1,
    ),
  );

  final int _monthlyCapCents;
  int _monthlyUsedCents;
  final int _perInvocationCapCents;
  final Map<String, Map<String, Object?>> _responses =
      <String, Map<String, Object?>>{};

  int startCalls = 0;
  int completeCalls = 0;

  int get monthlyUsedCents => _monthlyUsedCents;

  @override
  Future<ProxyAccountingStartResult> startRequest({
    required String idempotencyKey,
    required String requestType,
    required OperatorContext operator,
    required String usageClass,
    required ProxyUsageTelemetry telemetry,
    required ProxyUsageChargeEstimate estimate,
    required DateTime now,
  }) async {
    startCalls += 1;
    final existing = _responses[idempotencyKey];
    if (existing != null) {
      return ProxyAccountingReplayed(responsePayload: existing);
    }

    final status = ProxyCapStatus(
      usageClass: usageClass,
      monthlyCapCents: _monthlyCapCents,
      monthlyUsedCents: _monthlyUsedCents,
      perInvocationCapCents: _perInvocationCapCents,
      estimatedCostCents: estimate.costCents,
    );
    if (!status.allowed) {
      return ProxyAccountingRefused(capStatus: status);
    }

    _monthlyUsedCents += estimate.costCents;
    return ProxyAccountingReserved(capStatus: status);
  }

  int commitCalls = 0;
  ProxyUsageTelemetry? lastCommittedTelemetry;
  int? lastCommittedTokenCount;
  int? lastCommittedCostCents;

  @override
  Future<void> commitUsageLog({
    required OperatorContext operator,
    required String usageClass,
    required ProxyUsageTelemetry telemetry,
    required ProxyUsageChargeEstimate estimate,
    required DateTime now,
  }) async {
    commitCalls += 1;
    lastCommittedTelemetry = telemetry;
    lastCommittedTokenCount = estimate.tokenCount;
    lastCommittedCostCents = estimate.costCents;
  }

  @override
  Future<void> completeRequest({
    required OperatorContext operator,
    required String idempotencyKey,
    required Map<String, Object?> responsePayload,
    required DateTime now,
  }) async {
    completeCalls += 1;
    _responses[idempotencyKey] = Map<String, Object?>.from(responsePayload);
  }
}

class _StaticHitAdvisorCache implements AdvisorResponseCache {
  const _StaticHitAdvisorCache(this.answer);
  final String answer;

  @override
  Future<String?> lookup({
    required String operatorId,
    required String locationId,
    required String queryClass,
    required String questionHash,
    required String corpusVersion,
  }) async => answer;
}

OperatorContext _operatorContext() => const OperatorContext(
  userId: 'user_x',
  operatorId: 'op_777',
  locationId: 'loc_999',
  roles: <String>['advisor.read'],
);

OperatorContext _uuidOperatorContext() => const OperatorContext(
  userId: '11111111-1111-4111-8111-111111111111',
  operatorId: '22222222-2222-4222-8222-222222222222',
  locationId: '33333333-3333-4333-8333-333333333333',
  roles: <String>['advisor.read'],
);

ProxyJwtClaims _claims() => const ProxyJwtClaims(
  userId: 'user_x',
  operatorId: 'op_777',
  locationId: 'loc_999',
  roles: <String>['advisor.read'],
);

ProxyUsageTelemetry _telemetry() => const ProxyUsageTelemetry(
  queryClass: 'methodology_lookup',
  cacheHit: false,
  llmTier: 'haiku',
  modelUsed: 'claude-haiku-4-5',
);

class _PostgresSqlCall {
  const _PostgresSqlCall(this.sql, this.parameters);

  final String sql;
  final PostgresParameters parameters;
}

class _AccountingPostgresPool implements PostgresPool {
  final transactions = <_AccountingPostgresTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _AccountingPostgresTransaction();
    transactions.add(tx);
    return tx;
  }
}

class _AccountingPostgresTransaction implements PostgresTransaction {
  final executedSql = <String>[];
  final executeCalls = <_PostgresSqlCall>[];
  final queryCalls = <_PostgresSqlCall>[];
  var committed = false;
  var rolledBack = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    queryCalls.add(_PostgresSqlCall(sql, parameters));
    if (sql.contains('select response_payload') &&
        sql.contains('from public.proxy_requests')) {
      return const <PostgresRow>[];
    }
    if (sql.contains('from public.usage_caps')) {
      return const <PostgresRow>[
        <String, Object?>{
          'monthly_cap_usd': '10.00',
          'monthly_used_usd': '1.25',
          'per_invocation_cap_usd': '2.00',
        },
      ];
    }
    if (sql.contains('insert into public.proxy_requests')) {
      return const <PostgresRow>[
        <String, Object?>{
          'request_id': '44444444-4444-4444-8444-444444444444',
          'response_payload': null,
        },
      ];
    }
    if (sql.contains('insert into public.usage_logs')) {
      return const <PostgresRow>[
        <String, Object?>{
          'token_count': 123,
          'cost_usd': '0.2500',
          'request_count': 1,
        },
      ];
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    executedSql.add(sql);
    executeCalls.add(_PostgresSqlCall(sql, parameters));
    return 1;
  }

  @override
  Future<void> commit() async {
    committed = true;
  }

  @override
  Future<void> rollback() async {
    rolledBack = true;
  }
}

class _HttpResponseSnapshot {
  _HttpResponseSnapshot({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

Future<_HttpResponseSnapshot> _httpGet(
  HttpClient client,
  Uri uri, {
  String? authorization,
  Map<String, String>? headers,
}) async {
  final request = await client.getUrl(uri);
  // Disable connection reuse so a per-test HttpClient never picks up
  // a half-open connection targeting a previously-bound server port.
  request.persistentConnection = false;
  if (authorization != null) {
    request.headers.set(HttpHeaders.authorizationHeader, authorization);
  }
  headers?.forEach(request.headers.set);
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  return _HttpResponseSnapshot(statusCode: response.statusCode, body: body);
}

/// POST helper for the Phase 9 B6 auth-session endpoint tests. Sends
/// [body] as JSON when supplied, or an empty body when [body] is null
/// (used by the /revoke-all "default reason" test).
Future<_HttpResponseSnapshot> _httpPost(
  HttpClient client,
  Uri uri, {
  String? authorization,
  Map<String, Object?>? body,
  Map<String, String>? headers,
}) async {
  final request = await client.postUrl(uri);
  request.persistentConnection = false;
  request.headers.contentType = ContentType.json;
  if (authorization != null) {
    request.headers.set(HttpHeaders.authorizationHeader, authorization);
  }
  headers?.forEach(request.headers.set);
  if (body != null) {
    final encoded = utf8.encode(jsonEncode(body));
    request.contentLength = encoded.length;
    request.add(encoded);
  } else {
    request.contentLength = 0;
  }
  final response = await request.close();
  final responseBody = await response.transform(utf8.decoder).join();
  return _HttpResponseSnapshot(
    statusCode: response.statusCode,
    body: responseBody,
  );
}

/// Generic JSON helper used by the 11A.1 admin-route tests. Handles
/// arbitrary HTTP methods (POST / PATCH / DELETE) with an optional
/// JSON body.
Future<_HttpResponseSnapshot> _httpJson(
  HttpClient client,
  String method,
  Uri uri, {
  String? authorization,
  Map<String, Object?>? body,
}) async {
  final request = await client.openUrl(method, uri);
  request.persistentConnection = false;
  if (authorization != null) {
    request.headers.set(HttpHeaders.authorizationHeader, authorization);
  }
  if (body != null) {
    request.headers.contentType = ContentType.json;
    final encoded = utf8.encode(jsonEncode(body));
    request.contentLength = encoded.length;
    request.add(encoded);
  } else {
    request.contentLength = 0;
  }
  final response = await request.close();
  final responseBody = await response.transform(utf8.decoder).join();
  return _HttpResponseSnapshot(
    statusCode: response.statusCode,
    body: responseBody,
  );
}

// ─── 9.1 — Firebase verifier test helpers ────────────────────────────────────

pc.RSAPublicKey _rsaFixturePublicKey() => pc.RSAPublicKey(
  BigInt.parse(
    '20620915813302906913761247666337410938401372343750709187749515126790853245302593205328533062154315527282056175455193812046134139935830222032257750866653461677566720508752544506266533943725970345491747964654489405936145559121373664620352701801574863309087932865304205561439525871868738640172656811470047745445089832193075388387376667722031640892525639171016297098395245887609359882693921643396724693523583076582208970794545581164952427577506035951122669158313095779596666008591745562008787129160302313244329988240795948461701615228062848622019620094307696506764461083870202605984497833670577046553861732258592935325691',
  ),
  BigInt.parse('65537'),
);

pc.RSAPrivateKey _rsaFixturePrivateKey() => pc.RSAPrivateKey(
  BigInt.parse(
    '20620915813302906913761247666337410938401372343750709187749515126790853245302593205328533062154315527282056175455193812046134139935830222032257750866653461677566720508752544506266533943725970345491747964654489405936145559121373664620352701801574863309087932865304205561439525871868738640172656811470047745445089832193075388387376667722031640892525639171016297098395245887609359882693921643396724693523583076582208970794545581164952427577506035951122669158313095779596666008591745562008787129160302313244329988240795948461701615228062848622019620094307696506764461083870202605984497833670577046553861732258592935325691',
  ),
  BigInt.parse(
    '11998058528661160053642124235359844880039079149364512302169225182946866898849176558365314596732660324493329967536772364327680348872134489319530228055102152992797567579226269544119435926913937183793755182388650533700918602627770886358900914370472445911502526145837923104029967812779021649252540542517598618021899291933220000807916271555680217608559770825469218984818060775562259820009637370696396889812317991880425127772801187664191059506258517954313903362361211485802288635947903604738301101038823790599295749578655834195416886345569976295245464597506584866355976650830539380175531900288933412328525689718517239330305',
  ),
  BigInt.parse(
    '144173682842817587002196172066264549138375068078359231382946906898412792452632726597279520229873489736777248181678202636100459215718497240474064366927544074501134727745837254834206456400508719134610847814227274992298238973375146473350157304285346424982280927848339601514720098577525635486320547905945936448443',
  ),
  BigInt.parse(
    '143028293421514654659358549214971921584534096938352096320458818956414890934365483375293202045679474764569937266017713262196941957149321696805368542065644090886347646782188634885321277533175667840285448510687854061424867903968633218073060468434469761149335255007464091258725753837522484082998329871306803923137',
  ),
);

Uint8List _signRs256(Uint8List message, pc.RSAPrivateKey privateKey) {
  final random = pc.SecureRandom('Fortuna')
    ..seed(pc.KeyParameter(Uint8List.fromList(List<int>.filled(32, 7))));
  final signer = pc.Signer('SHA-256/RSA')
    ..init(
      true,
      pc.ParametersWithRandom(
        pc.PrivateKeyParameter<pc.RSAPrivateKey>(privateKey),
        random,
      ),
    );
  return (signer.generateSignature(message) as pc.RSASignature).bytes;
}

String _rsaFixtureCertificatePem() {
  final publicKey = _rsaFixturePublicKey();
  final rsaAlgorithm = pc.ASN1Sequence(
    elements: <pc.ASN1Object>[
      pc.ASN1ObjectIdentifier(<int>[1, 2, 840, 113549, 1, 1, 1]),
      pc.ASN1Null(),
    ],
  );
  final rsaPublicKey = pc.ASN1Sequence(
    elements: <pc.ASN1Object>[
      pc.ASN1Integer(publicKey.modulus),
      pc.ASN1Integer(publicKey.publicExponent),
    ],
  ).encode();
  final subjectPublicKeyInfo = pc.ASN1Sequence(
    elements: <pc.ASN1Object>[
      rsaAlgorithm,
      pc.ASN1BitString(stringValues: rsaPublicKey),
    ],
  );
  final tbsCertificate = pc.ASN1Sequence(
    elements: <pc.ASN1Object>[
      pc.ASN1Integer(BigInt.one),
      rsaAlgorithm,
      pc.ASN1Sequence(elements: <pc.ASN1Object>[]),
      pc.ASN1Sequence(elements: <pc.ASN1Object>[]),
      pc.ASN1Sequence(elements: <pc.ASN1Object>[]),
      subjectPublicKeyInfo,
    ],
  );
  final certificate = pc.ASN1Sequence(
    elements: <pc.ASN1Object>[
      tbsCertificate,
      rsaAlgorithm,
      pc.ASN1BitString(stringValues: <int>[0]),
    ],
  ).encode();
  return _pemBlock('CERTIFICATE', certificate);
}

String _pemBlock(String label, Uint8List bytes) {
  final encoded = base64Encode(bytes);
  final lines = <String>[];
  for (var i = 0; i < encoded.length; i += 64) {
    final end = i + 64 > encoded.length ? encoded.length : i + 64;
    lines.add(encoded.substring(i, end));
  }
  return '-----BEGIN $label-----\n'
      '${lines.join('\n')}\n'
      '-----END $label-----';
}

class _FixedJwksKeySource implements JwksKeySource {
  _FixedJwksKeySource(this._keys);

  final Map<String, JwtKeyMaterial> _keys;

  @override
  Future<JwtKeyMaterial?> publicKeyFor(String kid) async => _keys[kid];
}

class _AlwaysAcceptRs256Validator implements JwtRs256SignatureValidator {
  const _AlwaysAcceptRs256Validator();

  @override
  bool verify({
    required Uint8List signedInput,
    required Uint8List signature,
    required JwtKeyMaterial keyMaterial,
  }) {
    return true;
  }
}

class _AlwaysRejectRs256Validator implements JwtRs256SignatureValidator {
  const _AlwaysRejectRs256Validator();

  @override
  bool verify({
    required Uint8List signedInput,
    required Uint8List signature,
    required JwtKeyMaterial keyMaterial,
  }) {
    return false;
  }
}

class _BoomRs256Validator implements JwtRs256SignatureValidator {
  const _BoomRs256Validator();

  @override
  bool verify({
    required Uint8List signedInput,
    required Uint8List signature,
    required JwtKeyMaterial keyMaterial,
  }) {
    throw FormatException('placeholder format failure');
  }
}

/// Builds a test Firebase ID token (header.payload.signature) using
/// raw base64url encoding. The signature segment is a placeholder
/// non-empty value because tests inject a [JwtRs256SignatureValidator]
/// that does not actually inspect the bytes.
String _firebaseTestToken({
  String kid = 'kid-good',
  String? algOverride,
  String projectId = 'forge-flow-staging',
  String? issuerOverride,
  Object? audienceOverride,
  String sub = 'user_abc',
  String? operatorId = 'op_777',
  String? locationId = 'loc_999',
  bool isSuperAdmin = false,
  bool isFfSupport = false,
  int? rolesVersion,
  required DateTime issuedAt,
  required DateTime expiresAt,
  DateTime? authTime,
}) {
  final headerJson = <String, Object?>{
    'alg': algOverride ?? 'RS256',
    if (kid.isNotEmpty) 'kid': kid,
    'typ': 'JWT',
  };
  final payloadJson = <String, Object?>{
    'iss': issuerOverride ?? 'https://securetoken.google.com/$projectId',
    'aud': audienceOverride ?? projectId,
    if (sub.isNotEmpty) 'sub': sub,
    'iat': issuedAt.toUtc().millisecondsSinceEpoch ~/ 1000,
    'exp': expiresAt.toUtc().millisecondsSinceEpoch ~/ 1000,
    if (authTime != null)
      'auth_time': authTime.toUtc().millisecondsSinceEpoch ~/ 1000,
    if (operatorId != null) 'operator_id': operatorId,
    if (locationId != null) 'location_id': locationId,
    if (isSuperAdmin) 'is_super_admin': true,
    if (isFfSupport) 'is_ff_support': true,
    if (rolesVersion != null) 'roles_version': rolesVersion,
  };
  final headerSegment = _base64UrlEncodeJson(headerJson);
  final payloadSegment = _base64UrlEncodeJson(payloadJson);
  // Signature segment: placeholder non-empty bytes — the test
  // signature validator never inspects them.
  final signatureSegment = base64Url
      .encode(<int>[0x01, 0x02, 0x03, 0x04])
      .replaceAll('=', '');
  return '$headerSegment.$payloadSegment.$signatureSegment';
}

String _base64UrlEncodeJson(Map<String, Object?> data) {
  final bytes = utf8.encode(jsonEncode(data));
  return base64Url.encode(bytes).replaceAll('=', '');
}

Future<void> _expectVerifierError(
  Future<ProxyJwtClaims> future,
  Matcher messageMatcher,
) async {
  ProxyJwtVerificationError? thrown;
  try {
    await future;
  } on ProxyJwtVerificationError catch (error) {
    thrown = error;
  }
  expect(
    thrown,
    isNotNull,
    reason: 'expected ProxyJwtVerificationError but verify() returned',
  );
  expect(thrown!.message, messageMatcher);
}

// ─── Phase 9 B6 — auth-session ledger test fakes ─────────────────────

/// Records every call into the writer so route tests can assert what
/// the proxy delegated. Login responses carry a queued list of
/// session_ids so a single fake can drive multiple sequential logins.
class _RecordingAuthSessionLedger implements AuthSessionLedgerWriter {
  _RecordingAuthSessionLedger({
    List<String>? loginSessionIds,
    int revokeAllReturnCount = 0,
  }) : _loginSessionIds = List<String>.from(
         loginSessionIds ?? const <String>['session-test-default'],
       ),
       _revokeAllReturnCount = revokeAllReturnCount;

  final List<String> _loginSessionIds;
  final int _revokeAllReturnCount;

  final List<AuthSessionLedgerLogin> logins = <AuthSessionLedgerLogin>[];
  final List<
    ({String sessionId, String userId, String operatorId, String locationId})
  >
  refreshes =
      <
        ({
          String sessionId,
          String userId,
          String operatorId,
          String locationId,
        })
      >[];
  final List<
    ({
      String sessionId,
      String userId,
      String operatorId,
      String locationId,
      String reason,
    })
  >
  revokes =
      <
        ({
          String sessionId,
          String userId,
          String operatorId,
          String locationId,
          String reason,
        })
      >[];
  final List<
    ({String userId, String operatorId, String locationId, String reason})
  >
  revokeAlls =
      <
        ({String userId, String operatorId, String locationId, String reason})
      >[];

  @override
  Future<String> recordLogin(AuthSessionLedgerLogin login) async {
    logins.add(login);
    if (_loginSessionIds.isEmpty) return 'session-test-default';
    return _loginSessionIds.removeAt(0);
  }

  @override
  Future<void> recordRefresh({
    required String sessionId,
    required String userId,
    required String operatorId,
    required String locationId,
  }) async {
    refreshes.add((
      sessionId: sessionId,
      userId: userId,
      operatorId: operatorId,
      locationId: locationId,
    ));
  }

  @override
  Future<void> revokeSession({
    required String sessionId,
    required String userId,
    required String operatorId,
    required String locationId,
    required String reason,
  }) async {
    revokes.add((
      sessionId: sessionId,
      userId: userId,
      operatorId: operatorId,
      locationId: locationId,
      reason: reason,
    ));
  }

  @override
  Future<int> revokeAllSessionsForUser({
    required String userId,
    required String operatorId,
    required String locationId,
    required String reason,
  }) async {
    revokeAlls.add((
      userId: userId,
      operatorId: operatorId,
      locationId: locationId,
      reason: reason,
    ));
    return _revokeAllReturnCount;
  }
}

/// Throws [error] from every method. Lets the route tests assert that
/// the proxy NEVER lets a writer's raw exception text leak into the
/// HTTP response (defense-in-depth for connection strings, secrets,
/// or stack-trace fragments that real Postgres errors can carry).
class _ThrowingAuthSessionLedger implements AuthSessionLedgerWriter {
  _ThrowingAuthSessionLedger({required this.error});

  final Object error;

  @override
  Future<String> recordLogin(AuthSessionLedgerLogin login) async {
    throw error;
  }

  @override
  Future<void> recordRefresh({
    required String sessionId,
    required String userId,
    required String operatorId,
    required String locationId,
  }) async {
    throw error;
  }

  @override
  Future<void> revokeSession({
    required String sessionId,
    required String userId,
    required String operatorId,
    required String locationId,
    required String reason,
  }) async {
    throw error;
  }

  @override
  Future<int> revokeAllSessionsForUser({
    required String userId,
    required String operatorId,
    required String locationId,
    required String reason,
  }) async {
    throw error;
  }
}
