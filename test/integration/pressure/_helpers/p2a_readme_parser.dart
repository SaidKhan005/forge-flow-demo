// Phase 2A pressure harness — per-vendor README parser.
//
// Each vendor README at `test/fixtures/vendor_payloads/<v>/README.md`
// has a Markdown table whose first column is a fixture filename and
// whose second column is the documented outcome. Vendor authors used
// slightly different prose ("accept", "reject (no row)", "drop",
// "refresh path triggers", "N/A — `_sourcing_gap` set", etc.). The
// parser collapses every variant into one of:
//
//   pass        — adapter writes a canonical fact
//   reject      — adapter refuses (signature, parse, sanity)
//   quarantine  — adapter quarantines (Toast scenario_c phrases this)
//   refresh     — credential rotation path (no fact write expected)
//   na          — out of scope for the harness (sourcing gap, etc.)
//   unknown     — outcome wording the parser does not understand;
//                 logged as a `readme_unparseable` finding.

import 'dart:io';

class P2aReadmeRow {
  const P2aReadmeRow({
    required this.fixtureFile,
    required this.rawOutcome,
    required this.normalizedOutcome,
  });

  /// Filename without directory (e.g. `happy_path_order_completed.json`).
  final String fixtureFile;

  /// Verbatim outcome cell from the README.
  final String rawOutcome;

  /// One of: `pass`, `reject`, `quarantine`, `refresh`, `na`,
  /// `unknown`.
  final String normalizedOutcome;
}

/// Parse one vendor README into row records. Returns an empty list
/// when no Scenarios table can be found (caller logs a
/// `readme_unparseable` finding).
///
/// Some vendor authors put the filename in column 1 (most common);
/// Square uses `Scenario | File | Expected outcome | Asserts` so the
/// filename is in column 2. The parser locates the filename cell by
/// scanning every cell of every row for a `*.json` pattern, then
/// picks the cell that *follows* the filename as the outcome — but
/// only when that following cell normalizes to something recognizable
/// (`pass`/`reject`/`refresh`/etc.). When two tables list the same
/// filename, the row whose outcome cell normalizes to a known word
/// wins so the "skeleton assertion" tables (which have no outcome
/// word) do not overwrite the real outcome.
List<P2aReadmeRow> parseVendorReadme(String readmePath) {
  final file = File(readmePath);
  if (!file.existsSync()) return const <P2aReadmeRow>[];
  final lines = file.readAsLinesSync();

  final byFile = <String, P2aReadmeRow>{};
  for (final raw in lines) {
    final line = raw.trim();
    if (!line.startsWith('|')) continue;
    final cells = line
        .split('|')
        .map((c) => c.trim())
        .where((c) => c.isNotEmpty)
        .toList();
    if (cells.length < 2) continue;
    if (cells[0].startsWith('---')) continue; // separator row
    if (cells[0].toLowerCase() == 'file' ||
        cells[0].toLowerCase() == 'scenario') {
      continue; // header row
    }
    // Find the cell that holds the JSON filename.
    int fileIdx = -1;
    String? fixtureFile;
    for (var i = 0; i < cells.length; i++) {
      final stripped = cells[i].replaceAll('`', '').trim();
      if (stripped.endsWith('.json')) {
        fileIdx = i;
        fixtureFile = stripped;
        break;
      }
    }
    if (fixtureFile == null || fileIdx < 0) continue;
    if (fileIdx + 1 >= cells.length) continue;
    final outcome = cells[fileIdx + 1];
    final normalized = _normalizeOutcome(outcome);
    final row = P2aReadmeRow(
      fixtureFile: fixtureFile,
      rawOutcome: outcome,
      normalizedOutcome: normalized,
    );
    final existing = byFile[fixtureFile];
    if (existing == null) {
      byFile[fixtureFile] = row;
    } else if (existing.normalizedOutcome == 'unknown' &&
        normalized != 'unknown') {
      // A later table has a recognizable outcome — prefer it over the
      // earlier "unknown" wording.
      byFile[fixtureFile] = row;
    }
  }
  return byFile.values.toList();
}

String _normalizeOutcome(String outcome) {
  final lc = outcome.toLowerCase();
  // Compound outcomes ("reject OR documented projection") — match
  // either branch; the harness treats this as "ambiguous" so neither
  // a pass nor a reject finding fires.
  if (lc.contains(' or ') &&
      (lc.contains('reject') ||
          lc.contains('drop') ||
          lc.contains('accept') ||
          lc.contains('projection'))) {
    return 'ambiguous';
  }
  // Order matters — most specific phrases first.
  if (lc.contains('refresh')) return 'refresh';
  if (lc.contains('rotat')) return 'refresh';
  if (lc.contains('n/a') ||
      lc.contains('non-event') ||
      lc.contains('skip') ||
      lc.contains('sourcing_gap') ||
      lc.contains('sourcing gap') ||
      lc.contains('out of scope') ||
      lc.contains('out-of-scope') ||
      lc.contains('tolerated') ||
      lc.contains('no_refresh_path') ||
      lc.contains('no refresh path')) {
    return 'na';
  }
  if (lc.contains('quarantine')) return 'quarantine';
  if (lc.contains('reject') || lc.contains('drop')) return 'reject';
  if (lc.contains('accept')) return 'pass';
  if (lc.contains('namespace_isolated') ||
      lc.contains('namespaced') ||
      lc.contains('isolated')) {
    return 'pass';
  }
  // Square's table phrases happy paths as "Adapter produces ..." or
  // "Adapter namespaces ..." — treat the verb-leading shape as a
  // pass when no rejection phrase is present.
  if (lc.contains('adapter produces') ||
      lc.contains('adapter namespaces') ||
      lc.contains('produces') ||
      lc.contains('parses unambiguously') ||
      lc.contains('returns non-null') ||
      lc.contains('resolves')) {
    return 'pass';
  }
  if (lc.contains('write') && !lc.contains('no row')) return 'pass';
  return 'unknown';
}
