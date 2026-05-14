// Phase 9 repo-lints — permission key catalog drift / orphan / missing.
//
// The frozen permission key catalog is mirrored across three sources
// (CLAUDE.md "Service-Layer Split" + `lib/auth/permission_keys.dart`
// header):
//
//   1. db/migrations/202604250008_auth_schema_foundation.sql (and
//      additive 9.0a / 9.0Σ.h2 / MFA-hardening follow-ups)
//   2. lib/auth/permission_keys.dart
//   3. docs/contracts/auth_permission_key_catalog.md
//
// Drift between any two copies is a launch-blocking integrity bug —
// runtime permission resolution and the audit log become incoherent
// if the catalog at the seed layer disagrees with the constants the
// runtime checks against. This lint covers the Dart-side ↔ catalog-doc
// pair; the Dart-side ↔ migration-seed pair is already covered by
// `Phase 9 auth schema foundation migration (9.0)` in
// `test/advisor_proxy_test.dart`.
//
// Two declaration shapes are parsed:
//
//   * Class-namespaced (active today):
//       static const String forgeflowShiftView = 'forgeflow.shift.view';
//     Members of `class PermissionKeys`. Runtime exposure travels
//     through `PermissionKeys.all` (a `Set<String>` listing every key
//     the resolver supports). Direct callers reference these as
//     `PermissionKeys.<name>`.
//
//   * Top-level `kFf…` / `kPerm…` (reserved for the future refactor
//     that lifts constants out of the class wrapper):
//       const String kFfShiftView = 'forgeflow.shift.view';
//     Direct callers reference the bare name.
//
// Both shapes contribute to ORPHAN / CATALOG_DRIFT / CATALOG_MISSING:
//
//   - `ORPHAN`         constant declared, but neither in
//                      `PermissionKeys.all` nor referenced by any
//                      `*.dart` under lib/ outside permission_keys.dart.
//                      Top-level constants are orphaned solely on the
//                      direct-reference axis (no `all` set involved).
//   - `CATALOG_DRIFT`  catalog row exists, no constant declares the
//                      dotted key.
//   - `CATALOG_MISSING` constant declared, catalog row absent.
//
// Exempt list (`_exemptKeys`) is the documented escape hatch for
// ORPHAN findings only. Default empty. Adding an entry is an explicit
// code change with a required inline reason. Class-namespaced exempts
// use the bare member name (`forgeflowShiftView`); top-level exempts
// use the constant name (`kFfShiftView`).
//
// Exposed surface:
//   * `PermissionKeyLintRunner` — testable façade. Construct with a
//     `permission_keys.dart` body, a map of additional Dart files
//     (relative-path → body) for ORPHAN scan, the catalog markdown
//     body, and an optional exempt set. Call `run()`.
//   * `main(List<String>)` — CLI entrypoint that reads the on-disk
//     tree and exits 1 on any non-exempt finding.
//
// Run locally:
//
//   dart run tool/permission_key_lint.dart

import 'dart:io';

// ─── Exempt list ──────────────────────────────────────────────────
//
// Adding a key here suppresses ORPHAN findings for that key. Class-
// namespaced exempts use the bare member name (e.g. `forgeflowShiftView`);
// top-level exempts use the constant name (e.g. `kFfShiftView`).
// Default empty; each entry MUST carry an inline `// reason` comment.

const Set<String> _exemptKeys = <String>{
  // Example (commented out so the default is empty):
  // 'forgeflowReservedPlaceholder', // Phase 9.UX.Z planned, not wired yet.
  // 'kFfReservedPlaceholder',       // Future top-level shape.
};

// ─── Raw-literal scan scope ───────────────────────────────────────
//
// The RAW_LITERAL pass enforces that operator-self-service widgets do
// not bypass the frozen `PermissionKeys.*` catalog at
// `lib/auth/permission_keys.dart`. Scanned paths are listed below;
// adding a directory broadens the scope and MUST be a deliberate code
// change (the explicit allowlist mirrors CODE_OPS_DEBT.md Theme F).
//
// Files inside the scope where literal permission-shaped strings are
// intentional (catalog descriptions, fixture data, audit-log action
// strings that happen to overlap dotted keys) are listed in
// `_rawLiteralFileAllowlist`. Each entry carries an inline reason.
//
// Per-line escape hatch: append `// ignore-permission-key-lint: <reason>`
// on the same line as the literal. The lint suppresses the finding for
// that line only.

