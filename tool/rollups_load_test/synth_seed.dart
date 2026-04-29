// Phase 9.0Σ.k — synthetic Tier-M rollups load-test harness (B38).
//
// Authority:
//   * docs/phases/phase_9/phase_9_execution_backlog.md — B38 only.
//   * docs/phases/phase_9/phase_9_scalability_performance_audit_2026-04-27.md
//     Prelaunch Performance Test Matrix → Rollups row.
//
// What this tool does:
//   * Default mode is plan-only — prints the Tier-M row counts, the
//     target tables, the live preflight checklist, and the current
//     load-path blockers. No SQL is written; no database is touched.
//   * On explicit opt-in (`--emit-sql --output=<path>`) writes a
//     synthetic seed SQL file that populates `rollup_business_day`
//     plus the FK prerequisites (`operators`, `org_units`,
//     `locations`) and seeds one `aggregation_state` row for the
//     `(rollup_business_day, business_day)` watermark. The file is
//     not executed by this tool.
//
// What this tool does NOT do (slice hard constraints):
//   * Never connects to a database. There is no `package:postgres`
//     import in this file. SQL is written to a regular file only.
//   * Never invents product formulas. The `metrics` jsonb is a
//     fixed `'{"synthetic": true}'` placeholder so seed rows
//     exercise row volume, indexes, and the deterministic UPSERT
//     key without forging vendor-side sales/labor truth.
//   * Never triggers `pg_cron`, runs the worker, or measures p95.
//     The current repo cannot exercise the cron + worker
//     recomputation path end to end (the vendor aggregator that
//     produces raw facts has not landed). The result doc records
//     this as a blocker.
//
// CLI shape:
//
//   # Plan only (default).
//   dart run tool/rollups_load_test/synth_seed.dart
//
//   # Plan only, smaller scope.
//   dart run tool/rollups_load_test/synth_seed.dart \
//     --operators 2 --locations-per-operator 2 --days 3
//
//   # Emit synthetic SQL for a small scope.
//   dart run tool/rollups_load_test/synth_seed.dart \
//     --operators 2 --locations-per-operator 2 --days 3 \
//     --emit-sql --output=build/rollups_load_test/seed.sql
//
//   # Emit synthetic Tier-M-sized SQL (gated).
//   dart run tool/rollups_load_test/synth_seed.dart \
//     --emit-sql --output=build/rollups_load_test/tierm.sql \
//     --confirm-tier-m-scale
//
// Tier-M defaults (locked in B38):
//   operators              = 500
//   locations-per-operator = 200
//   days                   = 90
//   metric-families        = sales,labor,traffic
//   start-date             = 2026-01-01
//
//   rollup_business_day rows = 500 × 200 × 90 × 3 = 27,000,000.

import 'dart:io';

const int kTierMOperators = 500;
const int kTierMLocationsPerOperator = 200;
const int kTierMDays = 90;
const String kTierMStartDate = '2026-01-01';
const List<String> kTierMMetricFamilies = <String>['sales', 'labor', 'traffic'];

/// Refusal threshold for `--emit-sql` writes. Anything at or above
/// this many rollup rows requires `--confirm-tier-m-scale` so a typo
/// cannot accidentally produce a multi-gigabyte SQL file.
const int kTierMRefusalThreshold = 1000000;

/// Fixed `metrics` jsonb literal. Stays a placeholder per the slice
/// contract — vendor-side aggregation formulas are NOT defined here.
const String kSyntheticMetricsJsonbLiteral = "'{\"synthetic\": true}'";
const String kSyntheticDimensionsJsonbLiteral = "'{}'";
const String kSyntheticRuleVersion = 'load_test_v1';
const String kSyntheticTimezone = 'America/Toronto';
final RegExp _metricFamilyPattern = RegExp(r'^[a-z][a-z0-9_]{0,63}$');

/// Reserved UUID prefix segments so synthetic rows are visually
/// distinguishable from real tenant data:
///   operator_id          — `00000000-0000-0001-0000-…`
///   org_unit (root) id   — `00000000-0000-0002-0000-…`
///   location_id          — `<op8hex>-0000-0003-0000-…`
const String kSyntheticOperatorIdPrefix = '00000000-0000-0001-0000-';
const String kSyntheticOrgUnitIdPrefix = '00000000-0000-0002-0000-';

