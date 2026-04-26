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

import 'package:flutter_test/flutter_test.dart';

import '../tool/advisor_proxy/advisor_proxy.dart';

void main() {
  group('ProxyConfig.fromEnvironment', () {
    Map<String, String> environmentWithAllSecrets({String? port}) {
      return <String, String>{
        ProxySecretNames.anthropicApiKey: 'placeholder-anthropic',
        ProxySecretNames.voyageApiKey: 'placeholder-voyage',
        ProxySecretNames.postgresUrl: 'placeholder-postgres-url',
        ProxySecretNames.postgresAdminUrl: 'placeholder-postgres-admin-url',
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
    test('usage log SQL is an atomic telemetry-aware UPSERT', () {
      final sql = ProxyUsageLogSql.atomicUpsert.toLowerCase();

      expect(sql, contains('insert into public.usage_logs'));
      expect(sql, contains('on conflict'));
      expect(sql, contains('do update set'));
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
      expect(
        sql,
        contains(
          'token_count = public.usage_logs.token_count + '
          'excluded.token_count',
        ),
      );
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
  });

  group('Advisor proxy usage counters migration (11a.10b)', () {
    test('creates the counter table with RLS, service-role policy, and '
        'operator/location/tier/minute uniqueness', () {
      final migration = File(
        'db/migrations/202604250004_advisor_proxy_usage_counters.sql',
      ).readAsStringSync();

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
      ).readAsStringSync();
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
      ).readAsStringSync();
      normalizedMigration = migration.replaceAll(RegExp(r'\s+'), ' ');
      auditSql = File(
        'db/verification/'
        '202604250006_advisor_schema_hardening_audits.sql',
      ).readAsStringSync();
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
      ).readAsStringSync();
      normalizedMigration = migration.replaceAll(RegExp(r'\s+'), ' ');
    });

    test('migration file follows the Contextual Retrieval telemetry migration',
        () {
      expect(
        migrationNames,
        contains('202604250007_advisor_rls_index_hardening.sql'),
      );
      expect(
        migrationNames.indexOf('202604250007_advisor_rls_index_hardening.sql'),
        equals(
          migrationNames.indexOf(
                '202604250006_advisor_contextual_retrieval_telemetry.sql',
              ) +
              1,
        ),
      );
    });

    test('advisor_proxy_usage_counters final primary key is tenant-leading',
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
    });

    test('proxy_requests final primary and idempotency keys are tenant-leading',
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
    });
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
      ).readAsStringSync();
      normalizedMigration = migration.replaceAll(RegExp(r'\s+'), ' ');
      permissionKeysSource = File(
        'lib/auth/permission_keys.dart',
      ).readAsStringSync();
      catalogContract = File(
        'docs/contracts/auth_permission_key_catalog.md',
      ).readAsStringSync();
    });

    test('migration is the next deterministic file after 11a.11c.6 hardening',
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
    });

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
        'firebase_uid uuid not null default gen_random_uuid()',
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

    test('operator_admins is extended and gets a composite scope-location FK',
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
    });

    test('legacy users.role column is migrated into user_roles and dropped',
        () {
      // The DO block guards the backfill on column existence so re-runs
      // after the column was already dropped are safe.
      expect(
        migration,
        contains(
          "where table_schema = 'public'\n       and table_name = 'users'\n"
          "       and column_name = 'role'",
        ),
      );
      expect(migration, contains('insert into public.user_roles'));
      expect(
        migration,
        contains('alter table public.users drop column role'),
      );
    });

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

    test(
      'user_roles_active_grant_idx is tenant-leading and supports the same '
      'user holding the same role across different operators',
      () {
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
      },
    );

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

    test(
      'operator-scoped tables carry tenant-leading indexes per RLS '
      'performance discipline',
      () {
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
      },
    );

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

    test('every new auth table has RLS enabled and a service-role policy stub',
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
    });

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
        contains(
          'revoke update, delete on public.role_audit_log from public',
        ),
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
      expect(
        migration,
        contains('auth_events_audit_service_role_append_only'),
      );
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
      expect(
        migration,
        contains('insert into public.permission_keys'),
      );
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

    test('every key from PermissionKeys.all is seeded into permission_keys',
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
      // Every key declared in constants must be seeded by the migration.
      for (final key in keys) {
        expect(
          migration,
          contains("'$key'"),
          reason: 'PermissionKeys constant $key not seeded by migration',
        );
      }
    });

    test('MFA-required keys are flagged in the migration with requires_mfa '
        'true and documented in the catalog contract', () {
      const mfaRequiredKeys = <String>[
        'admin.users.erase_pii',
        'admin.roles.edit_seeded',
        'admin.pricing_tier.edit',
        'billing.subscription.manage',
        'billing.payment_method.manage',
        'billing.usage_caps.edit',
        'integration.key_rotate',
      ];
      for (final key in mfaRequiredKeys) {
        // The seed row for an MFA-required key carries `true, true` at
        // the (requires_mfa, frozen) tail of the values tuple.
        final escapedKey = RegExp.escape(key);
        final pattern = RegExp(
          "'$escapedKey',[\\s\\S]*?true,\\s*true\\b",
        );
        expect(
          pattern.hasMatch(migration),
          isTrue,
          reason: 'MFA-required key $key not flagged with requires_mfa=true',
        );
        expect(
          catalogContract,
          contains(key),
          reason:
              'MFA-required key $key missing from catalog contract doc',
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

    test('migration does not introduce pgmq, Firebase config, or live calls',
        () {
      // pgmq is not exposed by Azure flexible server; the queue-provider
      // choice is locked to FOR UPDATE SKIP LOCKED + Cloud Tasks (see
      // CLAUDE.md). The 9.0 schema must not reintroduce it.
      expect(migration.toLowerCase(), isNot(contains('pgmq')));
      // 9.0 is schema-only/local-first. Firebase wiring belongs to 9.1.
      expect(migration.toLowerCase(), isNot(contains('firebase_admin')));
      expect(migration.toLowerCase(), isNot(contains('http://')));
      expect(migration.toLowerCase(), isNot(contains('https://')));
    });
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

    test('GET /healthz returns 200 ok and is unauthenticated', () async {
      await withRealHttp(() async {
        await spinUpServer();
        try {
          final response = await _httpGet(client, baseUri.resolve(healthPath));
          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['status'], equals('ok'));
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
            expect(body['postgres_select_1'], equals('ok'));
            expect(body['age_cypher_match'], equals('ok'));
            expect(body['pgvector_similarity'], equals('ok'));
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
          expect(body['age_cypher_match'], equals('failed'));
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

    test('GET /v1/usage-smoke happy path returns operator/location, tier, '
        'timeout, max tokens, and remaining budget', () async {
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
          expect(body['operator_id'], equals('op_777'));
          expect(body['location_id'], equals('loc_999'));
          expect(body['policy_tier'], equals('launch'));
          expect(
            body['request_timeout_seconds'],
            equals(PolicyTier.launch.requestTimeoutSeconds),
          );
          expect(
            body['max_output_tokens'],
            equals(PolicyTier.launch.maxOutputTokens),
          );
          expect(
            body['remaining_requests_this_minute'],
            equals(PolicyTier.launch.maxRequestsPerMinute - 5),
          );
          expect(
            body['remaining_cost_cents_this_month'],
            equals(PolicyTier.launch.maxMonthlyCostCents - 250),
          );
          expect(body['estimate_request_tokens'], equals(256));
          expect(body['note'], contains('11a.10b'));
          expect(body['note'], contains('No provider call performed'));
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

    test(
      'GET /healthz still 200 unauthenticated when usage guard is installed',
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
              baseUri.resolve(healthPath),
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
  });
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

  @override
  Future<void> completeRequest({
    required String idempotencyKey,
    required Map<String, Object?> responsePayload,
    required DateTime now,
  }) async {
    completeCalls += 1;
    _responses[idempotencyKey] = Map<String, Object?>.from(responsePayload);
  }
}

OperatorContext _operatorContext() => const OperatorContext(
  userId: 'user_x',
  operatorId: 'op_777',
  locationId: 'loc_999',
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
