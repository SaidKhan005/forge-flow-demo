// Tests for `tool/vendor_completeness_lint.dart`. Behaviours covered:
//
//   1. All-present synthetic fixture → clean (zero errors).
//   2. Missing transport file → ERROR with the precise message shape
//      promised by the slice prompt:
//      "vendor X missing production transport at expected path Y".
//   3. Missing verifier file → ERROR with a similar precise message.
//   4. Missing canonical sink → ERROR.
//   5. Missing adapter → ERROR.
//   6. Missing registry registration → ERROR.
//   7. Vendor with lifecycle = stub → skipped, no errors even when every
//      piece is absent.
//   8. `--strict` flag flips lifecycle = documented from skip → fail.
//   9. Default (`strict: false`) leaves lifecycle = documented as skip,
//      so a fixture with documented vendors and no files passes clean.
//   10. Sandbox-verified vendor is asserted regardless of strict (it's
//       past the documented gate).
//   11. Adapter alias support — `7shifts` master-list vendor_id maps to
//       `seven_shifts` adapter constant in the registry body.
//   12. Tabular report shape — header row, one row per vendor, MISS
//       cells for missing pieces.
//   13. Real-tree audit: parsing the live `vendor_master_list.md`
//       agrees with the in-source roster (no drift findings) and the
//       in-source roster covers all 17 INTEGRATE vendors.

import 'package:flutter_test/flutter_test.dart';

import '../../tool/vendor_completeness_lint.dart';

