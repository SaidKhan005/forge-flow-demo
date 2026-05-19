// Phase 9.8 — SendGrid webhook handler tests.
//
// Stubs the gateway and the verifier inputs so the orchestration
// contract is asserted end-to-end: signature → parse → dispatch.
// Signature plumbing is exercised against an ephemeral keypair; the
// in-process [_FakeGateway] records each ingest call so the test can
// assert idempotency + outbox flips.

import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/pointycastle.dart';
import 'package:pointycastle/ecc/curves/secp256r1.dart';
import 'package:pointycastle/key_generators/ec_key_generator.dart';
import 'package:pointycastle/random/fortuna_random.dart';

import 'package:forge_and_flow/services/email/sendgrid_event_payload_parser.dart';
import 'package:forge_and_flow/services/email/sendgrid_webhook_handler.dart';

void main() {
  group('SendGridWebhookHandler', () {
    late _Fixture fx;

    setUp(() {
      fx = _Fixture.build();
    });

    test('valid batch -> Accepted with ingested counts', () async {
      final body = _eventsBody([
        _event(eventType: 'delivered', sgEventId: 'evt-1'),
        _event(eventType: 'open', sgEventId: 'evt-2'),
      ]);
      final outcome = await fx.handle(body);
      expect(outcome, isA<SendGridWebhookOutcomeAccepted>());
      final accepted = outcome as SendGridWebhookOutcomeAccepted;
      expect(accepted.ingested, 2);
      expect(accepted.deduplicated, 0);
      expect(accepted.outboxStatusFlips, 0);
      expect(accepted.parseFailures, isEmpty);
    });

    test('replayed event_id -> deduplicated bucket', () async {
      final body = _eventsBody([
        _event(eventType: 'delivered', sgEventId: 'evt-1'),
      ]);
      await fx.handle(body);
      final outcome = await fx.handle(body);
      final accepted = outcome as SendGridWebhookOutcomeAccepted;
      expect(accepted.ingested, 0);
      expect(accepted.deduplicated, 1);
    });

    test('bounce flips outbox, dedupe replay does NOT re-flip', () async {
      final body = _eventsBody([
        _event(
          eventType: 'bounce',
          sgEventId: 'evt-bounce',
          emailId: '11111111-2222-3333-4444-555555555555',
        ),
      ]);
      final firstOutcome =
          await fx.handle(body) as SendGridWebhookOutcomeAccepted;
      expect(firstOutcome.outboxStatusFlips, 1);
      final replayOutcome =
          await fx.handle(body) as SendGridWebhookOutcomeAccepted;
      expect(replayOutcome.outboxStatusFlips, 0);
      expect(replayOutcome.deduplicated, 1);
    });

    test('signature missing -> Rejected', () async {
      final body = _eventsBody([
        _event(eventType: 'delivered', sgEventId: 'evt-1'),
      ]);
      final outcome = await fx.handler.handle(
        rawBody: body,
        signatureHeader: null,
        timestampHeader: fx.timestampHeader,
      );
      expect(outcome, isA<SendGridWebhookOutcomeRejected>());
    });

    test('tampered body -> Rejected', () async {
      final body = _eventsBody([
        _event(eventType: 'delivered', sgEventId: 'evt-1'),
      ]);
      final tampered = utf8.encode('[{"event":"DIFFERENT"}]');
      final sig = fx.signFor(body);
      final outcome = await fx.handler.handle(
        rawBody: tampered,
        signatureHeader: sig,
        timestampHeader: fx.timestampHeader,
      );
      expect(outcome, isA<SendGridWebhookOutcomeRejected>());
    });

    test('non-array JSON body -> BadRequest', () async {
      final body = utf8.encode('{"foo":1}');
      final sig = fx.signFor(body);
      final outcome = await fx.handler.handle(
        rawBody: body,
        signatureHeader: sig,
        timestampHeader: fx.timestampHeader,
      );
      expect(outcome, isA<SendGridWebhookOutcomeBadRequest>());
    });

    test('empty body -> BadRequest', () async {
      final body = <int>[];
      final sig = fx.signFor(body);
      final outcome = await fx.handler.handle(
        rawBody: body,
        signatureHeader: sig,
        timestampHeader: fx.timestampHeader,
      );
      expect(outcome, isA<SendGridWebhookOutcomeBadRequest>());
    });

    test('mixed batch with malformed event -> Accepted with parse failures',
        () async {
      final body = utf8.encode(jsonEncode([
        <String, Object?>{
          'event': 'delivered',
          'sg_event_id': 'evt-good',
          'timestamp': 1700000000,
        },
        <String, Object?>{
          'event': 'delivered',
          // missing sg_event_id
          'timestamp': 1700000001,
        },
      ]));
      final outcome = await fx.handle(body) as SendGridWebhookOutcomeAccepted;
      expect(outcome.ingested, 1);
      expect(outcome.parseFailures, hasLength(1));
    });
  });
}

/// In-memory test fixture: ephemeral keypair, fake gateway, fixed clock.
class _Fixture {
  _Fixture._({
    required this.handler,
    required this.gateway,
    required this.privateKey,
    required this.timestampHeader,
  });

  factory _Fixture.build() {
    final kp = _generateP256KeyPair();
    final publicKeyBase64 = _encodeP256PublicKeyAsSpkiBase64(kp.publicKey);
    final gateway = _FakeGateway();
    const ts = '1700000000';
    final fixedNow = DateTime.fromMillisecondsSinceEpoch(
      1700000060 * 1000,
      isUtc: true,
    );
    final handler = SendGridWebhookHandler(
      publicKeyBase64: publicKeyBase64,
      gateway: gateway,
      now: () => fixedNow,
    );
    return _Fixture._(
      handler: handler,
      gateway: gateway,
      privateKey: kp.privateKey,
      timestampHeader: ts,
    );
  }

