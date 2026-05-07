// Phase 8 Wave B `8.gap-7.vendor-completeness-lint` — vendor completeness
// lint.
//
// Authority:
//   * `docs/phases/phase_8/vendor_master_list.md` — canonical roster of
//     17 INTEGRATE vendors and their lifecycle.
//   * `docs/contracts/vendor_adapter_slice_contract.md` — framework rules
//     each adapter must honour.
//   * `memory/project_phase_8_engineer_all_17_doctrine.md` — engineer-all-
//     17 decision lock.
//
// Why this lint exists: adding a new vendor without one of (adapter, sink,
// transport, signature verifier, registration in adapter_registry) silently
// leaves a dormancy gap. The framework will accept the new `vendor_id`
// in capability profiles / connector_connection rows, but the runtime path
// won't actually wake up because either the canonical sink isn't wired,
// the transport isn't built, or the registry doesn't know how to construct
// the adapter. This lint asserts every non-stub vendor in
// `vendor_master_list.md` has all five pieces, and prints a tabular
// per-vendor report.
//
// Pattern conventions:
//   * adapter file:    `lib/integrations/<category>/<vendor>_*_adapter.dart`
//   * canonical sink:  `lib/infrastructure/persistence/postgres/<vendor>_*_postgres_sink.dart`
//   * transport:       `lib/integrations/<category>/<vendor>_*_production_api_client.dart`
//   * verifier:        `lib/integrations/<category>/<vendor>_webhook_signature_verifier.dart`
//   * registry:        `tool/advisor_proxy/<category>_adapter_registry.dart`
//     contains the literal vendor_id string somewhere in its body.
//
// `*` is a shell-style glob (matches zero or more characters, including
// underscores). For the verifier the literal pattern matches exactly:
// `<vendor>_webhook_signature_verifier.dart`.
//
// Lifecycle handling (lifecycle column in vendor_master_list.md):
//   * `stub` (or no lifecycle declared but vendor is in CANNOT/DO NOT
//     INTEGRATE) — skipped. Today no vendor in this list carries the
//     `stub` lifecycle, but the lint accepts it for forward compatibility.
//   * `documented` — default Wave B target. Skipped UNLESS `--strict` is
//     passed. Strict mode is the V1 hardening gate the operator runs
//     manually before launch; CI runs the default loose gate.
//   * `sandbox_verified` / `production_credentialed` — always asserted.
//
// Exposed surface:
//   * `VendorCompletenessLintRunner` — testable façade. Construct with a
//     fake filesystem (a `VendorCompletenessFs`) and a parsed roster.
//     Tests pass synthetic data; the CLI reads the live repo.
//   * `parseVendorMasterList(String body)` — parses the master list
//     markdown into `List<VendorRoster>`.
//   * `main(List<String>)` — CLI entrypoint.
//
// Run locally:
//
//   dart run tool/vendor_completeness_lint.dart [--strict]
//
// Default mode (no flag) skips `documented` vendors (the entire Wave B
// roster today) — useful as a CI guard against silent regressions while
// `*.live.*` slices land. Strict mode flips `documented` → fail and is
// the gate the operator runs before V1.
//
// Expected-failure list at slice-close (`8.gap-7` lands 2026-05-06):
//
//   12 of 17 vendors carry a webhook signature verifier; the other 5
//   are awaiting Gap 1 (the verifier-coverage slice). The 5 expected
//   verifier-missing rows under `--strict` are:
//
//     - oracle_micros_simphony    (POS)
//     - quickbooks_time           (Scheduling)
//     - humanity                  (Scheduling)
//     - agendrix                  (Scheduling)
//     - push_operations           (Scheduling)
//
//   When Gap 1 lands and creates
//   `lib/integrations/<category>/<vendor>_webhook_signature_verifier.dart`
//   for each of the above, this lint run under `--strict` should exit 0.
//   No code change in this script is required at that point — the file
//   discovery is automatic.

import 'dart:io';

// ─── Roster types ──────────────────────────────────────────────────

/// Vendor lifecycle declared in `vendor_master_list.md`. Encoded loosely
/// because the master list is human-edited markdown; unrecognised values
/// fall back to `documented` (the Wave B default).
enum VendorLifecycle {
  /// Engineering not started; lint skips entirely regardless of `--strict`.
  stub,

  /// Wave B documented adapter. Skipped without `--strict`; failed with.
  documented,