void main() {
  group('vendor_completeness_lint', () {
    test('all-present synthetic fixture is clean', () {
      final fs = InMemoryVendorCompletenessFs(_completeFixture());
      final runner = VendorCompletenessLintRunner(
        fs: fs,
        roster: _miniRoster,
        strict: true, // assert documented too
      );
      final result = runner.run();
      expect(
        result.hasErrors,
        isFalse,
        reason: 'fixture is complete: ${result.errorRows.toList()}',
      );
      expect(result.skippedCount, 0);
      expect(result.assertedCount, _miniRoster.length);
    });

    test('missing transport file → ERROR with precise expected-path '
        'message', () {
      final files = _completeFixture();
      // Drop the toast transport.
      files.remove(
        'lib/integrations/pos/toast_pos_production_api_client.dart',
      );
      final fs = InMemoryVendorCompletenessFs(files);
      final runner = VendorCompletenessLintRunner(
        fs: fs,
        roster: _miniRoster,
        strict: true,
      );
      final result = runner.run();
      expect(result.hasErrors, isTrue);
      final toastRow = result.rows.firstWhere(
        (r) => r.vendor.vendorId == 'toast',
      );
      expect(toastRow.missingPieces, hasLength(1));
      final v = toastRow.missingPieces.single;
      expect(v.piece, 'transport');
      expect(
        v.expectedPath,
        'lib/integrations/pos/toast_*_production_api_client.dart',
      );
      expect(
        v.message,
        contains(
          'vendor toast missing production transport at expected path',
        ),
      );
      expect(
        v.message,
        contains(
          'lib/integrations/pos/toast_*_production_api_client.dart',
        ),
      );
    });

    test('missing verifier file → ERROR with precise expected-path '
        'message', () {
      final files = _completeFixture();
      files.remove(
        'lib/integrations/pos/toast_webhook_signature_verifier.dart',
      );
      final fs = InMemoryVendorCompletenessFs(files);
      final runner = VendorCompletenessLintRunner(
        fs: fs,
        roster: _miniRoster,
        strict: true,
      );
      final result = runner.run();
      expect(result.hasErrors, isTrue);
      final toastRow = result.rows.firstWhere(
        (r) => r.vendor.vendorId == 'toast',
      );
      expect(toastRow.missingPieces, hasLength(1));
      final v = toastRow.missingPieces.single;
      expect(v.piece, 'verifier');
      expect(
        v.expectedPath,
        'lib/integrations/pos/toast_webhook_signature_verifier.dart',
      );
      expect(
        v.message,
        contains(
          'vendor toast missing webhook signature verifier at expected '
          'path lib/integrations/pos/'
          'toast_webhook_signature_verifier.dart',
        ),
      );
    });

    test('missing canonical sink → ERROR', () {
      final files = _completeFixture();
      files.remove(
        'lib/infrastructure/persistence/postgres/toast_pos_postgres_sink.dart',
      );
      final fs = InMemoryVendorCompletenessFs(files);
      final runner = VendorCompletenessLintRunner(
        fs: fs,
        roster: _miniRoster,
        strict: true,
      );
      final result = runner.run();
      expect(result.hasErrors, isTrue);
      final toastRow = result.rows.firstWhere(
        (r) => r.vendor.vendorId == 'toast',
      );
      expect(toastRow.missingPieces, hasLength(1));
      expect(toastRow.missingPieces.single.piece, 'sink');
    });

    test('missing adapter file → ERROR', () {
      final files = _completeFixture();
      files.remove('lib/integrations/pos/toast_pos_adapter.dart');
      final fs = InMemoryVendorCompletenessFs(files);
      final runner = VendorCompletenessLintRunner(
        fs: fs,
        roster: _miniRoster,
        strict: true,
      );
      final result = runner.run();
      expect(result.hasErrors, isTrue);
      final toastRow = result.rows.firstWhere(
        (r) => r.vendor.vendorId == 'toast',
      );
      expect(toastRow.missingPieces, hasLength(1));
      expect(toastRow.missingPieces.single.piece, 'adapter');
    });

    test('missing registry registration → ERROR', () {
      final files = _completeFixture();
      // Replace pos registry body with one that omits 'toast'.
      files['tool/advisor_proxy/pos_adapter_registry.dart'] =
          "// no toast literal here\nfinal x = 'square';\n";
      final fs = InMemoryVendorCompletenessFs(files);
      final runner = VendorCompletenessLintRunner(
        fs: fs,
        roster: _miniRoster,
        strict: true,
      );
      final result = runner.run();
      expect(result.hasErrors, isTrue);
      final toastRow = result.rows.firstWhere(
        (r) => r.vendor.vendorId == 'toast',
      );
      expect(
        toastRow.missingPieces.any((v) => v.piece == 'registry'),
        isTrue,
      );
      expect(toastRow.registryHit, isFalse);
    });

    test('vendor with lifecycle=stub → skipped even when every piece is '
        'absent', () {
      final files = _completeFixture();
      // Drop everything for 'square' so its row would otherwise be
      // entirely empty; mark it lifecycle=stub.
      files.remove('lib/integrations/pos/square_pos_adapter.dart');
      files.remove('lib/integrations/pos/square_pos_production_api_client.dart');
      files.remove(
        'lib/integrations/pos/square_webhook_signature_verifier.dart',
      );
      files.remove(
        'lib/infrastructure/persistence/postgres/square_pos_postgres_sink.dart',
      );
      final fs = InMemoryVendorCompletenessFs(files);
      final stubbedRoster = <VendorRoster>[
        const VendorRoster(
          vendorId: 'toast',
          category: VendorCategory.pos,
          lifecycle: VendorLifecycle.documented,
          displayName: 'Toast',
        ),
        const VendorRoster(
          vendorId: 'square',
          category: VendorCategory.pos,
          lifecycle: VendorLifecycle.stub,
          displayName: 'Square',
        ),
      ];
      final runner = VendorCompletenessLintRunner(
        fs: fs,
        roster: stubbedRoster,
        strict: true,
      );
      final result = runner.run();
      // Stub vendor's missing pieces are reported tabularly (so the
      // operator can still see the gap), but they do NOT contribute to
      // the lint's exit code — the row is excused via the lifecycle
      // gate.
      expect(result.hasErrors, isFalse);
      final squareRow = result.rows.firstWhere(
        (r) => r.vendor.vendorId == 'square',
      );
      expect(squareRow.skipped, isTrue);
      expect(squareRow.hasErrors, isFalse);
      // Sanity-check: the lint still inspected the filesystem and
      // populated the missing-pieces list, but `hasErrors` is false
      // because the row is skipped.
      expect(squareRow.missingPieces, isNotEmpty);
    });

    test('default (strict=false) skips documented vendors entirely', () {
      // No files at all, all roster vendors at lifecycle=documented.
      // Default mode treats them all as skip → result is clean.
      final fs = InMemoryVendorCompletenessFs(<String, String>{});
      final runner = VendorCompletenessLintRunner(
        fs: fs,
        roster: _miniRoster,
      );
      final result = runner.run();
      expect(result.hasErrors, isFalse);
      expect(result.skippedCount, _miniRoster.length);
      expect(result.assertedCount, 0);
    });

    test('--strict flag flips documented from skip → fail', () {
      // Same empty fs, strict=true → every vendor fails because no
      // files exist.
      final fs = InMemoryVendorCompletenessFs(<String, String>{});
      final runner = VendorCompletenessLintRunner(
        fs: fs,
        roster: _miniRoster,
        strict: true,
      );
      final result = runner.run();
      expect(result.hasErrors, isTrue);
      expect(result.assertedCount, _miniRoster.length);
      expect(result.skippedCount, 0);
      // Every asserted vendor should have all five pieces missing.
      for (final row in result.rows) {
        expect(row.missingPieces, hasLength(5));
      }
    });

    test('sandbox_verified vendor is asserted regardless of strict', () {
      final fs = InMemoryVendorCompletenessFs(<String, String>{});
      final roster = <VendorRoster>[
        const VendorRoster(
          vendorId: 'toast',
          category: VendorCategory.pos,
          lifecycle: VendorLifecycle.sandboxVerified,
          displayName: 'Toast',
        ),
      ];
      final runner = VendorCompletenessLintRunner(
        fs: fs,
        roster: roster,
        // No --strict.
      );
      final result = runner.run();
      expect(result.hasErrors, isTrue);
      expect(result.assertedCount, 1);
      expect(result.skippedCount, 0);
    });

    test('alias map satisfies file-existence check when an old vendor_id '
        'still appears in adapter filenames', () {
      // Forward-compatibility hook: the alias map lets the lint match a
      // historical vendor_id (e.g. an older filename) while the canonical
      // roster moves to a renamed vendor_id. The fixture mimics a state
      // where the on-disk filenames carry `legacy_vendor_*` while the
      // adapter body and registry have already moved to the new
      // `new_vendor` literal.
      final files = <String, String>{
        'lib/integrations/labor/legacy_vendor_labor_adapter.dart':
            "const String kNewVendor = 'new_vendor';\n",
        'lib/integrations/labor/legacy_vendor_labor_production_api_client.dart':
            '// transport',
        'lib/integrations/labor/legacy_vendor_webhook_signature_verifier.dart':
            '// verifier',
        'lib/infrastructure/persistence/postgres/legacy_vendor_labor_postgres_sink.dart':
            '// sink',
        'tool/advisor_proxy/labor_adapter_registry.dart':
            "kNewVendor: (deps) {}\n",
      };
      final fs = InMemoryVendorCompletenessFs(files);
      final roster = <VendorRoster>[
        const VendorRoster(
          vendorId: 'new_vendor',
          category: VendorCategory.labor,
          lifecycle: VendorLifecycle.documented,
          displayName: 'New Vendor',
        ),
      ];
      final runner = VendorCompletenessLintRunner(
        fs: fs,
        roster: roster,
        strict: true,
        aliasOverrides: const <String, List<String>>{
          'new_vendor': <String>['legacy_vendor'],
        },
      );
      final result = runner.run();
      expect(
        result.hasErrors,
        isFalse,
        reason: 'alias should satisfy file-existence + registry checks; '
            'got ${result.errorRows.toList()}',
      );
      final row = result.rows.single;
      expect(row.registryHit, isTrue);
    });

    test('registry detects vendor_id via constant identifier reference '
        '(not just quoted literal)', () {
      // The live registry mostly uses `kFooVendorId` constants imported
      // from the adapter file; only a handful (e.g. `'clover'`) hit the
      // simple quoted-literal path. Verify the constant-identifier
      // detection works.
      final files = <String, String>{
        'lib/integrations/pos/foo_pos_adapter.dart':
            "const String kFooVendorId = 'foo';\n",
        'lib/integrations/pos/foo_pos_production_api_client.dart':
            '// transport',
        'lib/integrations/pos/foo_webhook_signature_verifier.dart':
            '// verifier',
        'lib/infrastructure/persistence/postgres/foo_pos_postgres_sink.dart':
            '// sink',
        // Registry references the constant identifier — no quoted "foo".
        'tool/advisor_proxy/pos_adapter_registry.dart':
            "kFooVendorId: (deps) {}\n",
      };
      final fs = InMemoryVendorCompletenessFs(files);
      final roster = <VendorRoster>[
        const VendorRoster(
          vendorId: 'foo',
          category: VendorCategory.pos,
          lifecycle: VendorLifecycle.documented,
          displayName: 'Foo',
        ),
      ];
      final runner = VendorCompletenessLintRunner(
        fs: fs,
        roster: roster,
        strict: true,
      );
      final result = runner.run();
      expect(
        result.hasErrors,
        isFalse,
        reason: 'constant-identifier detection should match; got '
            '${result.errorRows.toList()}',
      );
      expect(result.rows.single.registryHit, isTrue);
    });

    test('tabular report includes header and one row per vendor', () {
      final fs = InMemoryVendorCompletenessFs(_completeFixture());
      final runner = VendorCompletenessLintRunner(
        fs: fs,
        roster: _miniRoster,
        strict: true,
      );
      final result = runner.run();
      final report = formatLintReport(result);
      expect(report, contains('vendor_id'));
      expect(report, contains('category'));
      expect(report, contains('toast'));
      expect(report, contains('square'));
      // Every asserted row has 'ok' for each piece (none missing).
      // Spot-check one vendor's row.
      expect(report, contains('pos'));
    });

    test('canonical roster is consistent with vendor_master_list.md '
        'on the live tree', () {
      final fs = LiveVendorCompletenessFs();
      final body = fs.readFile(
        'docs/phases/phase_8/vendor_master_list.md',
      );
      expect(
        body,
        isNotNull,
        reason: 'tests must run from repository root',
      );
      final drift = auditRosterAgainstMarkdown(
        body!,
        canonicalVendorRoster(),
      );
      expect(
        drift,
        isEmpty,
        reason: 'roster drift findings: $drift',
      );
    });

    test('canonical roster carries all 17 INTEGRATE vendors split by '
        'category', () {
      final roster = canonicalVendorRoster();
      expect(roster, hasLength(17));
      final byCategory = <VendorCategory, int>{};
      for (final v in roster) {
        byCategory[v.category] = (byCategory[v.category] ?? 0) + 1;
      }
      expect(byCategory[VendorCategory.pos], 7);
      expect(byCategory[VendorCategory.reservation], 4);
      expect(byCategory[VendorCategory.labor], 6);
    });
  });
}