/// Repo-relative directory or file paths whose Dart contents the
/// RAW_LITERAL pass scans. Path separators are normalized to `/` before
/// matching. Listing a directory matches every `*.dart` file beneath
/// it (recursive).
const Set<String> _rawLiteralScanScope = <String>{
  'lib/operator_web/',
  'lib/screens/team/',
  'lib/screens/settings_screen.dart',
};

/// Files inside `_rawLiteralScanScope` where raw permission-shaped
/// literals are intentional and the RAW_LITERAL pass MUST NOT flag.
/// Each entry carries an inline reason. Default keeps the operator-
/// self-service surfaces clean; the entries below are catalog /
/// fixture / audit-log-action files that purposely enumerate dotted
/// keys for non-gating uses.
const Set<String> _rawLiteralFileAllowlist = <String>{
  // Renders the verbatim seed-row description for every permission
  // key in the catalog; the literals are the explainer's data shape,
  // not an inline gate that bypasses PermissionKeys.*.
  'lib/operator_web/screens/permission_explainer_screen.dart',
  // Demo-only role-preset + audit-row fixtures. Replacing every
  // literal with PermissionKeys.* references would not change the
  // demo behaviour and is tracked as a separate clean-up slice.
  'lib/operator_web/services/demo_team_fixtures.dart',
  // `audit_logs.action` filter constants. The values overlap dotted
  // permission keys by convention but they are action-string filters,
  // not gating literals — see the file's class header for the
  // contract distinction.
  'lib/operator_web/services/web_team_audit_log_gateway.dart',
  // Role + permission-snapshot bridging. Out of CODE_OPS_DEBT.md
  // Theme F slice scope; flagged as a follow-up clean-up.
  'lib/operator_web/auth/firebase_operator_web_auth_source.dart',
  // Single `'integrations.configure'` gate; out of Theme F scope,
  // tracked as follow-up clean-up.
  'lib/operator_web/screens/vendor_connections_screen.dart',
  'lib/operator_web/screens/my_account_screen.dart',
};

/// Permission-key category prefixes the RAW_LITERAL pass treats as a
/// permission-key shape. A literal `'<category>.<rest>'` whose first
/// segment is in this set fires a RAW_LITERAL finding when the literal
/// appears on a non-allowlisted line. Mirrors the categories enumerated
/// in `lib/auth/permission_keys.dart` (file header).
const Set<String> _permissionCategoryPrefixes = <String>{
  'team',
  'admin',
  'operator',
  'product',
  'forgeflow',
  'barrio',
  'account',
  'business_timing',
  'billing',
  'integration',
  'integrations',
  'workflow',
};

/// Per-line escape hatch token. A line that ends with
/// `// ignore-permission-key-lint: <reason>` (case-insensitive) is
/// excluded from the RAW_LITERAL pass. The reason text is required so
/// suppressions are auditable.
final RegExp _rawLiteralIgnorePattern = RegExp(
  r'//\s*ignore-permission-key-lint:\s*\S',
);

/// Code for a finding emitted by the lint.
enum PermissionKeyFindingCode {
  orphan,
  catalogDrift,
  catalogMissing,
  rawLiteral,
  // Wave 2 R-1L — metadata gates. Mirror discipline for the four
  // metadata columns added by migration
  // `202605142100_phase_R_1L_roles_schema_rewrite.sql`.
  metadataMissing,
  metadataInvalid,
}

/// Declaration shape for a parsed constant.
enum PermissionKeyShape { classMember, topLevel }

/// One finding from the lint.
class PermissionKeyFinding {
  const PermissionKeyFinding({
    required this.code,
    required this.constName,
    required this.dottedKey,
    required this.detail,
    this.location = '',
  });

  final PermissionKeyFindingCode code;

  /// Constant name (e.g. `forgeflowShiftView` or `kFfShiftView`). Empty
  /// when the finding is a `CATALOG_DRIFT` (catalog has the key but no
  /// constant declares it).
  final String constName;

  /// Dotted key (e.g. `forgeflow.shift.view`). Empty when the finding
  /// is an `ORPHAN` whose const has no string value.
  final String dottedKey;

