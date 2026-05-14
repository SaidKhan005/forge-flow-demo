// W-1 (Wave 2 Lane W — Members edit-user write path) — unit tests for
// the route-layer pre-flight + email-shape helper. The helpers live
// outside `advisor_proxy.dart` so the bleed-stop ceiling at
// `tool/advisor_proxy_size_lint.dart` does not creep up; this test
// pins the helper behaviour without standing up the full proxy harness.

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/advisor_proxy/team_users_edit_member_validation.dart';

String? _nonBlank(Object? raw) {
  if (raw is! String) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

void main() {
  group('looksLikeEmailForEditMember', () {
    test('accepts a typical email', () {
      expect(looksLikeEmailForEditMember('pat.lee@example.test'), isTrue);
    });

    test('rejects empty + whitespace', () {
      expect(looksLikeEmailForEditMember(''), isFalse);
      expect(looksLikeEmailForEditMember('a@b. c'), isFalse);
    });

    test('rejects missing @', () {
      expect(looksLikeEmailForEditMember('pat.lee.example.test'), isFalse);
    });

    test('rejects empty local part', () {
      expect(looksLikeEmailForEditMember('@example.test'), isFalse);
    });

    test('rejects empty domain part', () {
      expect(looksLikeEmailForEditMember('pat.lee@'), isFalse);
    });

    test('rejects multiple @', () {
      expect(looksLikeEmailForEditMember('a@b@c.test'), isFalse);
    });

    test('rejects domain without dot', () {
      expect(looksLikeEmailForEditMember('pat.lee@example'), isFalse);
    });

    test('rejects domain with leading/trailing dot', () {
      expect(looksLikeEmailForEditMember('pat.lee@.example.test'), isFalse);
      expect(looksLikeEmailForEditMember('pat.lee@example.test.'), isFalse);
    });
  });

  group('validateEditMemberRouteBody', () {
    test('happy path returns trimmed fields, no rejection', () {
      final inputs = validateEditMemberRouteBody(
        targetUserId: 'user-1',
        nonBlankString: _nonBlank,
        rawDisplayName: 'Pat Lee',
        rawEmail: 'pat.lee@example.test',
        rawReason: null,
        rawAdminReason: 'operator typo fix',
      );
      expect(inputs.rejection, isNull);
      expect(inputs.displayName, equals('Pat Lee'));
      expect(inputs.email, equals('pat.lee@example.test'));
      expect(inputs.reason, equals('operator typo fix'));
    });

    test('missing target user id → 400 missing_user_profile_fields', () {
      final inputs = validateEditMemberRouteBody(
        targetUserId: null,
        nonBlankString: _nonBlank,
        rawDisplayName: 'Pat Lee',
        rawEmail: null,
        rawReason: 'reason',
        rawAdminReason: null,
      );
      expect(inputs.rejection?.statusCode, equals(400));
      expect(inputs.rejection?.error, equals('missing_user_profile_fields'));
    });

    test('missing reason → 400', () {
      final inputs = validateEditMemberRouteBody(
        targetUserId: 'user-1',
        nonBlankString: _nonBlank,
        rawDisplayName: 'Pat Lee',
        rawEmail: null,
        rawReason: null,
        rawAdminReason: null,
      );
      expect(inputs.rejection?.statusCode, equals(400));
      expect(inputs.rejection?.error, equals('missing_user_profile_fields'));
    });

    test('all-null email + display_name → 400', () {
      final inputs = validateEditMemberRouteBody(
        targetUserId: 'user-1',
        nonBlankString: _nonBlank,
        rawDisplayName: null,
        rawEmail: null,
        rawReason: 'reason',
        rawAdminReason: null,
      );
      expect(inputs.rejection?.statusCode, equals(400));
      expect(inputs.rejection?.error, equals('missing_user_profile_fields'));
      expect(
        inputs.rejection?.message,
        contains('at least one of display_name or email'),
      );
    });

    test('malformed email → 400 invalid_email', () {
      final inputs = validateEditMemberRouteBody(
        targetUserId: 'user-1',
        nonBlankString: _nonBlank,
        rawDisplayName: 'Pat Lee',
        rawEmail: 'not-an-email',
        rawReason: 'reason',
        rawAdminReason: null,
      );
      expect(inputs.rejection?.statusCode, equals(400));
      expect(inputs.rejection?.error, equals('invalid_email'));
    });

    test('email-only patch is accepted', () {
      final inputs = validateEditMemberRouteBody(
        targetUserId: 'user-1',
        nonBlankString: _nonBlank,
        rawDisplayName: null,
        rawEmail: 'new@example.test',
        rawReason: null,
        rawAdminReason: 'operator change',
      );
      expect(inputs.rejection, isNull);
      expect(inputs.displayName, isNull);
      expect(inputs.email, equals('new@example.test'));
    });

    test('display-name-only patch is accepted', () {
      final inputs = validateEditMemberRouteBody(
        targetUserId: 'user-1',
        nonBlankString: _nonBlank,
        rawDisplayName: 'New Name',
        rawEmail: null,
        rawReason: 'reason',
        rawAdminReason: null,
      );
      expect(inputs.rejection, isNull);
      expect(inputs.displayName, equals('New Name'));
      expect(inputs.email, isNull);
    });
  });
}
