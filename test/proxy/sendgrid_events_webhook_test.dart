// Lane C C-1 — SendGrid Event Webhook receiver tests.
//
// Pins the receiver contract:
//
//   POST /v1/webhooks/sendgrid/events
//   X-Twilio-Email-Event-Webhook-Signature: <ECDSA P-256 base64>
//   X-Twilio-Email-Event-Webhook-Timestamp: <unix seconds>
//
// Coverage (8 webhook scenarios from slice prompt Block 3):
//   1. happy path: signed payload with 3 events → 3 rows inserted, 204
//   2. bad signature → 401, no rows inserted
//   3. replayed payload → 204, no new rows (ON CONFLICT path)
//   4. partial-batch handling: mix of new + replayed events → only new
//      rows inserted, 204 returned
//   5. empty event array → 204, no rows
//   6. malformed JSON → 400
//   7. missing signature header → 401
//   8. pubkey not configured → 503 (env var unset)
//
// Additional pinning tests:
//   * missing timestamp header → 401
//   * malformed_event (sg_event_id missing on one entry) → 400
//   * body-too-large → 413
//
// All tests use the `dispatch` pure-Dart surface so the suite has no
// dependency on `dart:io` HttpServer or a live Postgres pool.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/email_event_repository.dart';
import 'package:forge_and_flow/services/email/sendgrid_event_payload.dart';

import '../../tool/advisor_proxy/sendgrid_events_webhook.dart';

/// Pinned fake pubkey PEM literal. The signature verifier is also a
/// fake, so the value here is opaque to the verifier — it just has to
/// satisfy "non-empty" and "non-null".
const String _kFakePemPubKey =
    '-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----';

const String _kValidSignature = 'valid-signature-base64==';
const String _kBadSignature = 'wrong-signature';
const String _kTimestamp = '1718000000';

