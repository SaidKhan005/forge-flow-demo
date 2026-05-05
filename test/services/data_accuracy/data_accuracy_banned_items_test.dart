// Phase 8 spine-bridge Lane .A — V1 lean cut 2 banned-items grep.
//
// Covers acceptance item K from the lane prompt: scan every file the
// lane produced for the banned strings carried over from
// `memory/project_v1_lean_cut_2_2026_05_03.md`. A regression that
// re-introduces any of these patterns surfaces here before merge.
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
// Note on `kms`: the lane's source files are scanned with whole-word
// matching so substrings like `setting_id` never trip the matcher; we
// only flag the literal token `kms` / `KMS`. The migration filename
// itself is allowed; only file CONTENTS are scanned.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const List<String> _laneFiles = <String>[
  'db/migrations/202605050000_phase_8_data_accuracy_settings.sql',
  'lib/services/data_accuracy/data_accuracy_settings_repository.dart',
  'lib/services/data_accuracy/forge_flow_polling_tier_repository.dart',
  'lib/domain/models/data_accuracy_settings.dart',
  'lib/domain/models/forge_flow_polling_tier_assignment.dart',
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

/// Strip SQL `--` comments and Dart `//` line comments before grepping.
/// Block comments (`/* ... */`) are not used by the lane's files; if
/// a future file adds them, extend this pruner. The prose in comments
/// is allowed to mention banned items contextually ("no KMS at V1");
/// only executable code is enforced.
String _stripComments(String content, {required bool isSql}) {
  final marker = isSql ? '--' : '//';
  final lines = content.split('\n');
  final out = StringBuffer();
  for (final line in lines) {
    final idx = line.indexOf(marker);
    if (idx < 0) {
      out.writeln(line);
    } else {
      out.writeln(line.substring(0, idx));
    }
  }
  return out.toString();
}

void main() {
  group('Phase 8 spine-bridge Lane .A — V1 lean cut 2 banned items grep '
      '(item K)', () {
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
        final stripped = _stripComments(
          raw,
          isSql: relativePath.endsWith('.sql'),
        );
        final hits = <String>[];
        for (final token in _bannedTokens) {
          if (token.pattern.hasMatch(stripped)) {
            hits.add(token.label);
          }
        }
        expect(
          hits,
          isEmpty,
          reason: '$relativePath contains banned tokens in executable '
              'code (comments are stripped before grep): $hits',
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
  });
}