  /// Sandbox-verified `*.live.sandbox` slice landed. Always asserted.
  sandboxVerified,

  /// Production-credentialed `*.live.prod` slice landed. Always asserted.
  productionCredentialed,
}

String _lifecycleLabel(VendorLifecycle l) {
  switch (l) {
    case VendorLifecycle.stub:
      return 'stub';
    case VendorLifecycle.documented:
      return 'documented';
    case VendorLifecycle.sandboxVerified:
      return 'sandbox_verified';
    case VendorLifecycle.productionCredentialed:
      return 'production_credentialed';
  }
}

/// Vendor categories the lint distinguishes. Mapped to the
/// `lib/integrations/{pos,reservation,labor}/` directory and the
/// `tool/advisor_proxy/{pos,reservation,labor}_adapter_registry.dart`
/// filename.
enum VendorCategory { pos, reservation, labor }

String _categoryLabel(VendorCategory c) {
  switch (c) {
    case VendorCategory.pos:
      return 'pos';
    case VendorCategory.reservation:
      return 'reservation';
    case VendorCategory.labor:
      return 'labor';
  }
}

/// One row of the vendor roster after parsing `vendor_master_list.md`.
class VendorRoster {
  const VendorRoster({
    required this.vendorId,
    required this.category,
    required this.lifecycle,
    required this.displayName,
  });

  /// Stable `connector_connection.vendor_id` (e.g. `'toast'`,
  /// `'oracle_micros_simphony'`).
  final String vendorId;

  final VendorCategory category;

  final VendorLifecycle lifecycle;

  /// Cosmetic — used in the per-vendor table report only.
  final String displayName;

  @override
  String toString() =>
      'VendorRoster($vendorId/${_categoryLabel(category)}/${_lifecycleLabel(lifecycle)})';
}

// ─── Roster parser ──────────────────────────────────────────────────

/// Hardcoded roster of the 17 INTEGRATE vendors. The lint resolves the
/// vendor_id (column `Slice` in the wave plan, e.g. `8.TS` → `toast`)
/// because the master-list table headers describe display names, not
/// vendor_ids. Parsing the markdown directly is brittle (the table is
/// "Vendor | Verdict | Why | Notes" with display names like "Lightspeed
/// Restaurant (K-Series)"); this lookup table sits in the lint and is
/// source-controlled alongside.
///
/// When a new vendor lands, edit this list AND the master-list document.
/// The roster parser asserts both lists agree (every vendor here has a
/// matching INTEGRATE-row display name in the markdown) so a drift
/// fails the lint.
const List<VendorRoster> _kCanonicalRoster = <VendorRoster>[
  // POS — 7 INTEGRATE vendors.
  VendorRoster(
    vendorId: 'toast',
    category: VendorCategory.pos,
    lifecycle: VendorLifecycle.documented,
    displayName: 'Toast',
  ),
  VendorRoster(
    vendorId: 'square',
    category: VendorCategory.pos,
    lifecycle: VendorLifecycle.documented,
    displayName: 'Square',
  ),
  VendorRoster(
    vendorId: 'lightspeed_lsk',
    category: VendorCategory.pos,
    lifecycle: VendorLifecycle.documented,
    displayName: 'Lightspeed Restaurant (K-Series)',
  ),
  VendorRoster(
    vendorId: 'clover',
    category: VendorCategory.pos,
    lifecycle: VendorLifecycle.documented,
    displayName: 'Clover',
  ),
  VendorRoster(
    vendorId: 'revel',
    category: VendorCategory.pos,
    lifecycle: VendorLifecycle.documented,
    displayName: 'Revel',
  ),
  VendorRoster(
    vendorId: 'aloha_ncr_voyix',
    category: VendorCategory.pos,
    lifecycle: VendorLifecycle.documented,
    displayName: 'Aloha (NCR Voyix)',
  ),
  VendorRoster(
    vendorId: 'oracle_micros_simphony',
    category: VendorCategory.pos,
    lifecycle: VendorLifecycle.documented,
    displayName: 'Oracle MICROS Simphony',
  ),
  // Reservations — 4 INTEGRATE vendors.
  VendorRoster(
    vendorId: 'libro',
    category: VendorCategory.reservation,
    lifecycle: VendorLifecycle.documented,
    displayName: 'Libro',
  ),
  VendorRoster(
    vendorId: 'opentable',
    category: VendorCategory.reservation,
    lifecycle: VendorLifecycle.documented,
    displayName: 'OpenTable',
  ),
  VendorRoster(
    vendorId: 'sevenrooms',
    category: VendorCategory.reservation,
    lifecycle: VendorLifecycle.documented,
    displayName: 'SevenRooms',
  ),
  VendorRoster(
    vendorId: 'tock',
    category: VendorCategory.reservation,
    lifecycle: VendorLifecycle.documented,
    displayName: 'Tock',
  ),
  // Labor / scheduling — 6 INTEGRATE vendors.
  VendorRoster(
    vendorId: 'quickbooks_time',
    category: VendorCategory.labor,
    lifecycle: VendorLifecycle.documented,
    displayName: 'QuickBooks Time',
  ),
  // 7shifts master-list display = "7shifts"; runtime vendor_id is
  // `seven_shifts` (matches the `kSevenShiftsVendorId = 'seven_shifts'`
  // constant in `lib/integrations/labor/seven_shifts_labor_adapter.dart`
  // which keys `connector_connection.vendor_id`). The lint asserts file
  // existence under the runtime vendor_id; the master-list audit relies
  // on the displayName field.
  VendorRoster(
    vendorId: 'seven_shifts',
    category: VendorCategory.labor,
    lifecycle: VendorLifecycle.documented,
    displayName: '7shifts',
  ),
  VendorRoster(
    vendorId: 'adp',
    category: VendorCategory.labor,
    lifecycle: VendorLifecycle.documented,
    displayName: 'ADP (Workforce Now / Manager)',
  ),
  VendorRoster(
    vendorId: 'humanity',
    category: VendorCategory.labor,
    lifecycle: VendorLifecycle.documented,
    displayName: 'Humanity (TCP)',
  ),
  VendorRoster(
    vendorId: 'agendrix',
    category: VendorCategory.labor,
    lifecycle: VendorLifecycle.documented,
    displayName: 'Agendrix',
  ),
  VendorRoster(
    vendorId: 'push_operations',
    category: VendorCategory.labor,
    lifecycle: VendorLifecycle.documented,
    displayName: 'Push Operations',
  ),
];

