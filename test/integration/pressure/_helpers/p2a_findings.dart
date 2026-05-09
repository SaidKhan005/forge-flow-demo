// Phase 2A pressure harness — finding record + sink.
//
// The harness is a FINDING GENERATOR, not a gate. Every divergence
// from expected adapter behavior is appended to a JSONL artifact at
// `test/integration/pressure/p2a_adapter_findings.jsonl` so Phase 5
// can consume the full divergence catalog in a single run.
//
// Findings are not committed; the path is gitignored. The harness
// also returns the in-memory list to the caller so the summary table
// renders in the test log.

import 'dart:convert';
import 'dart:io';

/// One divergence detected during the harness run.
///
/// `divergenceType` values (kept open-ended; new types can be added as
/// the harness probes more seams):
///
/// * `expected_pass_got_reject` — README says accept; adapter / DTO
///   refused.
/// * `expected_reject_got_pass` — README says reject; adapter / DTO
///   accepted.
/// * `wrong_reject_reason` — adapter rejected for a different reason
///   than the README documents.
/// * `wrong_fact_type` — DTO produced a fact of the wrong canonical
///   type (e.g. labor expected, sales returned).
/// * `fact_field_mismatch` — DTO produced a fact whose field values
///   differ from the README's `expectedFactSlice`.
/// * `adapter_not_found` — vendor registry has no parse probe for
///   this adapter (the parse helper is private and no public DTO
///   surface exists).
/// * `fixture_unparseable` — fixture JSON failed to load.
/// * `readme_unparseable` — vendor README's Scenarios table could
///   not be parsed.
/// * `cross_vendor_namespace_collision` — scenario_f pair produced
///   facts with the same vendor namespace (idempotency violation).
/// * `audit_claim_mismatch` — capability profile contradicts an
///   external audit claim (e.g. "Oracle Simphony uses mTLS" when the
///   adapter declares OAuth).
/// * `pre_flagged_bug_confirmed` — known-broken behavior reproduced
///   exactly as predicted by the Phase 5 bug catalog.
/// * `pre_flagged_bug_silently_fixed` — predicted-broken behavior
///   no longer reproduces; bug appears fixed without being recorded.
/// * `harness_defensiveness_gap` — harness needed to swallow an
///   exception to keep going.
class P2aFinding {
  P2aFinding({
    required this.vendor,
    required this.scenario,
    required this.divergenceType,
    required this.detail,
    required this.fixturePath,
  });

  final String vendor;
  final String scenario;
  final String divergenceType;
  final String detail;
  final String fixturePath;

  Map<String, Object?> toJson() => <String, Object?>{
        'vendor': vendor,
        'scenario': scenario,
        'divergence_type': divergenceType,
        'detail': detail,
        'fixture_path': fixturePath,
      };
}

/// Accumulator + JSONL writer for findings. Construct one per harness
/// run; call [record] for each divergence; call [flush] at the end of
/// the test to write the artifact.
class P2aFindingSink {
  P2aFindingSink({required this.outputPath});

  final String outputPath;
  final List<P2aFinding> _findings = <P2aFinding>[];

  List<P2aFinding> get findings => List.unmodifiable(_findings);

  void record(P2aFinding finding) {
    _findings.add(finding);
  }

  /// Write all findings as JSON Lines to [outputPath]. Creates the
  /// file (overwriting existing) so the artifact reflects only the
  /// most recent run.
  void flush() {
    final file = File(outputPath);
    file.parent.createSync(recursive: true);
    final buffer = StringBuffer();
    for (final f in _findings) {
      buffer.writeln(jsonEncode(f.toJson()));
    }
    file.writeAsStringSync(buffer.toString());
  }

  /// Render a sorted summary table grouped by divergence type, then
  /// vendor. Used as the PR-body table.
  String summaryTable() {
    if (_findings.isEmpty) return 'No findings recorded.';
    final byType = <String, Map<String, int>>{};
    for (final f in _findings) {
      byType.putIfAbsent(f.divergenceType, () => <String, int>{});
      byType[f.divergenceType]!
          .update(f.vendor, (n) => n + 1, ifAbsent: () => 1);
    }
    final out = StringBuffer();
    out.writeln('| Divergence Type | Vendor | Count |');
    out.writeln('|---|---|---|');
    final types = byType.keys.toList()..sort();
    for (final t in types) {
      final vendors = byType[t]!.keys.toList()..sort();
      for (final v in vendors) {
        out.writeln('| $t | $v | ${byType[t]![v]} |');
      }
    }
    out.writeln('');
    out.writeln('Total findings: ${_findings.length}');
    return out.toString();
  }
}
