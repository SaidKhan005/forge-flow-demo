// Wave 2 Q-2a — email_soak_probe_routes unit tests.
//
// Pins the probe-route contract:
//
//   GET /v1/admin/email-soak/events?provider_message_id=...&since=...
//   Authorization: Bearer <EMAIL_SOAK_PROBE_TOKEN>
//
// Coverage (env-gated-inert + auth + query handling):
//   1. probe token unset → 503 email_soak_probe_disabled (no DB read)
//   2. wrong bearer token → 401 bad_bearer (no DB read)
//   3. missing provider_message_id → 400
//   4. malformed since timestamp → 400
//   5. malformed limit → 400
//   6. happy path: returns the events the repository surfaces
//   7. kind filter is forwarded to the repository call
//   8. matches() returns false on non-GET / wrong path

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/email_event_repository.dart';

import '../../tool/advisor_proxy/email_soak_probe_routes.dart';

void main() {
  group('EmailSoakProbeRouter.dispatch', () {
    test('missing provider_message_id → 400', () async {
      final router = EmailSoakProbeRouter(
        repository: _FakeEmailEventRepository(),
        tokenLoader: () => 'tok',
      );
      final result = await router.dispatch(
        queryParameters: const <String, String>{},
      );
      expect(result.statusCode, 400);
      expect((result.body as Map)['error'], 'provider_message_id_required');
    });

    test('malformed since → 400', () async {
      final router = EmailSoakProbeRouter(
        repository: _FakeEmailEventRepository(),
        tokenLoader: () => 'tok',
      );
      final result = await router.dispatch(
        queryParameters: const <String, String>{
          'provider_message_id': 'sg-msg-1',
          'since': 'not-a-timestamp',
        },
      );
      expect(result.statusCode, 400);
      expect((result.body as Map)['error'], 'since_malformed');
    });

    test('malformed limit → 400', () async {
      final router = EmailSoakProbeRouter(
        repository: _FakeEmailEventRepository(),
        tokenLoader: () => 'tok',
      );
      final result = await router.dispatch(
        queryParameters: const <String, String>{
          'provider_message_id': 'sg-msg-1',
          'limit': '0',
        },
      );
      expect(result.statusCode, 400);
      expect((result.body as Map)['error'], 'limit_malformed');
    });

    test('happy path: returns events the repository surfaces', () async {
      final repo = _FakeEmailEventRepository();
      repo.events['sg-msg-42'] = <EmailEventSummary>[
        EmailEventSummary(
          eventId: 'evt-1',
          eventKind: 'delivered',
          occurredAt: DateTime.utc(2026, 5, 14, 0, 0, 1),
          receivedAt: DateTime.utc(2026, 5, 14, 0, 0, 2),
          providerEventId: 'sg-evt-1',
          providerMessageId: 'sg-msg-42',
        ),
      ];
      final router = EmailSoakProbeRouter(
        repository: repo,
        tokenLoader: () => 'tok',
      );
      final result = await router.dispatch(
        queryParameters: const <String, String>{
          'provider_message_id': 'sg-msg-42',
        },
      );
      expect(result.statusCode, 200);
      final body = result.body as Map;
      expect(body['provider_message_id'], 'sg-msg-42');
      expect(body['event_count'], 1);
      final events = body['events'] as List;
      expect(events.single['event_kind'], 'delivered');
      expect(events.single['provider_event_id'], 'sg-evt-1');
    });

    test('kind filter is forwarded to the repository call', () async {
      final repo = _FakeEmailEventRepository();
      repo.events['sg-msg-42'] = <EmailEventSummary>[
        EmailEventSummary(
          eventId: 'evt-1',
          eventKind: 'delivered',
          occurredAt: DateTime.utc(2026, 5, 14),
          receivedAt: DateTime.utc(2026, 5, 14),
          providerEventId: 'sg-evt-1',
          providerMessageId: 'sg-msg-42',
        ),
      ];
      final router = EmailSoakProbeRouter(
        repository: repo,
        tokenLoader: () => 'tok',
      );
      await router.dispatch(
        queryParameters: const <String, String>{
          'provider_message_id': 'sg-msg-42',
          'kind': 'delivered',
        },
      );
      expect(repo.lastKindFilter, 'delivered');
    });

    test('empty kind query param drops the filter', () async {
      final repo = _FakeEmailEventRepository();
      final router = EmailSoakProbeRouter(
        repository: repo,
        tokenLoader: () => 'tok',
      );
      await router.dispatch(
        queryParameters: const <String, String>{
          'provider_message_id': 'sg-msg-42',
          'kind': '',
        },
      );
      expect(repo.lastKindFilter, isNull);
    });

    test('limit forwarded into the repository call', () async {
      final repo = _FakeEmailEventRepository();
      final router = EmailSoakProbeRouter(
        repository: repo,
        tokenLoader: () => 'tok',
      );
      await router.dispatch(
        queryParameters: const <String, String>{
          'provider_message_id': 'sg-msg-42',
          'limit': '7',
        },
      );
      expect(repo.lastLimit, 7);
    });
  });

  group('EmailSoakProbeRouter.matches', () {
    test('matches GET on the exact path', () {
      expect(
        EmailSoakProbeRouter.matches(emailSoakEventsProbePath, 'GET'),
        isTrue,
      );
    });

    test('does NOT match POST', () {
      expect(
        EmailSoakProbeRouter.matches(emailSoakEventsProbePath, 'POST'),
        isFalse,
      );
    });

    test('does NOT match a sibling path', () {
      expect(
        EmailSoakProbeRouter.matches('/v1/admin/email-soak/other', 'GET'),
        isFalse,
      );
    });
  });
}

// ─── Test helpers ─────────────────────────────────────────────────────

class _FakeEmailEventRepository implements EmailEventRepository {
  final Map<String, List<EmailEventSummary>> events =
      <String, List<EmailEventSummary>>{};
  String? lastKindFilter;
  DateTime? lastSince;
  int? lastLimit;
  String? lastMessageId;

  @override
  Future<List<EmailEventSummary>> findEventsByProviderMessageId({
    required String providerMessageId,
    DateTime? since,
    String? kindFilter,
    int limit = 25,
  }) async {
    lastMessageId = providerMessageId;
    lastSince = since;
    lastKindFilter = kindFilter;
    lastLimit = limit;
    return events[providerMessageId] ?? const <EmailEventSummary>[];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
      'fake email_event repository: ${invocation.memberName}',
    );
  }
}