class SynthSeedException implements Exception {
  SynthSeedException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Parsed CLI configuration. Pure data — no I/O.
class SynthSeedConfig {
  SynthSeedConfig({
    required this.operators,
    required this.locationsPerOperator,
    required this.days,
    required this.startDate,
    required this.metricFamilies,
    required this.emitSql,
    required this.outputPath,
    required this.confirmTierMScale,
  });

  final int operators;
  final int locationsPerOperator;
  final int days;
  final DateTime startDate;
  final List<String> metricFamilies;
  final bool emitSql;
  final String? outputPath;
  final bool confirmTierMScale;

  /// Total `rollup_business_day` rows the seed produces.
  /// `operators × locationsPerOperator × days × |metricFamilies|`.
  int get rollupRowCount =>
      operators * locationsPerOperator * days * metricFamilies.length;

  /// Operator + org_unit (one root each) + location prerequisite rows.
  int get prerequisiteRowCount =>
      operators + operators + (operators * locationsPerOperator);

  /// Whether the requested config matches the locked Tier-M profile.
  bool get isTierMProfile =>
      operators == kTierMOperators &&
      locationsPerOperator == kTierMLocationsPerOperator &&
      days == kTierMDays &&
      _listEqual(metricFamilies, kTierMMetricFamilies);

  /// True when emitting SQL would cross the refusal threshold and
  /// must therefore be gated by `--confirm-tier-m-scale`.
  bool get requiresTierMConfirmation =>
      rollupRowCount >= kTierMRefusalThreshold;
}

bool _listEqual(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Internal parse outcome — distinguishes `--help` from a runnable
/// configuration so `runCli` can exit 0 on help without throwing.
class _ParseResult {
  _ParseResult.help() : config = null, helpRequested = true;
  _ParseResult.config(SynthSeedConfig c) : config = c, helpRequested = false;

  final SynthSeedConfig? config;
  final bool helpRequested;
}

const Set<String> _booleanFlags = <String>{
  '--emit-sql',
  '--confirm-tier-m-scale',
  '--help',
  '-h',
};

/// Normalize space-separated `--flag value` pairs into the
/// `--flag=value` form so the rest of the parser only handles
/// the equals form. Boolean flags pass through unchanged.
List<String> normalizeArgs(List<String> args) {
  final result = <String>[];
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--')) {
      result.add(arg);
      continue;
    }
    if (arg.contains('=')) {
      result.add(arg);
      continue;
    }
    if (_booleanFlags.contains(arg)) {
      result.add(arg);
      continue;
    }
    if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
      result.add('$arg=${args[i + 1]}');
      i++;
      continue;
    }
    // No value after a value-taking flag; let parseArgs reject it
    // with a useful error.
    result.add(arg);
  }
  return result;
}

_ParseResult _parseArgsInternal(List<String> rawArgs) {
  final args = normalizeArgs(rawArgs);

  var operators = kTierMOperators;
  var locationsPerOperator = kTierMLocationsPerOperator;
  var days = kTierMDays;
  var startDateRaw = kTierMStartDate;
  var metricFamilies = List<String>.of(kTierMMetricFamilies);
  var emitSql = false;
  String? outputPath;
  var confirmTierMScale = false;

  for (final arg in args) {
    if (arg == '--help' || arg == '-h') {
      return _ParseResult.help();
    }
    if (arg == '--emit-sql') {
      emitSql = true;
    } else if (arg == '--confirm-tier-m-scale') {
      confirmTierMScale = true;
    } else if (arg.startsWith('--operators=')) {
      operators = _parsePositiveInt(
        arg.substring('--operators='.length),
        '--operators',
      );
    } else if (arg.startsWith('--locations-per-operator=')) {
      locationsPerOperator = _parsePositiveInt(
        arg.substring('--locations-per-operator='.length),
        '--locations-per-operator',
      );
    } else if (arg.startsWith('--days=')) {
      days = _parsePositiveInt(arg.substring('--days='.length), '--days');
    } else if (arg.startsWith('--start-date=')) {
      startDateRaw = arg.substring('--start-date='.length);
    } else if (arg.startsWith('--metric-families=')) {
      final raw = arg.substring('--metric-families='.length);
      metricFamilies = _parseMetricFamilies(raw);
    } else if (arg.startsWith('--output=')) {
      final value = arg.substring('--output='.length);
      if (value.isEmpty) {
        throw SynthSeedException('--output requires a non-empty path');
      }
      outputPath = value;
    } else {
      throw SynthSeedException('unknown flag: $arg');
    }
  }

  final startDate = _parseStartDate(startDateRaw);

  if (emitSql && (outputPath == null || outputPath.isEmpty)) {
    throw SynthSeedException(
      '--emit-sql requires --output=<path>; this tool never connects to a '
      'database, SQL is written to a file only',
    );
  }

  return _ParseResult.config(
    SynthSeedConfig(
      operators: operators,
      locationsPerOperator: locationsPerOperator,
      days: days,
      startDate: startDate,
      metricFamilies: metricFamilies,
      emitSql: emitSql,
      outputPath: outputPath,
      confirmTierMScale: confirmTierMScale,
    ),
  );
}

