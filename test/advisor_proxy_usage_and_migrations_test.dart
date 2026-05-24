// 11a.10b / 11a.11d / 11a.11c — Advisor proxy usage + accounting + migrations.
//
// Bucket 5c-usage+migrations of the 2026-05-20 test-suite tightening audit:
// split out of `test/advisor_proxy_test.dart` (8,328 lines). This file
// holds the ProxyUsageGuard + accounting (11a.10b / 11a.11d) groups and
// the advisor-proxy SQL migration audits: usage counters (11a.10b),
// cloud foundation (11a.11c.1), schema hardening (11a.11c.6a), RLS index
// hardening (11a.11c.6 live fix), and the Phase 9.0Σ.g usage_caps
// two-slot key migration (B28 / item 6).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../tool/advisor_proxy/advisor_proxy.dart';
import 'advisor_proxy_test_helpers.dart';

void main() {
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
      final store = RecordingProxyUsageStore();
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
        final store = FixedSnapshotProxyUsageStore(
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
      final store = FixedSnapshotProxyUsageStore(
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
      final store = FixedSnapshotProxyUsageStore(
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
        store: BoomProxyUsageStore(
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
        final store = InMemoryAccountingStore(
          capStatus: const ProxyCapStatus(
            usageClass: 'advisor_qa',
            monthlyCapCents: 1,
            monthlyUsedCents: 0,
            perInvocationCapCents: 1,
            estimatedCostCents: 1,
          ),
        );
        final operator = defaultOperatorContext();
        final starts = await Future.wait(<Future<ProxyAccountingStartResult>>[
          store.startRequest(
            idempotencyKey: 'idem_a',
            requestType: 'advisor_smoke',
            operator: operator,
            usageClass: 'advisor_qa',
            telemetry: defaultProxyTelemetry(),
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
            telemetry: defaultProxyTelemetry(),
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
      final pool = AccountingPostgresPool();
      final store = PostgresProxyAccountingStore(
        wrapper: TenantTransactionWrapper(pool),
      );
      final operator = defaultUuidOperatorContext();
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
      final pool = AccountingPostgresPool();
      final store = PostgresProxyAccountingStore(
        wrapper: TenantTransactionWrapper(pool),
      );
      final operator = defaultUuidOperatorContext();

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

    test(
      'AI Metrics: a cap refusal records exactly one usage_cap_events row '
      'with operator/location/usage_class/query_class + snapshotted '
      'cap_usd/attempted_usd and a SQL-derived business_date',
      () async {
        final pool = AccountingPostgresPool();
        final store = PostgresProxyAccountingStore(
          wrapper: TenantTransactionWrapper(pool),
        );
        final operator = defaultUuidOperatorContext();

        // The fake cap-status row exposes a per-invocation cap of $2.00
        // (`AccountingPostgresPool.query` for `public.usage_caps`). A
        // 500-cent ($5.00) estimate exceeds it, so startRequest refuses.
        final start = await store.startRequest(
          idempotencyKey: 'idem-cap-refusal',
          requestType: 'advisor_smoke',
          operator: operator,
          usageClass: 'advisor_qa',
          telemetry: const ProxyUsageTelemetry(
            queryClass: 'methodology_lookup',
            cacheHit: false,
            llmTier: 'haiku',
            modelUsed: 'claude-haiku-4-5',
          ),
          estimate: const ProxyUsageChargeEstimate(
            tokenCount: 123,
            costCents: 500,
          ),
          now: DateTime.utc(2026, 4, 26, 12),
        );

        expect(start, isA<ProxyAccountingRefused>());

        // Two transactions: the cap-check (committed, no reservation
        // insert) and a SEPARATE best-effort cap-event transaction. The
        // recorder runs AFTER the cap-check tx, so there is no nesting.
        expect(pool.transactions, hasLength(2));
        final capCheckTx = pool.transactions.first;
        final capEventTx = pool.transactions[1];
        expect(capCheckTx.committed, isTrue);
        expect(capEventTx.committed, isTrue);
        expect(capEventTx.rolledBack, isFalse);

        // The cap-event tx ran inside tenant context (SET LOCAL operator +
        // location) so the per-tenant RLS INSERT policy admits the row.
        expect(
          capEventTx.executedSql,
          containsAll(<String>[
            "select set_config('app.operator_id', @value, true)",
            "select set_config('app.location_id', @value, true)",
            "select set_config('app.user_id', @value, true)",
          ]),
        );

        // Exactly one cap-event INSERT, and no reservation insert on a
        // refusal (the request never reserved an idempotency row).
        final capEventInserts = capEventTx.executeCalls
            .where((c) => c.sql.contains('insert into public.usage_cap_events'))
            .toList();
        expect(capEventInserts, hasLength(1));
        final insert = capEventInserts.single;

        // business_date is derived in SQL from the location's timezone +
        // business_day_rollover_hour (Time Guardrails) — not bound from
        // Dart. The INSERT ... SELECT FROM public.locations carries the
        // same projection as the Phase 8 denorm trigger.
        expect(insert.sql, contains('from public.locations l'));
        expect(insert.sql, contains('business_day_rollover_hour'));
        expect(insert.sql, contains('at time zone'));
        expect(insert.parameters.containsKey('business_date'), isFalse);

        // Correct attribution + snapshotted amounts. The per-invocation
        // cap ($2.00) tripped, so cap_usd = 2.0000 and attempted_usd =
        // the single call's projected cost (5.0000). Both fixed-4 strings.
        expect(insert.parameters['operator_id'], equals(operator.operatorId));
        expect(insert.parameters['location_id'], equals(operator.locationId));
        expect(insert.parameters['usage_class'], equals('advisor_qa'));
        expect(insert.parameters['query_class'], equals('methodology_lookup'));
        expect(insert.parameters['cap_usd'], equals('2.0000'));
        expect(insert.parameters['attempted_usd'], equals('5.0000'));
        expect(
          insert.parameters['occurred_at'],
          equals(DateTime.utc(2026, 4, 26, 12).toIso8601String()),
        );
      },
    );

    test(
      'AI Metrics: a cap-event insert failure does NOT change the refusal '
      '(still refuses, no throw escapes the hot path)',
      () async {
        // Pool whose cap-event INSERT throws. The cap-check path uses the
        // standard fake responses (delegated), so the refusal is decided
        // exactly as in the happy case; only the observability write fails.
        final pool = _CapEventFailingPool();
        final store = PostgresProxyAccountingStore(
          wrapper: TenantTransactionWrapper(pool),
        );
        final operator = defaultUuidOperatorContext();

        final start = await store.startRequest(
          idempotencyKey: 'idem-cap-refusal-fail',
          requestType: 'advisor_smoke',
          operator: operator,
          usageClass: 'advisor_qa',
          telemetry: const ProxyUsageTelemetry(
            queryClass: 'methodology_lookup',
            cacheHit: false,
            llmTier: 'haiku',
            modelUsed: 'claude-haiku-4-5',
          ),
          estimate: const ProxyUsageChargeEstimate(
            tokenCount: 123,
            costCents: 500,
          ),
          now: DateTime.utc(2026, 4, 26, 12),
        );

        // The refusal is unchanged despite the logging-write failure: the
        // call returns ProxyAccountingRefused and does NOT throw.
        expect(start, isA<ProxyAccountingRefused>());
        final refused = start as ProxyAccountingRefused;
        expect(refused.capStatus.perInvocationExceeded, isTrue);

        // The cap-event transaction was attempted (and rolled back by the
        // wrapper when the INSERT threw), but the failure was swallowed.
        expect(pool.capEventInsertAttempted, isTrue);
        expect(pool.transactions.last.rolledBack, isTrue);
      },
    );
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

}

/// Pool whose `usage_cap_events` INSERT throws, used to prove the
/// cap-event recorder is non-blocking: a logging-write failure must not
/// change the refusal or escape the hot path. The cap-check path delegates
/// to the same fake responses [AccountingPostgresTransaction] uses, so the
/// refusal is decided exactly as in the happy case.
class _CapEventFailingPool implements PostgresPool {
  final transactions = <_CapEventFailingTransaction>[];
  var capEventInsertAttempted = false;

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _CapEventFailingTransaction(this);
    transactions.add(tx);
    return tx;
  }
}

class _CapEventFailingTransaction implements PostgresTransaction {
  _CapEventFailingTransaction(this._pool);

  final _CapEventFailingPool _pool;
  final _delegate = AccountingPostgresTransaction();
  var committed = false;
  var rolledBack = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) {
    // Reuse the standard fake's cap-status / replay / reservation
    // responses so the refusal decision is identical to the happy path.
    return _delegate.query(sql, parameters: parameters);
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (sql.contains('insert into public.usage_cap_events')) {
      _pool.capEventInsertAttempted = true;
      // Mirror a Postgres write failure on the observability INSERT.
      throw StateError('simulated usage_cap_events insert failure');
    }
    // SET LOCAL config statements and any other writes pass through.
    return _delegate.execute(sql, parameters: parameters);
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