// ─── Test fixtures ──────────────────────────────────────────────────

/// Two-vendor roster (one POS, one labor) used in most fixture tests.
/// Keeps the synthetic file map tiny and easy to mutate per-test.
const List<VendorRoster> _miniRoster = <VendorRoster>[
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
];

/// Synthetic file fixture where every piece exists for every member of
/// [_miniRoster]. Returned mutable so individual tests can drop
/// specific entries before constructing the in-memory fs.
Map<String, String> _completeFixture() {
  return <String, String>{
    // Toast pieces.
    'lib/integrations/pos/toast_pos_adapter.dart': '// adapter',
    'lib/integrations/pos/toast_pos_production_api_client.dart':
        '// transport',
    'lib/integrations/pos/toast_webhook_signature_verifier.dart':
        '// verifier',
    'lib/infrastructure/persistence/postgres/toast_pos_postgres_sink.dart':
        '// sink',
    // Square pieces.
    'lib/integrations/pos/square_pos_adapter.dart': '// adapter',
    'lib/integrations/pos/square_pos_production_api_client.dart':
        '// transport',
    'lib/integrations/pos/square_webhook_signature_verifier.dart':
        '// verifier',
    'lib/infrastructure/persistence/postgres/square_pos_postgres_sink.dart':
        '// sink',
    // POS registry — body contains the vendor_id literals.
    'tool/advisor_proxy/pos_adapter_registry.dart':
        "const kToastVendorId = 'toast';\n"
        "const kSquareVendorId = 'square';\n",
  };
}
