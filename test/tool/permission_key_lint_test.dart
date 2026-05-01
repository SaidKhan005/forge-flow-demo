// Tests for `tool/permission_key_lint.dart`.
//
// The lint parses both shapes: class-namespaced
// (`static const String forgeflowShiftView = '...'` inside
// `class PermissionKeys`) and the future top-level `kFf…`/`kPerm…`
// constants. Class-member orphan detection respects membership in the
// `PermissionKeys.all` / `requiresMfa` / `baselineRoleKeys` sets — a
// constant referenced via any of those is reachable at runtime. Only
// values that match a permission-key shape (lowercase first segment +
// at least one `.`) are subject to catalog drift / missing checks;
// undotted role keys (`super_admin`, `ff_support`, …) are filtered
// out. Catalog parsing anchors on table-row first cells so prose
// mentions of `\`PermissionKeys.all\`` or `\`public.roles\`` do not
// bleed into the catalog set.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/permission_key_lint.dart';

void main() {
  group('permission_key_lint', () {
    test('clean against the real on-disk tree', () {
      final keysSrc =
          File('lib/auth/permission_keys.dart').readAsStringSync();
      final catalog = File(
        'docs/contracts/auth_permission_key_catalog.md',
      ).readAsStringSync();
      final references = _walkLibDart();

      final result = PermissionKeyLintRunner(
        permissionKeysSource: keysSrc,
        referenceFiles: references,
        catalogMarkdown: catalog,
      ).run();
      expect(
        result.isClean,
        isTrue,
        reason: 'real tree should pass; findings: ${result.findings}',
      );
    });

    test('flags a top-level ORPHAN — declared, never referenced', () {
      const keysSrc = '''
const String kFfOrphanKey = 'forgeflow.orphan.key';
''';
      const catalog = '''
| Key | Description | MFA |
|---|---|---|
| `forgeflow.orphan.key` | Some orphan. | — |
''';
      final result = PermissionKeyLintRunner(
        permissionKeysSource: keysSrc,
        referenceFiles: const <String, String>{
          'lib/feature_x/screen.dart': 'void main() {}',
        },
        catalogMarkdown: catalog,
      ).run();
      expect(result.orphans, hasLength(1));
      expect(result.orphans.single.constName, 'kFfOrphanKey');
      expect(result.drifts, isEmpty);
      expect(result.missing, isEmpty);
    });

    test('flags a class-member ORPHAN — declared, not in '
        'PermissionKeys.all, not referenced', () {
      const keysSrc = '''
class PermissionKeys {
  static const String forgeflowOrphanKey = 'forgeflow.orphan.key';
  static const String forgeflowGoodKey = 'forgeflow.good.key';

  static const Set<String> all = <String>{
    forgeflowGoodKey,
  };
}
''';
      const catalog = '''
| `forgeflow.orphan.key` | Orphan in code. | — |
| `forgeflow.good.key` | In all set. | — |
''';
      final result = PermissionKeyLintRunner(
        permissionKeysSource: keysSrc,
        referenceFiles: const <String, String>{
          'lib/feature_x/screen.dart': 'void main() {}',
        },
        catalogMarkdown: catalog,
      ).run();
      expect(result.orphans, hasLength(1));
      expect(result.orphans.single.constName, 'forgeflowOrphanKey');
    });

    test('membership in PermissionKeys.all suppresses ORPHAN', () {
      const keysSrc = '''
class PermissionKeys {
  static const String forgeflowGoodKey = 'forgeflow.good.key';

  static const Set<String> all = <String>{
    forgeflowGoodKey,
  };
}
''';
      const catalog = '''
| `forgeflow.good.key` | desc | — |
''';
      final result = PermissionKeyLintRunner(
        permissionKeysSource: keysSrc,
        referenceFiles: const <String, String>{
          // Note: NO direct reference under lib/. The constant is only
          // reachable via PermissionKeys.all iteration. The lint must
          // accept this (runtime resolver iterates the set).
          'lib/services/something.dart': 'void main() {}',
        },
        catalogMarkdown: catalog,
      ).run();
      expect(result.isClean, isTrue);
    });

    test('membership in PermissionKeys.requiresMfa suppresses ORPHAN', () {
      const keysSrc = '''
class PermissionKeys {
  static const String adminMfaKey = 'admin.mfa.key';

  static const Set<String> all = <String>{};

  static const Set<String> requiresMfa = <String>{
    adminMfaKey,
  };
}
''';
      const catalog = '''
| `admin.mfa.key` | MFA-only. | yes |
''';
      final result = PermissionKeyLintRunner(
        permissionKeysSource: keysSrc,
        referenceFiles: const <String, String>{
          'lib/services/x.dart': 'void main() {}',
        },
        catalogMarkdown: catalog,
      ).run();
      expect(result.isClean, isTrue);
    });

    test('role keys (undotted values) are not subject to catalog drift',
        () {
      const keysSrc = '''
class PermissionKeys {
  static const String roleSuperAdmin = 'super_admin';
  static const String forgeflowKey = 'forgeflow.shift.view';

  static const Set<String> all = <String>{
    forgeflowKey,
  };
  static const Set<String> baselineRoleKeys = <String>{
    roleSuperAdmin,
  };
}
''';
      const catalog = '''
| `forgeflow.shift.view` | desc | — |
''';
      final result = PermissionKeyLintRunner(
        permissionKeysSource: keysSrc,
        referenceFiles: const <String, String>{
          'lib/x.dart': 'void main() {}',
        },
        catalogMarkdown: catalog,
      ).run();
      // roleSuperAdmin's value is undotted → filtered out of the
      // permission-key constant set entirely. forgeflowKey is present
      // in PermissionKeys.all and in the catalog → clean.
      expect(result.isClean, isTrue);
      expect(result.parsedConstantCount, 1);
    });

    test('catalog parsing anchors on table-row first cells; prose '
        'mentions of dotted identifiers are ignored', () {
      const keysSrc = '''
class PermissionKeys {
  static const String forgeflowKey = 'forgeflow.shift.view';
  static const Set<String> all = <String>{forgeflowKey};
}
''';
      const catalog = '''
The 9.0 test group asserts every key in `PermissionKeys.all` is
seeded from `public.permission_keys`. Six roles are seeded into
`public.roles` at apply time.

| Key | Description | MFA |
|---|---|---|
| `forgeflow.shift.view` | desc | — |
''';
      final result = PermissionKeyLintRunner(
        permissionKeysSource: keysSrc,
        referenceFiles: const <String, String>{
          'lib/x.dart': 'void main() {}',
        },
        catalogMarkdown: catalog,
      ).run();
      expect(result.isClean, isTrue);
      expect(result.catalogKeyCount, 1);
    });

    test('flags CATALOG_DRIFT — catalog has key, code does not', () {
      const keysSrc = '''
const String kFfShiftView = 'forgeflow.shift.view';
''';
      const catalog = '''
| `forgeflow.shift.view` | View shift surface. | — |
| `forgeflow.ghost.key` | Catalog row without a constant. | — |
''';
      final result = PermissionKeyLintRunner(
        permissionKeysSource: keysSrc,
        referenceFiles: const <String, String>{
          'lib/services/shift_service.dart': '''
import 'package:forge_and_flow/auth/permission_keys.dart';
final perm = kFfShiftView;
''',
        },
        catalogMarkdown: catalog,
      ).run();
      expect(result.drifts, hasLength(1));
      expect(result.drifts.single.dottedKey, 'forgeflow.ghost.key');
      expect(result.orphans, isEmpty);
      expect(result.missing, isEmpty);
    });

    test('flags CATALOG_MISSING — code declares key, catalog does not',
        () {
      const keysSrc = '''
const String kFfNewKey = 'forgeflow.new.key';
''';
      const catalog = '''
No relevant rows here.
''';
      final result = PermissionKeyLintRunner(
        permissionKeysSource: keysSrc,
        referenceFiles: const <String, String>{
          'lib/services/some_service.dart': '''
final useTheKey = kFfNewKey;
''',
        },
        catalogMarkdown: catalog,
      ).run();
      expect(result.missing, hasLength(1));
      expect(result.missing.single.constName, 'kFfNewKey');
      expect(result.missing.single.dottedKey, 'forgeflow.new.key');
      expect(result.orphans, isEmpty);
      expect(result.drifts, isEmpty);
    });

    test('honours the exempt list — exempt key is not flagged ORPHAN',
        () {
      const keysSrc = '''
const String kFfExemptKey = 'forgeflow.exempt.key';
''';
      const catalog = '''
| `forgeflow.exempt.key` | Reserved placeholder. | — |
''';
      final result = PermissionKeyLintRunner(
        permissionKeysSource: keysSrc,
        referenceFiles: const <String, String>{
          'lib/services/other.dart': 'void main() {}',
        },
        catalogMarkdown: catalog,
        exemptKeys: const <String>{'kFfExemptKey'},
      ).run();
      expect(result.isClean, isTrue);
    });

    test('parses both kFf… and kPerm… name shapes', () {
      const keysSrc = '''
const String kFfOne = 'forgeflow.one';
const String kPermTwo = 'admin.two';
''';
      const catalog = '''
| `forgeflow.one` | desc | — |
| `admin.two` | desc | — |
''';
      final result = PermissionKeyLintRunner(
        permissionKeysSource: keysSrc,
        referenceFiles: const <String, String>{
          'lib/a.dart': 'final x = kFfOne;',
          'lib/b.dart': 'final y = kPermTwo;',
        },
        catalogMarkdown: catalog,
      ).run();
      expect(result.parsedConstantCount, 2);
      expect(result.isClean, isTrue);
    });

    test('parses every class-member permission key on the real '
        'on-disk file (matches PermissionKeys.all size)', () {
      final keysSrc =
          File('lib/auth/permission_keys.dart').readAsStringSync();
      final catalog = File(
        'docs/contracts/auth_permission_key_catalog.md',
      ).readAsStringSync();
      // Pass the real catalog so the constant set and catalog are both
      // populated. Run with empty referenceFiles to isolate the parse
      // step from the orphan/usage cross-check (PermissionKeys.all
      // membership suppresses orphan findings).
      final result = PermissionKeyLintRunner(
        permissionKeysSource: keysSrc,
        referenceFiles: const <String, String>{},
        catalogMarkdown: catalog,
      ).run();
      // Class members with permission-key shaped values (dotted) are
      // counted; undotted role-key constants are filtered out by
      // _permissionKeyValueShape so the count matches PermissionKeys.all.
      expect(result.classMemberCount, greaterThan(0));
      expect(result.classMemberCount, equals(result.catalogKeyCount));
    });
  });
}

/// Walks `lib/` for all `*.dart` files except
/// `lib/auth/permission_keys.dart` itself.
Map<String, String> _walkLibDart() {
  final out = <String, String>{};
  final dir = Directory('lib');
  if (!dir.existsSync()) return out;
  for (final entity in dir.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    if (!entity.path.toLowerCase().endsWith('.dart')) continue;
    final rel = entity.path.replaceAll(r'\', '/');
    if (rel == 'lib/auth/permission_keys.dart') continue;
    out[rel] = entity.readAsStringSync().replaceAll('\r\n', '\n');
  }
  return out;
}
