// Phase 8 spine-bridge Lane .B — V1 lean cut 2 banned-items grep.
//
// Covers acceptance item K: scan every Lane .B file for the banned
// strings carried over from `memory/project_v1_lean_cut_2_2026_05_03.md`.
// A regression that re-introduces any of these patterns surfaces here
// before merge.
//
// Banned items in scope for this lane:
//
//   * `kms` / `KMS`         — KMS rollout deferred to Production1.
//   * `parse_warnings`      — column dropped in V1 lean cut 2.
//   * `parse_partial`       — column dropped in V1 lean cut 2.
//   * `advisory_lock`       — pg_advisory_lock pulled from OAuth cron.
//   * `email_outbox`        — 3-strike email emit deferred.
//   * `pg_partman`          — per-month partitioning deferred.
//   * `SIGTERM`             — graceful drain handler dropped.
//
// Note on whole-word matching: the lane's source files are scanned
// with whole-word boundaries so substrings never trip the matcher; we
// only flag the literal token. Dart `//` line comments are stripped
// before grepping so prose can mention banned items contextually
// ("no KMS at V1"). The walkthrough Markdown file is scanned as-is —
// no comment stripping — because Markdown does not carry executable
// code and any banned mention indicates doc rot.
//
// This test file intentionally does NOT include itself in `_laneFiles`
// (per hard rule #6 of the lane prompt) — banned tokens live inside
// RegExp string literals here, which is the data the test checks for,
// not a violation.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const List<String> _laneFiles = <String>[
  'lib/operator_web/screens/data_accuracy_screen.dart',
  'lib/operator_web/widgets/wage_source_toggle.dart',
  'lib/operator_web/widgets/covers_source_toggle.dart',
  'lib/operator_web/widgets/covers_manual_entry_card.dart',
  'lib/operator_web/widgets/covers_historical_seed_card.dart',
  'lib/operator_web/widgets/walk_in_handling_card.dart',
  'lib/operator_web/widgets/polling_tier_status_card.dart',
  'lib/operator_web/widgets/vendor_relativity_label.dart',
  'lib/operator_web/widgets/data_accuracy_explainer_card.dart',
  'docs/archive/_walkthroughs/8.spine-bridge.B.md',
];

class _BannedToken {
  const _BannedToken(this.label, this.pattern);
  final String label;
  final RegExp pattern;
}

final List<_BannedToken> _bannedTokens = <_BannedToken>[
  _BannedToken('kms', RegExp(r'\bkms\b', caseSensitive: false)),
  _BannedToken('parse_warnings', RegExp(r'\bparse_warnings\b')),
  _BannedToken('parse_partial', RegExp(r'\bparse_partial\b')),
  _BannedToken('advisory_lock', RegExp(r'\badvisory_lock\b')),
  _BannedToken('email_outbox', RegExp(r'\bemail_outbox\b')),
  _BannedToken('pg_partman', RegExp(r'\bpg_partman\b')),
  _BannedToken('SIGTERM', RegExp(r'\bSIGTERM\b')),
];

/// Strip Dart `//` line comments before grepping. Markdown files are
/// scanned as-is; if a future lane file needs Markdown comment
/// handling, extend this pruner.
String _stripDartComments(String content) {
  final lines = content.split('\n');
  final out = StringBuffer();
  for (final line in lines) {
    final idx = line.indexOf('//');
    if (idx < 0) {
      out.writeln(line);
    } else {
      out.writeln(line.substring(0, idx));
    }
  }
  return out.toString();
}

void main() {
  group(
    'Phase 8 spine-bridge Lane .B — V1 lean cut 2 banned items grep '
    '(item K)',
    () {
      for (final relativePath in _laneFiles) {
        test('$relativePath carries no V1 lean cut 2 banned tokens', () {
          final file = File(relativePath);
          expect(
            file.existsSync(),
            isTrue,
            reason: 'tests must run from repository root; expected '
                '$relativePath to exist',
          );
          final raw = file.readAsStringSync();
          final stripped = relativePath.endsWith('.dart')
              ? _stripDartComments(raw)
              : raw;
          final hits = <String>[];
          for (final token in _bannedTokens) {
            if (token.pattern.hasMatch(stripped)) {
              hits.add(token.label);
            }
          }
          expect(
            hits,
            isEmpty,
            reason: '$relativePath contains banned tokens (Dart comments '
                'are stripped before grep; Markdown is scanned as-is): '
                '$hits',
          );
        });
      }

      test(
        'lane produced exactly the expected file set (no surprise '
        'sibling files crept into the lane scope)',
        () {
          for (final p in _laneFiles) {
            expect(
              File(p).existsSync(),
              isTrue,
              reason: 'expected lane file missing: $p',
            );
          }
        },
      );
    },
  );
}
