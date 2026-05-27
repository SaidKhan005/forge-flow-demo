// Forge & Flow advisor proxy — A4.2b route tests.
//
// Advisor Knowledge Activation — Slice A4.2b: POST /v1/advisor/answer.
//
// FAKES-ONLY end-to-end tests for the ACTIVATING agentic answer route.
// A loopback HttpServer drives the real `routeRequest` dispatch (mirroring
// `advisor_retrieve_a2b_text_query_test.dart`); a scripted
// `AnthropicToolUseCompleteFn` stands in for the Anthropic round-trip
// (returns a tool_use turn then a final text turn, mirroring
// `advisor_agentic_answer_part_test.dart`); the three operational repos and
// the encrypted conversation-log repo are the REAL classes backed by a fake
// `PostgresPool` (the same recorder shape as
// `advisor_operational_tools_part_test.dart`), so the load-bearing HP #4
// guarantee — every tenant SET LOCAL carries the CALLER's operator_id — is
// proven at the DB-session layer rather than trusted from a stub. The CMK
// resolver is a fake returning a FIXED 32-byte TEST key (never a real key).
//
// No live Anthropic / Voyage / Postgres — all fakes.
//
// Proves (against the handler's ACTUAL contract, read from
// `advisor_answer_route_group_part.dart`):
//   (a) happy path → 200 with answer + citations + conversation_id +
//       usage_class 'advisor_answer';
//   (b) TWO recordTurn writes (user + assistant) with correct turn_index
//       (from prior_turns length) + role + NON-EMPTY encrypted fields;
//   (c) FAIL-CLOSED: CMK resolver null → 503, NO provider call, no answer;
//       and conversation-log repo null → 503 likewise;
//   (d) cap-refusal: an exhausted usage guard refuses 402 before the
//       provider call;
//   (e) metering: commitUsageLog under usage_class 'advisor_answer'
//       attributed to the caller's operator/location, cost derived from the
//       provider-returned tokens;
//   (f) HP #4: recordTurn + tool reads scope to the caller's
//       OperatorContext (from the JWT), NEVER a body-supplied operator_id;
//   (g) missing/empty question → 400 invalid_question, no provider call.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/services/advisor_provider_constants.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/advisor_conversation_log_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/shift_records_read_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/target_cycle_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/weekly_plan_snapshot_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';
import '../../tool/advisor_proxy/anthropic_tool_use_complete_fn.dart';
import '../advisor_proxy_test_helpers.dart';

// ── Caller identity (the verified JWT scope) ─────────────────────────────────
// UUID-shaped so the values flow cleanly into the uuid-typed conversation-log
// columns the real repository binds.
const String _callerUserId = '11111111-1111-4111-8111-111111111111';
const String _callerOperatorId = '22222222-2222-4222-8222-222222222222';
const String _callerLocationId = '33333333-3333-4333-8333-333333333333';

// A foreign / hallucinated operator id a malicious body might try to smuggle
// in. It must NEVER reach SET LOCAL or a conversation-log write (HP #4).
const String _foreignOperatorId = '99999999-9999-4999-8999-999999999999';

const String _restaurantId = 'demo_restaurant_001';

ProxyJwtClaims _callerClaims({
  List<String> roles = const <String>['advisor.read'],
}) => ProxyJwtClaims(
  userId: _callerUserId,
  operatorId: _callerOperatorId,
  locationId: _callerLocationId,
  roles: roles,
);

// ── Scripted Anthropic tool-use gateway ──────────────────────────────────────

/// Terminal (final-text) turn.
AnthropicToolUseTurn _textTurn(
  String text, {
  int inputTokens = 0,
  int outputTokens = 0,
}) {
  return AnthropicToolUseTurn(
    stopReason: 'end_turn',
    finalText: text,
    toolUseRequests: const <AnthropicToolUseRequest>[],
    assistantContentBlocks: <Object?>[
      <String, Object?>{'type': 'text', 'text': text},
    ],
    inputTokens: inputTokens,
    outputTokens: outputTokens,
  );
}

/// `tool_use` turn requesting one tool call.
AnthropicToolUseTurn _toolUseTurn({
  required String toolUseId,
  required String toolName,
  Map<String, Object?> input = const <String, Object?>{},
  int inputTokens = 0,
  int outputTokens = 0,
}) {
  final block = <String, Object?>{
    'type': 'tool_use',
    'id': toolUseId,
    'name': toolName,
    'input': input,
  };
  return AnthropicToolUseTurn(
    stopReason: 'tool_use',
    finalText: '',
    toolUseRequests: <AnthropicToolUseRequest>[
      AnthropicToolUseRequest(id: toolUseId, name: toolName, input: input),
    ],
    assistantContentBlocks: <Object?>[block],
    inputTokens: inputTokens,
    outputTokens: outputTokens,
  );
}

/// A scripted gateway: returns the next turn from [script] on each call and
/// records the messages it was handed so a test can assert the caller's
/// scope never leaked into the model prompt.
class _ScriptedGateway {
  _ScriptedGateway(this.script);

  final List<AnthropicToolUseTurn> script;
  int callCount = 0;
  final List<String> modelIds = <String>[];
  final List<List<Map<String, Object?>>> messagesPerCall =
      <List<Map<String, Object?>>>[];

  AnthropicToolUseCompleteFn get fn =>
      ({
        required String modelId,
        String? system,
        required List<Map<String, Object?>> messages,
        required List<AnthropicToolDefinition> tools,
        Map<String, Object?>? toolChoice,
      }) async {
        modelIds.add(modelId);
        messagesPerCall.add(
          List<Map<String, Object?>>.from(
            messages.map((m) => Map<String, Object?>.from(m)),
          ),
        );
        final turn = script[callCount];
        callCount++;
        return turn;
      };
}

