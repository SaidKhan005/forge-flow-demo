// Slice C-4 - DemoModeMasterSwitchRouter envelope pinning tests.
//
// A2(b) refactor-preparation work. The refactor phase B3 will extract
// envelope helpers from the hybrid dispatchers (B2.1, B11.2, C-4); B4
// will split `tool/advisor_proxy/advisor_proxy.dart` into 3 bounded
// contexts. Before that, the current envelope shape (route match,
// auth guard, idempotency key handling, error machine codes + human
// `message` copy) MUST be pinned so post-refactor behavior can be
// diffed.
//
// Existing coverage gaps closed here (vs. the real-HTTP integration
// tests in `test/proxy/mobile_operational_sync_demo_and_error_paths_test.dart`):
//
//   1. The static `DemoModeMasterSwitchRouter.match()` matcher: pin
//      method gate (POST only), path-shape gate (`/v1/operators/:op/`
//      `locations/:loc/demo-mode-master-switch`), URL-encoded segment
//      decoding, and the negative shape branches.
//   2. Router-level happy-path response envelope: pin `flipped_count`,
//      the `demo_mode_states` array shape, per-record `is_demo` /
//      `flipped_to_live_at` / `operator_id` / `location_id` fields.
//   3. The full error envelope `{error, message}` for every
//      router-emitted 4xx / 409 path: `live_to_demo_refused`,
//      `invalid_target_mode`, `demo_mode_already_live`. Each is
//      pinned at the ROUTER level (no HTTP), so B3 cannot silently
//      drop the human-readable `message` when envelope construction
//      moves to a shared helper.
//   4. Demo Mode is HP #2 per CLAUDE.md ("kDemoMode is a writer-side
//      switch"). This route is the operator-facing master Demo -> Live
//      transition; envelope drift is HP #2 risk.
//
// Authority:
//   * tool/advisor_proxy/demo_mode_master_switch_routes.dart
//   * docs/contracts/proxy_error_envelope_contract.md (envelope shape)
//   * docs/contracts/demo_mode_contract.md (HP #2 + master switch)
//   * docs/phases/refactor_phase/refactor_phase_plan.md (A2(b))

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/demo_mode_state_repository.dart';
import 'package:forge_and_flow/services/integration/demo_mode_state.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import '../../tool/advisor_proxy/demo_mode_master_switch_routes.dart';

const String _opId = 'op-1';
const String _locId = 'loc-1';
const String _actor = 'user-1';