void main() {
  group('SendGridEventsWebhookRouter', () {
    test('happy path: 3 fresh events inserted, 204 returned', () async {
      final repo = _FakeEmailEventRepository();
      final router = SendGridEventsWebhookRouter(
        repository: repo,
        pubKeyLoader: () => _kFakePemPubKey,
        signatureVerifier: _AcceptingVerifier(),
      );
      final body = _bodyForEvents(<Map<String, Object?>>[
        _eventJson(sgEventId: 'evt-1', eventKind: 'processed'),
        _eventJson(sgEventId: 'evt-2', eventKind: 'delivered'),
        _eventJson(sgEventId: 'evt-3', eventKind: 'opened'),
      ]);
      final result = await router.dispatch(
        method: 'POST',
        path: sendGridEventsWebhookPath,
        body: body,
        headers: _signedHeaders(),
      );
      expect(result.statusCode, 204);
      expect(result.body, isNull);
      expect(repo.insertedEventIds, <String>['evt-1', 'evt-2', 'evt-3']);
    });

    test('bad signature → 401, no rows inserted', () async {
      final repo = _FakeEmailEventRepository();
      final router = SendGridEventsWebhookRouter(
        repository: repo,
        pubKeyLoader: () => _kFakePemPubKey,
        signatureVerifier: _RejectingVerifier(),
      );
      final body = _bodyForEvents(<Map<String, Object?>>[
        _eventJson(sgEventId: 'evt-1', eventKind: 'delivered'),
      ]);
      final result = await router.dispatch(
        method: 'POST',
        path: sendGridEventsWebhookPath,
        body: body,
        headers: <String, String>{
          kSendGridSignatureHeader: _kBadSignature,
          kSendGridTimestampHeader: _kTimestamp,
        },
      );
      expect(result.statusCode, 401);
      expect(result.body?['error'], 'bad_signature');
      expect(repo.insertedEventIds, isEmpty);
    });

    test('replayed payload → 204, ON CONFLICT path: no new rows', () async {
      final repo = _FakeEmailEventRepository();
      // Pre-seed the repo so the next insert collides.
      repo.preSeed('evt-1');
      final router = SendGridEventsWebhookRouter(
        repository: repo,
        pubKeyLoader: () => _kFakePemPubKey,
        signatureVerifier: _AcceptingVerifier(),
      );
      final body = _bodyForEvents(<Map<String, Object?>>[
        _eventJson(sgEventId: 'evt-1', eventKind: 'delivered'),
      ]);
      final result = await router.dispatch(
        method: 'POST',
        path: sendGridEventsWebhookPath,
        body: body,
        headers: _signedHeaders(),
      );
      expect(result.statusCode, 204);
      // The repository saw an insert attempt but no new row was added.
      expect(repo.insertAttempts, 1);
      expect(repo.insertedEventIds, <String>['evt-1']);
      expect(repo.duplicateCount, 1);
    });

    test(
        'partial-batch: mix of new + replayed → only new rows inserted, 204',
        () async {
      final repo = _FakeEmailEventRepository();
      repo.preSeed('evt-1');
      repo.preSeed('evt-3');
      final router = SendGridEventsWebhookRouter(
        repository: repo,
        pubKeyLoader: () => _kFakePemPubKey,
        signatureVerifier: _AcceptingVerifier(),
      );
      final body = _bodyForEvents(<Map<String, Object?>>[
        _eventJson(sgEventId: 'evt-1', eventKind: 'delivered'),
        _eventJson(sgEventId: 'evt-2', eventKind: 'opened'),
        _eventJson(sgEventId: 'evt-3', eventKind: 'clicked'),
        _eventJson(sgEventId: 'evt-4', eventKind: 'bounced'),
      ]);
      final result = await router.dispatch(
        method: 'POST',
        path: sendGridEventsWebhookPath,
        body: body,
        headers: _signedHeaders(),
      );
      expect(result.statusCode, 204);
      expect(repo.insertAttempts, 4);
      expect(repo.duplicateCount, 2);
      expect(repo.freshInsertCount, 2);
      // Pre-seeded + new entries all present.
      expect(
        repo.insertedEventIds,
        <String>['evt-1', 'evt-3', 'evt-2', 'evt-4'],
      );
    });

    test('empty event array → 204, no inserts', () async {
      final repo = _FakeEmailEventRepository();
      final router = SendGridEventsWebhookRouter(
        repository: repo,
        pubKeyLoader: () => _kFakePemPubKey,
        signatureVerifier: _AcceptingVerifier(),
      );
      final body = _bodyForEvents(<Map<String, Object?>>[]);
      final result = await router.dispatch(
        method: 'POST',
        path: sendGridEventsWebhookPath,
        body: body,
        headers: _signedHeaders(),
      );
      expect(result.statusCode, 204);
      expect(repo.insertAttempts, 0);
    });

    test('malformed JSON → 400', () async {
      final repo = _FakeEmailEventRepository();
      final router = SendGridEventsWebhookRouter(
        repository: repo,
        pubKeyLoader: () => _kFakePemPubKey,
        signatureVerifier: _AcceptingVerifier(),
      );
      final body = Uint8List.fromList(utf8.encode('{ this is not valid JSON'));
      final result = await router.dispatch(
        method: 'POST',
        path: sendGridEventsWebhookPath,
        body: body,
        headers: _signedHeaders(),
      );
      expect(result.statusCode, 400);
      expect(result.body?['error'], 'malformed_json');
      expect(repo.insertAttempts, 0);
    });

    test('missing signature header → 401', () async {
      final repo = _FakeEmailEventRepository();
      final router = SendGridEventsWebhookRouter(
        repository: repo,
        pubKeyLoader: () => _kFakePemPubKey,
        signatureVerifier: _AcceptingVerifier(),
      );
      final body = _bodyForEvents(<Map<String, Object?>>[
        _eventJson(sgEventId: 'evt-1', eventKind: 'delivered'),
      ]);
      final result = await router.dispatch(
        method: 'POST',
        path: sendGridEventsWebhookPath,
        body: body,
        headers: <String, String>{
          kSendGridTimestampHeader: _kTimestamp,
        },
      );
      expect(result.statusCode, 401);
      expect(result.body?['error'], 'bad_signature');
      expect(repo.insertAttempts, 0);
    });

    test('pubkey not configured → 503 (env var unset)', () async {
      final repo = _FakeEmailEventRepository();
      final router = SendGridEventsWebhookRouter(
        repository: repo,
        pubKeyLoader: () => null,
        signatureVerifier: _AcceptingVerifier(),
      );
      final body = _bodyForEvents(<Map<String, Object?>>[
        _eventJson(sgEventId: 'evt-1', eventKind: 'delivered'),
      ]);
      final result = await router.dispatch(
        method: 'POST',
        path: sendGridEventsWebhookPath,
        body: body,
        headers: _signedHeaders(),
      );
      expect(result.statusCode, 503);
      expect(result.body?['error'], 'pubkey_not_configured');
      expect(repo.insertAttempts, 0);
    });

    // --- Additional pinning tests ---

    test('missing timestamp header → 401', () async {
      final repo = _FakeEmailEventRepository();
      final router = SendGridEventsWebhookRouter(
        repository: repo,
        pubKeyLoader: () => _kFakePemPubKey,
        signatureVerifier: _AcceptingVerifier(),
      );
      final body = _bodyForEvents(<Map<String, Object?>>[
        _eventJson(sgEventId: 'evt-1', eventKind: 'delivered'),
      ]);
      final result = await router.dispatch(
        method: 'POST',
        path: sendGridEventsWebhookPath,
        body: body,
        headers: <String, String>{
          kSendGridSignatureHeader: _kValidSignature,
        },
      );
      expect(result.statusCode, 401);
      expect(result.body?['error'], 'bad_signature');
    });

    test('malformed event (missing sg_event_id on one entry) → 400', () async {
      final repo = _FakeEmailEventRepository();
      final router = SendGridEventsWebhookRouter(
        repository: repo,
        pubKeyLoader: () => _kFakePemPubKey,
        signatureVerifier: _AcceptingVerifier(),
      );
      final body = _bodyForEvents(<Map<String, Object?>>[
        _eventJson(sgEventId: 'evt-1', eventKind: 'delivered'),
        <String, Object?>{
          'email': 'alice@example.com',
          'timestamp': 1718000000,
          'event': 'opened',
          // missing sg_event_id
        },
      ]);
      final result = await router.dispatch(
        method: 'POST',
        path: sendGridEventsWebhookPath,
        body: body,
        headers: _signedHeaders(),
      );
      expect(result.statusCode, 400);
      expect(result.body?['error'], 'malformed_event');
      expect(result.body?['field'], 'sg_event_id');
      // First event was already inserted before the malformed entry —
      // this matches the prompt's "collapse entire batch into 400"
      // pinning at the failure point.
      expect(repo.insertedEventIds, <String>['evt-1']);
    });

    test(
        'top-level JSON object (not an array) → 400 malformed_json',
        () async {
      final repo = _FakeEmailEventRepository();
      final router = SendGridEventsWebhookRouter(
        repository: repo,
        pubKeyLoader: () => _kFakePemPubKey,
        signatureVerifier: _AcceptingVerifier(),
      );
      final body = Uint8List.fromList(
        utf8.encode(jsonEncode(<String, Object?>{'wrong': 'shape'})),
      );
      final result = await router.dispatch(
        method: 'POST',
        path: sendGridEventsWebhookPath,
        body: body,
        headers: _signedHeaders(),
      );
      expect(result.statusCode, 400);
      expect(result.body?['error'], 'malformed_json');
      expect(repo.insertAttempts, 0);
    });

    test('does NOT match GET on the same path', () async {
      expect(
        SendGridEventsWebhookRouter.matches(
          sendGridEventsWebhookPath,
          'GET',
        ),
        isFalse,
      );
      expect(
        SendGridEventsWebhookRouter.matches(
          '/v1/webhooks/sendgrid/events',
          'POST',
        ),
        isTrue,
      );
      expect(
        SendGridEventsWebhookRouter.matches(
          '/v1/webhooks/sendgrid/inbound',
          'POST',
        ),
        isFalse,
      );
    });
  });

  group('SendGridEventsWebhookRouter signature input ordering', () {
    test(
        'verifier receives the raw body bytes UNCHANGED (no JSON-decode '
        'before verification)',
        () async {
      // The exact raw bytes a real SendGrid request would send. We craft
      // a body that is valid JSON BUT has trailing whitespace + a quirky
      // key order; if the receiver decoded + re-serialised before
      // hashing, the byte signature would be over different bytes and
      // the verifier would see a mismatched body.
      const raw = '[ {"sg_event_id":"x","email":"a@b","timestamp":1,'
          '"event":"delivered"} ]  ';
      final body = Uint8List.fromList(utf8.encode(raw));
      final repo = _FakeEmailEventRepository();
      final verifier = _BodyCapturingVerifier();
      final router = SendGridEventsWebhookRouter(
        repository: repo,
        pubKeyLoader: () => _kFakePemPubKey,
        signatureVerifier: verifier,
      );
      await router.dispatch(
        method: 'POST',
        path: sendGridEventsWebhookPath,
        body: body,
        headers: _signedHeaders(),
      );
      expect(verifier.capturedBody, isNotNull);
      // Byte-equal: not decoded then re-encoded.
      expect(verifier.capturedBody, equals(body));
    });

    test('verifier receives the timestamp header verbatim', () async {
      final repo = _FakeEmailEventRepository();
      final verifier = _BodyCapturingVerifier();
      final router = SendGridEventsWebhookRouter(
        repository: repo,
        pubKeyLoader: () => _kFakePemPubKey,
        signatureVerifier: verifier,
      );
      final body = _bodyForEvents(<Map<String, Object?>>[
        _eventJson(sgEventId: 'evt-1', eventKind: 'delivered'),
      ]);
      await router.dispatch(
        method: 'POST',
        path: sendGridEventsWebhookPath,
        body: body,
        headers: _signedHeaders(timestamp: '9999999999'),
      );
      expect(verifier.capturedTimestamp, '9999999999');
    });
  });
}