// ── Fake CMK resolver (FIXED 32-byte TEST key, never a real key) ─────────────

/// Returns a deterministic 32-byte (AES-256) TEST key. The bytes are a fixed
/// pattern so the value object is reproducible; this is test material only and
/// MUST NEVER be a production key. Records how many times it resolved so a
/// fail-closed test can assert the resolver was never even consulted.
class _FakeCmkResolver implements AdvisorConversationCmkResolver {
  static const String keyRef = 'kv://forge-flow/cmk/test';
  int resolveCalls = 0;

  @override
  ({List<int> keyBytes, String keyRef}) resolve() {
    resolveCalls++;
    return (
      keyBytes: List<int>.generate(32, (i) => (i * 7 + 3) & 0xff),
      keyRef: keyRef,
    );
  }
}

/// A CMK resolver that returns a WRONG-length key (misprovisioned). Drives the
/// `AdvisorConversationKeyLengthError` fail-closed path.
class _ShortKeyCmkResolver implements AdvisorConversationCmkResolver {
  @override
  ({List<int> keyBytes, String keyRef}) resolve() => (
    keyBytes: List<int>.filled(16, 1), // 128-bit, not 256-bit → too short
    keyRef: 'kv://forge-flow/cmk/test-short',
  );
}

class _FixedAdvisorAnswerPlanResolver implements AdvisorAnswerPlanResolver {
  const _FixedAdvisorAnswerPlanResolver(this.plan);

  final AdvisorAnswerPlan plan;

  @override
  Future<AdvisorAnswerPlan> resolve(OperatorContext operator) async => plan;
}

// ── Fake Postgres pool (drives the REAL repos) ───────────────────────────────

class _SqlCall {
  const _SqlCall(this.sql, this.parameters);
  final String sql;
  final PostgresParameters parameters;
}

/// Fake pool that records every transaction's SQL. Reads return canned rows
/// matched by table substring (same shape as
/// `advisor_operational_tools_part_test.dart`); the advisor-conversation-log
/// INSERT returns a synthetic uuid `id` so the real `recordTurn` does not
/// throw "insert returned no rows".
class _FakePool implements PostgresPool {
  _FakePool({this.targetCycleRows = const <PostgresRow>[]});

  final List<PostgresRow> targetCycleRows;

  /// The single own restaurant the resolver sees (read from
  /// `active_target_profiles`). Fixed: the answer tests only ever exercise the
  /// single-restaurant happy path, so scope resolution is unambiguous.
  static const List<PostgresRow> restaurantIdRows = <PostgresRow>[
    <String, Object?>{'restaurant_id': _restaurantId},
  ];

  final List<_FakeTransaction> transactions = <_FakeTransaction>[];

  /// Every `insert into advisor_conversation_log` call recorded across all
  /// transactions, in order. The captured parameters carry exactly what the
  /// handler bound — the scope (HP #4) + the encrypted fields.
  List<_SqlCall> get conversationLogInserts => <_SqlCall>[
    for (final tx in transactions)
      for (final c in tx.queryCalls)
        if (c.sql.contains('insert into advisor_conversation_log')) c,
  ];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _FakeTransaction(
      targetCycleRows: targetCycleRows,
      restaurantIdRows: restaurantIdRows,
    );
    transactions.add(tx);
    return tx;
  }
}

class _FakeTransaction implements PostgresTransaction {
  _FakeTransaction({
    required this.targetCycleRows,
    required this.restaurantIdRows,
  });

  final List<PostgresRow> targetCycleRows;
  final List<PostgresRow> restaurantIdRows;
  final List<_SqlCall> queryCalls = <_SqlCall>[];
  final List<_SqlCall> executeCalls = <_SqlCall>[];

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    queryCalls.add(_SqlCall(sql, parameters));
    // The encrypted conversation-log write returns the freshly minted uuid id.
    if (sql.contains('insert into advisor_conversation_log')) {
      return const <PostgresRow>[
        <String, Object?>{'id': '44444444-4444-4444-8444-444444444444'},
      ];
    }
    if (sql.contains('from public.active_target_profiles')) {
      return restaurantIdRows;
    }
    if (sql.contains('from public.target_cycles')) return targetCycleRows;
    if (sql.contains('from public.target_cycle_dayparts')) {
      return const <PostgresRow>[];
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    executeCalls.add(_SqlCall(sql, parameters));
    return 1;
  }

  @override
  Future<void> commit() async {}

  @override
  Future<void> rollback() async {}
}

// ── Recording accounting store (captures every commitUsageLog) ───────────────

class _CommitCall {
  const _CommitCall({
    required this.operatorId,
    required this.locationId,
    required this.usageClass,
    required this.tokenCount,
    required this.costCents,
    required this.modelUsed,
  });

  final String operatorId;
  final String locationId;
  final String usageClass;
  final int tokenCount;
  final int costCents;
  final String modelUsed;
}

/// Records EVERY `commitUsageLog` call so the metering test can find the
/// `advisor_answer` commit and assert its attribution + token-derived cost.
/// The other store methods are minimal no-ops — the answer route meters via
/// `commitUsageLog` only.
class _RecordingAccountingStore implements ProxyAccountingStore {
  _RecordingAccountingStore({
    this.startResult = const ProxyAccountingReserved(
      capStatus: ProxyCapStatus(
        usageClass: 'unused',
        monthlyCapCents: 0,
        monthlyUsedCents: 0,
        perInvocationCapCents: 0,
        estimatedCostCents: 0,
      ),
    ),
  });