/// In-source vendor_id alias map. Some adapter files use a slightly
/// different vendor_id literal than the canonical roster vendor_id;
/// the alias list lets the registry / file-existence scan match either
/// string. Today the map is empty — the roster vendor_ids align 1:1
/// with the runtime `kFooVendorId` constants — but the hook stays so a
/// future migration that renames a vendor_id can land without the lint
/// going red on the in-flight commit.
const Map<String, List<String>> _kVendorIdAliases = <String, List<String>>{};

/// Returns the canonical vendor roster. Tests can pass their own list
/// directly to [VendorCompletenessLintRunner]; the CLI uses this.
List<VendorRoster> canonicalVendorRoster() =>
    List<VendorRoster>.unmodifiable(_kCanonicalRoster);

/// Sanity-check that the canonical roster declared above and the
/// markdown master list agree. Returns the list of (vendor_id,
/// reason) drift findings — empty on success. The CLI runs this
/// before checking files so a missing roster row in the markdown
/// fails immediately.
List<({String vendorId, String reason})> auditRosterAgainstMarkdown(
  String markdown,
  List<VendorRoster> roster,
) {
  final findings = <({String vendorId, String reason})>[];
  // Per-row check: each canonical display name must appear under the
  // matching category section header. Categories live under
  // `## POS …`, `## Reservations …`, `## Scheduling …`. The lint walks
  // the markdown line-by-line, tracking the active category, and
  // verifies the display name appears in an `INTEGRATE` row of that
  // section.
  final lines = markdown.split(RegExp(r'\r?\n'));
  VendorCategory? activeCategory;
  final seen = <String>{}; // vendor_id keys seen in the markdown.
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.startsWith('## POS')) {
      activeCategory = VendorCategory.pos;
      continue;
    }
    if (trimmed.startsWith('## Reservation')) {
      activeCategory = VendorCategory.reservation;
      continue;
    }
    if (trimmed.startsWith('## Scheduling')) {
      activeCategory = VendorCategory.labor;
      continue;
    }
    if (trimmed.startsWith('## ')) {
      // Some other section.
      activeCategory = null;
      continue;
    }
    if (activeCategory == null) continue;
    if (!trimmed.startsWith('|')) continue;
    if (!trimmed.contains('INTEGRATE')) continue;
    if (trimmed.contains('DO NOT INTEGRATE')) continue;
    if (trimmed.contains('CANNOT INTEGRATE')) continue;
    // Match by canonical display name.
    for (final v in roster) {
      if (v.category != activeCategory) continue;
      if (trimmed.contains(v.displayName)) {
        seen.add(v.vendorId);
      }
    }
  }
  for (final v in roster) {
    if (!seen.contains(v.vendorId)) {
      findings.add((
        vendorId: v.vendorId,
        reason:
            'roster vendor "${v.displayName}" '
            '(category=${_categoryLabel(v.category)}) not found in any '
            'INTEGRATE row of vendor_master_list.md',
      ));
    }
  }
  return findings;
}