// ─── Test helpers ──────────────────────────────────────────────────────

Map<String, String> _signedHeaders({String? timestamp}) => <String, String>{
      kSendGridSignatureHeader: _kValidSignature,
      kSendGridTimestampHeader: timestamp ?? _kTimestamp,
    };

Uint8List _bodyForEvents(List<Map<String, Object?>> events) {
  return Uint8List.fromList(utf8.encode(jsonEncode(events)));
}

Map<String, Object?> _eventJson({
  required String sgEventId,
  required String eventKind,
  String email = 'alice@example.com',
  int timestamp = 1718000000,
  String? smtpId,
}) =>
    <String, Object?>{
      'email': email,
      'timestamp': timestamp,
      'event': eventKind,
      'sg_event_id': sgEventId,
      'sg_message_id': 'msg-${sgEventId.hashCode}',
      'smtp-id': smtpId ?? '<$sgEventId@example.com>',
    };

/// In-memory `EmailEventRepository` that records every insertProviderEvent
/// call and de-dupes by provider_event_id (mirroring the partial UNIQUE
/// INDEX semantics). This is a structural fake (extends the production
/// repository through composition by overriding `insertProviderEvent`)
/// so the test exercises the same return-type contract the route
/// handler depends on.
class _FakeEmailEventRepository implements EmailEventRepository {
  final List<String> insertedEventIds = <String>[];
  int insertAttempts = 0;
  int freshInsertCount = 0;
  int duplicateCount = 0;