  final ProxyAccountingStartResult startResult;
  int startCalls = 0;
  int completeCalls = 0;
  final List<_CommitCall> commits = <_CommitCall>[];

  @override
  Future<void> commitUsageLog({
    required OperatorContext operator,
    required String usageClass,
    required ProxyUsageTelemetry telemetry,
    required ProxyUsageChargeEstimate estimate,
    required DateTime now,
  }) async {
    commits.add(
      _CommitCall(
        operatorId: operator.operatorId,
        locationId: operator.locationId,
        usageClass: usageClass,
        tokenCount: estimate.tokenCount,
        costCents: estimate.costCents,
        modelUsed: telemetry.modelUsed,
      ),
    );
  }

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
    return startResult;
  }

  @override
  Future<void> completeRequest({
    required OperatorContext operator,
    required String idempotencyKey,
    required Map<String, Object?> responsePayload,
    required DateTime now,
    ProxyRequestStats? stats,
  }) async {
    completeCalls += 1;
  }

  @override
  Future<void> recordRequestStats({
    required OperatorContext operator,
    required ProxyRequestStats stats,
  }) async {}
}

// ── Usage-guard builders ─────────────────────────────────────────────────────

/// An OPEN guard: zero usage, launch tier. Allows the request.
ProxyUsageGuard _openGuard() => ProxyUsageGuard(
  store: FixedSnapshotProxyUsageStore(
    snapshot: UsageSnapshot(
      requestsThisMinute: 0,
      costCentsThisMonth: 0,
      minuteBucketStart: DateTime.utc(2026, 5, 24, 12, 0),
      monthBucketStart: DateTime.utc(2026, 5, 1),
    ),
  ),
  tierResolver: const FixedLaunchTierResolver(),
);

/// An EXHAUSTED guard: the monthly cost cap is already reached, so
/// `requireAllowed` raises `UsageRefusal` (402 monthly_cap_reached).
ProxyUsageGuard _exhaustedGuard() => ProxyUsageGuard(
  store: FixedSnapshotProxyUsageStore(
    snapshot: UsageSnapshot(
      requestsThisMinute: 0,
      costCentsThisMonth: PolicyTier.launch.maxMonthlyCostCents,
      minuteBucketStart: DateTime.utc(2026, 5, 24, 12, 0),
      monthBucketStart: DateTime.utc(2026, 5, 1),
    ),
  ),
  tierResolver: const FixedLaunchTierResolver(),
);

// ── Fixed fact rows (caller-owned) ───────────────────────────────────────────

PostgresRow _cycleRow() => <String, Object?>{
  'cycle_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'operator_id': _callerOperatorId,
  'location_id': _callerLocationId,
  'restaurant_id': _restaurantId,
  'source': 'recommended',
  'effective_start': '2026-05-01',
  'effective_end': '2026-06-30',
  'calibration_window_start': '2026-04-01',
  'calibration_window_end': '2026-04-30',
  'target_cplh': 8.0,
  'target_splh': 120.0,
  'target_ppa': 24.0,
  'foh_wage': 18.0,
  'boh_wage': 20.0,
  'opz_floor_cplh': 7.0,
  'opz_ceiling_cplh': 9.5,
  'manager_override_used': false,
  'manager_override_at': null,
  'manager_override_by_user_id': null,
  'admin_replaced_at': null,
  'admin_replaced_by_user_id': null,
  'supersedes_cycle_id': null,
  'selected_shift_count': 12,
  'selected_record_keys': '[]',
  'selection_decision_ids': '[]',
  'replacement_reason': null,
  'idempotency_key': 'idem-cycle-1',
  'request_hash': 'hash-1',
  'created_by': _callerUserId,
  'created_at': '2026-05-01T00:00:00.000Z',
  'updated_at': '2026-05-01T00:00:00.000Z',
  'deactivated_at': null,
};

// ── Server harness ───────────────────────────────────────────────────────────