// ─── Filesystem abstraction ────────────────────────────────────────

/// Read-only filesystem façade so the lint can run against an in-memory
/// fixture in tests. The CLI passes a [LiveVendorCompletenessFs] that
/// wraps `dart:io`; tests pass a [InMemoryVendorCompletenessFs].
abstract class VendorCompletenessFs {
  /// Returns the basenames of every regular file under [dirPath]
  /// relative to repo root, e.g. `'lib/integrations/pos'`. Returns
  /// empty list if the directory does not exist.
  List<String> listDir(String dirPath);

  /// Returns the file body for [filePath] (relative to repo root), or
  /// null if the file does not exist.
  String? readFile(String filePath);
}

/// dart:io-backed filesystem implementation. Used by the CLI.
class LiveVendorCompletenessFs implements VendorCompletenessFs {
  const LiveVendorCompletenessFs([this.repoRoot = '.']);

  final String repoRoot;

  @override
  List<String> listDir(String dirPath) {
    final dir = Directory('$repoRoot/$dirPath');
    if (!dir.existsSync()) return const <String>[];
    return dir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .toList(growable: false);
  }

  @override
  String? readFile(String filePath) {
    final f = File('$repoRoot/$filePath');
    if (!f.existsSync()) return null;
    return f.readAsStringSync();
  }
}

/// In-memory fs for tests. The map keys are repo-rooted paths
/// (e.g. `'lib/integrations/pos/toast_pos_adapter.dart'`) and the
/// values are file bodies.
class InMemoryVendorCompletenessFs implements VendorCompletenessFs {
  InMemoryVendorCompletenessFs(this.files);

  final Map<String, String> files;

  @override
  List<String> listDir(String dirPath) {
    final prefix = dirPath.endsWith('/') ? dirPath : '$dirPath/';
    final out = <String>[];
    for (final p in files.keys) {
      if (!p.startsWith(prefix)) continue;
      final tail = p.substring(prefix.length);
      // Only direct children (no nested dirs).
      if (tail.contains('/')) continue;
      out.add(tail);
    }
    return out;
  }

  @override
  String? readFile(String filePath) => files[filePath];
}

// ─── Lint runner ───────────────────────────────────────────────────

/// One per-vendor row of the lint result table.
class VendorLintRow {
  const VendorLintRow({
    required this.vendor,
    required this.skipped,
    required this.missingPieces,
    required this.adapterPath,
    required this.sinkPath,
    required this.transportPath,
    required this.verifierPath,
    required this.registryHit,
  });

  final VendorRoster vendor;

  /// True when the lifecycle gate excused this vendor from contributing
  /// to the error count. The lint still inspects the filesystem for
  /// every roster entry (so the table reports the per-piece state) but
  /// missing pieces on a skipped row never raise the exit code.
  final bool skipped;

  /// Per-piece findings. Always populated from the filesystem inspection,
  /// regardless of whether the vendor is skipped, so downstream tooling
  /// can render the table accurately.
  final List<VendorLintViolation> missingPieces;

  /// Resolved file path for each piece, if found. Useful for the
  /// table; empty string when the piece was not found.
  final String adapterPath;
  final String sinkPath;
  final String transportPath;
  final String verifierPath;

  /// True when the vendor_id (or any alias) was found in the matching
  /// `tool/advisor_proxy/<category>_adapter_registry.dart` body.
  final bool registryHit;

  /// True when the vendor has missing pieces AND is not skipped — i.e.
  /// the lifecycle gate is engaged and the vendor isn't complete. Used
  /// to drive the CLI exit code.
  bool get hasErrors => !skipped && missingPieces.isNotEmpty;
}

