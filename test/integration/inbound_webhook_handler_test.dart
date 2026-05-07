// Phase 8.0 (V1 lean cut 2) — Inbound webhook handler integration
// tests.
//
// Drives [InboundWebhookHandler] through every rejection branch
// (signature, replay, binding, idempotency, sanity drop, dead-letter
// at attempt 3) with an in-memory gateway + stub signature verifier
// + stub adapter so no live database or vendor SDK is needed.
//
// V1 lean cut 2 changes from iter1:
//   * No parse_warnings / parse_partial assertions (those columns
//     were removed in the trim).
//   * New: sanity-drop assertions exercising the timestamp guard.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/integration/inbound_webhook_handler.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/pos_adapter.dart';

void main() {
  group('InboundWebhookHandler', () {
    late _FakeWebhookGateway gateway;
    late _StubSignatureVerifier verifier;
    late _StubPosAdapter adapter;
    late InboundWebhookHandler handler;
    late DateTime nowFixed;

    setUp(() {
      nowFixed = DateTime.utc(2026, 5, 4, 12, 0, 0);
      gateway = _FakeWebhookGateway();
      verifier = _StubSignatureVerifier(vendorId: 'lightspeed_lsk');
      adapter = _StubPosAdapter(vendorId: 'lightspeed_lsk');
      handler = InboundWebhookHandler(
        gateway: gateway,
        posAdapterFactories: <String, PosAdapterFactory>{
          adapter.vendorId:
              ({required operatorId, required locationId}) async => adapter,
        },
        laborAdapterFactories: const <String, LaborAdapterFactory>{},
        reservationAdapterFactories:
            const <String, ReservationAdapterFactory>{},
        signatureVerifiers: <String, VendorWebhookSignatureVerifier>{
          verifier.vendorId: verifier,
        },
        bindingExtractor: WebhookBindingExtractor(),
        now: () => nowFixed,
      );
    });

    test('accepted: valid signature, binding, fresh event', () async {
      gateway.bindings['lightspeed_lsk'] = const ConnectionBinding(
        connectionId: 'conn-1',
        metadata: <String, Object?>{'business_id': 'lsk-biz-7c2f'},
        status: ConnectionStatus.connected,
      );
      gateway.signingSecrets['lightspeed_lsk'] = 'secret';
      verifier.shouldPass = true;
      adapter.handleResult = const HandleWebhookResult(recordsWritten: 1);

      final result = await handler.dispatch(
        operatorId: _opId,
        locationId: _locId,
        vendorId: 'lightspeed_lsk',
        rawBody: Uint8List.fromList(utf8.encode('{}')),
        payload: <String, Object?>{
          'event_id': 'evt-1',
          'business_id': 'lsk-biz-7c2f',
          // Sane timestamps — sanity guard passes.
          'opened_at': nowFixed.subtract(const Duration(hours: 2)).toIso8601String(),
          'closed_at': nowFixed.subtract(const Duration(hours: 1)).toIso8601String(),
        },
        headers: const <String, String>{},
      );

      expect(result.outcome, WebhookOutcome.accepted);
      expect(result.statusCode, 200);
      expect(result.recordsWritten, 1);
      expect(adapter.handleCalls, 1);
    });

    test(
        'fail-closed: missing webhook signing secret rejects 403 + no '
        'adapter dispatch (CODE_OPS_DEBT G#2)', () async {
      // Critical posture: when `vendor_credentials.webhook_signing_secret_ciphertext`
      // has not yet been provisioned for the (operator, location, vendor)
      // triple, the gateway returns null and the handler MUST reject
      // the webhook with 403 — never silently skip verification, never
      // hand the payload to the adapter.
      gateway.bindings['lightspeed_lsk'] = const ConnectionBinding(
        connectionId: 'conn-1',
        metadata: <String, Object?>{'business_id': 'lsk-biz-7c2f'},
        status: ConnectionStatus.connected,
      );
      // Intentionally NOT setting gateway.signingSecrets['lightspeed_lsk']:
      // simulates the unprovisioned column. Gateway returns null →
      // handler short-circuits with 403 before invoking the verifier.
      verifier.shouldPass = true;

      final result = await handler.dispatch(
        operatorId: _opId,
        locationId: _locId,
        vendorId: 'lightspeed_lsk',
        rawBody: Uint8List.fromList(utf8.encode('{}')),
        payload: const <String, Object?>{
          'event_id': 'evt-no-signing-secret',
          'business_id': 'lsk-biz-7c2f',
        },
        headers: const <String, String>{},
      );

      expect(result.outcome, WebhookOutcome.signatureInvalid);
      expect(result.statusCode, 403);
      expect(result.message, contains('no signing secret on file'),
          reason: 'message must reference the unprovisioned-secret cause '
              'so triage knows to run the runbook flow');
      expect(adapter.handleCalls, 0,
          reason:
              'fail-closed: adapter MUST NOT see the payload when the '
              'webhook signing secret has not been provisioned');
    });

    test('rejected: signature invalid', () async {
      gateway.bindings['lightspeed_lsk'] = const ConnectionBinding(
        connectionId: 'conn-1',
        metadata: <String, Object?>{'business_id': 'lsk-biz-7c2f'},
        status: ConnectionStatus.connected,
      );
      gateway.signingSecrets['lightspeed_lsk'] = 'secret';
      verifier.shouldPass = false;
      verifier.failureReason = 'bad signature';

      final result = await handler.dispatch(
        operatorId: _opId,
        locationId: _locId,
        vendorId: 'lightspeed_lsk',
        rawBody: Uint8List.fromList(utf8.encode('{}')),
        payload: const <String, Object?>{'event_id': 'evt-2'},
        headers: const <String, String>{},
      );

      expect(result.outcome, WebhookOutcome.signatureInvalid);
      expect(result.statusCode, 403);
      expect(adapter.handleCalls, 0);
      expect(gateway.failedAttempts['evt-2'], 1);
    });

    test(
        'replay defense: rejects signature timestamp older than 24h '
        '(V1 lean cut 2 — strict 5-min window deleted)', () async {
      gateway.bindings['lightspeed_lsk'] = const ConnectionBinding(
        connectionId: 'conn-1',
        metadata: <String, Object?>{'business_id': 'lsk-biz-7c2f'},
        status: ConnectionStatus.connected,
      );
      gateway.signingSecrets['lightspeed_lsk'] = 'secret';
      verifier.shouldPass = true;
      verifier.timestampOverride = nowFixed.subtract(
        const Duration(hours: 25),
      );

      final result = await handler.dispatch(
        operatorId: _opId,
        locationId: _locId,
        vendorId: 'lightspeed_lsk',
        rawBody: Uint8List.fromList(utf8.encode('{}')),
        payload: const <String, Object?>{'event_id': 'evt-3'},
        headers: const <String, String>{},
      );

      expect(result.outcome, WebhookOutcome.replayTooOld);
      expect(result.statusCode, 403);
    });

    test(
        'replay defense: accepts signature timestamp within 24h tolerance '
        '(legitimate vendor retry)', () async {
      gateway.bindings['lightspeed_lsk'] = const ConnectionBinding(
        connectionId: 'conn-1',
        metadata: <String, Object?>{'business_id': 'lsk-biz-7c2f'},
        status: ConnectionStatus.connected,
      );
      gateway.signingSecrets['lightspeed_lsk'] = 'secret';
      verifier.shouldPass = true;
      // 6 minutes old — would have been rejected under iter1 strict
      // 5-min window. V1 lean cut 2 accepts it; idempotency UNIQUE
      // prevents double-write.
      verifier.timestampOverride = nowFixed.subtract(
        const Duration(minutes: 6),
      );

      final result = await handler.dispatch(
        operatorId: _opId,
        locationId: _locId,
        vendorId: 'lightspeed_lsk',
        rawBody: Uint8List.fromList(utf8.encode('{}')),
        payload: const <String, Object?>{'event_id': 'evt-3-replay-window'},
        headers: const <String, String>{},
      );

      expect(result.outcome, isNot(WebhookOutcome.replayTooOld));
      expect(result.statusCode, isNot(403));
    });

    test('binding mismatch: rejects 403 + no fact write', () async {
      gateway.bindings['lightspeed_lsk'] = const ConnectionBinding(
        connectionId: 'conn-1',
        metadata: <String, Object?>{'business_id': 'lsk-biz-AAAA'},
        status: ConnectionStatus.connected,
      );
      gateway.signingSecrets['lightspeed_lsk'] = 'secret';
      verifier.shouldPass = true;

      final result = await handler.dispatch(
        operatorId: _opId,
        locationId: _locId,
        vendorId: 'lightspeed_lsk',
        rawBody: Uint8List.fromList(utf8.encode('{}')),
        payload: const <String, Object?>{
          'event_id': 'evt-4',
          'business_id': 'lsk-biz-DIFFERENT',
        },
        headers: const <String, String>{},
      );

      expect(result.outcome, WebhookOutcome.bindingMismatch);
      expect(result.statusCode, 403);
      expect(adapter.handleCalls, 0);
    });

    test('idempotent: duplicate event short-circuits to 200 no-op', () async {
      gateway.bindings['lightspeed_lsk'] = const ConnectionBinding(
        connectionId: 'conn-1',
        metadata: <String, Object?>{'business_id': 'lsk-biz-7c2f'},
        status: ConnectionStatus.connected,
      );
      gateway.signingSecrets['lightspeed_lsk'] = 'secret';
      verifier.shouldPass = true;
      adapter.handleResult = const HandleWebhookResult(recordsWritten: 1);
      gateway.duplicateOnSecondCall = true;

      final payload = <String, Object?>{
        'event_id': 'evt-5',
        'business_id': 'lsk-biz-7c2f',
        'opened_at':
            nowFixed.subtract(const Duration(hours: 2)).toIso8601String(),
        'closed_at':
            nowFixed.subtract(const Duration(hours: 1)).toIso8601String(),
      };
      final first = await handler.dispatch(
        operatorId: _opId,
        locationId: _locId,
        vendorId: 'lightspeed_lsk',
        rawBody: Uint8List.fromList(utf8.encode('{}')),
        payload: payload,
        headers: const <String, String>{},
      );
      final second = await handler.dispatch(
        operatorId: _opId,
        locationId: _locId,
        vendorId: 'lightspeed_lsk',
        rawBody: Uint8List.fromList(utf8.encode('{}')),
        payload: payload,
        headers: const <String, String>{},
      );

      expect(first.outcome, WebhookOutcome.accepted);
      expect(second.outcome, WebhookOutcome.duplicate);
      expect(second.statusCode, 200);
      expect(adapter.handleCalls, 1);
    });

    test('sanity drop: future-dated event is dropped + logged', () async {
      gateway.bindings['lightspeed_lsk'] = const ConnectionBinding(
        connectionId: 'conn-1',
        metadata: <String, Object?>{'business_id': 'lsk-biz-7c2f'},
        status: ConnectionStatus.connected,
      );
      gateway.signingSecrets['lightspeed_lsk'] = 'secret';
      verifier.shouldPass = true;
      adapter.handleResult = const HandleWebhookResult(recordsWritten: 1);

      final result = await handler.dispatch(
        operatorId: _opId,
        locationId: _locId,
        vendorId: 'lightspeed_lsk',
        rawBody: Uint8List.fromList(utf8.encode('{}')),
        payload: <String, Object?>{
          'event_id': 'evt-future',
          'business_id': 'lsk-biz-7c2f',
          // Future-dated by 5 days — sanity guard rule 2 fires.
          'opened_at':
              nowFixed.add(const Duration(days: 5)).toIso8601String(),
        },
        headers: const <String, String>{},
      );

      expect(result.outcome, WebhookOutcome.sanityDropped);
      expect(adapter.handleCalls, 0,
          reason: 'sanity drop must run BEFORE adapter dispatch');
      expect(gateway.sanityDrops.length, 1);
      expect(gateway.sanityDrops.single['rule'], 'opened_in_future');
    });

    test('sanity drop: closed_at < opened_at is dropped + logged', () async {
      gateway.bindings['lightspeed_lsk'] = const ConnectionBinding(
        connectionId: 'conn-1',
        metadata: <String, Object?>{'business_id': 'lsk-biz-7c2f'},
        status: ConnectionStatus.connected,
      );
      gateway.signingSecrets['lightspeed_lsk'] = 'secret';
      verifier.shouldPass = true;

      final result = await handler.dispatch(
        operatorId: _opId,
        locationId: _locId,
        vendorId: 'lightspeed_lsk',
        rawBody: Uint8List.fromList(utf8.encode('{}')),
        payload: <String, Object?>{
          'event_id': 'evt-out-of-order',
          'business_id': 'lsk-biz-7c2f',
          'opened_at':
              nowFixed.subtract(const Duration(hours: 1)).toIso8601String(),
          'closed_at':
              nowFixed.subtract(const Duration(hours: 2)).toIso8601String(),
        },
        headers: const <String, String>{},
      );

      expect(result.outcome, WebhookOutcome.sanityDropped);
      expect(gateway.sanityDrops.length, 1);
      expect(gateway.sanityDrops.single['rule'], 'closed_before_opened');
    });

    test(
        'per-tenant routing: same vendor, different (operator, location) '
        'tuples → factory called per delivery with the right tuple', () async {
      // Two tenants share the same vendor. The factory is invoked
      // per webhook delivery; each call must hand back the
      // correctly-tenant-scoped adapter so that the credential
      // bridges close over the right (operator, location).
      final perTenantAdapters = <String, _StubPosAdapter>{};
      final factoryCalls = <Map<String, String>>[];
      final perTenantHandler = InboundWebhookHandler(
        gateway: gateway,
        posAdapterFactories: <String, PosAdapterFactory>{
          'lightspeed_lsk':
              ({required operatorId, required locationId}) async {
            factoryCalls.add(<String, String>{
              'operator_id': operatorId,
              'location_id': locationId,
            });
            final key = '$operatorId|$locationId';
            return perTenantAdapters.putIfAbsent(
              key,
              () => _StubPosAdapter(vendorId: 'lightspeed_lsk')
                ..tenantTag = key
                ..handleResult = const HandleWebhookResult(recordsWritten: 1),
            );
          },
        },
        laborAdapterFactories: const <String, LaborAdapterFactory>{},
        reservationAdapterFactories:
            const <String, ReservationAdapterFactory>{},
        signatureVerifiers: <String, VendorWebhookSignatureVerifier>{
          'lightspeed_lsk': verifier,
        },
        bindingExtractor: WebhookBindingExtractor(),
        now: () => nowFixed,
      );

      gateway.bindings['lightspeed_lsk'] = const ConnectionBinding(
        connectionId: 'conn-shared',
        metadata: <String, Object?>{'business_id': 'lsk-biz-7c2f'},
        status: ConnectionStatus.connected,
      );
      gateway.signingSecrets['lightspeed_lsk'] = 'secret';
      verifier.shouldPass = true;

      const tenantAOperator = '00000000-0000-4000-8000-0000000000a0';
      const tenantALocation = '00000000-0000-4000-8000-0000000000a1';
      const tenantBOperator = '00000000-0000-4000-8000-0000000000b0';
      const tenantBLocation = '00000000-0000-4000-8000-0000000000b1';

      Map<String, Object?> payloadFor(String eventId) => <String, Object?>{
            'event_id': eventId,
            'business_id': 'lsk-biz-7c2f',
            'opened_at':
                nowFixed.subtract(const Duration(hours: 2)).toIso8601String(),
            'closed_at':
                nowFixed.subtract(const Duration(hours: 1)).toIso8601String(),
          };

      final resultA = await perTenantHandler.dispatch(
        operatorId: tenantAOperator,
        locationId: tenantALocation,
        vendorId: 'lightspeed_lsk',
        rawBody: Uint8List.fromList(utf8.encode('{}')),
        payload: payloadFor('evt-tenant-a'),
        headers: const <String, String>{},
      );
      final resultB = await perTenantHandler.dispatch(
        operatorId: tenantBOperator,
        locationId: tenantBLocation,
        vendorId: 'lightspeed_lsk',
        rawBody: Uint8List.fromList(utf8.encode('{}')),
        payload: payloadFor('evt-tenant-b'),
        headers: const <String, String>{},
      );

      expect(resultA.outcome, WebhookOutcome.accepted);
      expect(resultB.outcome, WebhookOutcome.accepted);
      expect(factoryCalls, hasLength(2));
      expect(factoryCalls[0], <String, String>{
        'operator_id': tenantAOperator,
        'location_id': tenantALocation,
      });
      expect(factoryCalls[1], <String, String>{
        'operator_id': tenantBOperator,
        'location_id': tenantBLocation,
      });
      // Each tenant got its own adapter instance.
      expect(perTenantAdapters, hasLength(2));
      expect(
        perTenantAdapters['$tenantAOperator|$tenantALocation']!.handleCalls,
        1,
      );
      expect(
        perTenantAdapters['$tenantBOperator|$tenantBLocation']!.handleCalls,
        1,
      );
    });

    test('dead-letter on 3rd consecutive failure', () async {
      gateway.bindings['lightspeed_lsk'] = const ConnectionBinding(
        connectionId: 'conn-1',
        metadata: <String, Object?>{'business_id': 'lsk-biz-7c2f'},
        status: ConnectionStatus.connected,
      );
      gateway.signingSecrets['lightspeed_lsk'] = 'secret';
      verifier.shouldPass = false;
      verifier.failureReason = 'bad signature';

      for (var i = 0; i < 3; i++) {
        await handler.dispatch(
          operatorId: _opId,
          locationId: _locId,
          vendorId: 'lightspeed_lsk',
          rawBody: Uint8List.fromList(utf8.encode('{}')),
          payload: const <String, Object?>{'event_id': 'evt-7'},
          headers: const <String, String>{},
        );
      }
      expect(gateway.failedAttempts['evt-7'], 3);
      expect(gateway.deadLetterCalls.length, 1);
      expect(
        gateway.deadLetterCalls.single['failure_kind'],
        InboundWebhookFailureKind.signatureInvalid,
      );
    });
  });

  group('constantTimeBytesEquals', () {
    test('returns true for equal byte sequences', () {
      expect(
        constantTimeBytesEquals(<int>[1, 2, 3], <int>[1, 2, 3]),
        true,
      );
    });
    test('returns false for differing-length sequences', () {
      expect(
        constantTimeBytesEquals(<int>[1, 2, 3], <int>[1, 2, 3, 4]),
        false,
      );
    });
    test('returns false for differing content', () {
      expect(
        constantTimeBytesEquals(<int>[1, 2, 3], <int>[1, 2, 4]),
        false,
      );
    });
  });
}