  final SendGridWebhookHandler handler;
  final _FakeGateway gateway;
  final ECPrivateKey privateKey;
  final String timestampHeader;

  Future<SendGridWebhookOutcome> handle(List<int> body) {
    return handler.handle(
      rawBody: body,
      signatureHeader: signFor(body),
      timestampHeader: timestampHeader,
    );
  }

  String signFor(List<int> body) {
    return _signSendGridPayload(privateKey, timestampHeader, body);
  }
}

class _FakeGateway implements SendGridWebhookGateway {
  final Set<String> _seen = <String>{};
  final List<SendGridEventRecord> ingested = <SendGridEventRecord>[];

  @override
  Future<SendGridEventIngestResult> ingest(SendGridEventRecord event) async {
    final fresh = _seen.add(event.providerEventId);
    if (fresh) ingested.add(event);
    final terminal =
        kSendGridOutboxTerminalStatuses.containsKey(event.eventKind);
    return SendGridEventIngestResult(
      providerEventId: event.providerEventId,
      inserted: fresh,
      outboxStatusUpdated: fresh && terminal && event.emailId != null,
      boundEmailId: event.emailId,
    );
  }
}

Map<String, Object?> _event({
  required String eventType,
  required String sgEventId,
  String? emailId,
}) {
  return <String, Object?>{
    'event': eventType,
    'sg_event_id': sgEventId,
    'sg_message_id': 'sg-msg-1',
    'timestamp': 1700000000,
    if (emailId != null) 'email_id': emailId,
  };
}

List<int> _eventsBody(List<Map<String, Object?>> events) =>
    utf8.encode(jsonEncode(events));

class _P256KeyPair {
  _P256KeyPair(this.publicKey, this.privateKey);
  final ECPublicKey publicKey;
  final ECPrivateKey privateKey;
}

_P256KeyPair _generateP256KeyPair() {
  final params = ECCurve_secp256r1();
  final keyParams = ECKeyGeneratorParameters(params);
  final secureRandom = FortunaRandom();
  final seed = Uint8List.fromList(
    List<int>.generate(32, (_) => Random.secure().nextInt(256)),
  );
  secureRandom.seed(KeyParameter(seed));
  final generator = ECKeyGenerator()
    ..init(ParametersWithRandom(keyParams, secureRandom));
  final pair = generator.generateKeyPair();
  return _P256KeyPair(
    pair.publicKey as ECPublicKey,
    pair.privateKey as ECPrivateKey,
  );
}

String _signSendGridPayload(
  ECPrivateKey privateKey,
  String timestampHeader,
  List<int> rawBody,
) {
  final tsBytes = utf8.encode(timestampHeader);
  final message = Uint8List(tsBytes.length + rawBody.length)
    ..setRange(0, tsBytes.length, tsBytes)
    ..setRange(tsBytes.length, tsBytes.length + rawBody.length, rawBody);
  final secureRandom = FortunaRandom();
  final seed = Uint8List.fromList(
    List<int>.generate(32, (_) => Random.secure().nextInt(256)),
  );
  secureRandom.seed(KeyParameter(seed));
  final signer = ECDSASigner(SHA256Digest())
    ..init(
      true,
      ParametersWithRandom(
        PrivateKeyParameter<ECPrivateKey>(privateKey),
        secureRandom,
      ),
    );
  final sig = signer.generateSignature(message) as ECSignature;
  final der = _encodeEcdsaDer(sig.r, sig.s);
  return base64.encode(der);
}

Uint8List _encodeEcdsaDer(BigInt r, BigInt s) {
  final rBytes = _encodeAsn1Integer(r);
  final sBytes = _encodeAsn1Integer(s);
  final body = <int>[...rBytes, ...sBytes];
  return Uint8List.fromList(<int>[0x30, body.length, ...body]);
}

List<int> _encodeAsn1Integer(BigInt value) {
  final hex = value.toRadixString(16);
  final padded = hex.length.isOdd ? '0$hex' : hex;
  final raw = <int>[];
  for (var i = 0; i < padded.length; i += 2) {
    raw.add(int.parse(padded.substring(i, i + 2), radix: 16));
  }
  if (raw.first & 0x80 != 0) {
    raw.insert(0, 0x00);
  }
  return <int>[0x02, raw.length, ...raw];
}

String _encodeP256PublicKeyAsSpkiBase64(ECPublicKey key) {
  final q = key.Q!;
  final x = _bigIntToFixedLengthBytes(q.x!.toBigInteger()!, 32);
  final y = _bigIntToFixedLengthBytes(q.y!.toBigInteger()!, 32);
  final point = <int>[0x04, ...x, ...y];
  final algId = <int>[
    0x30, 0x13,
    0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
    0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07,
  ];
  final bitString = <int>[
    0x03, 1 + point.length,
    0x00,
    ...point,
  ];
  final body = <int>[...algId, ...bitString];
  final spki = <int>[0x30, body.length, ...body];
  return base64.encode(spki);
}

List<int> _bigIntToFixedLengthBytes(BigInt value, int length) {
  var hex = value.toRadixString(16);
  if (hex.length.isOdd) hex = '0$hex';
  final bytes = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  while (bytes.length < length) {
    bytes.insert(0, 0);
  }
  if (bytes.length > length) {
    return bytes.sublist(bytes.length - length);
  }
  return bytes;
}