/// Single missing-piece finding.
class VendorLintViolation {
  const VendorLintViolation({
    required this.vendorId,
    required this.piece,
    required this.expectedPath,
    required this.message,
  });

  final String vendorId;

  /// One of: `'adapter'`, `'sink'`, `'transport'`, `'verifier'`,
  /// `'registry'`.
  final String piece;

  /// Glob-style path the lint expected. For registry, this is the
  /// registry filename.
  final String expectedPath;

  /// Operator-facing remediation message.
  final String message;

  @override
  String toString() => '$vendorId · $piece · expected=$expectedPath';
}

/// Aggregate lint result.
class VendorLintResult {
  const VendorLintResult({
    required this.rows,
    required this.skippedCount,
    required this.assertedCount,
  });

  final List<VendorLintRow> rows;
  final int skippedCount;
  final int assertedCount;

  Iterable<VendorLintRow> get errorRows => rows.where((r) => r.hasErrors);

  bool get hasErrors => errorRows.isNotEmpty;

  /// Total individual missing-piece findings on rows whose lifecycle
  /// gate is engaged (i.e., not skipped). Drives the CLI's "N missing
  /// piece(s) detected" summary.
  int get violationCount => rows
      .where((r) => !r.skipped)
      .fold<int>(0, (sum, r) => sum + r.missingPieces.length);

  /// Total missing-piece findings across all rows, including skipped
  /// ones. Used by the report to show the verifier-list expected
  /// failures even when the default lint exits clean.
  int get totalMissingPieceCount =>
      rows.fold<int>(0, (sum, r) => sum + r.missingPieces.length);
}

/// Lint façade. Construct with a vendor roster + a filesystem, then
/// call [run] to get a [VendorLintResult].
class VendorCompletenessLintRunner {
  VendorCompletenessLintRunner({
    required this.fs,
    List<VendorRoster>? roster,
    this.strict = false,
    Map<String, List<String>>? aliasOverrides,
  }) : roster = roster ?? canonicalVendorRoster(),
       aliases = aliasOverrides ?? _kVendorIdAliases;

  final VendorCompletenessFs fs;
  final List<VendorRoster> roster;
  final bool strict;
  final Map<String, List<String>> aliases;