  /// Free-form remediation hint.
  final String detail;

  /// `path:line` of the offending line for `RAW_LITERAL`; empty for
  /// other finding shapes.
  final String location;

  String get codeString {
    switch (code) {
      case PermissionKeyFindingCode.orphan:
        return 'ORPHAN';
      case PermissionKeyFindingCode.catalogDrift:
        return 'CATALOG_DRIFT';
      case PermissionKeyFindingCode.catalogMissing:
        return 'CATALOG_MISSING';
      case PermissionKeyFindingCode.rawLiteral:
        return 'RAW_LITERAL';
      case PermissionKeyFindingCode.metadataMissing:
        return 'METADATA_MISSING';
      case PermissionKeyFindingCode.metadataInvalid:
        return 'METADATA_INVALID';
    }
  }

  @override
  String toString() {
    final parts = <String>[
      codeString,
      if (location.isNotEmpty) 'at=$location',
      if (constName.isNotEmpty) 'const=$constName',
      if (dottedKey.isNotEmpty) 'key=$dottedKey',
      if (detail.isNotEmpty) detail,
    ];
    return parts.join(' ');
  }
}

/// Aggregate result of a lint run.
class PermissionKeyLintResult {
  const PermissionKeyLintResult({
    required this.findings,
    required this.parsedConstantCount,
    required this.classMemberCount,
    required this.topLevelCount,
    required this.allSetMemberCount,
    required this.catalogKeyCount,
    required this.exemptCount,
  });

  final List<PermissionKeyFinding> findings;
  final int parsedConstantCount;
  final int classMemberCount;
  final int topLevelCount;
  final int allSetMemberCount;
  final int catalogKeyCount;
  final int exemptCount;

  Iterable<PermissionKeyFinding> get orphans =>
      findings.where((f) => f.code == PermissionKeyFindingCode.orphan);

  Iterable<PermissionKeyFinding> get drifts =>
      findings.where((f) => f.code == PermissionKeyFindingCode.catalogDrift);

  Iterable<PermissionKeyFinding> get missing =>
      findings.where((f) => f.code == PermissionKeyFindingCode.catalogMissing);

  Iterable<PermissionKeyFinding> get rawLiterals =>
      findings.where((f) => f.code == PermissionKeyFindingCode.rawLiteral);

  Iterable<PermissionKeyFinding> get metadataMissing => findings
      .where((f) => f.code == PermissionKeyFindingCode.metadataMissing);

  Iterable<PermissionKeyFinding> get metadataInvalid => findings
      .where((f) => f.code == PermissionKeyFindingCode.metadataInvalid);

  bool get isClean => findings.isEmpty;
}

/// In-memory façade so tests can drive the lint without touching the
/// filesystem.
class PermissionKeyLintRunner {
  PermissionKeyLintRunner({
    required this.permissionKeysSource,
    required this.referenceFiles,
    required this.catalogMarkdown,
    this.permissionKeyMetadataSource,
    Set<String>? exemptKeys,
    Set<String>? rawLiteralScanScope,
    Set<String>? rawLiteralFileAllowlist,
  }) : exemptKeys = exemptKeys ?? _exemptKeys,
       rawLiteralScanScope = rawLiteralScanScope ?? _rawLiteralScanScope,
       rawLiteralFileAllowlist =
           rawLiteralFileAllowlist ?? _rawLiteralFileAllowlist;

  /// Source body of `lib/auth/permission_keys.dart`.
  final String permissionKeysSource;

  /// Map of `relative-path → file body` for every `*.dart` file in the
  /// ORPHAN-scan scope (lib/, EXCLUDING `lib/auth/permission_keys.dart`).
  /// Also doubles as the input pool for the RAW_LITERAL pass; the pass
  /// ignores any file whose path does not fall under
  /// `rawLiteralScanScope` or that is listed in
  /// `rawLiteralFileAllowlist`.
  final Map<String, String> referenceFiles;

  /// Raw markdown of `docs/contracts/auth_permission_key_catalog.md`.
  final String catalogMarkdown;

