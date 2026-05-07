// Code-health PCACHE-FANOUT — exercises the cross-instance permission
// cache invalidation seam.
//
// The cache itself (LRU + TTL + roles_version key) is covered by the
// existing `test/permission_runtime_test.dart` group. This file pins
// the new bit: a `PermissionCacheInvalidationListener` that consumes
// `permission_cache_invalidate` NOTIFY events and drops the matching
// `userId` from the local in-process cache.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/auth/permission_cache.dart';
import 'package:forge_and_flow/auth/permission_cache_invalidation_listener.dart';
import 'package:forge_and_flow/auth/permission_effect.dart';

const String _userA = '11111111-1111-1111-1111-111111111111';
const String _userB = '22222222-2222-2222-2222-222222222222';
const String _opA = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const String _locA = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';

PermissionSnapshot _snapshot({
  String userId = _userA,
  int rolesVersion = 1,
  String operatorId = _opA,
  String locationId = _locA,
  DateTime? at,
}) {
  return PermissionSnapshot(
    userId: userId,
    rolesVersion: rolesVersion,
    operatorId: operatorId,
    locationId: locationId,
    evaluatedAt: at ?? DateTime.utc(2026, 5, 7, 12),
    entries: const <String, PermissionEffect>{
      'forgeflow.shift.view': PermissionEffect.allow,
    },
  );
}

class _FakeInvalidationSource implements PermissionCacheInvalidationSource {
  _FakeInvalidationSource();

  final StreamController<PermissionCacheInvalidation> _controller =
      StreamController<PermissionCacheInvalidation>.broadcast();
  bool started = false;
  bool stopped = false;

  @override
  Stream<PermissionCacheInvalidation> get notifications => _controller.stream;

  @override
  Future<void> start() async {
    started = true;
  }

  @override
  Future<void> stop() async {
    stopped = true;
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }

  void fire(PermissionCacheInvalidation event) {
    _controller.add(event);
  }

  void fireError(Object error) {
    _controller.addError(error, StackTrace.current);
  }
}