  VendorLintResult run() {
    // Cache directory listings + registry bodies once per category.
    final dirCache = <VendorCategory, List<String>>{};
    final sinkDir = fs.listDir(
      'lib/infrastructure/persistence/postgres',
    );
    final registryBodies = <VendorCategory, String>{};
    for (final c in VendorCategory.values) {
      dirCache[c] = fs.listDir('lib/integrations/${_categoryLabel(c)}');
      final registryPath = _registryPathFor(c);
      registryBodies[c] = fs.readFile(registryPath) ?? '';
    }

    var skipped = 0;
    var asserted = 0;
    final rows = <VendorLintRow>[];
    for (final v in roster) {
      final shouldSkip = _shouldSkip(v.lifecycle, strict);
      if (shouldSkip) {
        skipped++;
      } else {
        asserted++;
      }

      final integrationsListing = dirCache[v.category]!;
      final missing = <VendorLintViolation>[];
      // Vendor filename prefixes the lint should accept for this row.
      // Aliases let a recently-renamed vendor's old filenames keep
      // satisfying the lint while the rename rolls through.
      final fileSearchKeys = <String>[v.vendorId, ...?aliases[v.vendorId]];

      // 1. Adapter — `<vendor>_*_adapter.dart`, but rule out files that
      // already match a more specific pattern (production_api_client,
      // postgres_credential_store, etc.). The simplest reliable rule:
      // the basename ends with `_adapter.dart` AND starts with
      // `<vendor>_`.
      String? adapterPath;
      for (final k in fileSearchKeys) {
        adapterPath = _matchInDir(
          listing: integrationsListing,
          dirPath: 'lib/integrations/${_categoryLabel(v.category)}',
          startsWith: '${k}_',
          endsWith: '_adapter.dart',
          forbidContains: const <String>[],
        );
        if (adapterPath != null) break;
      }
      if (adapterPath == null) {
        missing.add(
          VendorLintViolation(
            vendorId: v.vendorId,
            piece: 'adapter',
            expectedPath:
                'lib/integrations/${_categoryLabel(v.category)}/'
                '${v.vendorId}_*_adapter.dart',
            message:
                'vendor ${v.vendorId} missing adapter at expected path '
                'lib/integrations/${_categoryLabel(v.category)}/'
                '${v.vendorId}_*_adapter.dart',
          ),
        );
      }

      // 2. Sink — `lib/infrastructure/persistence/postgres/<vendor>_*_postgres_sink.dart`.
      // The trailing `_postgres_sink.dart` is exact; the middle is
      // optional (e.g., `agendrix_postgres_sink.dart` has empty middle,
      // `aloha_ncr_voyix_pos_postgres_sink.dart` carries `_pos`).
      String? sinkPath;
      for (final k in fileSearchKeys) {
        sinkPath = _matchInDir(
          listing: sinkDir,
          dirPath: 'lib/infrastructure/persistence/postgres',
          startsWith: k,
          endsWith: '_postgres_sink.dart',
          forbidContains: const <String>[],
        );
        if (sinkPath != null) break;
      }
      if (sinkPath == null) {
        missing.add(
          VendorLintViolation(
            vendorId: v.vendorId,
            piece: 'sink',
            expectedPath:
                'lib/infrastructure/persistence/postgres/'
                '${v.vendorId}_*_postgres_sink.dart',
            message:
                'vendor ${v.vendorId} missing canonical sink at expected '
                'path lib/infrastructure/persistence/postgres/'
                '${v.vendorId}_*_postgres_sink.dart',
          ),
        );
      }

      // 3. Transport — `<vendor>_*_production_api_client.dart`.
      String? transportPath;
      for (final k in fileSearchKeys) {
        transportPath = _matchInDir(
          listing: integrationsListing,
          dirPath: 'lib/integrations/${_categoryLabel(v.category)}',
          startsWith: k,
          endsWith: '_production_api_client.dart',
          forbidContains: const <String>[],
        );
        if (transportPath != null) break;
      }
      if (transportPath == null) {
        missing.add(
          VendorLintViolation(
            vendorId: v.vendorId,
            piece: 'transport',
            expectedPath:
                'lib/integrations/${_categoryLabel(v.category)}/'
                '${v.vendorId}_*_production_api_client.dart',
            message:
                'vendor ${v.vendorId} missing production transport at '
                'expected path lib/integrations/'
                '${_categoryLabel(v.category)}/'
                '${v.vendorId}_*_production_api_client.dart',
          ),
        );
      }

      // 4. Verifier — exact path
      // `<vendor>_webhook_signature_verifier.dart`.
      final verifierBasename =
          '${v.vendorId}_webhook_signature_verifier.dart';
      String? verifierPath;
      for (final k in fileSearchKeys) {
        final candidate = '${k}_webhook_signature_verifier.dart';
        if (integrationsListing.contains(candidate)) {
          verifierPath =
              'lib/integrations/${_categoryLabel(v.category)}/$candidate';
          break;
        }
      }
      if (verifierPath == null) {
        missing.add(
          VendorLintViolation(
            vendorId: v.vendorId,
            piece: 'verifier',
            expectedPath:
                'lib/integrations/${_categoryLabel(v.category)}/'
                '$verifierBasename',
            message:
                'vendor ${v.vendorId} missing webhook signature verifier '
                'at expected path lib/integrations/'
                '${_categoryLabel(v.category)}/$verifierBasename',
          ),
        );
      }

      // 5. Registry — vendor_id either as a quoted string literal in
      // the registry body, OR via a constant identifier defined in the
      // adapter file (e.g., `kAlohaNcrVoyixVendorId = 'aloha_ncr_voyix'`)
      // and referenced from the registry. Both are valid registration
      // shapes; mirroring how the live registry already uses one or the
      // other per vendor.
      final registryPath = _registryPathFor(v.category);
      final registryBody = registryBodies[v.category] ?? '';
      var registryHit = false;
      // 5a — quoted-literal match. A partial identifier match cannot
      // satisfy the lint because we wrap the vendor_id in `'…'` / `"…"`.
      for (final k in fileSearchKeys) {
        if (registryBody.contains("'$k'") || registryBody.contains('"$k"')) {
          registryHit = true;
          break;
        }
      }
      // 5b — constant-identifier match. Pull every `const String FOO =
      // '<vendor_id_or_alias>'` from the adapter file (when found) and
      // check the registry body for the FOO identifier as a whole word.
      if (!registryHit && adapterPath != null) {
        final adapterBody = fs.readFile(adapterPath) ?? '';
        for (final k in fileSearchKeys) {
          for (final ident in _vendorIdConstantIdentifiers(adapterBody, k)) {
            if (RegExp('\\b${RegExp.escape(ident)}\\b').hasMatch(
              registryBody,
            )) {
              registryHit = true;
              break;
            }
          }
          if (registryHit) break;
        }
      }
      if (!registryHit) {
        missing.add(
          VendorLintViolation(
            vendorId: v.vendorId,
            piece: 'registry',
            expectedPath: registryPath,
            message:
                'vendor ${v.vendorId} not registered in $registryPath '
                '(neither a quoted "${v.vendorId}" literal nor a '
                'kFooVendorId constant resolving to "${v.vendorId}" found)',
          ),
        );
      }

      rows.add(
        VendorLintRow(
          vendor: v,
          skipped: shouldSkip,
          missingPieces: missing,
          adapterPath: adapterPath ?? '',
          sinkPath: sinkPath ?? '',
          transportPath: transportPath ?? '',
          verifierPath: verifierPath ?? '',
          registryHit: registryHit,
        ),
      );
    }

    return VendorLintResult(
      rows: rows,
      skippedCount: skipped,
      assertedCount: asserted,
    );
  }