void main() {
  group('DemoModeMasterSwitchRouter.match (request envelope pin)', () {
    test('matches POST /v1/operators/<op>/locations/<loc>/demo-mode-master-switch',
        () {
      final m = DemoModeMasterSwitchRouter.match(
        '/v1/operators/op-1/locations/loc-1/demo-mode-master-switch',
        'POST',
      );
      expect(m, isNotNull);
      expect(m!.operatorId, equals('op-1'));
      expect(m.locationId, equals('loc-1'));
    });

    test('decodes URL-encoded operator + location segments', () {
      final m = DemoModeMasterSwitchRouter.match(
        '/v1/operators/op%201/locations/loc%2Fslash/demo-mode-master-switch',
        'POST',
      );
      expect(m, isNotNull);
      expect(m!.operatorId, equals('op 1'));
      expect(m.locationId, equals('loc/slash'));
    });

    test('rejects GET on the master-switch path (write-only route)', () {
      final m = DemoModeMasterSwitchRouter.match(
        '/v1/operators/op-1/locations/loc-1/demo-mode-master-switch',
        'GET',
      );
      expect(m, isNull);
    });

    test('rejects PATCH on the master-switch path (POST-only route)', () {
      expect(
        DemoModeMasterSwitchRouter.match(
          '/v1/operators/op-1/locations/loc-1/demo-mode-master-switch',
          'PATCH',
        ),
        isNull,
      );
      expect(
        DemoModeMasterSwitchRouter.match(
          '/v1/operators/op-1/locations/loc-1/demo-mode-master-switch',
          'DELETE',
        ),
        isNull,
      );
      expect(
        DemoModeMasterSwitchRouter.match(
          '/v1/operators/op-1/locations/loc-1/demo-mode-master-switch',
          'PUT',
        ),
        isNull,
      );
    });

    test('rejects unrelated /v1/operators/.../... paths', () {
      // wrong resource on the tail
      expect(
        DemoModeMasterSwitchRouter.match(
          '/v1/operators/op-1/locations/loc-1/shift_records',
          'POST',
        ),
        isNull,
      );
      // wrong intermediate segment
      expect(
        DemoModeMasterSwitchRouter.match(
          '/v1/operators/op-1/restaurants/loc-1/demo-mode-master-switch',
          'POST',
        ),
        isNull,
      );
      // missing trailing resource
      expect(
        DemoModeMasterSwitchRouter.match(
          '/v1/operators/op-1/locations/loc-1',
          'POST',
        ),
        isNull,
      );
      // too many segments
      expect(
        DemoModeMasterSwitchRouter.match(
          '/v1/operators/op-1/locations/loc-1/demo-mode-master-switch/extra',
          'POST',
        ),
        isNull,
      );
      // wrong prefix
      expect(
        DemoModeMasterSwitchRouter.match(
          '/v2/operators/op-1/locations/loc-1/demo-mode-master-switch',
          'POST',
        ),
        isNull,
      );
    });
  });

  group('DemoModeMasterSwitchRouter.handle (happy 200 envelope pin)', () {
    test('flipped 200 body carries flipped_count + demo_mode_states + per-row '
        'shape', () async {
      final gateway = _RecordingGateway(
        result: DemoModeMasterSwitchResult(
          flippedCount: 2,
          records: <DemoModeRecord>[
            DemoModeRecord(
              operatorId: _opId,
              locationId: _locId,
              category: IntegrationCategory.pos,
              isDemo: false,
              flippedToLiveAt: DateTime.utc(2026, 5, 13, 12),
              flippedByConnectionId: 'conn-pos',
            ),
            DemoModeRecord(
              operatorId: _opId,
              locationId: _locId,
              category: IntegrationCategory.labor,
              isDemo: false,
              flippedToLiveAt: DateTime.utc(2026, 5, 13, 12),
            ),
          ],
        ),
      );
      final router = DemoModeMasterSwitchRouter(
        gateway: gateway,
        now: () => DateTime.utc(2026, 5, 13, 12),
      );
      final result = await router.handle(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _actor,
        idempotencyKey: 'idem-happy',
        body: const <String, Object?>{'target_mode': 'live'},
      );

      expect(result.statusCode, equals(200));
      // Top-level envelope keys — pin so B3 helper extraction cannot
      // re-shape the success envelope.
      expect(result.body.keys, containsAll(<String>[
        'demo_mode_states',
        'flipped_count',
      ]));
      expect(result.body['flipped_count'], equals(2));
      final states = result.body['demo_mode_states']! as List<Object?>;
      expect(states, hasLength(2));
      // Per-record keys — pin each field the front-end depends on.
      final first = states.first as Map<String, Object?>;
      expect(first.keys, containsAll(<String>[
        'operator_id',
        'location_id',
        'category',
        'is_demo',
      ]));
      expect(first['operator_id'], equals(_opId));
      expect(first['location_id'], equals(_locId));
      expect(first['is_demo'], isFalse);
      // category is the enum name (string), not the index.
      expect(first['category'], isA<String>());
      // flipped_to_live_at present + ISO-8601 UTC string.
      expect(first['flipped_to_live_at'], isA<String>());
      expect((first['flipped_to_live_at']! as String), endsWith('Z'));
      // flipped_by_connection_id is included only when non-null.
      expect(first['flipped_by_connection_id'], equals('conn-pos'));

      // Record without connectionId — flipped_by_connection_id key
      // omitted (not present as `null`).
      final second = states[1] as Map<String, Object?>;
      expect(second.containsKey('flipped_by_connection_id'), isFalse);
    });
  });

  group('DemoModeMasterSwitchRouter.handle (error envelope pins)', () {
    test('target_mode=demo throws live_to_demo_refused 409 with message',
        () async {
      final gateway = _RecordingGateway();
      final router = DemoModeMasterSwitchRouter(
        gateway: gateway,
        now: () => DateTime.utc(2026, 5, 13, 12),
      );
      Object? thrown;
      try {
        await router.handle(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _actor,
          idempotencyKey: 'idem-demo',
          body: const <String, Object?>{'target_mode': 'demo'},
        );
      } on DemoModeMasterSwitchRejected catch (e) {
        thrown = e;
      }
      expect(thrown, isA<DemoModeMasterSwitchRejected>());
      final rejected = thrown! as DemoModeMasterSwitchRejected;
      expect(rejected.code, equals('live_to_demo_refused'));
      expect(rejected.statusCode, equals(409));
      expect(rejected.message.isNotEmpty, isTrue);
      // Plain-English human copy — no em-dash per CLAUDE.md UX no-
      // em-dash law.
      expect(rejected.message.contains('—'), isFalse);
      // Gateway was NOT called — rejection happens before any
      // repository write.
      expect(gateway.callCount, equals(0));
    });

    test('is_demo=true (boolean form) also throws live_to_demo_refused',
        () async {
      // The router accepts either `target_mode: 'demo'` or
      // `is_demo: true` shapes. Pin both forms.
      final gateway = _RecordingGateway();
      final router = DemoModeMasterSwitchRouter(
        gateway: gateway,
        now: () => DateTime.utc(2026, 5, 13, 12),
      );
      Object? thrown;
      try {
        await router.handle(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _actor,
          idempotencyKey: 'idem-demo-bool',
          body: const <String, Object?>{'is_demo': true},
        );
      } on DemoModeMasterSwitchRejected catch (e) {
        thrown = e;
      }
      final rejected = thrown! as DemoModeMasterSwitchRejected;
      expect(rejected.code, equals('live_to_demo_refused'));
      expect(rejected.statusCode, equals(409));
    });

    test('camelCase isDemo:true also rejected (alias form)', () async {
      // The router checks both `is_demo` and `isDemo` keys.
      final gateway = _RecordingGateway();
      final router = DemoModeMasterSwitchRouter(
        gateway: gateway,
        now: () => DateTime.utc(2026, 5, 13, 12),
      );
      Object? thrown;
      try {
        await router.handle(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _actor,
          idempotencyKey: 'idem-demo-camel',
          body: const <String, Object?>{'isDemo': true},
        );
      } on DemoModeMasterSwitchRejected catch (e) {
        thrown = e;
      }
      final rejected = thrown! as DemoModeMasterSwitchRejected;
      expect(rejected.code, equals('live_to_demo_refused'));
    });

    test('target_mode=stage (non-live/demo value) throws invalid_target_mode '
        '400', () async {
      final gateway = _RecordingGateway();
      final router = DemoModeMasterSwitchRouter(
        gateway: gateway,
        now: () => DateTime.utc(2026, 5, 13, 12),
      );
      Object? thrown;
      try {
        await router.handle(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _actor,
          idempotencyKey: 'idem-stage',
          body: const <String, Object?>{'target_mode': 'stage'},
        );
      } on DemoModeMasterSwitchRejected catch (e) {
        thrown = e;
      }
      final rejected = thrown! as DemoModeMasterSwitchRejected;
      expect(rejected.code, equals('invalid_target_mode'));
      expect(rejected.statusCode, equals(400));
      expect(rejected.message.isNotEmpty, isTrue);
      expect(gateway.callCount, equals(0));
    });

    test('camelCase targetMode=stage also rejected as invalid_target_mode',
        () async {
      final gateway = _RecordingGateway();
      final router = DemoModeMasterSwitchRouter(
        gateway: gateway,
        now: () => DateTime.utc(2026, 5, 13, 12),
      );
      Object? thrown;
      try {
        await router.handle(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _actor,
          idempotencyKey: 'idem-stage-camel',
          body: const <String, Object?>{'targetMode': 'stage'},
        );
      } on DemoModeMasterSwitchRejected catch (e) {
        thrown = e;
      }
      final rejected = thrown! as DemoModeMasterSwitchRejected;
      expect(rejected.code, equals('invalid_target_mode'));
      expect(rejected.statusCode, equals(400));
    });

    test('empty body / no target_mode key passes guard (treated as live)',
        () async {
      // The router accepts empty body as "default to live". Pin
      // this so the helper extraction in B3 does not tighten the
      // guard to require an explicit target_mode.
      final gateway = _RecordingGateway(
        result: DemoModeMasterSwitchResult(
          flippedCount: 1,
          records: <DemoModeRecord>[
            DemoModeRecord(
              operatorId: _opId,
              locationId: _locId,
              category: IntegrationCategory.pos,
              isDemo: false,
              flippedToLiveAt: DateTime.utc(2026, 5, 13, 12),
            ),
          ],
        ),
      );
      final router = DemoModeMasterSwitchRouter(
        gateway: gateway,
        now: () => DateTime.utc(2026, 5, 13, 12),
      );
      final result = await router.handle(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _actor,
        idempotencyKey: 'idem-empty',
        body: const <String, Object?>{},
      );
      expect(result.statusCode, equals(200));
      expect(gateway.callCount, equals(1));
    });

    test('zero flipped rows raises demo_mode_already_live 409 with message',
        () async {
      // The repository returns flippedCount=0 + no records when the
      // operator+location already had live data. Pin the 409
      // envelope so the helper extraction in B3 cannot silently
      // collapse it with the live_to_demo_refused 409.
      final gateway = _RecordingGateway(
        result: const DemoModeMasterSwitchResult(
          flippedCount: 0,
          records: <DemoModeRecord>[],
        ),
      );
      final router = DemoModeMasterSwitchRouter(
        gateway: gateway,
        now: () => DateTime.utc(2026, 5, 13, 12),
      );
      Object? thrown;
      try {
        await router.handle(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _actor,
          idempotencyKey: 'idem-no-rows',
          body: const <String, Object?>{'target_mode': 'live'},
        );
      } on DemoModeMasterSwitchRejected catch (e) {
        thrown = e;
      }
      final rejected = thrown! as DemoModeMasterSwitchRejected;
      expect(rejected.code, equals('demo_mode_already_live'));
      expect(rejected.statusCode, equals(409));
      expect(rejected.message.isNotEmpty, isTrue);
    });

    test('gateway rejection (e.g. idempotency_key_conflict from repository) '
        'is surfaced as a DemoModeMasterSwitchRejected', () async {
      // The repository raises DemoModeStateRepositoryRejected when an
      // idempotency-key body-hash drifts (same key, different body).
      // The router unwraps that into a DemoModeMasterSwitchRejected
      // with the same code/statusCode (via the
      // RepositoryDemoModeMasterSwitchGateway adapter). Pin the wire
      // shape here by raising a DemoModeMasterSwitchRejected directly
      // from the gateway fake.
      final gateway = _RecordingGateway(
        throwOnFirstCall: const DemoModeMasterSwitchRejected(
          code: 'idempotency_key_conflict',
          message: 'Idempotency-Key was already used for another request',
          statusCode: 409,
        ),
      );
      final router = DemoModeMasterSwitchRouter(
        gateway: gateway,
        now: () => DateTime.utc(2026, 5, 13, 12),
      );
      Object? thrown;
      try {
        await router.handle(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _actor,
          idempotencyKey: 'idem-conflict',
          body: const <String, Object?>{'target_mode': 'live'},
        );
      } on DemoModeMasterSwitchRejected catch (e) {
        thrown = e;
      }
      final rejected = thrown! as DemoModeMasterSwitchRejected;
      expect(rejected.code, equals('idempotency_key_conflict'));
      expect(rejected.statusCode, equals(409));
      expect(rejected.message.isNotEmpty, isTrue);
    });
  });

  group('DemoModeMasterSwitchRouter gateway args (idempotency pin)', () {
    test('forwards the idempotency key + a stable body hash to the gateway',
        () async {
      // Pin that the router passes the operator-supplied idem key
      // and a SHA-256 hash of the canonical body to the gateway.
      // The hash is what guards "same key, different body" replay
      // attempts at the repository layer; helper extraction in B3
      // must not silently change how the hash is computed.
      final gateway = _RecordingGateway(
        result: DemoModeMasterSwitchResult(
          flippedCount: 1,
          records: <DemoModeRecord>[
            DemoModeRecord(
              operatorId: _opId,
              locationId: _locId,
              category: IntegrationCategory.pos,
              isDemo: false,
              flippedToLiveAt: DateTime.utc(2026, 5, 13, 12),
            ),
          ],
        ),
      );
      final router = DemoModeMasterSwitchRouter(
        gateway: gateway,
        now: () => DateTime.utc(2026, 5, 13, 12),
      );
      await router.handle(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _actor,
        idempotencyKey: 'idem-canonical',
        body: const <String, Object?>{'target_mode': 'live'},
      );
      expect(gateway.lastCall, isNotNull);
      expect(gateway.lastCall!.idempotencyKey, equals('idem-canonical'));
      expect(gateway.lastCall!.operatorId, equals(_opId));
      expect(gateway.lastCall!.locationId, equals(_locId));
      expect(gateway.lastCall!.actorUserId, equals(_actor));
      // SHA-256 hex = 64 lowercase-hex chars.
      expect(gateway.lastCall!.requestBodyHash, hasLength(64));
      expect(
        RegExp(r'^[0-9a-f]{64}$').hasMatch(gateway.lastCall!.requestBodyHash),
        isTrue,
      );
    });

    test('body-hash is stable under map-key reordering (canonical JSON)',
        () async {
      // The router canonicalises the body before hashing (sorted
      // keys). Pin so two callers sending the same fields in
      // different order produce the same body-hash, which is the
      // repository-side idempotency-replay invariant.
      Future<String> hashFor(Map<String, Object?> body) async {
        final gateway = _RecordingGateway(
          result: DemoModeMasterSwitchResult(
            flippedCount: 1,
            records: <DemoModeRecord>[
              DemoModeRecord(
                operatorId: _opId,
                locationId: _locId,
                category: IntegrationCategory.pos,
                isDemo: false,
                flippedToLiveAt: DateTime.utc(2026, 5, 13, 12),
              ),
            ],
          ),
        );
        final router = DemoModeMasterSwitchRouter(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 13, 12),
        );
        await router.handle(
          operatorId: _opId,
          locationId: _locId,
          actorUserId: _actor,
          idempotencyKey: 'idem-hash',
          body: body,
        );
        return gateway.lastCall!.requestBodyHash;
      }

      // Two different key orderings for the same logical payload.
      final hashA = await hashFor(<String, Object?>{
        'target_mode': 'live',
        'note': 'first',
      });
      final hashB = await hashFor(<String, Object?>{
        'note': 'first',
        'target_mode': 'live',
      });
      expect(hashA, equals(hashB));

      // A different note should produce a DIFFERENT hash (sanity).
      final hashC = await hashFor(<String, Object?>{
        'target_mode': 'live',
        'note': 'second',
      });
      expect(hashA, isNot(equals(hashC)));
    });

    test('forwards the `now()` clock as flippedAt (router clock pin)',
        () async {
      final gateway = _RecordingGateway(
        result: DemoModeMasterSwitchResult(
          flippedCount: 1,
          records: <DemoModeRecord>[
            DemoModeRecord(
              operatorId: _opId,
              locationId: _locId,
              category: IntegrationCategory.pos,
              isDemo: false,
              flippedToLiveAt: DateTime.utc(2026, 5, 13, 12),
            ),
          ],
        ),
      );
      final fixedNow = DateTime.utc(2026, 5, 13, 12);
      final router = DemoModeMasterSwitchRouter(
        gateway: gateway,
        now: () => fixedNow,
      );
      await router.handle(
        operatorId: _opId,
        locationId: _locId,
        actorUserId: _actor,
        idempotencyKey: 'idem-clock',
        body: const <String, Object?>{'target_mode': 'live'},
      );
      // The router converts to UTC before forwarding so we can pin
      // the exact value.
      expect(gateway.lastCall!.flippedAt, equals(fixedNow.toUtc()));
    });
  });
}

