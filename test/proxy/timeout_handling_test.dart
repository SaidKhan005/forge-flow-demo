// HARD-G observability — outbound timeout enforcement.
//
// Verifies that the Postgres adapter wraps `beginTransaction` and
// every per-statement call in `.timeout(...)`, surfaces the failure
// as the typed [DependencyTimeoutException] (so the route layer can
// emit the contract-pinned `dependency_timeout` envelope), and that
// the HIBP screener still maps a slow fetcher to
// `screenerUnavailable` (the contract's fail-open behavior).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/package_postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/services/auth/firebase_admin_auth_client.dart';
import 'package:forge_and_flow/services/auth/hibp_pwned_password_screener.dart';
import 'package:forge_and_flow/services/observability/dependency_timeout_exception.dart';
import 'package:postgres/postgres.dart' as pg;

class _HangingConnection implements PackagePostgresConnection {
  _HangingConnection({required this.delay});

  final Duration delay;
  bool closed = false;

  @override
  Future<pg.Result> execute(
    Object query, {
    Object? parameters,
    bool ignoreRows = false,
  }) async {
    await Future<void>.delayed(delay);
    throw StateError('the timeout should have fired before this point');
  }

  @override
  Future<void> close({bool force = false}) async {
    closed = true;
  }
}

class _TimeoutHibpFetcher implements HibpRangeFetcher {
  @override
  Future<String> fetchRange(String hexPrefix) {
    return Future<String>.delayed(const Duration(seconds: 2))
        .timeout(const Duration(milliseconds: 50));
  }
}

