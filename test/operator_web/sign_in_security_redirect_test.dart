import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('static sign-in-security redirects', () {
    test('operator-web nginx config returns a 301 before index fallback', () {
      final dockerfile = File('Dockerfile.operator_web').readAsStringSync();

      _expectNginxRedirectBlock(
        dockerfile: dockerfile,
        legacyPath: '/operator-web/sign-in-security',
      );
    });

    test('admin nginx config returns a 301 before index fallback', () {
      final dockerfile = File('Dockerfile.admin_console').readAsStringSync();

      _expectNginxRedirectBlock(
        dockerfile: dockerfile,
        legacyPath: '/admin/sign-in-security',
      );
    });
  });
}

void _expectNginxRedirectBlock({
  required String dockerfile,
  required String legacyPath,
}) {
  final legacyLocation = "        '    location = $legacyPath {' \\";
  final fallbackLocation = "        '    location / {' \\";
  final redirectLine =
      r'''        '        return 301 "/my-account$is_args$args#security";' \''';

  final legacyIndex = dockerfile.indexOf(legacyLocation);
  final fallbackIndex = dockerfile.indexOf(fallbackLocation);

  expect(
    legacyIndex,
    greaterThanOrEqualTo(0),
    reason: 'legacy path must have an exact nginx location block',
  );
  expect(
    fallbackIndex,
    greaterThanOrEqualTo(0),
    reason: 'static shell fallback should still be present',
  );
  expect(
    legacyIndex,
    lessThan(fallbackIndex),
    reason: 'legacy redirect must run before Flutter index fallback',
  );

  final legacyBlock = dockerfile.substring(legacyIndex, fallbackIndex);
  expect(
    legacyBlock,
    contains(redirectLine),
    reason:
        '301 Location must preserve query params via \$is_args\$args '
        'and target the My Account security fragment',
  );
}