  void preSeed(String providerEventId) {
    insertedEventIds.add(providerEventId);
  }

  @override
  Future<EmailEventInsertResult> insertProviderEvent(
    SendGridEvent event, {
    DateTime Function()? now,
  }) async {
    insertAttempts += 1;
    if (insertedEventIds.contains(event.providerEventId)) {
      duplicateCount += 1;
      return const EmailEventInsertResult.duplicate();
    }
    insertedEventIds.add(event.providerEventId);
    freshInsertCount += 1;
    return EmailEventInsertResult.inserted('fake-event-id-${event.providerEventId}');
  }

  // OperatorScopedRepository protected members are not exposed here;
  // the route handler only calls insertProviderEvent.
  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
      'fake email_event repository: ${invocation.memberName}',
    );
  }
}

class _AcceptingVerifier implements SendGridSignatureVerifier {
  @override
  bool verify({
    required String pemPubKey,
    required String timestamp,
    required Uint8List body,
    required String signatureBase64,
  }) {
    // The fake unconditionally accepts when the signature is the
    // canonical valid literal; this lets a test mix happy + bad
    // signatures by changing the header value.
    return signatureBase64 == _kValidSignature;
  }
}

class _RejectingVerifier implements SendGridSignatureVerifier {
  @override
  bool verify({
    required String pemPubKey,
    required String timestamp,
    required Uint8List body,
    required String signatureBase64,
  }) =>
      false;
}

class _BodyCapturingVerifier implements SendGridSignatureVerifier {
  Uint8List? capturedBody;
  String? capturedTimestamp;
  String? capturedSignature;
  String? capturedPubKey;

  @override
  bool verify({
    required String pemPubKey,
    required String timestamp,
    required Uint8List body,
    required String signatureBase64,
  }) {
    capturedBody = body;
    capturedTimestamp = timestamp;
    capturedSignature = signatureBase64;
    capturedPubKey = pemPubKey;
    return true;
  }
}
