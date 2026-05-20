// 11a.10a — Bearer-token extraction + ProxyRequestGuard tests.
//
// Bucket 5c-token+guard of the 2026-05-20 test-suite tightening audit:
// split out of `test/advisor_proxy_test.dart` (8,328 lines). This file
// holds the `extractBearerToken` helper and the
// `ProxyRequestGuard.requireOperatorContext` middleware path coverage
// (missing auth / bad bearer / verifier-throws / missing operator+location
// claims / happy path).

import 'package:flutter_test/flutter_test.dart';

import '../tool/advisor_proxy/advisor_proxy.dart';
import 'advisor_proxy_test_helpers.dart';

void main() {
  group('extractBearerToken', () {
    test('returns null for missing / blank / non-bearer headers', () {
      expect(extractBearerToken(null), isNull);
      expect(extractBearerToken(''), isNull);
      expect(extractBearerToken('Basic dXNlcjpwYXNz'), isNull);
      // Case-sensitive per RFC 6750.
      expect(extractBearerToken('bearer abcd'), isNull);
      // Empty token after the prefix.
      expect(extractBearerToken('Bearer '), isNull);
      expect(extractBearerToken('Bearer    '), isNull);
    });

    test('extracts and trims the bearer token portion', () {
      expect(extractBearerToken('Bearer abc.def.ghi'), equals('abc.def.ghi'));
      expect(
        extractBearerToken('Bearer   token-with-trailing-spaces   '),
        equals('token-with-trailing-spaces'),
      );
    });
  });

  group('ProxyRequestGuard.requireOperatorContext', () {
    test('rejects missing Authorization with 401', () async {
      final guard = ProxyRequestGuard(verifier: AlwaysOkVerifier());

      ProxyAuthError? thrown;
      try {
        await guard.requireOperatorContext(authorizationHeader: null);
      } on ProxyAuthError catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      expect(thrown!.statusCode, equals(401));
      expect(thrown.message, contains('Authorization'));
    });

    test('rejects malformed bearer with 401', () async {
      final guard = ProxyRequestGuard(verifier: AlwaysOkVerifier());

      ProxyAuthError? thrown;
      try {
        await guard.requireOperatorContext(
          authorizationHeader: 'Basic dXNlcjpwYXNz',
        );
      } on ProxyAuthError catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      expect(thrown!.statusCode, equals(401));
    });

    test('translates verifier failure into 401', () async {
      final guard = ProxyRequestGuard(
        verifier: RaisingVerifier('signature mismatch'),
      );

      ProxyAuthError? thrown;
      try {
        await guard.requireOperatorContext(
          authorizationHeader: 'Bearer fake.token.value',
        );
      } on ProxyAuthError catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      expect(thrown!.statusCode, equals(401));
      expect(thrown.message, contains('verification failed'));
      expect(thrown.message, contains('signature mismatch'));
    });

    test('rejects verified token without operator scope (403)', () async {
      final guard = ProxyRequestGuard(
        verifier: FixedClaimsVerifier(
          const ProxyJwtClaims(
            userId: 'user_123',
            operatorId: null,
            locationId: 'loc_999',
            roles: <String>[],
          ),
        ),
      );

      ProxyAuthError? thrown;
      try {
        await guard.requireOperatorContext(
          authorizationHeader: 'Bearer fake.token.value',
        );
      } on ProxyAuthError catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      expect(thrown!.statusCode, equals(403));
      expect(thrown.message, contains('operator'));
    });

    test('rejects verified token without location scope (403)', () async {
      final guard = ProxyRequestGuard(
        verifier: FixedClaimsVerifier(
          const ProxyJwtClaims(
            userId: 'user_123',
            operatorId: 'op_777',
            locationId: '',
            roles: <String>['advisor.read'],
          ),
        ),
      );

      ProxyAuthError? thrown;
      try {
        await guard.requireOperatorContext(
          authorizationHeader: 'Bearer fake.token.value',
        );
      } on ProxyAuthError catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      expect(thrown!.statusCode, equals(403));
    });

    test('happy path returns scoped OperatorContext with userId / operator / '
        'location / roles', () async {
      final guard = ProxyRequestGuard(
        verifier: FixedClaimsVerifier(
          const ProxyJwtClaims(
            userId: 'user_123',
            operatorId: 'op_777',
            locationId: 'loc_999',
            roles: <String>['advisor.read', 'methodology.read'],
          ),
        ),
      );

      final context = await guard.requireOperatorContext(
        authorizationHeader: 'Bearer fake.token.value',
      );

      expect(context.userId, equals('user_123'));
      expect(context.operatorId, equals('op_777'));
      expect(context.locationId, equals('loc_999'));
      expect(
        context.roles,
        equals(<String>['advisor.read', 'methodology.read']),
      );
      expect(context.hasRole('advisor.read'), isTrue);
      expect(context.hasRole('admin.write'), isFalse);
    });

    test(
      'verified claims path allows global admin tokens without tenant scope',
      () async {
        final guard = ProxyRequestGuard(
          verifier: FixedClaimsVerifier(
            const ProxyJwtClaims(
              userId: 'admin_user',
              operatorId: null,
              locationId: null,
              roles: <String>['super_admin'],
            ),
          ),
        );

        final claims = await guard.requireVerifiedClaims(
          authorizationHeader: 'Bearer fake.token.value',
        );

        expect(claims.userId, equals('admin_user'));
        expect(claims.operatorId, isNull);
        expect(claims.locationId, isNull);
        expect(claims.roles, contains('super_admin'));
      },
    );

    test('B1 — accepts scope-less ff_support tokens with empty operator '
        'and location strings', () async {
      final guard = ProxyRequestGuard(
        verifier: FixedClaimsVerifier(
          const ProxyJwtClaims(
            userId: 'support_user',
            operatorId: null,
            locationId: null,
            roles: <String>['ff_support'],
          ),
        ),
      );

      final context = await guard.requireOperatorContext(
        authorizationHeader: 'Bearer fake.token.value',
      );

      expect(context.userId, equals('support_user'));
      expect(context.operatorId, equals(''));
      expect(context.locationId, equals(''));
      expect(context.roles, contains('ff_support'));
    });

    test('B1 — accepts scope-less super_admin tokens with empty operator '
        'and location strings', () async {
      final guard = ProxyRequestGuard(
        verifier: FixedClaimsVerifier(
          const ProxyJwtClaims(
            userId: 'admin_user',
            operatorId: null,
            locationId: null,
            roles: <String>['super_admin'],
          ),
        ),
      );

      final context = await guard.requireOperatorContext(
        authorizationHeader: 'Bearer fake.token.value',
      );

      expect(context.userId, equals('admin_user'));
      expect(context.operatorId, equals(''));
      expect(context.locationId, equals(''));
      expect(context.roles, contains('super_admin'));
    });

    test('B1 — non-admin scope-less tokens still 403 with structured log '
        'context (unchanged contract for tenant-scoped users)', () async {
      final guard = ProxyRequestGuard(
        verifier: FixedClaimsVerifier(
          const ProxyJwtClaims(
            userId: 'tenant_user',
            operatorId: null,
            locationId: null,
            roles: <String>['advisor.read'],
          ),
        ),
      );

      ProxyAuthError? thrown;
      try {
        await guard.requireOperatorContext(
          authorizationHeader: 'Bearer fake.token.value',
        );
      } on ProxyAuthError catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      expect(thrown!.statusCode, equals(403));
      expect(thrown.message, contains('operator'));
    });

    test('B1 — global admin with partial operator scope still falls through '
        'the global-admin accept branch (tolerant of either scope being '
        'present)', () async {
      final guard = ProxyRequestGuard(
        verifier: FixedClaimsVerifier(
          const ProxyJwtClaims(
            userId: 'support_user',
            operatorId: 'op_777',
            locationId: null,
            roles: <String>['ff_support'],
          ),
        ),
      );

      final context = await guard.requireOperatorContext(
        authorizationHeader: 'Bearer fake.token.value',
      );

      // Operator id surfaces because the JWT carried it; the
      // location id stays empty per the global-admin contract.
      expect(context.operatorId, equals('op_777'));
      expect(context.locationId, equals(''));
      expect(context.roles, contains('ff_support'));
    });
  });

}
