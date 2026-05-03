// Phase 11A.5 — Debug console admin gateway tests.
//
// Coverage on the in-memory gateway (the launch surface ships
// without a live proxy, so the in-memory shape is the contract the
// screen widget tests rely on):
//
//   * `listRequests` — every filter axis (operator, location,
//     usage_class, status, time-window, search) AND-filters together
//     and the result is sorted started_at desc with a bounded limit.
//   * `getByRequestId` and `getByIdempotencyKey` — exact-match
//     lookups; null on miss.
//   * `tailRecent` — most-recent-first slice bounded by `limit`.
//   * `listFullContentOptIns` — opt-in projections sorted by
//     operator_id.
//   * `RequestLogFilter.matches` — the same matcher the proxy will
//     emulate; pinned here so a future schema bump cannot quietly
//     drift the screen.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/admin/models/debug_console_admin_models.dart';
import 'package:forge_and_flow/admin/services/debug_console_admin_gateway.dart';

void main() {
  RequestLogEntry entry({
    required String id,
    required String operatorId,
    String? locationId,
    String usageClass = 'advisor_qa',
    RequestLogStatus status = RequestLogStatus.success,
    DateTime? startedAt,
    int latencyMs = 100,
    String idempotencyKey = '',
    bool fullContentOptInOn = false,
    Map<String, Object?>? fullContent,
  }) {
    return RequestLogEntry(
      requestId: id,
      idempotencyKey: idempotencyKey.isEmpty ? 'idem-$id' : idempotencyKey,
      operatorId: operatorId,
      locationId: locationId,
      usageClass: usageClass,
      status: status,
      startedAt: startedAt ?? DateTime.utc(2026, 5, 3, 11, 30),
      latencyMs: latencyMs,
      requestMeta: const <String, Object?>{'route': '/v1/test'},
      fullContentOptInOn: fullContentOptInOn,
      fullContentPayload: fullContent,
    );
  }

  group('RequestLogFilter.matches', () {
    final base = entry(
      id: 'req-1',
      operatorId: 'op-A',
      locationId: 'loc-1',
      usageClass: 'advisor_qa',
      status: RequestLogStatus.success,
      startedAt: DateTime.utc(2026, 5, 3, 11, 30),
      idempotencyKey: 'idem-foo-001',
    );

    test('empty filter matches every entry', () {
      const filter = RequestLogFilter();
      expect(filter.isEmpty, isTrue);
      expect(filter.matches(base), isTrue);
    });

    test('operator filter rejects mismatched rows', () {
      const filter = RequestLogFilter(operatorId: 'op-B');
      expect(filter.matches(base), isFalse);
    });

    test('location filter rejects mismatched rows', () {
      const filter = RequestLogFilter(locationId: 'loc-other');
      expect(filter.matches(base), isFalse);
    });

    test('usage_class filter rejects mismatched rows', () {
      const filter = RequestLogFilter(usageClass: 'wf_pl');
      expect(filter.matches(base), isFalse);
    });

    test('status filter rejects mismatched rows', () {
      const filter = RequestLogFilter(status: RequestLogStatus.error);
      expect(filter.matches(base), isFalse);
    });

    test('time_window rejects rows older than the window', () {
      const filter = RequestLogFilter(timeWindow: RequestLogTimeWindow.last5m);
      // base.startedAt is 11:30; reference 11:40 → row 10m old → drop.
      expect(
        filter.matches(base, now: DateTime.utc(2026, 5, 3, 11, 40)),
        isFalse,
      );
    });

    test('time_window keeps rows inside the window', () {
      const filter = RequestLogFilter(timeWindow: RequestLogTimeWindow.last1h);
      expect(
        filter.matches(base, now: DateTime.utc(2026, 5, 3, 11, 40)),
        isTrue,
      );
    });

    test('search matches request_id substring', () {
      const filter = RequestLogFilter(searchText: 'req-1');
      expect(filter.matches(base), isTrue);
    });

    test('search matches idempotency_key substring', () {
      const filter = RequestLogFilter(searchText: 'foo');
      expect(filter.matches(base), isTrue);
    });

    test('search rejects when neither id nor key match', () {
      const filter = RequestLogFilter(searchText: 'no-such-needle');
      expect(filter.matches(base), isFalse);
    });

    test('AND-filter: every populated axis must hold', () {
      const filter = RequestLogFilter(
        operatorId: 'op-A',
        usageClass: 'advisor_qa',
        status: RequestLogStatus.success,
      );
      expect(filter.matches(base), isTrue);
      const stricter = RequestLogFilter(
        operatorId: 'op-A',
        usageClass: 'advisor_qa',
        status: RequestLogStatus.error, // mismatched
      );
      expect(stricter.matches(base), isFalse);
    });
  });

  group('InMemoryDebugConsoleAdminGateway', () {
    final older = entry(
      id: 'req-older',
      operatorId: 'op-A',
      startedAt: DateTime.utc(2026, 5, 3, 10),
      idempotencyKey: 'idem-old',
    );
    final newer = entry(
      id: 'req-newer',
      operatorId: 'op-A',
      startedAt: DateTime.utc(2026, 5, 3, 12),
      idempotencyKey: 'idem-new',
    );
    final foreign = entry(
      id: 'req-foreign',
      operatorId: 'op-B',
      locationId: 'loc-foreign',
      usageClass: 'wf_pl',
      status: RequestLogStatus.error,
      startedAt: DateTime.utc(2026, 5, 3, 11, 45),
      idempotencyKey: 'idem-foreign',
    );

    test('listRequests sorts started_at desc and respects limit', () async {
      final gateway = InMemoryDebugConsoleAdminGateway(
        seed: <RequestLogEntry>[older, foreign, newer],
        now: () => DateTime.utc(2026, 5, 3, 12, 30),
      );
      final all = await gateway.listRequests(const RequestLogFilter());
      expect(all.map((e) => e.requestId).toList(), <String>[
        'req-newer',
        'req-foreign',
        'req-older',
      ]);
      final limited = await gateway.listRequests(
        const RequestLogFilter(),
        limit: 2,
      );
      expect(limited.map((e) => e.requestId).toList(), <String>[
        'req-newer',
        'req-foreign',
      ]);
    });

    test('listRequests narrows by operator_id', () async {
      final gateway = InMemoryDebugConsoleAdminGateway(
        seed: <RequestLogEntry>[older, foreign, newer],
        now: () => DateTime.utc(2026, 5, 3, 12, 30),
      );
      final scoped = await gateway.listRequests(
        const RequestLogFilter(operatorId: 'op-B'),
      );
      expect(
        scoped.map((e) => e.requestId).toList(),
        <String>['req-foreign'],
      );
    });

    test('listRequests narrows by status + time-window', () async {
      final gateway = InMemoryDebugConsoleAdminGateway(
        seed: <RequestLogEntry>[older, foreign, newer],
        now: () => DateTime.utc(2026, 5, 3, 12, 30),
      );
      final scoped = await gateway.listRequests(
        const RequestLogFilter(
          status: RequestLogStatus.error,
          timeWindow: RequestLogTimeWindow.last1h,
        ),
      );
      // foreign row is the only error AND inside the 1h window from 12:30.
      expect(scoped.map((e) => e.requestId).toList(), <String>['req-foreign']);
    });

    test('listRequests narrows by free-form search across id and key',
        () async {
      final gateway = InMemoryDebugConsoleAdminGateway(
        seed: <RequestLogEntry>[older, foreign, newer],
        now: () => DateTime.utc(2026, 5, 3, 12, 30),
      );
      final byId = await gateway.listRequests(
        const RequestLogFilter(searchText: 'newer'),
      );
      expect(byId.map((e) => e.requestId).toList(), <String>['req-newer']);
      final byKey = await gateway.listRequests(
        const RequestLogFilter(searchText: 'foreign'),
      );
      expect(byKey.map((e) => e.requestId).toList(), <String>['req-foreign']);
    });

    test('getByRequestId returns the row or null', () async {
      final gateway = InMemoryDebugConsoleAdminGateway(
        seed: <RequestLogEntry>[older, newer],
      );
      expect((await gateway.getByRequestId('req-newer'))?.requestId,
          equals('req-newer'));
      expect(await gateway.getByRequestId('req-missing'), isNull);
    });

    test('getByIdempotencyKey returns the row or null', () async {
      final gateway = InMemoryDebugConsoleAdminGateway(
        seed: <RequestLogEntry>[older, newer],
      );
      expect((await gateway.getByIdempotencyKey('idem-new'))?.requestId,
          equals('req-newer'));
      expect(await gateway.getByIdempotencyKey('idem-missing'), isNull);
    });

    test('tailRecent returns most-recent-first bounded by limit', () async {
      final gateway = InMemoryDebugConsoleAdminGateway(
        seed: <RequestLogEntry>[older, foreign, newer],
      );
      final tailed = await gateway.tailRecent(limit: 2);
      expect(tailed.map((e) => e.requestId).toList(), <String>[
        'req-newer',
        'req-foreign',
      ]);
    });

    test('listFullContentOptIns sorts by operator_id', () async {
      final gateway = InMemoryDebugConsoleAdminGateway(
        seed: const <RequestLogEntry>[],
        optInSeed: <FullContentOptIn>[
          FullContentOptIn(
            operatorId: 'op-Z',
            flagName: kDebugConsoleFullContentFlagName,
            enabled: true,
            updatedAt: DateTime.utc(2026, 5, 1),
          ),
          FullContentOptIn(
            operatorId: 'op-A',
            flagName: kDebugConsoleFullContentFlagName,
            enabled: false,
            updatedAt: DateTime.utc(2026, 5, 2),
          ),
        ],
      );
      final optIns = await gateway.listFullContentOptIns();
      expect(
        optIns.map((o) => o.operatorId).toList(),
        <String>['op-A', 'op-Z'],
      );
      expect(optIns.first.enabled, isFalse);
      expect(optIns.last.enabled, isTrue);
    });

    test('appendEntry surfaces a new row through tailRecent', () async {
      final gateway = InMemoryDebugConsoleAdminGateway(
        seed: <RequestLogEntry>[older],
      );
      gateway.appendEntry(newer);
      final tailed = await gateway.tailRecent();
      expect(tailed.first.requestId, equals('req-newer'));
    });
  });

  group('Demo seed', () {
    test('kDebugConsoleDemoEntries has at least one error/timeout/success', () {
      final statuses = kDebugConsoleDemoEntries
          .map((e) => e.status)
          .toSet();
      expect(statuses, contains(RequestLogStatus.success));
      expect(statuses, contains(RequestLogStatus.error));
      expect(statuses, contains(RequestLogStatus.timeout));
    });

    test('kDebugConsoleDemoOptIns covers both operator IDs in the entries seed',
        () {
      final operatorIds =
          kDebugConsoleDemoEntries.map((e) => e.operatorId).toSet();
      final optInOperators =
          kDebugConsoleDemoOptIns.map((o) => o.operatorId).toSet();
      // Every operator that appears in entries should also have a
      // corresponding opt-in projection — the screen reads opt-in by
      // operator_id and a missing entry would silently default to off.
      expect(optInOperators.containsAll(operatorIds), isTrue);
    });

    test('exactly one demo opt-in is enabled (Demo Diner)', () {
      final enabled = kDebugConsoleDemoOptIns.where((o) => o.enabled).toList();
      expect(enabled, hasLength(1));
      expect(
        enabled.single.operatorId,
        equals('00000000-0000-4000-8000-000000000001'),
      );
    });
  });
}