// ─── recording gateway fake ────────────────────────────────────────

class _GatewayCall {
  const _GatewayCall({
    required this.operatorId,
    required this.locationId,
    required this.actorUserId,
    required this.flippedAt,
    required this.idempotencyKey,
    required this.requestBodyHash,
  });

  final String operatorId;
  final String locationId;
  final String actorUserId;
  final DateTime flippedAt;
  final String idempotencyKey;
  final String requestBodyHash;
}

class _RecordingGateway implements DemoModeMasterSwitchGateway {
  _RecordingGateway({this.result, this.throwOnFirstCall});

  /// Result returned from the next `flipAllDemoRowsToLive` call. When
  /// null, the gateway returns an empty `(flippedCount: 0, records: [])`
  /// shape — useful for the `demo_mode_already_live` 409 path.
  final DemoModeMasterSwitchResult? result;

  /// When non-null, the first call throws this and clears the field.
  /// Subsequent calls return [result] (or the empty default).
  DemoModeMasterSwitchRejected? throwOnFirstCall;

  int callCount = 0;
  _GatewayCall? lastCall;

  @override
  Future<DemoModeMasterSwitchResult> flipAllDemoRowsToLive({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required DateTime flippedAt,
    required String idempotencyKey,
    required String requestBodyHash,
  }) async {
    callCount += 1;
    lastCall = _GatewayCall(
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
      flippedAt: flippedAt,
      idempotencyKey: idempotencyKey,
      requestBodyHash: requestBodyHash,
    );
    final toThrow = throwOnFirstCall;
    if (toThrow != null) {
      throwOnFirstCall = null;
      throw toThrow;
    }
    return result ??
        const DemoModeMasterSwitchResult(
          flippedCount: 0,
          records: <DemoModeRecord>[],
        );
  }
}