  /// Wave 2 R-1L — source body of
  /// `lib/auth/permission_key_metadata.dart`. Optional; when null the
  /// metadata-coverage pass is skipped (legacy callers that only care
  /// about the catalog ↔ constants pair).
  final String? permissionKeyMetadataSource;

  /// Constant names exempt from ORPHAN findings.
  final Set<String> exemptKeys;

  /// Repo-relative directory or file paths in scope for the RAW_LITERAL
  /// pass. Listing a directory matches every `*.dart` file beneath it.
  final Set<String> rawLiteralScanScope;

  /// Files inside `rawLiteralScanScope` whose raw permission-shaped
  /// literals are intentional (catalog descriptions, fixtures, audit-
  /// log action strings) and MUST NOT fire RAW_LITERAL.
  final Set<String> rawLiteralFileAllowlist;

  PermissionKeyLintResult run() {
    final findings = <PermissionKeyFinding>[];
    final constants = _parseConstants(permissionKeysSource);
    final allSetMembers = _parseAllSetMembers(permissionKeysSource);
    final catalogKeys = _parseCatalogKeys(catalogMarkdown);

    final classMemberCount =
        constants.where((c) => c.shape == PermissionKeyShape.classMember).length;
    final topLevelCount =
        constants.where((c) => c.shape == PermissionKeyShape.topLevel).length;

    final codeKeysByValue = <String, String>{};
    for (final c in constants) {
      codeKeysByValue[c.value] = c.name;
    }

    // ORPHAN — declared but unreachable.
    for (final c in constants) {
      if (exemptKeys.contains(c.name)) continue;

      // Class members are "exposed" if they appear in the
      // `PermissionKeys.all` set; the runtime resolver iterates that
      // set so set membership is a real runtime use of the constant.
      // Top-level constants have no equivalent set — they must be
      // referenced by name somewhere.
      if (c.shape == PermissionKeyShape.classMember &&
          allSetMembers.contains(c.name)) {
        continue;
      }

      // Direct-reference scan. Class members are typically referenced
      // as `PermissionKeys.<name>`; we also accept the bare name
      // because some callsites destructure into a local. Top-level
      // constants are referenced bare.
      final searchNeedle = c.name;
      final used = referenceFiles.values.any((body) {
        return RegExp(r'\b' + RegExp.escape(searchNeedle) + r'\b')
            .hasMatch(body);
      });
      if (!used) {
        findings.add(PermissionKeyFinding(
          code: PermissionKeyFindingCode.orphan,
          constName: c.name,
          dottedKey: c.value,
          detail: c.shape == PermissionKeyShape.classMember
              ? 'declared as PermissionKeys.${c.name} but not added to '
                  'PermissionKeys.all and not referenced under lib/. '
                  'Either add it to PermissionKeys.all or remove the '
                  'declaration.'
              : 'declared in lib/auth/permission_keys.dart but no '
                  'references found under lib/. Either wire it up or '
                  'add the constant name to _exemptKeys with a reason.',
        ));
      }
    }

    // CATALOG_MISSING — code defines a key, catalog doesn't.
    for (final c in constants) {
      if (!catalogKeys.contains(c.value)) {
        findings.add(PermissionKeyFinding(
          code: PermissionKeyFindingCode.catalogMissing,
          constName: c.name,
          dottedKey: c.value,
          detail: 'add a row for `${c.value}` to '
              'docs/contracts/auth_permission_key_catalog.md.',
        ));
      }
    }

    // CATALOG_DRIFT — catalog row exists, no constant declares the key.
    for (final ck in catalogKeys) {
      if (!codeKeysByValue.containsKey(ck)) {
        findings.add(PermissionKeyFinding(
          code: PermissionKeyFindingCode.catalogDrift,
          constName: '',
          dottedKey: ck,
          detail: 'remove the row from the catalog OR add a '
              'matching constant in lib/auth/permission_keys.dart.',
        ));
      }
    }

    // RAW_LITERAL — operator-self-service widgets routed inline strings
    // around the frozen catalog. Scope: every file under
    // `rawLiteralScanScope` whose path is not in
    // `rawLiteralFileAllowlist`. Per-line escape hatch:
    // `// ignore-permission-key-lint: <reason>` on the same line.
    findings.addAll(_scanRawLiterals(
      referenceFiles: referenceFiles,
      scanScope: rawLiteralScanScope,
      fileAllowlist: rawLiteralFileAllowlist,
    ));

    // Wave 2 R-1L — METADATA pass. Every constant in
    // `PermissionKeys.all` (i.e. shipped to the runtime resolver)
    // must carry an entry in
    // `PermissionKeyMetadataCatalog.byKey` with non-empty
    // `productLabel` + `categoryLabel` and a recognised
    // `scopeKind`. The pass is skipped when the metadata source
    // body is not supplied so legacy callers (and tests that only
    // care about the catalog ↔ constants pair) stay green.
    final metadataSource = permissionKeyMetadataSource;
    if (metadataSource != null) {
      // Build a name-keyed view of the parsed metadata entries.
      final parsedMetadata = _parsePermissionKeyMetadata(metadataSource);
      for (final c in constants) {
        if (c.shape != PermissionKeyShape.classMember) continue;
        // Skip orphans — those already fire ORPHAN. Metadata is only
        // required for keys actually exposed via PermissionKeys.all.
        if (!allSetMembers.contains(c.name)) continue;
        final meta = parsedMetadata[c.name];
        if (meta == null) {
          findings.add(PermissionKeyFinding(
            code: PermissionKeyFindingCode.metadataMissing,
            constName: c.name,
            dottedKey: c.value,
            detail: 'add a PermissionKeyMetadata entry for '
                '`${c.value}` to lib/auth/permission_key_metadata.dart '
                'with productLabel + categoryLabel + scopeKind. '
                'Wave 2 R-1L requires every grantable permission key '
                'to carry product / category / scope metadata so the '
                'R-2L editor can group + scope-validate it.',
          ));
          continue;
        }
        if (meta.productLabel.isEmpty) {
          findings.add(PermissionKeyFinding(
            code: PermissionKeyFindingCode.metadataInvalid,
            constName: c.name,
            dottedKey: c.value,
            detail: 'metadata entry for `${c.value}` carries empty '
                'productLabel. Set the product grouping (e.g. '
                "'forgeflow', 'team', 'integration').",
          ));
        }
        if (meta.categoryLabel.isEmpty) {
          findings.add(PermissionKeyFinding(
            code: PermissionKeyFindingCode.metadataInvalid,
            constName: c.name,
            dottedKey: c.value,
            detail: 'metadata entry for `${c.value}` carries empty '
                'categoryLabel. Set the UI grouping label (e.g. '
                "'Team management').",
          ));
        }
        if (!_validScopeKinds.contains(meta.scopeKind)) {
          findings.add(PermissionKeyFinding(
            code: PermissionKeyFindingCode.metadataInvalid,
            constName: c.name,
            dottedKey: c.value,
            detail: 'metadata entry for `${c.value}` has scopeKind '
                "'${meta.scopeKind}' which is not one of "
                "${_validScopeKinds.join(', ')}.",
          ));
        }
      }
    }

    return PermissionKeyLintResult(
      findings: findings,
      parsedConstantCount: constants.length,
      classMemberCount: classMemberCount,
      topLevelCount: topLevelCount,
      allSetMemberCount: allSetMembers.length,
      catalogKeyCount: catalogKeys.length,
      exemptCount: exemptKeys.length,
    );
  }
}