  static bool _shouldSkip(VendorLifecycle lifecycle, bool strict) {
    switch (lifecycle) {
      case VendorLifecycle.stub:
        return true;
      case VendorLifecycle.documented:
        return !strict;
      case VendorLifecycle.sandboxVerified:
      case VendorLifecycle.productionCredentialed:
        return false;
    }
  }

  static String _registryPathFor(VendorCategory c) =>
      'tool/advisor_proxy/${_categoryLabel(c)}_adapter_registry.dart';

  /// Returns the repo-relative path of the first basename in [listing]
  /// that starts with [startsWith], ends with [endsWith], and does not
  /// contain any of [forbidContains]. Returns null if no match.
  String? _matchInDir({
    required List<String> listing,
    required String dirPath,
    required String startsWith,
    required String endsWith,
    required List<String> forbidContains,
  }) {
    for (final basename in listing) {
      if (!basename.startsWith(startsWith)) continue;
      if (!basename.endsWith(endsWith)) continue;
      var bad = false;
      for (final f in forbidContains) {
        if (basename.contains(f)) {
          bad = true;
          break;
        }
      }
      if (bad) continue;
      return '$dirPath/$basename';
    }
    return null;
  }
}

// ─── Helpers ──────────────────────────────────────────────────────

/// Scans [adapterBody] for `const String <ident> = '<vendor_id>';`
/// declarations whose right-hand side equals [vendorId] (single OR
/// double quoted). Returns every matching identifier name. The adapter
/// file conventionally declares `kAlohaNcrVoyixVendorId = 'aloha_ncr_voyix'`
/// (or `agendrixVendorId`, no `k` prefix); the registry file then
/// imports that identifier and uses it as a map key. The lint accepts
/// either quoted-literal OR identifier-reference shape because both
/// are present in the live registry.
Iterable<String> _vendorIdConstantIdentifiers(
  String adapterBody,
  String vendorId,
) sync* {
  // Match either `const String NAME = 'value';` or
  // `const String NAME = "value";`. The pattern is anchored on the
  // `const` keyword and runs across whitespace; multiline regex is
  // unnecessary because each declaration sits on a single line in
  // every adapter file in scope.
  final escaped = RegExp.escape(vendorId);
  final pattern = RegExp(
    "const\\s+String\\s+([a-zA-Z_][\\w]*)\\s*=\\s*['\"]$escaped['\"]\\s*;",
  );
  for (final m in pattern.allMatches(adapterBody)) {
    yield m.group(1)!;
  }
}

// ─── Reporting ─────────────────────────────────────────────────────

