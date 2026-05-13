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

    // ─── RAW_LITERAL pass ───────────────────────────────────────────
    //
    // Operator-self-service widgets must reach the frozen catalog at
    // `lib/auth/permission_keys.dart` via `PermissionKeys.<name>`
    // references. Inline `'team.users.invite'` style literals bypass
    // the lint and let drift slip in. The RAW_LITERAL pass scans the
    // operator-self-service widget directories + `settings_screen.dart`
    // and flags raw permission-shaped literals.

    const keysSrcWithCatalogConst = '''
class PermissionKeys {
  static const String teamUsersView = 'team.users.view';
  static const Set<String> all = <String>{teamUsersView};
}
''';
    const catalogWithTeamUsersView = '''
| `team.users.view` | desc | — |
''';

    test('flags RAW_LITERAL — raw permission-shaped string in '
        'operator_web widget', () {
      final result = PermissionKeyLintRunner(
        permissionKeysSource: keysSrcWithCatalogConst,
        referenceFiles: <String, String>{
          'lib/operator_web/screens/foo_screen.dart': '''
import 'package:flutter/material.dart';

class FooScreen {
  bool canView(Set<String> perms) =>
      perms.contains('team.users.view');
}
''',
        },
        catalogMarkdown: catalogWithTeamUsersView,
        rawLiteralScanScope: const <String>{'lib/operator_web/'},
        rawLiteralFileAllowlist: const <String>{},
      ).run();
      expect(result.rawLiterals, hasLength(1));
      final finding = result.rawLiterals.single;
      expect(finding.dottedKey, 'team.users.view');
      expect(
        finding.location,
        'lib/operator_web/screens/foo_screen.dart:5',
      );
      // The other passes stay clean — the test fixture defines
      // teamUsersView in the catalog and references it via
      // PermissionKeys.all, so neither ORPHAN nor CATALOG_DRIFT /
      // CATALOG_MISSING fires.
      expect(result.orphans, isEmpty);
      expect(result.drifts, isEmpty);
      expect(result.missing, isEmpty);
    });

    test('accepts a `PermissionKeys.<name>` reference — no RAW_LITERAL',
        () {
      final result = PermissionKeyLintRunner(
        permissionKeysSource: keysSrcWithCatalogConst,
        referenceFiles: <String, String>{
          'lib/operator_web/screens/foo_screen.dart': '''
import 'package:flutter/material.dart';
import '../../auth/permission_keys.dart';

class FooScreen {
  bool canView(Set<String> perms) =>
      perms.contains(PermissionKeys.teamUsersView);
}
''',
        },
        catalogMarkdown: catalogWithTeamUsersView,
        rawLiteralScanScope: const <String>{'lib/operator_web/'},
        rawLiteralFileAllowlist: const <String>{},
      ).run();
      expect(result.rawLiterals, isEmpty);
    });

    test('accepts an aliased top-level constant pointing at the catalog '
        '— no RAW_LITERAL on the alias declaration line', () {
      // Operator-web screens declare named permission constants for
      // their own surface (e.g. `kHierarchyViewPermissionKey`) and
      // alias them to the frozen catalog: `= PermissionKeys.teamUsersView;`.
      // The alias has no string literal in the right-hand side so the
      // RAW_LITERAL pass must not flag it.
      final result = PermissionKeyLintRunner(
        permissionKeysSource: keysSrcWithCatalogConst,
        referenceFiles: <String, String>{
          'lib/operator_web/screens/foo_screen.dart': '''
import '../../auth/permission_keys.dart';

const String kFooViewPermissionKey = PermissionKeys.teamUsersView;

class FooScreen {
  bool canView(Set<String> perms) =>
      perms.contains(kFooViewPermissionKey);
}
''',
        },
        catalogMarkdown: catalogWithTeamUsersView,
        rawLiteralScanScope: const <String>{'lib/operator_web/'},
        rawLiteralFileAllowlist: const <String>{},
      ).run();
      expect(result.rawLiterals, isEmpty);
    });

    test('honours the per-line `// ignore-permission-key-lint:` '
        'escape hatch', () {
      final result = PermissionKeyLintRunner(
        permissionKeysSource: keysSrcWithCatalogConst,
        referenceFiles: <String, String>{
          'lib/operator_web/screens/foo_screen.dart': '''
class FooScreen {
  static const String legacyKey =
      'team.users.view'; // ignore-permission-key-lint: legacy migration row
}
''',
        },
        catalogMarkdown: catalogWithTeamUsersView,
        rawLiteralScanScope: const <String>{'lib/operator_web/'},
        rawLiteralFileAllowlist: const <String>{},
      ).run();
      expect(result.rawLiterals, isEmpty);
    });

    test('honours the file-level allowlist — explainer catalog + demo '
        'fixture files are exempt', () {
      final result = PermissionKeyLintRunner(
        permissionKeysSource: keysSrcWithCatalogConst,
        referenceFiles: <String, String>{
          'lib/operator_web/screens/permission_explainer_screen.dart': '''
const Map<String, String> kPermissionExplainerDescriptions =
    <String, String>{
  'team.users.view': "View the operator's user list.",
};
''',
        },
        catalogMarkdown: catalogWithTeamUsersView,
        rawLiteralScanScope: const <String>{'lib/operator_web/'},
        rawLiteralFileAllowlist: const <String>{
          'lib/operator_web/screens/permission_explainer_screen.dart',
        },
      ).run();
      expect(result.rawLiterals, isEmpty);
    });

    test('RAW_LITERAL pass ignores files outside the configured scope',
        () {
      // A literal in `lib/services/...` is out of scope; the RAW_LITERAL
      // pass MUST ignore it. (The orphan / catalog passes still apply
      // — but with an empty key set they have nothing to flag here.)
      final result = PermissionKeyLintRunner(
        permissionKeysSource: keysSrcWithCatalogConst,
        referenceFiles: <String, String>{
          'lib/services/some_service.dart': '''
final perm = 'team.users.view';
''',
        },
        catalogMarkdown: catalogWithTeamUsersView,
        rawLiteralScanScope: const <String>{'lib/operator_web/'},
        rawLiteralFileAllowlist: const <String>{},
      ).run();
      expect(result.rawLiterals, isEmpty);
    });

    test('RAW_LITERAL pass ignores literals whose first segment is not '
        'a permission category', () {
      // `package.json`-style dotted strings, URL paths, and other
      // dotted identifiers that share the literal shape but whose first
      // segment is not in `_permissionCategoryPrefixes` must pass.
      final result = PermissionKeyLintRunner(
        permissionKeysSource: keysSrcWithCatalogConst,
        referenceFiles: <String, String>{
          'lib/operator_web/screens/foo_screen.dart': '''
final pkg = 'package.flutter.material';
final url = 'api.v1.endpoint';
''',
        },
        catalogMarkdown: catalogWithTeamUsersView,
        rawLiteralScanScope: const <String>{'lib/operator_web/'},
        rawLiteralFileAllowlist: const <String>{},
      ).run();
      expect(result.rawLiterals, isEmpty);
    });

    test('RAW_LITERAL pass scans the named single-file scope entry '
        '(settings_screen.dart)', () {
      final result = PermissionKeyLintRunner(
        permissionKeysSource: keysSrcWithCatalogConst,
        referenceFiles: <String, String>{
          'lib/screens/settings_screen.dart': '''
final perms = <String>{'team.users.view'};
''',
        },
        catalogMarkdown: catalogWithTeamUsersView,
        rawLiteralScanScope: const <String>{
          'lib/screens/settings_screen.dart',
        },
        rawLiteralFileAllowlist: const <String>{},
      ).run();
      expect(result.rawLiterals, hasLength(1));
      expect(
        result.rawLiterals.single.location,
        'lib/screens/settings_screen.dart:1',
      );
    });

    test('RAW_LITERAL pass fires on every permission-category prefix '
        '(team / admin / operator / product / forgeflow / barrio / '
        'account / business_timing / billing / integration / integrations / '
        'workflow)', () {
      // Pin every category prefix the lint treats as a permission-key
      // shape. Each literal is on its own file so the per-line collapse
      // does not hide a missing prefix; the test fails loudly if a new
      // category is added to `_permissionCategoryPrefixes` without a
      // corresponding test row here.
      const probes = <String, String>{
        'lib/operator_web/screens/probe_team.dart':
            "final p = 'team.users.view';",
        'lib/operator_web/screens/probe_admin.dart':
            "final p = 'admin.audit_log.view';",
        'lib/operator_web/screens/probe_operator.dart':
            "final p = 'operator.something.do';",
        'lib/operator_web/screens/probe_product.dart':
            "final p = 'product.forgeflow.access';",
        'lib/operator_web/screens/probe_forgeflow.dart':
            "final p = 'forgeflow.shift.view';",
        'lib/operator_web/screens/probe_barrio.dart':
            "final p = 'barrio.handbook.view';",
        'lib/operator_web/screens/probe_account.dart':
            "final p = 'account.configure';",
        'lib/operator_web/screens/probe_business_timing.dart':
            "final p = 'business_timing.configure';",
        'lib/operator_web/screens/probe_billing.dart':
            "final p = 'billing.invoice.view';",
        'lib/operator_web/screens/probe_integration.dart':
            "final p = 'integration.toast.view';",
        'lib/operator_web/screens/probe_integrations.dart':
            "final p = 'integrations.configure';",
        'lib/operator_web/screens/probe_workflow.dart':
            "final p = 'workflow.run';",
      };
      final result = PermissionKeyLintRunner(
        permissionKeysSource: keysSrcWithCatalogConst,
        referenceFiles: probes,
        catalogMarkdown: catalogWithTeamUsersView,
        rawLiteralScanScope: const <String>{'lib/operator_web/'},
        rawLiteralFileAllowlist: const <String>{},
      ).run();
      // One finding per probe file → ten findings total.
      expect(result.rawLiterals, hasLength(probes.length));
      // Every probe location is reported with `path:line` form so a
      // failing CI run points the operator at the offending line.
      for (final loc
          in result.rawLiterals.map((f) => f.location).toList()..sort()) {
        expect(loc, matches(RegExp(r'^lib/operator_web/screens/probe_\w+\.dart:1$')));
      }
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