Future<void> _drainMicrotasks() async {
  // Two zero-delay yields are enough for a broadcast stream subscription
  // to deliver a synchronous controller add to its listener.
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  group('PermissionCacheInvalidation.fromPayload', () {
    test('parses a minimal {user_id} payload', () {
      final event = PermissionCacheInvalidation.fromPayload(
        '{"user_id":"$_userA"}',
      );
      expect(event.userId, equals(_userA));
      expect(event.operatorId, isNull);
      expect(event.locationId, isNull);
    });

    test('parses optional operator_id and location_id', () {
      final event = PermissionCacheInvalidation.fromPayload(
        '{"user_id":"$_userA","operator_id":"$_opA","location_id":"$_locA"}',
      );
      expect(event.userId, equals(_userA));
      expect(event.operatorId, equals(_opA));
      expect(event.locationId, equals(_locA));
    });

    test('throws when user_id is missing', () {
      expect(
        () => PermissionCacheInvalidation.fromPayload('{}'),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws when payload is not a JSON object', () {
      expect(
        () => PermissionCacheInvalidation.fromPayload('"just-a-string"'),
        throwsA(isA<FormatException>()),
      );
    });

    test('treats blank optional fields as null', () {
      final event = PermissionCacheInvalidation.fromPayload(
        '{"user_id":"$_userA","operator_id":"   "}',
      );
      expect(event.userId, equals(_userA));
      expect(event.operatorId, isNull);
    });
  });

  group('PermissionCacheInvalidationListener', () {
    test(
      'on NOTIFY, drops every cached snapshot for the matching userId',
      () async {
        final cache = PermissionCache(
          ttl: const Duration(minutes: 10),
          now: () => DateTime.utc(2026, 5, 7, 12),
        );
        cache.put(_snapshot(userId: _userA, rolesVersion: 1));
        cache.put(_snapshot(userId: _userA, rolesVersion: 2));
        cache.put(_snapshot(userId: _userB, rolesVersion: 1));

        final source = _FakeInvalidationSource();
        final listener = PermissionCacheInvalidationListener(
          cache: cache,
          source: source,
        );
        await listener.start();
        expect(source.started, isTrue);

        source.fire(const PermissionCacheInvalidation(userId: _userA));
        await _drainMicrotasks();

        // Both userA snapshots gone; userB snapshot still resident.
        expect(
          cache.read(
            userId: _userA,
            rolesVersion: 1,
            operatorId: _opA,
            locationId: _locA,
          ),
          isNull,
        );
        expect(
          cache.read(
            userId: _userA,
            rolesVersion: 2,
            operatorId: _opA,
            locationId: _locA,
          ),
          isNull,
        );
        expect(
          cache.read(
            userId: _userB,
            rolesVersion: 1,
            operatorId: _opA,
            locationId: _locA,
          ),
          isNotNull,
        );

        await listener.stop();
        expect(source.stopped, isTrue);
      },
    );

    test('start is idempotent — second call does not re-subscribe', () async {
      final cache = PermissionCache(
        ttl: const Duration(minutes: 10),
        now: () => DateTime.utc(2026, 5, 7, 12),
      );
      final source = _FakeInvalidationSource();
      final listener = PermissionCacheInvalidationListener(
        cache: cache,
        source: source,
      );
      await listener.start();
      await listener.start(); // second call must be a no-op

      cache.put(_snapshot(userId: _userA));
      source.fire(const PermissionCacheInvalidation(userId: _userA));
      await _drainMicrotasks();

      // One invalidation occurred (the second start did NOT add a
      // duplicate subscriber). Reading after invalidation is a miss.
      expect(
        cache.read(
          userId: _userA,
          rolesVersion: 1,
          operatorId: _opA,
          locationId: _locA,
        ),
        isNull,
      );

      await listener.stop();
    });

    test(
      'stream errors are swallowed — listener stays alive for the next event',
      () async {
        final cache = PermissionCache(
          ttl: const Duration(minutes: 10),
          now: () => DateTime.utc(2026, 5, 7, 12),
        );
        cache.put(_snapshot(userId: _userA));
        final source = _FakeInvalidationSource();
        final listener = PermissionCacheInvalidationListener(
          cache: cache,
          source: source,
        );
        await listener.start();

        source.fireError(StateError('transient blip'));
        await _drainMicrotasks();

        // Cache untouched by the error.
        expect(
          cache.read(
            userId: _userA,
            rolesVersion: 1,
            operatorId: _opA,
            locationId: _locA,
          ),
          isNotNull,
        );

        // A subsequent valid event still drains.
        source.fire(const PermissionCacheInvalidation(userId: _userA));
        await _drainMicrotasks();
        expect(
          cache.read(
            userId: _userA,
            rolesVersion: 1,
            operatorId: _opA,
            locationId: _locA,
          ),
          isNull,
        );

        await listener.stop();
      },
    );

    test(
      'invalidating an unknown userId is a no-op (no other entries dropped)',
      () async {
        final cache = PermissionCache(
          ttl: const Duration(minutes: 10),
          now: () => DateTime.utc(2026, 5, 7, 12),
        );
        cache.put(_snapshot(userId: _userA));
        cache.put(_snapshot(userId: _userB));

        final source = _FakeInvalidationSource();
        final listener = PermissionCacheInvalidationListener(
          cache: cache,
          source: source,
        );
        await listener.start();

        source.fire(
          const PermissionCacheInvalidation(userId: 'not-in-cache'),
        );
        await _drainMicrotasks();

        expect(
          cache.read(
            userId: _userA,
            rolesVersion: 1,
            operatorId: _opA,
            locationId: _locA,
          ),
          isNotNull,
        );
        expect(
          cache.read(
            userId: _userB,
            rolesVersion: 1,
            operatorId: _opA,
            locationId: _locA,
          ),
          isNotNull,
        );

        await listener.stop();
      },
    );
  });
}