/// Formats [result] as a tabular per-vendor report. Used by the CLI
/// and exposed for tests that want to assert on the exact output shape.
///
/// Every row reports the per-piece file state regardless of skip status
/// — the lint always inspects the filesystem. The skip flag only
/// controls whether a missing piece counts as an error. Skipped rows
/// suffix the per-piece cell with `(skip)` so the operator can tell
/// which findings would matter under `--strict`.
String formatLintReport(VendorLintResult result) {
  final buf = StringBuffer();
  buf.writeln(
    'vendor_completeness_lint: '
    '${result.assertedCount} asserted, ${result.skippedCount} skipped '
    '(documented vendors skip without --strict).',
  );
  // Header.
  buf.writeln(
    '┌─────────────────────────┬──────────────┬───────────┬───────────┬───────────┬───────────┬───────────┐',
  );
  buf.writeln(
    '│ vendor_id               │ category     │ adapter   │ sink      │ transport │ verifier  │ registry  │',
  );
  buf.writeln(
    '├─────────────────────────┼──────────────┼───────────┼───────────┼───────────┼───────────┼───────────┤',
  );
  for (final row in result.rows) {
    final missing = <String>{
      for (final p in row.missingPieces) p.piece,
    };
    String cell(String piece) {
      final has = !missing.contains(piece);
      if (has) return row.skipped ? 'ok (skip)' : 'ok';
      return row.skipped ? 'MISS(skip)' : 'MISS';
    }

    buf.writeln(
      '│ ${_pad(row.vendor.vendorId, 23)} │ '
      '${_pad(_categoryLabel(row.vendor.category), 12)} │ '
      '${_pad(cell('adapter'), 9)} │ '
      '${_pad(cell('sink'), 9)} │ '
      '${_pad(cell('transport'), 9)} │ '
      '${_pad(cell('verifier'), 9)} │ '
      '${_pad(cell('registry'), 9)} │',
    );
  }
  buf.writeln(
    '└─────────────────────────┴──────────────┴───────────┴───────────┴───────────┴───────────┴───────────┘',
  );
  // Always report missing pieces — even on skipped rows — so an operator
  // running the default lint sees the verifier-list expected failures
  // documented in the slice.
  final allMissingRows = result.rows.where(
    (r) => r.missingPieces.isNotEmpty,
  );
  if (allMissingRows.isNotEmpty) {
    buf.writeln('');
    buf.writeln(
      'Per-vendor findings (${result.totalMissingPieceCount} '
      'missing piece(s) across ${allMissingRows.length} vendor(s); '
      'rows tagged "(skip)" do not contribute to exit code):',
    );
    for (final row in allMissingRows) {
      for (final v in row.missingPieces) {
        final tag = row.skipped ? '[skip] ' : '[FAIL] ';
        buf.writeln('  $tag${v.message}');
      }
    }
  }
  return buf.toString();
}

String _pad(String s, int n) {
  if (s.length >= n) return s.substring(0, n);
  return s + ' ' * (n - s.length);
}

// ─── CLI entrypoint ────────────────────────────────────────────────

/// Production CLI. Walks the live repo, runs the lint, prints the
/// per-vendor table, and exits non-zero on any missing piece.
Future<void> main(List<String> args) async {
  final strict = args.contains('--strict');
  final fs = LiveVendorCompletenessFs();

  // Audit the canonical roster against the markdown master list first.
  // A drift here means the lint's hardcoded roster has fallen out of
  // sync with the doc — fail loudly so the operator updates both.
  final rosterMd = fs.readFile(
    'docs/phases/phase_8/vendor_master_list.md',
  );
  if (rosterMd == null) {
    stderr.writeln(
      'vendor_completeness_lint: '
      'docs/phases/phase_8/vendor_master_list.md not found '
      '(run from repository root).',
    );
    exitCode = 2;
    return;
  }
  final roster = canonicalVendorRoster();
  final drift = auditRosterAgainstMarkdown(rosterMd, roster);
  if (drift.isNotEmpty) {
    stderr.writeln(
      'vendor_completeness_lint: in-source roster drift vs '
      'vendor_master_list.md (${drift.length} finding(s)):',
    );
    for (final d in drift) {
      stderr.writeln('  - ${d.vendorId}: ${d.reason}');
    }
    stderr.writeln(
      'Fix: align _kCanonicalRoster in tool/vendor_completeness_lint.dart '
      'with the markdown master list.',
    );
    exitCode = 1;
    return;
  }

  final runner = VendorCompletenessLintRunner(
    fs: fs,
    roster: roster,
    strict: strict,
  );
  final result = runner.run();
  stdout.write(formatLintReport(result));

  if (result.hasErrors) {
    stderr.writeln(
      'vendor_completeness_lint: '
      '${result.violationCount} missing piece(s) detected. Exit 1.',
    );
    exitCode = 1;
    return;
  }

  stdout.writeln(
    'vendor_completeness_lint: clean — every '
    '${strict ? 'roster (incl. documented)' : 'non-documented'} vendor '
    'has adapter + sink + transport + verifier + registry registration.',
  );
}