/// Wave 2 R-1L — parsed metadata entry from
/// `lib/auth/permission_key_metadata.dart`. The lint cares only
/// about coverage (every PermissionKeys.all member has an entry) and
/// validity (productLabel + categoryLabel non-empty, scopeKind is one
/// of [_validScopeKinds]).
class _ParsedPermissionKeyMetadata {
  const _ParsedPermissionKeyMetadata({
    required this.productLabel,
    required this.categoryLabel,
    required this.scopeKind,
  });

  final String productLabel;
  final String categoryLabel;
  final String scopeKind;
}

/// Accepted values for `PermissionScopeKind`. The lint enforces the
/// runtime `enum` and the migration's CHECK stay in sync.
const Set<String> _validScopeKinds = <String>{
  'orgWide',
  'locationScoped',
  'either',
};

/// Matches a `PermissionKeyMetadataCatalog.byKey` map entry:
///
///   PermissionKeys.foo: PermissionKeyMetadata(
///     productLabel: 'foo',
///     categoryLabel: 'Foo group',
///     scopeKind: PermissionScopeKind.either,
///     implies: <String>[...],
///   ),
///
/// Captured groups:
///   1 — PermissionKeys constant name (e.g. `foo`).
///   2 — body of the PermissionKeyMetadata constructor call.
final RegExp _metadataEntryPattern = RegExp(
  r'PermissionKeys\.([A-Za-z_][A-Za-z0-9_]*)\s*:\s*'
  r'PermissionKeyMetadata\s*\(([\s\S]*?)\)\s*,',
);