void main() {
  // The proxy makes real localhost socket connections; disable Flutter's
  // HttpOverrides for the duration (mirrors the retrieve harness).
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
  late Uri baseUri;
  late SettableVerifier verifier;

  Future<void> spinUp({
    AnthropicToolUseCompleteFn? completeFn,
    AdvisorConversationCmkResolver? cmkResolver,
    AdvisorConversationLogRepository? conversationLogRepository,
    TargetCycleRepository? targetCycleRepository,
    WeeklyPlanSnapshotRepository? weeklyPlanSnapshotRepository,
    ShiftRecordsReadRepository? shiftRecordsReadRepository,
    AdvisorAnswerPlanResolver? planResolver,
    ProxyUsageGuard? usageGuard,
    ProxyAccountingStore? accountingStore,
    ProxyJwtClaims? claims,
  }) async {
    verifier = SettableVerifier();
    verifier.claims = claims ?? _callerClaims();
    final guard = ProxyRequestGuard(verifier: verifier);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        await routeRequest(
          request,
          guard,
          anthropicToolUseCompleteFnForAnswer: completeFn,
          advisorConversationCmkResolver: cmkResolver,
          advisorConversationLogRepository: conversationLogRepository,
          advisorAnswerTargetCycleRepository: targetCycleRepository,
          advisorAnswerWeeklyPlanSnapshotRepository:
              weeklyPlanSnapshotRepository,
          advisorAnswerShiftRecordsReadRepository: shiftRecordsReadRepository,
          advisorAnswerPlanResolver: planResolver,
          usageGuard: usageGuard,
          accountingStore: accountingStore,
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

  /// Builds the three real operational repos + the real conversation-log repo
  /// against [pool] via a single shared [TenantTransactionWrapper].
  ({
    TargetCycleRepository targets,
    WeeklyPlanSnapshotRepository weekPlan,
    ShiftRecordsReadRepository shifts,
    AdvisorConversationLogRepository log,
  })
  buildRepos(_FakePool pool) {
    final wrapper = TenantTransactionWrapper(pool);
    return (
      targets: TargetCycleRepository(wrapper),
      weekPlan: WeeklyPlanSnapshotRepository(wrapper),
      shifts: ShiftRecordsReadRepository(wrapper),
      log: AdvisorConversationLogRepository(wrapper),
    );
  }

  // A standard two-turn script: the model calls one operational tool, then
  // synthesizes a recommendation-only final answer.
  _ScriptedGateway twoTurnScript({
    int finalInputTokens = 1000000,
    int finalOutputTokens = 1000000,
  }) => _ScriptedGateway(<AnthropicToolUseTurn>[
    _toolUseTurn(
      toolUseId: 'toolu_1',
      toolName: advisorToolGetActiveTargets,
      input: const <String, Object?>{},
    ),
    _textTurn(
      'You could consider trimming the early prep shift; one option is '
      'shifting an hour to mid-day.',
      inputTokens: finalInputTokens,
      outputTokens: finalOutputTokens,
    ),
  ]);

  group('POST /v1/advisor/answer (A4.2b — happy path)', () {
    test('(a) returns 200 with answer + citations + conversation_id + '
        "usage_class 'advisor_answer'", () async {
      await withRealHttp(() async {
        final pool = _FakePool(targetCycleRows: <PostgresRow>[_cycleRow()]);
        final repos = buildRepos(pool);
        final gateway = twoTurnScript();
        await spinUp(
          completeFn: gateway.fn,
          cmkResolver: _FakeCmkResolver(),
          conversationLogRepository: repos.log,
          targetCycleRepository: repos.targets,
          weeklyPlanSnapshotRepository: repos.weekPlan,
          shiftRecordsReadRepository: repos.shifts,
        );
        try {
          final response = await httpPost(
            client,
            baseUri.resolve(advisorAnswerPath),
            authorization: 'Bearer token',
            body: <String, Object?>{'question': 'Why is my CPLH high?'},
          );
          expect(response.statusCode, equals(200));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;

          // Answer is the synthesized recommendation text (HP #6 framing).
          expect(decoded['answer'], contains('You could consider'));

          // Citations are the engine's real tool-sourced citations (the
          // active-target cycle is a citable operator fact).
          final citations = decoded['citations'] as List<Object?>;
          expect(citations, isNotEmpty);
          final firstCitation = citations.first as Map<String, Object?>;
          expect(
            (firstCitation['source_id'] as String),
            startsWith('target_cycle:'),
          );

          // conversation_id is minted (a non-empty v4 uuid string).
          final conversationId = decoded['conversation_id'] as String;
          expect(conversationId, isNotEmpty);
          expect(isValidUuidV4(conversationId), isTrue);

          // usage_class is the distinct advisor_answer class.
          expect(decoded['usage_class'], equals('advisor_answer'));
          expect(decoded['usage_class'], equals(kAdvisorAnswerUsageClass));

          // The engine ran the requested tool, then synthesized.
          expect(gateway.callCount, equals(2));
          expect(decoded['tool_calls'], equals(<String>['get_active_targets']));
          // assistant turn index = priorTurns.length (0) + 1 = 1.
          expect(decoded['turn_index'], equals(1));
          // HP #4: the response echoes the CALLER's scope.
          expect(decoded['operator_id'], equals(_callerOperatorId));
          expect(decoded['location_id'], equals(_callerLocationId));
        } finally {
          await shutDown();
        }
      });
    });

    test('(b) persists TWO encrypted turns (user + assistant) with correct '
        'turn_index, role, and NON-EMPTY encrypted fields', () async {
      await withRealHttp(() async {
        final pool = _FakePool(targetCycleRows: <PostgresRow>[_cycleRow()]);
        final repos = buildRepos(pool);
        final gateway = twoTurnScript();
        await spinUp(
          completeFn: gateway.fn,
          cmkResolver: _FakeCmkResolver(),
          conversationLogRepository: repos.log,
          targetCycleRepository: repos.targets,
          weeklyPlanSnapshotRepository: repos.weekPlan,
          shiftRecordsReadRepository: repos.shifts,
        );
        try {
          // One prior turn → user turn lands at index 1, assistant at 2.
          final response = await httpPost(
            client,
            baseUri.resolve(advisorAnswerPath),
            authorization: 'Bearer token',
            body: <String, Object?>{
              'question': 'And this week?',
              'prior_turns': <Map<String, Object?>>[
                <String, Object?>{
                  'role': 'user',
                  'content': 'How was last week?',
                },
              ],
            },
          );
          expect(response.statusCode, equals(200));

          final inserts = pool.conversationLogInserts;
          expect(inserts, hasLength(2), reason: 'exactly user + assistant');

          // First insert = the user turn at index 1 (priorTurns.length).
          final userParams = inserts[0].parameters;
          expect(userParams['role'], equals('user'));
          expect(userParams['turn_index'], equals(1));

          // Second insert = the assistant turn at index 2.
          final assistantParams = inserts[1].parameters;
          expect(assistantParams['role'], equals('assistant'));
          expect(assistantParams['turn_index'], equals(2));

          // Both turns carry NON-EMPTY encrypted fields (real AEAD output the
          // route produced; the DB never sees plaintext).
          for (final params in <PostgresParameters>[
            userParams,
            assistantParams,
          ]) {
            expect(
              (params['content_encrypted'] as List).isNotEmpty,
              isTrue,
              reason: 'content_encrypted must be non-empty ciphertext',
            );
            expect(
              (params['content_iv'] as List).isNotEmpty,
              isTrue,
              reason: 'content_iv must be a non-empty nonce',
            );
            expect(
              (params['content_key_ref'] as String).isNotEmpty,
              isTrue,
              reason: 'content_key_ref must name the CMK',
            );
            expect(
              (params['content_hash'] as String).isNotEmpty,
              isTrue,
              reason: 'content_hash must be the SHA-256 digest',
            );
            // The encrypted columns must NOT carry plaintext.
            expect(params['content_key_ref'], isNot(contains('How was last')));
            // surface + usage_class are the advisor_answer values.
            expect(params['surface'], equals('advisor_answer'));
            expect(params['usage_class'], equals('advisor_answer'));
          }

          // The assistant turn carries the provider/model/token provenance.
          expect(assistantParams['provider'], equals('anthropic'));
          expect(assistantParams['model_id'], isNotNull);
          expect(assistantParams['completion_token_count'], equals(1000000));
        } finally {
          await shutDown();
        }
      });
    });
  });

  group('POST /v1/advisor/answer (server-side preflight)', () {
    test('rejects a caller without advisor.read before encryption/provider '
        'work', () async {
      await withRealHttp(() async {
        final pool = _FakePool();
        final repos = buildRepos(pool);
        final gateway = _ScriptedGateway(<AnthropicToolUseTurn>[
          _textTurn('You could review the prep schedule.'),
        ]);
        final cmkResolver = _FakeCmkResolver();
        await spinUp(
          completeFn: gateway.fn,
          cmkResolver: cmkResolver,
          conversationLogRepository: repos.log,
          claims: _callerClaims(roles: const <String>[]),
        );
        try {
          final response = await httpPost(
            client,
            baseUri.resolve(advisorAnswerPath),
            authorization: 'Bearer token',
            body: <String, Object?>{'question': 'Why is my CPLH high?'},
          );
          expect(response.statusCode, equals(403));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect(decoded['error'], equals('permission_denied'));
          expect(decoded['permission_key'], equals('advisor.read'));
          expect(gateway.callCount, equals(0));
          expect(cmkResolver.resolveCalls, equals(0));
          expect(pool.conversationLogInserts, isEmpty);
        } finally {
          await shutDown();
        }
      });
    });

    test('ignores forged subscription_tier/query_class when routing the '
        'answer model', () async {
      await withRealHttp(() async {
        final pool = _FakePool();
        final repos = buildRepos(pool);
        final gateway = _ScriptedGateway(<AnthropicToolUseTurn>[
          _textTurn('You could review the prep schedule.'),
          _textTurn('You could compare the last two shifts.'),
        ]);
        await spinUp(
          completeFn: gateway.fn,
          cmkResolver: _FakeCmkResolver(),
          conversationLogRepository: repos.log,
          planResolver: const _FixedAdvisorAnswerPlanResolver(
            AdvisorAnswerPlan(
              subscriptionTier: 'premium',
              queryClass: 'recommendation',
              advisorEnabled: true,
            ),
          ),
        );
        try {
          final expectedModel = const ProxyLlmModelRouting().modelIdFor(
            ProxyLlmTier.sonnet,
          );

          final upgradeAttempt = await httpPost(
            client,
            baseUri.resolve(advisorAnswerPath),
            authorization: 'Bearer token',
            body: <String, Object?>{
              'question': 'Give me a nuanced recommendation.',
              'subscription_tier': 'enterprise',
              'query_class': 'recommendation',
            },
          );
          final downgradeAttempt = await httpPost(
            client,
            baseUri.resolve(advisorAnswerPath),
            authorization: 'Bearer token',
            body: <String, Object?>{
              'question': 'Keep it cheap.',
              'subscription_tier': 'starter',
              'query_class': 'methodology_lookup',
            },
          );

          expect(upgradeAttempt.statusCode, equals(200));
          expect(downgradeAttempt.statusCode, equals(200));
          expect(
            gateway.modelIds,
            equals(<String>[expectedModel, expectedModel]),
          );

          final decodedUpgrade =
              jsonDecode(upgradeAttempt.body) as Map<String, Object?>;
          final decodedDowngrade =
              jsonDecode(downgradeAttempt.body) as Map<String, Object?>;
          expect(decodedUpgrade['model_used'], equals(expectedModel));
          expect(decodedDowngrade['model_used'], equals(expectedModel));
          expect(decodedUpgrade['query_class'], equals('recommendation'));
          expect(decodedDowngrade['query_class'], equals('recommendation'));

          for (final insert in pool.conversationLogInserts) {
            expect(insert.parameters['query_class'], equals('recommendation'));
          }
        } finally {
          await shutDown();
        }
      });
    });

    test(
      'rejects when the server-side advisor entitlement is disabled',
      () async {
        await withRealHttp(() async {
          final pool = _FakePool();
          final repos = buildRepos(pool);
          final gateway = _ScriptedGateway(<AnthropicToolUseTurn>[
            _textTurn('You could review the prep schedule.'),
          ]);
          final cmkResolver = _FakeCmkResolver();
          await spinUp(
            completeFn: gateway.fn,
            cmkResolver: cmkResolver,
            conversationLogRepository: repos.log,
            planResolver: const _FixedAdvisorAnswerPlanResolver(
              AdvisorAnswerPlan(
                subscriptionTier: 'starter',
                queryClass: 'methodology_lookup',
                advisorEnabled: false,
              ),
            ),
          );
          try {
            final response = await httpPost(
              client,
              baseUri.resolve(advisorAnswerPath),
              authorization: 'Bearer token',
              body: <String, Object?>{'question': 'Why is my CPLH high?'},
            );
            expect(response.statusCode, equals(403));
            final decoded = jsonDecode(response.body) as Map<String, Object?>;
            expect(decoded['error'], equals('advisor_not_enabled'));
            expect(decoded['feature_slug'], equals(kAdvisorAnswerFeatureSlug));
            expect(gateway.callCount, equals(0));
            expect(cmkResolver.resolveCalls, equals(0));
            expect(pool.conversationLogInserts, isEmpty);
          } finally {
            await shutDown();
          }
        });
      },
    );
  });

  group('POST /v1/advisor/answer (A4.2b — fail-closed encryption-first)', () {
    test('(c) CMK resolver null → 503 advisor_answer_encryption_unavailable, '
        'NO provider call, no answer', () async {
      await withRealHttp(() async {
        final pool = _FakePool(targetCycleRows: <PostgresRow>[_cycleRow()]);
        final repos = buildRepos(pool);
        final gateway = twoTurnScript();
        await spinUp(
          completeFn: gateway.fn,
          // No CMK resolver wired → fail closed.
          cmkResolver: null,
          conversationLogRepository: repos.log,
          targetCycleRepository: repos.targets,
          weeklyPlanSnapshotRepository: repos.weekPlan,
          shiftRecordsReadRepository: repos.shifts,
        );
        try {
          final response = await httpPost(
            client,
            baseUri.resolve(advisorAnswerPath),
            authorization: 'Bearer token',
            body: <String, Object?>{'question': 'Why is my CPLH high?'},
          );
          expect(response.statusCode, equals(503));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect(
            decoded['error'],
            equals('advisor_answer_encryption_unavailable'),
          );
          // The provider was NEVER called (encryption checked first).
          expect(gateway.callCount, equals(0));
          // No answer field leaked.
          expect(decoded.containsKey('answer'), isFalse);
          // Nothing was persisted.
          expect(pool.conversationLogInserts, isEmpty);
        } finally {
          await shutDown();
        }
      });
    });

    test('conversation-log repo null → 503, NO provider call', () async {
      await withRealHttp(() async {
        final gateway = twoTurnScript();
        await spinUp(
          completeFn: gateway.fn,
          cmkResolver: _FakeCmkResolver(),
          // No conversation-log sink wired → fail closed.
          conversationLogRepository: null,
        );
        try {
          final response = await httpPost(
            client,
            baseUri.resolve(advisorAnswerPath),
            authorization: 'Bearer token',
            body: <String, Object?>{'question': 'Why is my CPLH high?'},
          );
          expect(response.statusCode, equals(503));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect(
            decoded['error'],
            equals('advisor_answer_encryption_unavailable'),
          );
          expect(gateway.callCount, equals(0));
        } finally {
          await shutDown();
        }
      });
    });

    test('provider seam null (CMK present) → 503 '
        'advisor_answer_not_configured', () async {
      await withRealHttp(() async {
        final pool = _FakePool();
        final repos = buildRepos(pool);
        await spinUp(
          // No completeFn wired, but encryption IS configured.
          completeFn: null,
          cmkResolver: _FakeCmkResolver(),
          conversationLogRepository: repos.log,
        );
        try {
          final response = await httpPost(
            client,
            baseUri.resolve(advisorAnswerPath),
            authorization: 'Bearer token',
            body: <String, Object?>{'question': 'Why is my CPLH high?'},
          );
          expect(response.statusCode, equals(503));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect(decoded['error'], equals('advisor_answer_not_configured'));
          // Nothing persisted (no answer produced).
          expect(pool.conversationLogInserts, isEmpty);
        } finally {
          await shutDown();
        }
      });
    });

    test('misprovisioned CMK (wrong length) → 503 encryption_unavailable, '
        'no answer leaked', () async {
      await withRealHttp(() async {
        final pool = _FakePool(targetCycleRows: <PostgresRow>[_cycleRow()]);
        final repos = buildRepos(pool);
        // Only a terminal turn so the engine still produces an answer; the
        // failure must occur at the encrypt step, not before.
        final gateway = _ScriptedGateway(<AnthropicToolUseTurn>[
          _textTurn('You could review the prep schedule.'),
        ]);
        await spinUp(
          completeFn: gateway.fn,
          cmkResolver: _ShortKeyCmkResolver(),
          conversationLogRepository: repos.log,
          targetCycleRepository: repos.targets,
          weeklyPlanSnapshotRepository: repos.weekPlan,
          shiftRecordsReadRepository: repos.shifts,
        );
        try {
          final response = await httpPost(
            client,
            baseUri.resolve(advisorAnswerPath),
            authorization: 'Bearer token',
            body: <String, Object?>{'question': 'Why is my CPLH high?'},
          );
          expect(response.statusCode, equals(503));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect(
            decoded['error'],
            equals('advisor_answer_encryption_unavailable'),
          );
          // Encryption-first: no answer is returned without a persisted
          // encrypted record, and nothing was persisted.
          expect(decoded.containsKey('answer'), isFalse);
          expect(pool.conversationLogInserts, isEmpty);
          // The misprovisioned key length must NOT leak into the response.
          expect(response.body, isNot(contains('16')));
        } finally {
          await shutDown();
        }
      });
    });
  });

  group('POST /v1/advisor/answer (A4.2b — cap refusal + metering)', () {
    test(
      '(d) an exhausted usage guard refuses 402 before the provider call',
      () async {
        await withRealHttp(() async {
          final pool = _FakePool(targetCycleRows: <PostgresRow>[_cycleRow()]);
          final repos = buildRepos(pool);
          final gateway = twoTurnScript();
          final accounting = _RecordingAccountingStore();
          await spinUp(
            completeFn: gateway.fn,
            cmkResolver: _FakeCmkResolver(),
            conversationLogRepository: repos.log,
            targetCycleRepository: repos.targets,
            weeklyPlanSnapshotRepository: repos.weekPlan,
            shiftRecordsReadRepository: repos.shifts,
            usageGuard: _exhaustedGuard(),
            accountingStore: accounting,
          );
          try {
            final response = await httpPost(
              client,
              baseUri.resolve(advisorAnswerPath),
              authorization: 'Bearer token',
              body: <String, Object?>{'question': 'expensive question'},
            );
            expect(response.statusCode, equals(402));
            final decoded = jsonDecode(response.body) as Map<String, Object?>;
            expect(decoded['error'], equals('monthly_cap_reached'));
            // Refused BEFORE the provider call → no answer, no persistence,
            // no metered cost.
            expect(gateway.callCount, equals(0));
            expect(pool.conversationLogInserts, isEmpty);
            expect(accounting.commits, isEmpty);
          } finally {
            await shutDown();
          }
        });
      },
    );

    test(
      'accounting cap refusal returns 402 before the provider call',
      () async {
        await withRealHttp(() async {
          final pool = _FakePool(targetCycleRows: <PostgresRow>[_cycleRow()]);
          final repos = buildRepos(pool);
          final gateway = twoTurnScript();
          final cmkResolver = _FakeCmkResolver();
          final accounting = _RecordingAccountingStore(
            startResult: const ProxyAccountingRefused(
              capStatus: ProxyCapStatus(
                usageClass: kAdvisorAnswerUsageClass,
                monthlyCapCents: 100,
                monthlyUsedCents: 95,
                perInvocationCapCents: 50,
                estimatedCostCents: 75,
              ),
            ),
          );
          await spinUp(
            completeFn: gateway.fn,
            cmkResolver: cmkResolver,
            conversationLogRepository: repos.log,
            targetCycleRepository: repos.targets,
            weeklyPlanSnapshotRepository: repos.weekPlan,
            shiftRecordsReadRepository: repos.shifts,
            usageGuard: _openGuard(),
            accountingStore: accounting,
          );
          try {
            final response = await httpPost(
              client,
              baseUri.resolve(advisorAnswerPath),
              authorization: 'Bearer token',
              body: <String, Object?>{'question': 'expensive question'},
            );
            expect(response.statusCode, equals(402));
            final decoded = jsonDecode(response.body) as Map<String, Object?>;
            expect(decoded['error'], equals('usage_cap_reached'));
            expect(gateway.callCount, equals(0));
            expect(cmkResolver.resolveCalls, equals(0));
            expect(pool.conversationLogInserts, isEmpty);
            expect(accounting.startCalls, equals(1));
            expect(accounting.completeCalls, equals(0));
            expect(accounting.commits, isEmpty);
          } finally {
            await shutDown();
          }
        });
      },
    );

    test(
      '(e) records a commitUsageLog under usage_class advisor_answer '
      'attributed to the caller, cost derived from provider tokens',
      () async {
        await withRealHttp(() async {
          final pool = _FakePool(targetCycleRows: <PostgresRow>[_cycleRow()]);
          final repos = buildRepos(pool);
          // 1,000,000 input + 1,000,000 output tokens on the final turn.
          final gateway = twoTurnScript(
            finalInputTokens: 1000000,
            finalOutputTokens: 1000000,
          );
          final accounting = _RecordingAccountingStore();
          await spinUp(
            completeFn: gateway.fn,
            cmkResolver: _FakeCmkResolver(),
            conversationLogRepository: repos.log,
            targetCycleRepository: repos.targets,
            weeklyPlanSnapshotRepository: repos.weekPlan,
            shiftRecordsReadRepository: repos.shifts,
            usageGuard: _openGuard(),
            accountingStore: accounting,
          );
          try {
            final response = await httpPost(
              client,
              baseUri.resolve(advisorAnswerPath),
              authorization: 'Bearer token',
              body: <String, Object?>{'question': 'Why is my CPLH high?'},
            );
            expect(response.statusCode, equals(200));
            final decoded = jsonDecode(response.body) as Map<String, Object?>;
            final modelUsed = decoded['model_used'] as String;

            // Exactly one commit, under the advisor_answer class, attributed
            // to the CALLER's operator + location (HP #4 / HP #9).
            expect(accounting.commits, hasLength(1));
            final commit = accounting.commits.single;
            expect(commit.usageClass, equals('advisor_answer'));
            expect(commit.usageClass, equals(kAdvisorAnswerUsageClass));
            expect(commit.operatorId, equals(_callerOperatorId));
            expect(commit.locationId, equals(_callerLocationId));
            expect(commit.modelUsed, equals(modelUsed));

            // token_count carries the summed provider totals (input + output).
            expect(commit.tokenCount, equals(2000000));

            // Cost is DERIVED from the provider tokens via the model rate, not
            // a hardcoded constant. Cross-check directly against the registry.
            final rate = LlmCostRateRegistry.rateFor(modelUsed);
            expect(rate, isNotNull, reason: 'routed model must have a rate');
            expect(
              commit.costCents,
              equals(
                rate!.costCentsFor(inputTokens: 1000000, outputTokens: 1000000),
              ),
            );
            // Sanity: the derived cost is non-zero (proves wiring end-to-end).
            expect(commit.costCents, greaterThan(0));
          } finally {
            await shutDown();
          }
        });
      },
    );
  });

  group('POST /v1/advisor/answer (A4.2b — HP #4 isolation)', () {
    test('(f) recordTurn + tool reads scope to the CALLER, never a '
        'body-supplied operator_id', () async {
      await withRealHttp(() async {
        final pool = _FakePool(targetCycleRows: <PostgresRow>[_cycleRow()]);
        final repos = buildRepos(pool);
        final gateway = twoTurnScript();
        await spinUp(
          completeFn: gateway.fn,
          cmkResolver: _FakeCmkResolver(),
          conversationLogRepository: repos.log,
          targetCycleRepository: repos.targets,
          weeklyPlanSnapshotRepository: repos.weekPlan,
          shiftRecordsReadRepository: repos.shifts,
        );
        try {
          // Smuggle a foreign operator_id / location_id into the BODY. They
          // must be ignored — scope stays the verified JWT's.
          final response = await httpPost(
            client,
            baseUri.resolve(advisorAnswerPath),
            authorization: 'Bearer token',
            body: <String, Object?>{
              'question': 'Why is my CPLH high?',
              'operator_id': _foreignOperatorId,
              'location_id': 'ffffffff-ffff-4fff-8fff-ffffffffffff',
            },
          );
          expect(response.statusCode, equals(200));

          // Every SET LOCAL app.operator_id across EVERY transaction (the tool
          // reads AND the two conversation-log writes) is the CALLER's id.
          var sawOperatorSetLocal = false;
          for (final tx in pool.transactions) {
            for (final c in tx.executeCalls) {
              if (c.sql.contains("set_config('app.operator_id'")) {
                expect(c.parameters['value'], equals(_callerOperatorId));
                expect(c.parameters['value'], isNot(_foreignOperatorId));
                sawOperatorSetLocal = true;
              }
            }
          }
          expect(
            sawOperatorSetLocal,
            isTrue,
            reason: 'at least one tenant SET LOCAL must have run',
          );

          // Both conversation-log writes bound the CALLER's operator/location.
          final inserts = pool.conversationLogInserts;
          expect(inserts, hasLength(2));
          for (final insert in inserts) {
            expect(insert.parameters['operator_id'], equals(_callerOperatorId));
            expect(insert.parameters['location_id'], equals(_callerLocationId));
            expect(insert.parameters['user_id'], equals(_callerUserId));
            expect(insert.parameters['operator_id'], isNot(_foreignOperatorId));
          }

          // The response echoes the caller scope, not the body's.
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect(decoded['operator_id'], equals(_callerOperatorId));
          expect(decoded['operator_id'], isNot(_foreignOperatorId));
        } finally {
          await shutDown();
        }
      });
    });
  });

  group('POST /v1/advisor/answer (A4.2b — input validation)', () {
    test(
      '(g) missing question → 400 invalid_question, no provider call',
      () async {
        await withRealHttp(() async {
          final pool = _FakePool();
          final repos = buildRepos(pool);
          final gateway = twoTurnScript();
          await spinUp(
            completeFn: gateway.fn,
            cmkResolver: _FakeCmkResolver(),
            conversationLogRepository: repos.log,
            targetCycleRepository: repos.targets,
            weeklyPlanSnapshotRepository: repos.weekPlan,
            shiftRecordsReadRepository: repos.shifts,
          );
          try {
            final response = await httpPost(
              client,
              baseUri.resolve(advisorAnswerPath),
              authorization: 'Bearer token',
              body: const <String, Object?>{},
            );
            expect(response.statusCode, equals(400));
            final decoded = jsonDecode(response.body) as Map<String, Object?>;
            expect(decoded['error'], equals('invalid_question'));
            expect(gateway.callCount, equals(0));
            expect(pool.conversationLogInserts, isEmpty);
          } finally {
            await shutDown();
          }
        });
      },
    );

    test('empty/whitespace question → 400 invalid_question', () async {
      await withRealHttp(() async {
        final pool = _FakePool();
        final repos = buildRepos(pool);
        final gateway = twoTurnScript();
        await spinUp(
          completeFn: gateway.fn,
          cmkResolver: _FakeCmkResolver(),
          conversationLogRepository: repos.log,
          targetCycleRepository: repos.targets,
          weeklyPlanSnapshotRepository: repos.weekPlan,
          shiftRecordsReadRepository: repos.shifts,
        );
        try {
          final response = await httpPost(
            client,
            baseUri.resolve(advisorAnswerPath),
            authorization: 'Bearer token',
            body: <String, Object?>{'question': '   '},
          );
          expect(response.statusCode, equals(400));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect(decoded['error'], equals('invalid_question'));
          expect(gateway.callCount, equals(0));
        } finally {
          await shutDown();
        }
      });
    });

    test('missing auth → 401 before any provider/encryption work', () async {
      await withRealHttp(() async {
        final pool = _FakePool();
        final repos = buildRepos(pool);
        final gateway = twoTurnScript();
        await spinUp(
          completeFn: gateway.fn,
          cmkResolver: _FakeCmkResolver(),
          conversationLogRepository: repos.log,
          targetCycleRepository: repos.targets,
          weeklyPlanSnapshotRepository: repos.weekPlan,
          shiftRecordsReadRepository: repos.shifts,
        );
        try {
          final response = await httpPost(
            client,
            baseUri.resolve(advisorAnswerPath),
            // No authorization header.
            body: <String, Object?>{'question': 'Why is my CPLH high?'},
          );
          expect(response.statusCode, equals(401));
          // Auth rejected first → no provider call, no persistence.
          expect(gateway.callCount, equals(0));
          expect(pool.conversationLogInserts, isEmpty);
        } finally {
          await shutDown();
        }
      });
    });
  });
}
