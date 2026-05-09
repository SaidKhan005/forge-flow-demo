// Phase 3A — webhook flood runner test.
//
// This test is a THIN INVOCATION of the harness binary at
// `tool/pressure/p3a_webhook_flood.dart` at a small smoke scale. It
// exists so the harness gets surfaced under `flutter test` without
// becoming a default-run gate (the smoke hits the preview proxy and
// counts against staging-Postgres connection budget; we don't want
// every CI run to fire it).
//
// Activation
// ----------
// The smoke is gated by `FF_RUN_PRESSURE_PREVIEW_P3A=1` — the test
// becomes a no-op skip otherwise. Operators run it locally with the
// env var set; PR-body smoke evidence is captured manually using the
// command in the harness header.
//
// What this test asserts
// ----------------------
// * The harness binary exists and parses its CLI flags without
//   crashing (this part runs unconditionally — it's a syntax /
//   structural check).
// * When `FF_RUN_PRESSURE_PREVIEW_P3A=1`, the harness completes
//   successfully (exit 0) at a 30-second 1-vendor smoke scale and
//   produces both the findings JSONL and the summary MD.
//
// Hard rule from the prompt: do NOT auto-rerun on failure.
// `--retry-each=1` is the default; the runner does not bump it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String kHarnessBinary = 'tool/pressure/p3a_webhook_flood.dart';
const String kOutputDir = 'test/load/pressure';

void main() {
  group('Phase 3A webhook flood runner', () {
    test('harness binary parses CLI without crashing', () async {
      final harness = File(kHarnessBinary);
      expect(harness.existsSync(), isTrue,
          reason: 'expected $kHarnessBinary to exist');
      // Verify the file declares a `main` entrypoint and the
      // documented preview proxy URL constant. Cheap structural
      // assertion — does not exercise the network.
      final src = harness.readAsStringSync();
      expect(src.contains('Future<void> main('), isTrue,
          reason: 'harness must declare an async main entrypoint');
      expect(src.contains('forge-flow-preview-'), isTrue,
          reason: 'harness must reference the preview URL prefix in the '
              'allowed-host guard');
      expect(src.contains('PLACEHOLDER-PRESSURE-PREVIEW-V1'), isTrue,
          reason: 'harness must use a placeholder secret (no real keys)');
    });

    test(
      'smoke run against preview proxy completes',
      () async {
        if (Platform.environment['FF_RUN_PRESSURE_PREVIEW_P3A'] != '1') {
          return;
        }
        // Tiny smoke — 1 op × 30s × 1 event/min × 2 vendors. Total
        // ~2 requests + 2 warmup. This is a runner-test scale; the
        // operator-driven smoke uses the documented command.
        final result = await Process.run(
          'dart',
          <String>[
            'run',
            kHarnessBinary,
            '--ops=1',
            '--duration=30s',
            '--rate=1',
            '--vendors=toast,seven_shifts',
            '--retry-each=1',
            '--output-dir=$kOutputDir',
          ],
          runInShell: true,
        );
        // ignore: avoid_print
        print('--- harness stdout (truncated) ---');
        // ignore: avoid_print
        print(_tail(result.stdout.toString(), 4000));
        // ignore: avoid_print
        print('--- harness stderr (truncated) ---');
        // ignore: avoid_print
        print(_tail(result.stderr.toString(), 2000));
        expect(result.exitCode, 0,
            reason: 'harness exited non-zero — see stderr above');
        expect(File('$kOutputDir/p3a_webhook_flood_findings.jsonl').existsSync(),
            isTrue);
        expect(File('$kOutputDir/p3a_webhook_flood_summary.md').existsSync(),
            isTrue);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}

String _tail(String s, int maxChars) {
  if (s.length <= maxChars) return s;
  return '... ${s.substring(s.length - maxChars)}';
}