final RegExp _productLabelPattern = RegExp(
  r"""productLabel\s*:\s*['"]([^'"]*)['"]""",
);
final RegExp _categoryLabelPattern = RegExp(
  r"""categoryLabel\s*:\s*['"]([^'"]*)['"]""",
);
final RegExp _scopeKindPattern = RegExp(
  r'scopeKind\s*:\s*PermissionScopeKind\.([A-Za-z_]+)\b',
);

/// Parses every `PermissionKeys.<name>: PermissionKeyMetadata(...)`
/// entry in `permission_key_metadata.dart` and returns a map keyed by
/// the bare constant name (e.g. `forgeflowShiftView`). The values
/// carry only the three lint-relevant fields; the `implies` field is
/// ignored — its correctness is enforced separately via the migration
/// + the runtime resolver tests.
Map<String, _ParsedPermissionKeyMetadata> _parsePermissionKeyMetadata(
  String source,
) {
  final out = <String, _ParsedPermissionKeyMetadata>{};
  for (final m in _metadataEntryPattern.allMatches(source)) {
    final name = m.group(1)!;
    final body = m.group(2)!;
    final productMatch = _productLabelPattern.firstMatch(body);
    final categoryMatch = _categoryLabelPattern.firstMatch(body);
    final scopeMatch = _scopeKindPattern.firstMatch(body);
    out[name] = _ParsedPermissionKeyMetadata(
      productLabel: productMatch?.group(1) ?? '',
      categoryLabel: categoryMatch?.group(1) ?? '',
      scopeKind: scopeMatch?.group(1) ?? '',
    );
  }
  return out;
}

/// Returns true iff [relPath] (forward-slash form) falls under any
/// entry in [scope]. A directory entry must end in `/`; a file entry
/// matches by exact equality.
bool _pathInScope(String relPath, Set<String> scope) {
  for (final entry in scope) {
    if (entry.endsWith('/')) {
      if (relPath.startsWith(entry)) return true;
    } else if (relPath == entry) {
      return true;
    }
  }
  return false;
}

/// Permission-key shaped string literal. Anchored on a quote followed
/// by a lowercase first segment, then at least one `.`-separated
/// subsegment, and a matching closing quote. Both `'` and `"` literal
/// styles are accepted (the back-reference forces the pair to match).
/// The first-segment filter keeps the regex from firing on unrelated
/// dotted strings (e.g. URL paths, package names); callers cross-check
/// against `_permissionCategoryPrefixes` before emitting a finding.
final RegExp _rawLiteralPattern = RegExp(
  r"""(['"])([a-z][a-z0-9_]*)\.([a-zA-Z0-9_]+(?:\.[a-zA-Z0-9_]+)*)\1""",
);

/// Scans [referenceFiles] for raw permission-key string literals and
/// returns one RAW_LITERAL finding per offending line.
Iterable<PermissionKeyFinding> _scanRawLiterals({
  required Map<String, String> referenceFiles,
  required Set<String> scanScope,
  required Set<String> fileAllowlist,
}) sync* {
  final entries = referenceFiles.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  for (final entry in entries) {
    final path = entry.key;
    if (!_pathInScope(path, scanScope)) continue;
    if (fileAllowlist.contains(path)) continue;
    final lines = entry.value.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (_rawLiteralIgnorePattern.hasMatch(line)) continue;
      for (final m in _rawLiteralPattern.allMatches(line)) {
        final firstSegment = m.group(2)!;
        if (!_permissionCategoryPrefixes.contains(firstSegment)) continue;
        final dotted = '$firstSegment.${m.group(3)!}';
        yield PermissionKeyFinding(
          code: PermissionKeyFindingCode.rawLiteral,
          constName: '',
          dottedKey: dotted,
          location: '$path:${i + 1}',
          detail: 'route this through the frozen catalog at '
              'lib/auth/permission_keys.dart (e.g. PermissionKeys.<name>) '
              'or add `// ignore-permission-key-lint: <reason>` on the '
              'same line if the literal is intentional.',
        );
        // One finding per line is enough — repeated literals on the
        // same line share a remediation.
        break;
      }
    }
  }
}

