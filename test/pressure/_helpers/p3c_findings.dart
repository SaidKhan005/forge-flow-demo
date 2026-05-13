// Phase 3C OAuth refresh storm pressure harness — finding sink.
//
// Mirrors the Phase 2A finding-sink pattern: every divergence
// observed during the storm becomes a JSONL line in
// `test/pressure/p3c_oauth_refresh_storm_findings.jsonl` so
// Phase 5 can consume the catalog in a single pass. The harness is a
// FINDING GENERATOR, not a gate — the test only fails when the
// harness itself cannot proceed.

import 'dart:convert';
import 'dart:io';

/// One divergence detected during a P3C run. `category` values are
/// the documented set in the prompt:
///
/// * `advisory_lock_failed` — multiple refreshes fired against the
///   same (operator, location, vendor) tuple where the broker's
///   per-tenant in-flight Future lock should have collapsed them.
/// * `mid_poll_dropped_request` — a polling adapter dropped its
///   request when the refresh worker rotated the token mid-call.
/// * `non_atomic_rotation` — a transactional read observed a window
///   where `token_expires_at` and `encrypted_access_token` were
///   inconsistent (token null/empty, or expiry advanced before the
///   ciphertext landed).
/// * `oauth_vendor_missing_closure` — adapter declares
///   `VendorAuthMode.oauth` but no entry exists in the worker's
///   refresh-closure registry.
/// * `non_oauth_vendor_has_closure` — adapter declares a non-OAuth
///   auth mode but the worker still wires a refresh closure.
/// * `agendrix_closure_status` — recorded reconciliation between the
///   audit's "static API key" claim and the adapter's
///   `capabilityProfile.authMode`.
/// * `oracle_simphony_closure_status` — same shape for Simphony
///   (audit claimed mTLS).
/// * `refresh_worker_crash` — the worker tick raised an uncaught
///   exception (broker promises typed errors; bare leakage is a bug).
/// * `setup_skipped` — harness could not reach a dependency (DB,
///   worker code, fixture) and skipped a probe.
class P3cFinding {
  P3cFinding({
    required this.category,
    required this.detail,
    this.vendorId,
    this.operatorId,
    this.locationId,
    this.observedAt,
    this.context,
  });

  final String category;
  final String detail;
  final String? vendorId;
  final String? operatorId;
  final String? locationId;
  final DateTime? observedAt;
  final Map<String, Object?>? context;

  Map<String, Object?> toJson() => <String, Object?>{
        'category': category,
        'detail': detail,
        if (vendorId != null) 'vendor_id': vendorId,
        if (operatorId != null) 'operator_id': operatorId,
        if (locationId != null) 'location_id': locationId,
        if (observedAt != null)
          'observed_at': observedAt!.toUtc().toIso8601String(),
        if (context != null) 'context': context,
      };
}

/// Accumulator + JSONL writer. Construct one per harness run, call
/// [record] for each divergence, then [flush] (and optionally
/// [writeSummaryMarkdown]) at the end.
class P3cFindingSink {
  P3cFindingSink({required this.outputJsonlPath, required this.summaryMdPath});

  final String outputJsonlPath;
  final String summaryMdPath;
  final List<P3cFinding> _findings = <P3cFinding>[];

  List<P3cFinding> get findings => List<P3cFinding>.unmodifiable(_findings);

  void record(P3cFinding finding) {
    _findings.add(finding);
  }

  /// Write all findings as JSONL. Overwrites any existing file so the
  /// artifact reflects only the most recent run.
  void flush() {
    final file = File(outputJsonlPath);
    file.parent.createSync(recursive: true);
    final buffer = StringBuffer();
    for (final f in _findings) {
      buffer.writeln(jsonEncode(f.toJson()));
    }
    file.writeAsStringSync(buffer.toString());
  }

  /// Render a markdown summary at [summaryMdPath]. Counts findings by
  /// category and includes the smoke parameters at the top.
  void writeSummaryMarkdown({
    required Map<String, Object?> smokeParameters,
    required Map<String, Object?> registryReconciliation,
  }) {
    final byCategory = <String, int>{};
    for (final f in _findings) {
      byCategory.update(f.category, (n) => n + 1, ifAbsent: () => 1);
    }
    final out = StringBuffer();
    out.writeln('# P3C OAuth Refresh Storm — Smoke Summary');
    out.writeln('');
    out.writeln('Generated: ${DateTime.now().toUtc().toIso8601String()}');
    out.writeln('');
    out.writeln('## Smoke Parameters');
    out.writeln('');
    smokeParameters.forEach((key, value) {
      out.writeln('- `$key`: $value');
    });
    out.writeln('');
    out.writeln('## Findings by Category');
    out.writeln('');
    if (byCategory.isEmpty) {
      out.writeln('No findings recorded.');
    } else {
      out.writeln('| Category | Count |');
      out.writeln('|---|---|');
      final types = byCategory.keys.toList()..sort();
      for (final t in types) {
        out.writeln('| $t | ${byCategory[t]} |');
      }
      out.writeln('');
      out.writeln('Total findings: ${_findings.length}');
    }
    out.writeln('');
    out.writeln('## Closure Registry Reconciliation');
    out.writeln('');
    registryReconciliation.forEach((key, value) {
      out.writeln('- `$key`: $value');
    });
    out.writeln('');
    final summaryFile = File(summaryMdPath);
    summaryFile.parent.createSync(recursive: true);
    summaryFile.writeAsStringSync(out.toString());
  }

  /// Counts findings by category. Used for the smoke output line.
  Map<String, int> countsByCategory() {
    final byCategory = <String, int>{};
    for (final f in _findings) {
      byCategory.update(f.category, (n) => n + 1, ifAbsent: () => 1);
    }
    return byCategory;
  }
}
