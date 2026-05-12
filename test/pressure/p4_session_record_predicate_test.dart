// Tests for the shared `SessionRecordCompleteness.assertComplete`
// predicate used by the p4 soak harnesses + (future) production
// observability gauge.

import 'package:flutter_test/flutter_test.dart';

import '../../tool/pressure/p4_session_record_predicate.dart';

void main() {
  group('SessionRecordCompleteness.assertComplete', () {
    test('tenant-scoped: all four fields non-empty → complete', () {
      final result = SessionRecordCompleteness.assertComplete(
        <String, Object?>{
          'session_id': 'sess_123',
          'user_id': 'user_a',
          'operator_id': 'op_777',
          'location_id': 'loc_999',
        },
        roles: <String>{},
      );

      expect(result.complete, isTrue);
      expect(result.missingFields, isEmpty);
      expect(result.unexpectedFields, isEmpty);
    });

    test('tenant-scoped: missing operator_id → incomplete', () {
      final result = SessionRecordCompleteness.assertComplete(
        <String, Object?>{
          'session_id': 'sess_123',
          'user_id': 'user_a',
          'operator_id': '',
          'location_id': 'loc_999',
        },
        roles: <String>{},
      );

      expect(result.complete, isFalse);
      expect(result.missingFields, contains('operator_id'));
    });

    test('tenant-scoped: missing user_id and location_id → both reported', () {
      final result = SessionRecordCompleteness.assertComplete(
        <String, Object?>{
          'session_id': 'sess_123',
          'operator_id': 'op_777',
        },
        roles: <String>{'advisor.read'},
      );

      expect(result.complete, isFalse);
      expect(result.missingFields, containsAll(<String>[
        'user_id',
        'location_id',
      ]));
    });

    test(
      'ff_support: session_id + user_id non-empty AND operator/location '
      'empty → complete',
      () {
        final result = SessionRecordCompleteness.assertComplete(
          <String, Object?>{
            'session_id': 'sess_abc',
            'user_id': 'support_user',
            'operator_id': '',
            'location_id': '',
          },
          roles: <String>{'ff_support'},
        );

        expect(result.complete, isTrue);
      },
    );

    test(
      'ff_support: operator_id non-empty → unexpected_fields populated',
      () {
        final result = SessionRecordCompleteness.assertComplete(
          <String, Object?>{
            'session_id': 'sess_abc',
            'user_id': 'support_user',
            'operator_id': 'op_777',
            'location_id': '',
          },
          roles: <String>{'ff_support'},
        );

        expect(result.complete, isFalse);
        expect(result.unexpectedFields, contains('operator_id'));
      },
    );

    test('super_admin uses same global-admin contract as ff_support', () {
      final result = SessionRecordCompleteness.assertComplete(
        <String, Object?>{
          'session_id': 'sess_abc',
          'user_id': 'admin_user',
          'operator_id': '',
          'location_id': '',
        },
        roles: <String>{'super_admin'},
      );

      expect(result.complete, isTrue);
    });

    test('user with both global-admin AND tenant roles uses admin contract',
        () {
      // Defensive contract pin: any global admin role lights up the
      // global-admin branch. A mixed-role token still maps to the
      // platform-wide identity.
      final result = SessionRecordCompleteness.assertComplete(
        <String, Object?>{
          'session_id': 'sess_abc',
          'user_id': 'support_user',
          'operator_id': '',
          'location_id': '',
        },
        roles: <String>{'ff_support', 'advisor.read'},
      );

      expect(result.complete, isTrue);
    });

    test('missing session_id always flagged regardless of role mode', () {
      final tenant = SessionRecordCompleteness.assertComplete(
        <String, Object?>{
          'session_id': '',
          'user_id': 'user_a',
          'operator_id': 'op',
          'location_id': 'loc',
        },
        roles: <String>{},
      );
      final admin = SessionRecordCompleteness.assertComplete(
        <String, Object?>{
          'session_id': '',
          'user_id': 'user_a',
          'operator_id': '',
          'location_id': '',
        },
        roles: <String>{'super_admin'},
      );

      expect(tenant.missingFields, contains('session_id'));
      expect(admin.missingFields, contains('session_id'));
    });
  });

  group('parseSoakDurationSeconds', () {
    test('parses seconds, minutes, hours', () {
      expect(parseSoakDurationSeconds('30s'), equals(30));
      expect(parseSoakDurationSeconds('5min'), equals(300));
      expect(parseSoakDurationSeconds('2h'), equals(7200));
    });

    test('rejects garbage strings', () {
      expect(
        () => parseSoakDurationSeconds('forever'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('isSoakProxyUrlAllowed', () {
    test('accepts preview/staging/localhost', () {
      expect(isSoakProxyUrlAllowed('http://localhost:8080'), isTrue);
      expect(isSoakProxyUrlAllowed('https://127.0.0.1:8080'), isTrue);
      expect(
        isSoakProxyUrlAllowed(
          'https://forge-flow-preview-backend.example.run.app',
        ),
        isTrue,
      );
      expect(
        isSoakProxyUrlAllowed(
          'https://forge-flow-staging-backend.example.run.app',
        ),
        isTrue,
      );
    });

    test('refuses arbitrary URLs', () {
      expect(
        isSoakProxyUrlAllowed('https://forge-flow-prod.example.run.app'),
        isFalse,
      );
      expect(isSoakProxyUrlAllowed('https://example.com'), isFalse);
    });
  });
}