const String _opId = '00000000-0000-4000-8000-000000000001';
const String _locId = '00000000-0000-4000-8000-0000000000a1';

class _FakeWebhookGateway implements InboundWebhookGateway {
  final Map<String, ConnectionBinding> bindings = <String, ConnectionBinding>{};
  final Map<String, String> signingSecrets = <String, String>{};
  final Map<String, int> failedAttempts = <String, int>{};
  final List<Map<String, Object?>> deadLetterCalls =
      <Map<String, Object?>>[];
  final List<Map<String, Object?>> processedWith =
      <Map<String, Object?>>[];
  final List<Map<String, Object?>> sanityDrops = <Map<String, Object?>>[];
  final Set<String> seenIdempotencyKeys = <String>{};
  bool duplicateOnSecondCall = false;

  @override
  Future<ConnectionBinding?> lookupBinding({
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) async {
    return bindings[vendorId];
  }

  @override
  Future<String?> lookupSigningSecret({
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) async {
    return signingSecrets[vendorId];
  }

  @override
  Future<IdempotencyOutcome> claimIdempotency({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required DateTime receivedAt,
  }) async {
    final key = '$vendorId:$vendorEventId';
    if (seenIdempotencyKeys.contains(key) && duplicateOnSecondCall) {
      return IdempotencyOutcome.duplicate;
    }
    seenIdempotencyKeys.add(key);
    return IdempotencyOutcome.firstTime;
  }

  @override
  Future<void> markProcessed({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required DateTime receivedAt,
  }) async {
    processedWith.add(<String, Object?>{
      'vendor_event_id': vendorEventId,
    });
  }

  @override
  Future<void> recordSanityDrop({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required String rule,
    required Map<String, Object?> payloadSummary,
  }) async {
    sanityDrops.add(<String, Object?>{
      'vendor_event_id': vendorEventId,
      'rule': rule,
      'payload_summary': payloadSummary,
    });
  }

  @override
  Future<int> recordFailedAttempt({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required String failureMessage,
    required DateTime receivedAt,
  }) async {
    failedAttempts[vendorEventId] = (failedAttempts[vendorEventId] ?? 0) + 1;
    return failedAttempts[vendorEventId]!;
  }

  @override
  Future<void> deadLetter({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required Map<String, Object?> payloadPreview,
    required InboundWebhookFailureKind failureKind,
    required String failureMessage,
  }) async {
    deadLetterCalls.add(<String, Object?>{
      'vendor_event_id': vendorEventId,
      'failure_kind': failureKind,
      'failure_message': failureMessage,
    });
  }

  @override
  Future<void> appendSyncLog({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String eventKind,
    String? errorMessage,
    int? recordsCount,
    Map<String, Object?>? payloadPreview,
  }) async {}
}

class _StubSignatureVerifier implements VendorWebhookSignatureVerifier {
  _StubSignatureVerifier({required this.vendorId});

  @override
  final String vendorId;

  bool shouldPass = true;
  String? failureReason;
  DateTime? timestampOverride;

  @override
  WebhookSignatureVerification verify({
    required Uint8List rawBody,
    required Map<String, String> headers,
    required String signingSecret,
    required DateTime now,
  }) {
    return WebhookSignatureVerification(
      valid: shouldPass,
      timestamp: timestampOverride,
      failureReason: failureReason,
    );
  }
}

class _StubPosAdapter implements PosAdapter {
  _StubPosAdapter({required this.vendorId});

  @override
  final String vendorId;

  /// Diagnostic-only label so the per-tenant routing test can assert
  /// that distinct adapter instances were handed back for distinct
  /// `(operator, location)` tuples.
  String? tenantTag;

  @override
  String get displayName => 'Stub POS';

  @override
  VendorCapabilityProfile get capabilityProfile => VendorCapabilityProfile(
        vendorId: vendorId,
        displayName: 'Stub POS',
        category: IntegrationCategory.pos,
        authMode: VendorAuthMode.oauth,
        grantScope: VendorGrantScope.perLocation,
        webhookSupport: VendorWebhookSupport.autoRegister,
        coversFieldExposed: true,
        lifecycle: VendorLifecycle.documented,
      );

  HandleWebhookResult handleResult = const HandleWebhookResult(
    recordsWritten: 0,
  );
  int handleCalls = 0;

  @override
  Future<HandleWebhookResult> handleWebhook(HandleWebhookCommand command) async {
    handleCalls++;
    return handleResult;
  }

  @override
  Future<ConnectResult> connect(ConnectCommand command) =>
      throw UnimplementedError();
  @override
  Future<TestConnectionResult> testConnection(TestConnectionCommand command) =>
      throw UnimplementedError();
  @override
  Future<BackfillResult> backfill(BackfillCommand command) =>
      throw UnimplementedError();
  @override
  Future<PollIncrementalResult> pollIncremental(
          PollIncrementalCommand command) =>
      throw UnimplementedError();
  @override
  Future<DisconnectResult> disconnect(DisconnectCommand command) =>
      throw UnimplementedError();
}