/// One parsed permission-key constant.
class _ParsedConstant {
  const _ParsedConstant({
    required this.name,
    required this.value,
    required this.shape,
  });
  final String name;
  final String value;
  final PermissionKeyShape shape;
}

// ─── Parsing helpers ──────────────────────────────────────────────

/// Class-namespaced declarations — `static const String <name> = '<value>';`
/// inside `class PermissionKeys`. Whitespace tolerant so multi-line
/// declarations (e.g. `static const String fooLong =\n    'bar';`)
/// parse correctly. Captured groups: 1=name, 2=value.
final RegExp _classMemberPattern = RegExp(
  r'''static\s+const\s+String\s+(\w+)\s*=\s*['"]([^'"]+)['"]\s*;''',
);

/// Top-level `const String kFf…` / `kPerm…` declarations. Anchored on
/// a line start so a `static const` member that happens to begin with
/// `kFf` or `kPerm` is not double-counted.
final RegExp _topLevelConstPattern = RegExp(
  r'''^const\s+String\s+(k(?:Ff|Perm)\w*)\s*=\s*['"]([^'"]+)['"]\s*;''',
  multiLine: true,
);

/// Any `static const Set<String> <name> = <String>{ … };` declaration.
/// Captures both the set name (g1) and the inner member list (g2).
/// `PermissionKeys.all` is the headline runtime set, but the file also
/// declares `requiresMfa` and `baselineRoleKeys`; a constant present
/// in any of these sets is reachable at runtime, which the orphan
/// rule must respect.
final RegExp _allSetPattern = RegExp(
  r'''static\s+const\s+Set<String>\s+(\w+)\s*=\s*<String>\s*\{([\s\S]*?)\};''',
);

/// A permission-key value is a lowercase identifier with at least
/// one `.` separator (e.g. `forgeflow.shift.view`,
/// `integration.7shifts.connect`). Bare identifiers (`super_admin`,
/// `ff_support` — these are role keys, declared in
/// `PermissionKeys.baselineRoleKeys`) are intentionally NOT permission
/// keys and are filtered out so the lint does not chase them through
/// the catalog cross-reference.
final RegExp _permissionKeyValueShape = RegExp(
  r'^[a-z][a-z0-9_]*(?:\.[a-zA-Z0-9_]+)+$',
);

List<_ParsedConstant> _parseConstants(String source) {
  final out = <_ParsedConstant>[];
  // Class members first. Both `_classMemberPattern` and
  // `_topLevelConstPattern` could in principle overlap on a name like
  // `kFfFoo`; class members have the `static` keyword, top-level
  // declarations don't, so the patterns are disjoint by construction.
  for (final m in _classMemberPattern.allMatches(source)) {
    final value = m.group(2)!;
    if (!_permissionKeyValueShape.hasMatch(value)) continue;
    out.add(_ParsedConstant(
      name: m.group(1)!,
      value: value,
      shape: PermissionKeyShape.classMember,
    ));
  }
  for (final m in _topLevelConstPattern.allMatches(source)) {
    final value = m.group(2)!;
    if (!_permissionKeyValueShape.hasMatch(value)) continue;
    out.add(_ParsedConstant(
      name: m.group(1)!,
      value: value,
      shape: PermissionKeyShape.topLevel,
    ));
  }
  return out;
}

/// Returns the union of bare member names listed across every
/// `static const Set<String>` member of `PermissionKeys`. The Set
/// initializer bodies are parsed for `\w+`-shaped tokens; non-
/// identifier tokens (commas, whitespace, comments, the surrounding
/// `<String>{}`) are discarded.
Set<String> _parseAllSetMembers(String source) {
  final out = <String>{};
  for (final m in _allSetPattern.allMatches(source)) {
    final inner = m.group(2)!;
    // Strip line and block comments inside the set body so an inline
    // comment like `// MFA` does not contribute spurious tokens.
    final stripped = inner
        .replaceAll(RegExp(r'//[^\n]*'), '')
        .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
    for (final tok in RegExp(r'\b([a-zA-Z_]\w*)\b').allMatches(stripped)) {
      out.add(tok.group(1)!);
    }
  }
  return out;
}