/// Parses CLI arguments. Throws [SynthSeedException] on malformed
/// flags, missing required values, or `--help` (since `--help` is not
/// a runnable mode — `runCli` handles it by printing usage instead).
SynthSeedConfig parseArgs(List<String> rawArgs) {
  final result = _parseArgsInternal(rawArgs);
  if (result.helpRequested) {
    throw SynthSeedException('--help is not a runnable mode');
  }
  return result.config!;
}

List<String> _parseMetricFamilies(String raw) {
  final parsed = raw
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  if (parsed.isEmpty) {
    throw SynthSeedException(
      '--metric-families requires a non-empty comma-separated list',
    );
  }
  for (final family in parsed) {
    if (!_metricFamilyPattern.hasMatch(family)) {
      throw SynthSeedException(
        '--metric-families values must match '
        r'^[a-z][a-z0-9_]{0,63}$'
        ' (got "$family")',
      );
    }
  }
  return parsed;
}

int _parsePositiveInt(String raw, String flag) {
  final n = int.tryParse(raw);
  if (n == null || n <= 0) {
    throw SynthSeedException('$flag requires a positive integer (got "$raw")');
  }
  return n;
}

DateTime _parseStartDate(String raw) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(raw)) {
    throw SynthSeedException('--start-date must be YYYY-MM-DD (got "$raw")');
  }
  final parts = raw.split('-');
  final year = int.parse(parts[0]);
  final month = int.parse(parts[1]);
  final day = int.parse(parts[2]);
  if (month < 1 || month > 12) {
    throw SynthSeedException('--start-date month out of range (got "$raw")');
  }
  if (day < 1 || day > 31) {
    throw SynthSeedException('--start-date day out of range (got "$raw")');
  }
  // DateTime.utc tolerates 32+ for day on 28-day months; reject by
  // round-tripping the parsed date back to the source.
  final dt = DateTime.utc(year, month, day);
  if (dt.year != year || dt.month != month || dt.day != day) {
    throw SynthSeedException(
      '--start-date is not a valid calendar date (got "$raw")',
    );
  }
  return dt;
}

// ─── Deterministic identifier helpers ────────────────────────────────
//
// Format follows the 8-4-4-4-12 hex shape so PostgreSQL's `uuid` type
// accepts every value. The IDs do not encode any v4/v5 randomness —
// they encode the operator/location index directly, which is the
// point: re-running the tool with the same flags produces the same
// SQL bytewise, and seed rows are visually identifiable as load-test
// data (the `0000-000{1,2,3}-` middle segment is the kind tag).

String operatorIdFor(int operatorIndex) {
  _checkNonNegative(operatorIndex, 'operatorIndex');
  return '$kSyntheticOperatorIdPrefix'
      '${operatorIndex.toRadixString(16).padLeft(12, '0')}';
}

String orgUnitIdFor(int operatorIndex) {
  _checkNonNegative(operatorIndex, 'operatorIndex');
  return '$kSyntheticOrgUnitIdPrefix'
      '${operatorIndex.toRadixString(16).padLeft(12, '0')}';
}

String locationIdFor(int operatorIndex, int locationIndex) {
  _checkNonNegative(operatorIndex, 'operatorIndex');
  _checkNonNegative(locationIndex, 'locationIndex');
  if (operatorIndex >= 0xFFFFFFFF) {
    throw SynthSeedException(
      'operatorIndex too large for 8-hex segment ($operatorIndex)',
    );
  }
  if (locationIndex >= 0xFFFFFFFFFFFF) {
    throw SynthSeedException(
      'locationIndex too large for 12-hex segment ($locationIndex)',
    );
  }
  return '${operatorIndex.toRadixString(16).padLeft(8, '0')}'
      '-0000-0003-0000-'
      '${locationIndex.toRadixString(16).padLeft(12, '0')}';
}

void _checkNonNegative(int value, String name) {
  if (value < 0) {
    throw SynthSeedException('$name must be >= 0 (got $value)');
  }
}

