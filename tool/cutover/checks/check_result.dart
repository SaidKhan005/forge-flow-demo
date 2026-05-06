// `cutover.0` pre-flight smoke harness — shared check result type.
//
// Every individual check returns a [CheckResult] with a uniform shape
// so the aggregator can render a consistent JSON report and decide
// overall green/red verdict without knowing about each check's
// specifics. The shape mirrors `tool/perf_gate/staging_console_probe.dart`
// at the per-probe level (a `name` + `status_code`/`error_count` style
// summary + structured details) so existing CI patterns can consume
// it.

/// Status verdict for a single pre-flight check.
enum CheckStatus {
  /// Check passed.
  green,

  /// Check passed with caveats (configuration drift, optional skip,
  /// non-blocking warning). Treated as non-blocking by the
  /// aggregator unless `--require-all` is set.
  yellow,

  /// Check failed. Blocking under default + `--require-all`.
  red,
}

extension CheckStatusJson on CheckStatus {
  String toJsonString() => switch (this) {
    CheckStatus.green => 'green',
    CheckStatus.yellow => 'yellow',
    CheckStatus.red => 'red',
  };
}

/// One pre-flight check's outcome.
class CheckResult {
  const CheckResult({
    required this.name,
    required this.status,
    required this.message,
    this.details = const <String, Object?>{},
    this.elapsedMs,
  });

  /// Stable check identifier — `schema_presence`, `rls_isolation`,
  /// `firewall_reachability`, etc. Used as the JSON key for that
  /// check inside the report `checks` array.
  final String name;

  /// Verdict.
  final CheckStatus status;

  /// One-line operator-readable summary. Emitted both in the human
  /// table and the JSON `message` field. Should be safe to log to
  /// stdout (no secrets).
  final String message;

  /// Optional structured detail. Each check defines its own shape;
  /// for schema_presence, this holds `{missing_tables: [...]}`;
  /// for rls_isolation, `{leak_count: 0, fixture_visible_to_other:
  /// false}`; etc. Never include connection strings, passwords, or
  /// tokens.
  final Map<String, Object?> details;

  /// Wall-clock duration of the check, milliseconds, if measured.
  final double? elapsedMs;

  bool get isGreen => status == CheckStatus.green;
  bool get isRed => status == CheckStatus.red;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'status': status.toJsonString(),
    'message': message,
    if (elapsedMs != null) 'elapsed_ms': _round(elapsedMs!),
    if (details.isNotEmpty) 'details': details,
  };
}

/// Stable rounding helper so JSON snapshots stay deterministic.
double _round(double value) => (value * 10).roundToDouble() / 10.0;