void main() {
  group('Postgres acquire-connection timeout', () {
    test('beginTransaction throws DependencyTimeoutException when '
        'openConnection exceeds the acquire budget', () async {
      final pool = PackagePostgresPool(
        openConnection: () async {
          await Future<void>.delayed(const Duration(seconds: 2));
          return _HangingConnection(delay: const Duration(seconds: 2));
        },
        acquireConnectionTimeout: const Duration(milliseconds: 50),
        perStatementTimeout: const Duration(seconds: 5),
      );
      Object? thrown;
      try {
        await pool.beginTransaction();
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<DependencyTimeoutException>());
      final timeout = thrown! as DependencyTimeoutException;
      expect(timeout.surface, equals('postgres'));
      expect(timeout.operation, equals('acquire_connection'));
      expect(timeout.elapsedMs, equals(50));
    });
  });

  group('Postgres per-statement timeout', () {
    test('beginTransaction throws DependencyTimeoutException when the '
        'BEGIN statement hangs past the per-statement budget',
        () async {
      final connection = _HangingConnection(
        delay: const Duration(seconds: 2),
      );
      final pool = PackagePostgresPool(
        openConnection: () async => connection,
        acquireConnectionTimeout: const Duration(seconds: 5),
        perStatementTimeout: const Duration(milliseconds: 50),
      );
      Object? thrown;
      try {
        await pool.beginTransaction();
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<DependencyTimeoutException>());
      final timeout = thrown! as DependencyTimeoutException;
      expect(timeout.surface, equals('postgres'));
      expect(timeout.operation, equals('begin'));
      expect(connection.closed, isTrue,
          reason: 'connection must be force-closed on timeout');
    });
  });

  group('Postgres timeout constants', () {
    test('contract-pinned defaults match the contract values', () {
      expect(
        kPostgresPerStatementTimeout,
        equals(const Duration(seconds: 5)),
      );
      expect(
        kPostgresAcquireConnectionTimeout,
        equals(const Duration(seconds: 10)),
      );
    });
  });

  group('DependencyTimeoutException envelope', () {
    test('exposes surface, operation, elapsed_ms', () {
      const exception = DependencyTimeoutException(
        surface: 'postgres',
        operation: 'query',
        elapsedMs: 5000,
      );
      expect(exception.surface, equals('postgres'));
      expect(exception.operation, equals('query'));
      expect(exception.elapsedMs, equals(5000));
      expect(
        exception.toString(),
        contains('postgres'),
      );
    });
  });

  group('Firebase Identity Toolkit timeout', () {
    test('a slow Firebase POST surfaces as DependencyTimeoutException '
        'with surface=firebase', () async {
      final client = IdentityToolkitFirebaseAdminAuthClient(
        projectId: 'forge-flow-test',
        apiKey: 'placeholder-key',
        accessTokenProvider: const _StaticToken('oauth-token'),
        httpClient: _HangingHttpClient(),
        timeout: const Duration(milliseconds: 50),
      );
      Object? thrown;
      try {
        await client.setDisabled(uid: 'user-1', disabled: true);
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<DependencyTimeoutException>());
      final timeout = thrown! as DependencyTimeoutException;
      expect(timeout.surface, equals('firebase'));
      expect(timeout.operation, contains('accounts'));
      expect(timeout.elapsedMs, equals(50));
    });

    test('a slow Firebase resetPassword (api-key path) surfaces as '
        'DependencyTimeoutException with surface=firebase', () async {
      final client = IdentityToolkitFirebaseAdminAuthClient(
        projectId: 'forge-flow-test',
        apiKey: 'placeholder-key',
        accessTokenProvider: const _StaticToken('oauth-token'),
        httpClient: _HangingHttpClient(),
        timeout: const Duration(milliseconds: 50),
      );
      Object? thrown;
      try {
        await client.confirmPasswordReset(
          oobCode: 'oob-1',
          newPassword: 'p@ssword!',
        );
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<DependencyTimeoutException>());
      final timeout = thrown! as DependencyTimeoutException;
      expect(timeout.surface, equals('firebase'));
    });
  });

  group('HIBP screener fail-open on timeout', () {
    test('a fetcher that throws TimeoutException maps to '
        'screenerUnavailable (fail-open)', () async {
      final screener = HibpPwnedPasswordScreener(
        fetcher: _TimeoutHibpFetcher(),
      );
      final result = await screener.screen('correct horse battery staple');
      expect(result, equals(PwnedPasswordResult.screenerUnavailable));
    });

    test('a fetcher that throws DependencyTimeoutException is also '
        'caught by the screener and surfaces as screenerUnavailable '
        '(fail-open contract)', () async {
      final screener = HibpPwnedPasswordScreener(
        fetcher: _DependencyTimeoutHibpFetcher(),
      );
      final result = await screener.screen('correct horse battery staple');
      expect(result, equals(PwnedPasswordResult.screenerUnavailable));
    });

    test('default HttpHibpRangeFetcher constructs without arguments '
        '(contract-pinned 15s timeout default lives inside the class)',
        () {
      // Sanity check that the default constructor still wires up
      // without callers having to thread the timeout through.
      final fetcher = HttpHibpRangeFetcher();
      expect(fetcher, isNotNull);
    });
  });
}

class _DependencyTimeoutHibpFetcher implements HibpRangeFetcher {
  @override
  Future<String> fetchRange(String hexPrefix) {
    throw const DependencyTimeoutException(
      surface: 'hibp',
      operation: 'range_fetch',
      elapsedMs: 15000,
    );
  }
}

class _StaticToken implements OAuthAccessTokenProvider {
  const _StaticToken(this._token);

  final String _token;

  @override
  Future<String> accessToken() async => _token;
}

/// HttpClient stand-in whose `postUrl` future never completes,
/// triggering the `.timeout(Duration)` wrapper inside the
/// IdentityToolkitFirebaseAdminAuthClient. Each call returns a
/// request stub whose `close()` future also hangs forever in case
/// the request reaches that path before the outer timeout fires.
class _HangingHttpClient implements HttpClient {
  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    await Future<void>.delayed(const Duration(seconds: 5));
    return _NoopHttpClientRequest(url);
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoopHttpClientRequest implements HttpClientRequest {
  _NoopHttpClientRequest(this.uri);

  @override
  final Uri uri;

  @override
  final HttpHeaders headers = _NoopHttpHeaders();

  @override
  int contentLength = -1;

  @override
  void add(List<int> data) {}

  @override
  Future<HttpClientResponse> close() async {
    await Future<void>.delayed(const Duration(seconds: 5));
    throw StateError('the timeout should have fired before close completes');
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoopHttpHeaders implements HttpHeaders {
  @override
  ContentType? contentType;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

