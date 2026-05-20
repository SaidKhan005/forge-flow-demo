import 'dart:io';

final List<_ProofSuite> _suites = [
  _ProofSuite(
    name: 'live-projector',
    description:
        'canonical POS/labor/reservation facts -> open_shift_snapshots',
    executable: 'flutter',
    args: [
      'test',
      'test/services/integration/open_shift_snapshot_projector_test.dart',
    ],
  ),
  _ProofSuite(
    name: 'proxy-mobile-open-snapshots',
    description: 'proxy -> mobile SQLite open snapshot pull',
    executable: 'flutter',
    args: [
      'test',
      'test/services/sync/http_sync_proxy_client_test.dart',
      'test/services/sync/postgres_shift_record_to_mobile_sync_test.dart',
      'test/proxy/mobile_operational_sync_shift_records_test.dart',
      'test/proxy/mobile_operational_sync_sync_and_idempotency_test.dart',
      'test/proxy/mobile_operational_sync_demo_and_error_paths_test.dart',
      'test/app_data_status_test.dart',
    ],
  ),
  _ProofSuite(
    name: 'closed-triplet',
    description: 'closed input -> builder -> writer timing triplet',
    executable: 'flutter',
    args: [
      'test',
      'test/services/integration/canonical_fact_covers_and_pos_aggregation_test.dart',
      'test/services/integration/canonical_fact_wage_and_labor_sources_test.dart',
      'test/services/integration/canonical_fact_rls_and_regression_checks_test.dart',
      'test/infrastructure/persistence/postgres/postgres_shift_record_writer_test.dart',
      'test/shift_fact_builder_test.dart',
      'test/domain/models/timing_provenance_models_test.dart',
    ],
  ),
  _ProofSuite(
    name: 'closed-labels',
    description: 'Variance/History/Learn labels from saved timing identity',
    executable: 'flutter',
    args: [
      'test',
      'test/variance_week_projection_read_service_test.dart',
      'test/history_benchmark_daypart_read_service_test.dart',
      'test/learn_repeatable_wins_read_service_test.dart',
      'test/history_pattern_builder_test.dart',
    ],
  ),
];

Future<void> main(List<String> args) async {
  if (args.contains('--list')) {
    for (final suite in _suites) {
      stdout.writeln('${suite.name}: ${suite.description}');
    }
    return;
  }

  final requested = args
      .where((arg) => arg.startsWith('--suite='))
      .map((arg) => arg.substring('--suite='.length))
      .toSet();
  final suites = requested.isEmpty
      ? _suites
      : _suites.where((suite) => requested.contains(suite.name)).toList();

  if (suites.isEmpty) {
    stderr.writeln('No matching proof suites. Run with --list for names.');
    exitCode = 64;
    return;
  }

  stdout.writeln('Mobile core live/closed truth proof harness');
  stdout.writeln('Suites: ${suites.map((suite) => suite.name).join(', ')}');

  final failures = <String>[];
  for (final suite in suites) {
    stdout.writeln('');
    stdout.writeln('== ${suite.name} ==');
    stdout.writeln(suite.description);
    stdout.writeln('${suite.executable} ${suite.args.join(' ')}');

    final process = await Process.start(
      suite.executable,
      suite.args,
      runInShell: Platform.isWindows,
    );
    await stdout.addStream(process.stdout);
    await stderr.addStream(process.stderr);
    final code = await process.exitCode;
    if (code == 0) {
      stdout.writeln('PASS ${suite.name}');
    } else {
      failures.add('${suite.name} exited $code');
      stdout.writeln('FAIL ${suite.name} exited $code');
    }
  }

  if (failures.isNotEmpty) {
    stderr.writeln('');
    stderr.writeln('Proof harness failed:');
    for (final failure in failures) {
      stderr.writeln('- $failure');
    }
    exitCode = 1;
  }
}

class _ProofSuite {
  const _ProofSuite({
    required this.name,
    required this.description,
    required this.executable,
    required this.args,
  });

  final String name;
  final String description;
  final String executable;
  final List<String> args;
}
