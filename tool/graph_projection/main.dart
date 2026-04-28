import 'dart:io';

import 'graph_projection.dart';

Future<void> main(List<String> args) async {
  final commands = args.where((arg) => !arg.startsWith('--')).toList();
  final command = commands.isEmpty ? 'prepare-rebuild' : commands.first;
  final repoRoot = Directory.current;

  try {
    switch (command) {
      case 'prepare-rebuild':
        final outputDirectory =
            _option(args, 'output') ?? 'build/graph_projection';
        final graphName = _option(args, 'graph') ?? defaultGraphName;
        final graphScopeFilter =
            _option(args, 'scope') ?? defaultGraphScopeFilter;
        final preparer = GraphProjectionRebuildPreparer(
          repoRoot: repoRoot,
          graphName: graphName,
          graphScopeFilter: graphScopeFilter,
        );
        final result = await preparer.prepare(outputDirectory: outputDirectory);
        stdout.writeln(
          'Graph projection rebuild prep OK: '
          'graph="${result.graphName}", scope="${result.graphScopeFilter}", '
          '${result.rebuildFiles.length} SQL artifacts + manifest.',
        );
        stdout.writeln('Rebuild run id: ${result.rebuildRunId}');
        stdout.writeln('Output: ${result.outputDirectory}');
        stdout.writeln('Files: ${result.rebuildFiles.join(', ')}, '
            '${result.manifestFile}');
        stdout.writeln(
          'Inputs: public.graph_nodes / public.graph_edges (canonical only).',
        );
        stdout.writeln(
          'Mode: generated artifacts only — no DB mutation, no provider call.',
        );
        stdout.writeln(
          'Blocker path: emits AGE_BLOCKER RAISE NOTICE when '
          'pg_available_extensions does not list age.',
        );
        break;
      default:
        stderr.writeln('Unknown command: $command');
        stderr.writeln(
          'Usage: dart run tool/graph_projection/main.dart [prepare-rebuild]',
        );
        exitCode = 64;
    }
  } on GraphProjectionException catch (error) {
    stderr.writeln('Graph projection error: ${error.message}');
    exitCode = 1;
  }
}

String? _option(List<String> args, String name) {
  final prefix = '--$name=';
  for (final arg in args) {
    if (arg.startsWith(prefix)) {
      return arg.substring(prefix.length);
    }
  }
  return null;
}
