// HARD-H — migration content reader with CRLF normalization.
//
// Windows checkouts store `db/migrations/*.sql` files with CRLF line
// endings (Git's `core.autocrlf=true` default). Tests that read those
// files and assert on multi-line substrings would fail on Windows when
// the substring contains LF-only newlines. This helper normalizes CRLF
// → LF at read time so substring assertions are line-ending-agnostic.
//
// Contract:
// `docs/contracts/hardening_test_corrections_contract.md` ("CRLF
// Normalization" section).
//
// Usage:
//
// ```dart
// import '_helpers/migration_lf.dart';
//
// final migration = readMigrationLFSync('db/migrations/foo.sql');
// expect(migration, contains('multi\nline\nsubstring'));
// ```

import 'dart:io';

/// Reads a `db/migrations/*.sql` file and returns its contents with
/// CRLF normalized to LF. Async variant — prefer this in `setUpAll`
/// blocks already returning a `Future`.
Future<String> readMigrationLF(String path) async {
  final raw = await File(path).readAsString();
  return raw.replaceAll('\r\n', '\n');
}

/// Reads a `db/migrations/*.sql` file and returns its contents with
/// CRLF normalized to LF. Synchronous variant — used in `setUpAll`
/// blocks that are not async, mirroring the existing `readAsStringSync`
/// call sites.
String readMigrationLFSync(String path) {
  return File(path).readAsStringSync().replaceAll('\r\n', '\n');
}