String _formatDateOnly(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String _formatTimestamptzUtc(DateTime d) => '${_formatDateOnly(d)} 00:00:00+00';

// ─── Plan report ─────────────────────────────────────────────────────

String formatPlanReport(SynthSeedConfig config) {
  final sb = StringBuffer();
  final profile = config.isTierMProfile ? 'Tier-M (default)' : 'custom';
  sb.writeln('# Phase 9.0Σ.k rollups load-test plan');
  sb.writeln('Profile:                  $profile');
  sb.writeln('Operators:                ${config.operators}');
  sb.writeln('Locations per operator:   ${config.locationsPerOperator}');
  sb.writeln('Days:                     ${config.days}');
  sb.writeln(
    'Metric families:          ${config.metricFamilies.join(', ')} '
    '(${config.metricFamilies.length})',
  );
  sb.writeln('Start date:               ${_formatDateOnly(config.startDate)}');
  sb.writeln('');
  sb.writeln('Row counts (deterministic):');
  sb.writeln(
    '  rollup_business_day:    ${config.rollupRowCount} '
    '(operators × locations × days × metric_families)',
  );
  sb.writeln(
    '  Prerequisite rows:      ${config.prerequisiteRowCount} '
    '(operators + 1 org_unit/op + locations)',
  );
  sb.writeln(
    "  aggregation_state:      1 (rollup_table='rollup_business_day', "
    "grain='business_day', last_processed_seq=0)",
  );
  sb.writeln('');
  sb.writeln(
    'Target tables (no DDL emitted; migrations 202604280010_a/b/c '
    'must already be applied):',
  );
  sb.writeln('  public.operators              (FK prerequisite)');
  sb.writeln(
    '  public.org_units              (FK prerequisite, one root per op)',
  );
  sb.writeln('  public.locations              (FK prerequisite)');
  sb.writeln('  public.rollup_business_day    (load body)');
  sb.writeln('  public.aggregation_state      (worker watermark seed)');
  sb.writeln('');
  if (config.emitSql) {
    sb.writeln('Mode: EMIT SQL → ${config.outputPath}');
    if (config.requiresTierMConfirmation) {
      if (config.confirmTierMScale) {
        sb.writeln('Tier-M-scale emit: confirmed via --confirm-tier-m-scale');
      } else {
        sb.writeln(
          'Tier-M-scale emit: REQUIRES --confirm-tier-m-scale '
          '(threshold = $kTierMRefusalThreshold rows)',
        );
      }
    }
  } else {
    sb.writeln('Mode: PLAN ONLY (no SQL written, no database touched)');
  }
  sb.writeln('');
  sb.writeln(
    'Live preflight checklist (NOT executed by this tool — every '
    'step must be done by an authorized operator on staging):',
  );
  sb.writeln(
    '  - Apply migrations 202604280010_a/b/c on the staging '
    'instance via the standard staging migration channel.',
  );
  sb.writeln(
    '  - Confirm the synthetic operator / org_unit / location IDs '
    "do NOT collide with real tenant data. The prefixes "
    "'00000000-0000-0001-0000-' (operators) and "
    "'00000000-0000-0002-0000-' (org_units) plus the "
    "'-0000-0003-0000-' middle segment (locations) are reserved for "
    'load-test rows.',
  );
  sb.writeln(
    '  - Apply the emitted SQL on staging. This tool never '
    'connects to a database; it only writes a SQL file.',
  );
  sb.writeln(
    '  - After apply, confirm pg_cron jobs `forge_rollup_hot_path` '
    'and `forge_rollup_cold_path` are listed in `cron.job` and that '
    'NOTIFY traffic on the `rollups_tick` channel is observed.',
  );
  sb.writeln(
    '  - Run the rollup worker (lib/services/rollups/'
    'rollup_worker.dart) against the staging instance and capture '
    'p50/p95/p99 latency, queue depth, freshness lag, claim '
    'contention, and aggregation_state advancement. Capture happens '
    'via psql / pg_stat_statements / pg_stat_activity, NOT via this '
    'tool.',
  );
  sb.writeln(
    '  - Record measurements in '
    'docs/phases/phase_9/phase_9_rollups_tierm_load_result.md.',
  );
  sb.writeln('');
  sb.writeln('Honest limitations:');
  sb.writeln(
    '  - This tool only seeds rollup rows + a watermark. The '
    'vendor-side aggregator that produces RAW facts has not landed '
    '(it follows post-7.58 vendor connector payload finalization). '
    'End-to-end recomputation under load therefore cannot be '
    'exercised today; the result doc records this as a blocker.',
  );
  sb.writeln(
    '  - No timing, latency, contention, or freshness '
    'measurement is taken locally. The tool is a deterministic '
    'fixture builder, not a benchmarking harness.',
  );
  sb.writeln(
    '  - The `metrics` jsonb is a fixed '
    '`{"synthetic": true}` placeholder. Do NOT compare any '
    'aggregated value from these seed rows to product truth.',
  );
  return sb.toString();
}

// ─── SQL emission ────────────────────────────────────────────────────

/// Streams the synthetic seed SQL through [writeLine]. Keeping the
/// callback shape (rather than an `IOSink`) lets tests collect into a
/// `StringBuffer` without implementing the full `IOSink` surface.
void writeSeedSql(
  SynthSeedConfig config,
  void Function(String line) writeLine,
) {
  writeLine(
    '-- Phase 9.0Σ.k — synthetic rollups load-test seed '
    '(B38 / cutover.0b row 8).',
  );
  writeLine('-- Generated by tool/rollups_load_test/synth_seed.dart.');
  writeLine(
    '-- Profile: '
    '${config.isTierMProfile ? "Tier-M (default)" : "custom"}.',
  );
  writeLine(
    '-- Operators: ${config.operators}. '
    'Locations/op: ${config.locationsPerOperator}. '
    'Days: ${config.days}. '
    'Metric families: ${config.metricFamilies.length}.',
  );
  writeLine('-- rollup_business_day rows: ${config.rollupRowCount}.');
  writeLine('-- Prerequisite rows: ${config.prerequisiteRowCount}.');
  writeLine('-- Start date: ${_formatDateOnly(config.startDate)}.');
  writeLine(
    '-- WARNING: synthetic data only. Apply on STAGING ONLY. '
    'Never apply on production.',
  );
  writeLine(
    '-- All inserts use ON CONFLICT DO NOTHING for idempotent '
    're-apply.',
  );
  writeLine('');
  writeLine('begin;');
  writeLine('');

  writeLine('-- operators (FK prerequisite).');
  for (var k = 0; k < config.operators; k++) {
    final id = operatorIdFor(k);
    final name = 'load_test op $k';
    final email = 'load_test+$k@forgeflow.dev';
    writeLine(
      "insert into public.operators "
      "(operator_id, business_name, owner_email) "
      "values ('$id', '$name', '$email') "
      "on conflict (operator_id) do nothing;",
    );
  }
  writeLine('');

  writeLine('-- org_units (one corp-root per operator; FK prerequisite).');
  for (var k = 0; k < config.operators; k++) {
    final opId = operatorIdFor(k);
    final ouId = orgUnitIdFor(k);
    final pathLabel = 'root_$k';
    writeLine(
      "insert into public.org_units "
      "(id, operator_id, parent_id, unit_type, path, name) "
      "values ('$ouId', '$opId', null, 'corp', '$pathLabel', "
      "'load_test root $k') "
      "on conflict (id) do nothing;",
    );
  }
  writeLine('');

  writeLine('-- locations (FK prerequisite).');
  for (var k = 0; k < config.operators; k++) {
    final opId = operatorIdFor(k);
    for (var j = 0; j < config.locationsPerOperator; j++) {
      final locId = locationIdFor(k, j);
      writeLine(
        "insert into public.locations "
        "(location_id, operator_id, name, timezone) "
        "values ('$locId', '$opId', 'load_test loc $k.$j', "
        "'$kSyntheticTimezone') "
        "on conflict (location_id) do nothing;",
      );
    }
  }
  writeLine('');

  writeLine('-- rollup_business_day (load body).');
  for (var k = 0; k < config.operators; k++) {
    final opId = operatorIdFor(k);
    final ouId = orgUnitIdFor(k);
    for (var j = 0; j < config.locationsPerOperator; j++) {
      final locId = locationIdFor(k, j);
      for (var d = 0; d < config.days; d++) {
        final periodStart = config.startDate.add(Duration(days: d));
        final periodEnd = config.startDate.add(Duration(days: d + 1));
        final periodStartStr = _formatTimestamptzUtc(periodStart);
        final periodEndStr = _formatTimestamptzUtc(periodEnd);
        final businessDateStr = _formatDateOnly(periodStart);
        for (var m = 0; m < config.metricFamilies.length; m++) {
          final family = config.metricFamilies[m];
          writeLine(
            "insert into public.rollup_business_day "
            "(operator_id, scoped_org_unit_id, location_id, "
            "period_start, period_end, business_date, metric_family, "
            "dimensions, metrics, source_watermark_seq, "
            "source_watermark_at, rule_version, freshness_status) "
            "values ('$opId', '$ouId', '$locId', '$periodStartStr', "
            "'$periodEndStr', '$businessDateStr', '$family', "
            "$kSyntheticDimensionsJsonbLiteral::jsonb, "
            "$kSyntheticMetricsJsonbLiteral::jsonb, 0, "
            "'$periodStartStr', '$kSyntheticRuleVersion', 'fresh') "
            "on conflict do nothing;",
          );
        }
      }
    }
  }
  writeLine('');

  writeLine('-- aggregation_state seed (worker watermark starting point).');
  writeLine(
    "insert into public.aggregation_state "
    "(rollup_table, grain, last_processed_seq) "
    "values ('rollup_business_day', 'business_day', 0) "
    "on conflict (rollup_table, grain) do nothing;",
  );
  writeLine('');

  writeLine('commit;');
}

// ─── CLI entry ───────────────────────────────────────────────────────

const String _usageBlock = '''
Usage: dart run tool/rollups_load_test/synth_seed.dart [flags]

Modes:
  (default)             Plan only — print scale math, target tables,
                        prerequisites. No SQL written; no DB touched.
  --emit-sql            Emit synthetic seed SQL to a file.
                        Requires --output=<path>.
                        Refuses Tier-M-sized output (>= 1,000,000 rows)
                        unless --confirm-tier-m-scale is also passed.

Tuning flags (apply to plan and emit modes):
  --operators=<N>                 default 500
  --locations-per-operator=<N>    default 200
  --days=<N>                      default 90
  --start-date=<YYYY-MM-DD>       default 2026-01-01
  --metric-families=<a,b,c>       default sales,labor,traffic

Output flags:
  --output=<path>          required for --emit-sql
  --confirm-tier-m-scale   required to emit >= 1,000,000 rows
  --help / -h              print this usage and exit

This tool NEVER connects to a database. --emit-sql writes to a file.
''';

/// Run the CLI. Returns the exit code:
///   * 0 — success (plan printed; SQL written if --emit-sql).
///   * 2 — configuration error (malformed flags, missing required
///         value, refused emit).
///   * 3 — runtime error (cannot open --output file).
Future<int> runCli(
  List<String> args, {
  void Function(String line)? writeOut,
  void Function(String line)? writeErr,
}) async {
  final outLine = writeOut ?? _defaultOutLine;
  final errLine = writeErr ?? _defaultErrLine;

  _ParseResult parsed;
  try {
    parsed = _parseArgsInternal(args);
  } on SynthSeedException catch (e) {
    errLine('synth_seed: ${e.message}');
    errLine('');
    errLine(_usageBlock);
    return 2;
  }
  if (parsed.helpRequested) {
    outLine(_usageBlock);
    return 0;
  }

  final config = parsed.config!;

  if (config.emitSql &&
      config.requiresTierMConfirmation &&
      !config.confirmTierMScale) {
    errLine(
      'synth_seed: refusing to emit ${config.rollupRowCount} rows without '
      '--confirm-tier-m-scale (Tier-M refusal threshold = '
      '$kTierMRefusalThreshold).',
    );
    errLine(
      'synth_seed: re-run with --confirm-tier-m-scale to acknowledge the '
      'size, or scope down with --operators / --locations-per-operator / '
      '--days.',
    );
    return 2;
  }

  outLine(formatPlanReport(config).trimRight());

  if (config.emitSql) {
    final outputPath = config.outputPath!;
    IOSink fileSink;
    try {
      final outFile = File(outputPath);
      outFile.parent.createSync(recursive: true);
      fileSink = outFile.openWrite();
    } catch (e) {
      errLine('synth_seed: cannot open --output=$outputPath: $e');
      return 3;
    }
    try {
      writeSeedSql(config, fileSink.writeln);
    } finally {
      await fileSink.flush();
      await fileSink.close();
    }
    final totalRows = config.rollupRowCount + config.prerequisiteRowCount + 1;
    outLine(
      'synth_seed: wrote $totalRows rows of synthetic SQL to $outputPath',
    );
  }

  return 0;
}

void _defaultOutLine(String line) => stdout.writeln(line);
void _defaultErrLine(String line) => stderr.writeln(line);

Future<void> main(List<String> args) async {
  exitCode = await runCli(args);
}