/// Catalog markdown contains the dotted permission keys in the first
/// cell of each per-category table row. The pattern anchors on the
/// row's leading `|` so backtick-wrapped identifiers in prose (e.g.
/// `\`PermissionKeys.all\``, `\`public.roles\``) do not bleed into
/// the catalog set. The first segment is restricted to lowercase
/// (`[a-z][a-z0-9_]*`) so the table marker `| Key | Description |`
/// header alongside Dart-identifier mentions stays out. Subdomains
/// after the first `.` may start with a digit
/// (`integration.7shifts.connect`).
final RegExp _catalogKeyPattern = RegExp(
  r'^\|\s*`([a-z][a-z0-9_]*(?:\.[a-zA-Z0-9_]+)+)`\s*\|',
  multiLine: true,
);

Set<String> _parseCatalogKeys(String markdown) {
  final out = <String>{};
  for (final m in _catalogKeyPattern.allMatches(markdown)) {
    out.add(m.group(1)!);
  }
  return out;
}

// ─── CLI ──────────────────────────────────────────────────────────

/// Production CLI entrypoint.
Future<void> main(List<String> args) async {
  final permissionKeysFile = File('lib/auth/permission_keys.dart');
  final catalogFile =
      File('docs/contracts/auth_permission_key_catalog.md');
  // Wave 2 R-1L — metadata mirror.
  final metadataFile = File('lib/auth/permission_key_metadata.dart');

  if (!permissionKeysFile.existsSync()) {
    stderr.writeln('permission_key_lint: '
        'lib/auth/permission_keys.dart not found '
        '(run from repository root).');
    exitCode = 2;
    return;
  }
  if (!catalogFile.existsSync()) {
    stderr.writeln('permission_key_lint: '
        'docs/contracts/auth_permission_key_catalog.md not found '
        '(run from repository root).');
    exitCode = 2;
    return;
  }
  if (!metadataFile.existsSync()) {
    stderr.writeln('permission_key_lint: '
        'lib/auth/permission_key_metadata.dart not found '
        '(run from repository root).');
    exitCode = 2;
    return;
  }

  final referenceFiles = <String, String>{};
  final libDir = Directory('lib');
  if (libDir.existsSync()) {
    for (final entity in libDir.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      if (!entity.path.toLowerCase().endsWith('.dart')) continue;
      final rel = entity.path.replaceAll(r'\', '/');
      if (rel == 'lib/auth/permission_keys.dart') continue;
      referenceFiles[rel] = entity.readAsStringSync();
    }
  }

  final runner = PermissionKeyLintRunner(
    permissionKeysSource: permissionKeysFile.readAsStringSync(),
    referenceFiles: referenceFiles,
    catalogMarkdown: catalogFile.readAsStringSync(),
    permissionKeyMetadataSource: metadataFile.readAsStringSync(),
  );
  final result = runner.run();

  stdout.writeln(
    'permission_key_lint: parsed ${result.parsedConstantCount} '
    'constant(s) (${result.classMemberCount} class members, '
    '${result.topLevelCount} top-level k(Ff|Perm)*); '
    '${result.allSetMemberCount} entries in PermissionKeys.all; '
    'catalog declares ${result.catalogKeyCount} dotted key(s); '
    '${result.exemptCount} exempt entries configured; '
    'RAW_LITERAL pass scope: '
    '${_rawLiteralScanScope.length} root(s), '
    '${_rawLiteralFileAllowlist.length} file allowlist entry(ies).',
  );

  if (result.isClean) {
    stdout.writeln('permission_key_lint: clean — no orphans / drift / '
        'missing entries / raw literals / missing or invalid '
        'PermissionKeyMetadata entries.');
    return;
  }

  stderr.writeln('permission_key_lint: '
      '${result.findings.length} finding(s):');
  for (final f in result.findings) {
    stderr.writeln('  - $f');
  }
  exitCode = 1;
}
