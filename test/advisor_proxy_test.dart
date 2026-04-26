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
    Map<String, String> environmentWithAllSecrets({
      String? port,
    }) {
      return <String, String>{
        ProxySecretNames.anthropicApiKey: 'placeholder-anthropic',
        ProxySecretNames.voyageApiKey: 'placeholder-voyage',
        ProxySecretNames.supabaseUrl: 'placeholder-supabase-url',
        ProxySecretNames.supabaseServiceRoleKey:
            'placeholder-service-role',
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
          ProxySecretNames.supabaseUrl,
          ProxySecretNames.supabaseServiceRoleKey,
        ]),
      );
      expect(
        config.hasSecretFor(ProxySecretNames.anthropicApiKey),
        isTrue,
      );
    });

    test('defaults port to 8080 when PORT is missing or invalid', () {
      final missing = ProxyConfig.fromEnvironment(
        environmentWithAllSecrets(),
      );
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
        ProxySecretNames.supabaseUrl: 'placeholder-url',
        ProxySecretNames.supabaseServiceRoleKey: '   ', // blank counts
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
          ProxySecretNames.supabaseServiceRoleKey,
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
        ProxySecretNames.supabaseUrl: marker,
        ProxySecretNames.supabaseServiceRoleKey: marker,
      };

      final config = ProxyConfig.fromEnvironment(environment);
      expect(config.toString(), isNot(contains(marker)));
      expect(
        config.toString(),
        contains(ProxySecretNames.anthropicApiKey),
      );

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

    test(
      'secretFor returns the loaded value but is the only accessor that '
      'returns it (callers must not log it)',
      () {
        final config = ProxyConfig.fromEnvironment(
          environmentWithAllSecrets(),
        );

        // Smoke: the value comes back through the explicit accessor —
        // no toString / no JSON / no iteration. Test reads it once and
        // does not write it anywhere.
        final value = config.secretFor(ProxySecretNames.anthropicApiKey);
        expect(value.isNotEmpty, isTrue);

        expect(
          () => config.secretFor('NEVER_REGISTERED_SECRET'),
          throwsStateError,
        );
      },
    );
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

    test(
      'rejects verified token without operator scope (403)',
      () async {
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
      },
    );

    test(
      'rejects verified token without location scope (403)',
      () async {
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
      },
    );

    test(
      'happy path returns scoped OperatorContext with userId / operator / '
      'location / roles',
      () async {
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

    test(
      'PolicyTier.launch defaults are non-zero and machine-usable',
      () {
        const tier = PolicyTier.launch;
        expect(tier.id, isNotEmpty);
        expect(tier.maxRequestTokens, greaterThan(0));
        expect(tier.maxRequestsPerMinute, greaterThan(0));
        expect(tier.maxMonthlyCostCents, greaterThan(0));
        expect(tier.requestTimeoutSeconds, greaterThan(0));
        expect(tier.maxOutputTokens, greaterThan(0));
      },
    );

    test(
      'over-token request refuses BEFORE the store is queried',
      () async {
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
      },
    );

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

    test(
      'monthly cost cap surfaces 402 monthly_cap_reached',
      () async {
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
      },
    );

    test(
      'happy path returns tier + remaining budget',
      () async {
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
      },
    );

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
        expect(
          thrown.details['reason'],
          contains('11a.10b scaffold'),
        );
      },
    );

    test(
      'non-StateError store failures also fail closed (503) with a '
      'generic reason that does not leak raw error contents',
      () async {
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
        expect(
          thrown.details['reason'],
          equals('unexpected store failure'),
        );
        // The raw exception payload (which would carry connection
        // strings / secrets in real failures) must not be echoed.
        final reasonText = thrown.details['reason'].toString();
        expect(reasonText, isNot(contains('pretend-secret')));
        expect(reasonText, isNot(contains('postgres://')));
      },
    );
  });

  group('Advisor proxy usage counters migration (11a.10b)', () {
    test(
      'creates the counter table with RLS, service-role policy, and '
      'operator/location/tier/minute uniqueness',
      () {
        final migration = File(
          'supabase/migrations/202604250004_advisor_proxy_usage_counters.sql',
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
        expect(
          migration,
          contains('request_count integer not null default 0'),
        );
        expect(migration, contains('token_count bigint not null default 0'));
        expect(migration, contains('cost_cents bigint not null default 0'));

        // Uniqueness over (operator, location, tier, period).
        expect(
          migration,
          contains(
            'unique (operator_id, location_id, tier_id, minute_bucket)',
          ),
        );

        // Indexes for read paths.
        expect(
          migration,
          contains('advisor_proxy_usage_counters_minute_idx'),
        );
        expect(
          migration,
          contains('advisor_proxy_usage_counters_month_idx'),
        );

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
      },
    );
  });

  group('Advisor cloud foundation migration (11a.11c.1)', () {
    late String migration;

    setUpAll(() {
      migration = File(
        'supabase/migrations/'
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
      expect(
        migration,
        contains('create table if not exists public.users'),
      );
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
          contains(
            "preferred_currency char(3) not null default 'CAD'",
          ),
        );
        expect(
          migration,
          contains('primary_location_id uuid null'),
        );
        // FK is added after locations exists to break the cycle, and is
        // composite on (operator_id, primary_location_id) so an
        // operator's primary_location_id cannot point at another
        // operator's location.
        expect(
          migration,
          contains('alter table public.operators'),
        );
        expect(
          migration,
          contains('add constraint operators_primary_location_fk'),
        );
        expect(
          migration,
          contains(
            'foreign key (operator_id, primary_location_id)',
          ),
        );
        expect(
          migration,
          contains(
            'references public.locations(operator_id, location_id)',
          ),
        );
        // ON DELETE SET NULL with a column list (PG15+) preserves
        // operator_id (NOT NULL on operators) when the referenced
        // location is deleted.
        expect(
          migration,
          contains('on delete set null (primary_location_id)'),
        );
      },
    );

    test(
      'locations carries timezone NOT NULL and '
      'business_day_rollover_hour with a 0-23 check',
      () {
        expect(migration, contains('timezone text not null'));
        expect(
          migration,
          contains('business_day_rollover_hour integer'),
        );
        expect(
          migration,
          contains(
            'check (business_day_rollover_hour between 0 and 23)',
          ),
        );
      },
    );

    test(
      'users + operator_admins reference operators with cascade and use '
      'a composite PK on operator_admins',
      () {
        expect(
          migration,
          contains(
            'operator_id uuid not null references public.operators(operator_id)',
          ),
        );
        // operator_admins composite PK so a user can admin multiple operators.
        expect(
          migration,
          contains('primary key (user_id, operator_id)'),
        );
        expect(
          migration,
          contains('is_super_admin boolean not null default false'),
        );
      },
    );

    test(
      'usage_logs is partitioned by period_start with composite PK and '
      'non-negative checks',
      () {
        expect(
          migration,
          contains('create table if not exists public.usage_logs'),
        );
        expect(
          migration,
          contains('partition by range (period_start)'),
        );
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
          contains(
            'create table if not exists public.usage_logs_default',
          ),
        );
        expect(
          migration,
          contains('partition of public.usage_logs default'),
        );
      },
    );

    test(
      'usage_caps is keyed on (operator_id, location_id, usage_class) '
      'with non-negative cap checks and nullable created_by/updated_by',
      () {
        expect(
          migration,
          contains('create table if not exists public.usage_caps'),
        );
        expect(
          migration,
          contains(
            'primary key (operator_id, location_id, usage_class)',
          ),
        );
        expect(migration, contains('check (monthly_cap_usd >= 0)'));
        expect(
          migration,
          contains('check (per_invocation_cap_usd >= 0)'),
        );
        expect(migration, contains('created_by uuid null'));
        expect(migration, contains('updated_by uuid null'));
      },
    );

    test(
      'proxy_requests has unique idempotency_key, request_type, and '
      'nullable response_payload jsonb',
      () {
        expect(
          migration,
          contains(
            'create table if not exists public.proxy_requests',
          ),
        );
        expect(
          migration,
          contains('idempotency_key text not null unique'),
        );
        expect(migration, contains('request_type text not null'));
        expect(migration, contains('response_payload jsonb null'));
      },
    );

    test(
      'feature_flags supports global / operator / location scopes via '
      'three partial unique indexes (no duplicates per logical scope)',
      () {
        expect(
          migration,
          contains(
            'create table if not exists public.feature_flags',
          ),
        );
        // Three partial unique indexes cover the three logical scopes.
        expect(
          migration,
          contains('feature_flags_global_scope_idx'),
        );
        expect(
          migration,
          contains('feature_flags_operator_scope_idx'),
        );
        expect(
          migration,
          contains('feature_flags_location_scope_idx'),
        );
        expect(
          migration,
          contains(
            'where operator_id is null and location_id is null',
          ),
        );
      },
    );

    test(
      'fx_rates is keyed on (base_currency, quote_currency, '
      'as_of_date) with positive rate and currency-format checks',
      () {
        expect(
          migration,
          contains('create table if not exists public.fx_rates'),
        );
        expect(
          migration,
          contains(
            'primary key (base_currency, quote_currency, as_of_date)',
          ),
        );
        expect(migration, contains('check (rate > 0)'));
        // Currency code shape check.
        expect(
          migration,
          contains(r"check (base_currency ~ '^[A-Z]{3}$')"),
        );
        expect(
          migration,
          contains(r"check (quote_currency ~ '^[A-Z]{3}$')"),
        );
      },
    );

    test(
      'every new table has RLS enabled and a service-role-only policy '
      'stub',
      () {
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
            contains(
              'alter table public.$table enable row level security',
            ),
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
      },
    );

    test(
      'migration uses TIMESTAMPTZ throughout — no `timestamp without '
      'time zone` (operator-scoped silent-DST hazard banned)',
      () {
        expect(
          migration.toLowerCase().contains('timestamp without time zone'),
          isFalse,
          reason:
              'TIMESTAMP WITHOUT TIME ZONE is banned in operator-scoped '
              'tables — silent DST corruption is unrecoverable.',
        );
      },
    );

    test(
      'locations carries an explicit `unique (operator_id, location_id)` '
      'so composite FKs from operator-scoped tables have a target',
      () {
        expect(
          migration,
          contains('unique (operator_id, location_id)'),
        );
      },
    );

    test(
      'every operator/location-scoped table references locations on '
      'the (operator_id, location_id) pair — rejects (operator_a, '
      'location_b) cross-tenant mismatches at the DB layer',
      () {
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
      },
    );

    test(
      'feature_flags rejects the malformed (location set, operator '
      'NULL) shape via a CHECK constraint',
      () {
        expect(
          migration,
          contains(
            'check (location_id is null or operator_id is not null)',
          ),
        );
      },
    );

    test(
      'feature_flags_location_scope_idx requires both operator_id and '
      'location_id to be present (so duplicates of the malformed '
      'shape cannot slip through)',
      () {
        expect(
          migration,
          contains(
            'where operator_id is not null and location_id is not null',
          ),
        );
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

    Future<void> spinUpServer({ProxyUsageGuard? usageGuard}) async {
      verifier = _SettableVerifier();
      final guard = ProxyRequestGuard(verifier: verifier);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // ignore: unawaited_futures
      server.listen((request) async {
        try {
          await routeRequest(request, guard, usageGuard: usageGuard);
        } catch (_) {
          try {
            request.response.statusCode = 500;
            await request.response.close();
          } catch (_) {/* ignore */}
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
    });

    test(
      'GET /v1/scope without Authorization returns 401',
      () async {
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
      },
    );

    test(
      'GET /v1/scope with verifier failure returns 401',
      () async {
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
      },
    );

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

    test(
      'GET /v1/scope happy path returns 200 with operator/location echo '
      'and notes the slice does not call providers',
      () async {
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
      },
    );

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

    test(
      'GET /v1/usage-smoke without a usage guard returns 503',
      () async {
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
      },
    );

    test(
      'GET /v1/usage-smoke without Authorization returns 401 even with '
      'a configured usage guard',
      () async {
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
      },
    );

    test(
      'GET /v1/usage-smoke with a non-StateError store failure returns 503 '
      'usage_store_unavailable without leaking raw error text',
      () async {
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
      },
    );

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
              baseUri.resolve(usageSmokePath).replace(
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

    test(
      'GET /v1/usage-smoke at the per-minute cap returns 429',
      () async {
        await withRealHttp(() async {
          await spinUpServer(
            usageGuard: ProxyUsageGuard(
              store: _FixedSnapshotStore(
                snapshot: UsageSnapshot(
                  requestsThisMinute:
                      PolicyTier.launch.maxRequestsPerMinute,
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
      },
    );

    test(
      'GET /v1/usage-smoke at the monthly cost cap returns 402',
      () async {
        await withRealHttp(() async {
          await spinUpServer(
            usageGuard: ProxyUsageGuard(
              store: _FixedSnapshotStore(
                snapshot: UsageSnapshot(
                  requestsThisMinute: 0,
                  costCentsThisMonth:
                      PolicyTier.launch.maxMonthlyCostCents,
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
      },
    );

    test(
      'GET /v1/usage-smoke happy path returns operator/location, tier, '
      'timeout, max tokens, and remaining budget',
      () async {
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
              baseUri.resolve(usageSmokePath).replace(
                queryParameters: <String, String>{
                  'est_tokens': '256',
                },
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
      },
    );

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
  }) async {/* no-op */}
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
}) async {
  final request = await client.getUrl(uri);
  // Disable connection reuse so a per-test HttpClient never picks up
  // a half-open connection targeting a previously-bound server port.
  request.persistentConnection = false;
  if (authorization != null) {
    request.headers.set(HttpHeaders.authorizationHeader, authorization);
  }
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  return _HttpResponseSnapshot(
    statusCode: response.statusCode,
    body: body,
  );
}
