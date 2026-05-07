// fix(M2.pepper-runtime): PepperResolver tests.
//
// Covers:
//   * EnvPepperResolver — returns the env value; throws when empty
//     and not in demo mode; demo mode returns ''.
//   * ProxyPepperResolver — caches active and by-id lookups with TTL;
//     resolveById returns null for unknown id (404-like response).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/services/auth/pepper_resolver.dart';

void main() {
  group('EnvPepperResolver', () {
    test('resolveActive returns the env pepper value', () async {
      const resolver = EnvPepperResolver(
        pepper: 'test-pepper-abc',
        demoMode: false,
      );
      expect(await resolver.resolveActive(), equals('test-pepper-abc'));
    });

    test(
      'resolveActive throws PepperResolutionException when empty and not demo',
      () async {
        const resolver = EnvPepperResolver(pepper: '', demoMode: false);
        await expectLater(
          resolver.resolveActive(),
          throwsA(isA<PepperResolutionException>()),
        );
      },
    );

    test(
      'resolveActive returns empty string in demo mode when pepper is empty',
      () async {
        const resolver = EnvPepperResolver(pepper: '', demoMode: true);
        expect(await resolver.resolveActive(), isEmpty);
      },
    );

    test(
      'resolveById returns the pepper for any id when pepper is non-empty',
      () async {
        const resolver = EnvPepperResolver(
          pepper: 'some-pepper',
          demoMode: false,
        );
        final result = await resolver.resolveById('sha256:anyid');
        expect(result, equals('some-pepper'));
      },
    );

    test('resolveById returns null when pepper is empty', () async {
      const resolver = EnvPepperResolver(pepper: '', demoMode: true);
      final result = await resolver.resolveById('sha256:anyid');
      expect(result, isNull);
    });
  });

  group('ProxyPepperResolver', () {
    test('caches active pepper result within TTL', () async {
      final http = _FakeHttpClient(
        activeResponse:
            '{"pepper_id":"id1","pepper_b64":"${_b64('hello')}"}',
      );
      final resolver = _buildResolver(
        http: http,
        ttl: const Duration(seconds: 30),
      );

      final first = await resolver.resolveActive();
      final second = await resolver.resolveActive();

      expect(first, equals('hello'));
      expect(second, equals('hello'));
      expect(http.activeGetCount, equals(1),
          reason: 'second call should hit cache, not HTTP');
    });

    test('re-fetches active pepper after TTL expires', () async {
      final http = _FakeHttpClient(
        activeResponse:
            '{"pepper_id":"id1","pepper_b64":"${_b64('hello')}"}',
      );
      final resolver = _buildResolver(
        http: http,
        ttl: const Duration(milliseconds: 1),
      );

      await resolver.resolveActive();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await resolver.resolveActive();

      expect(http.activeGetCount, greaterThanOrEqualTo(2));
    });

    test('resolveById returns null for unknown id (404)', () async {
      final http = _FakeHttpClient(notFoundForById: true);
      final resolver = _buildResolver(http: http);

      final result = await resolver.resolveById('sha256:unknown');
      expect(result, isNull);
    });

    test('resolveById returns cached result within TTL', () async {
      final http = _FakeHttpClient(
        byIdResponse:
            '{"pepper_id":"id2","pepper_b64":"${_b64('world')}"}',
      );
      final resolver = _buildResolver(
        http: http,
        ttl: const Duration(seconds: 30),
      );

      final first = await resolver.resolveById('sha256:id2');
      final second = await resolver.resolveById('sha256:id2');

      expect(first, equals('world'));
      expect(second, equals('world'));
      expect(http.byIdGetCount, equals(1),
          reason: 'second call should hit cache, not HTTP');
    });

    test('active pepper fetch warms by-id cache', () async {
      const pepperId = 'id-warm';
      final http = _FakeHttpClient(
        activeResponse:
            '{"pepper_id":"$pepperId","pepper_b64":"${_b64('warm')}"}',
      );
      final resolver = _buildResolver(
        http: http,
        ttl: const Duration(seconds: 30),
      );

      await resolver.resolveActive();
      final byId = await resolver.resolveById(pepperId);

      expect(byId, equals('warm'));
      expect(http.byIdGetCount, equals(0),
          reason: 'by-id cache should have been warmed by resolveActive');
    });
  });
}

// ─── helpers ──────────────────────────────────────────────────────────

String _b64(String input) => base64Encode(utf8.encode(input));

ProxyPepperResolver _buildResolver({
  required _FakeHttpClient http,
  Duration ttl = const Duration(minutes: 5),
}) {
  return ProxyPepperResolver(
    baseUri: Uri.parse('http://proxy.test'),
    bearerTokenProvider: () async => 'fake-jwt',
    ttl: ttl,
    httpClient: http,
  );
}

class _FakeHttpClient implements PepperHttpClient {
  _FakeHttpClient({
    this.activeResponse,
    this.byIdResponse,
    this.notFoundForById = false,
  });

  final String? activeResponse;
  final String? byIdResponse;
  final bool notFoundForById;

  int activeGetCount = 0;
  int byIdGetCount = 0;

  @override
  Future<String> get(Uri uri, {required String bearerToken}) async {
    final path = uri.path;
    if (path.endsWith('/active')) {
      activeGetCount++;
      final resp = activeResponse;
      if (resp == null) {
        throw PepperResolutionException('no active response configured');
      }
      return resp;
    }
    byIdGetCount++;
    if (notFoundForById) {
      throw PepperResolutionException('pepper not_found: HTTP 404 from $uri');
    }
    final resp = byIdResponse;
    if (resp == null) {
      throw PepperResolutionException('no by-id response configured');
    }
    return resp;
  }
}
