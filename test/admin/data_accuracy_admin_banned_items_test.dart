// Phase 8 spine-bridge Lane .C — acceptance item K.
//
// V1 lean cut 2 banned-items grep across the Lane .C files. Mirrors
// the Lane .A test in test/services/data_accuracy/. Comments are
// stripped before grep so contextual prose ("no KMS at V1") is
// allowed; only executable code is enforced.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const List<String> _laneFiles = <String>[
  'lib/admin/screens/per_location_data_accuracy_screen.dart',
  'lib/admin/screens/polling_and_pricing_admin_screen.dart',
  'lib/admin/widgets/per_location_data_accuracy_table.dart',
  'lib/admin/widgets/data_accuracy_audit_history_panel.dart',
  'lib/admin/widgets/tier_definitions_card.dart',
  'lib/admin/widgets/per_location_tier_assignment_table.dart',
  'lib/admin/widgets/per_vendor_cadence_editor.dart',
  'lib/admin/widgets/margin_rollup_card.dart',
  'lib/admin/widgets/tier_change_requests_card.dart',
  'lib/admin/widgets/plain_english_explainer_card.dart',
  'lib/admin/widgets/tier_definition_edit_dialog.dart',
  'lib/admin/services/data_accuracy_admin_gateway.dart',
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

/// Strip Dart `//` line comments before grepping. The lane's files are
/// Dart only — no SQL, no block comments. If a future file adds block
/// comments, extend this pruner.
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
  group('8.spine-bridge.C — V1 lean cut 2 banned items grep (item K)', () {
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

    test('all expected lane files are present', () {
      for (final p in _laneFiles) {
        expect(
          File(p).existsSync(),
          isTrue,
          reason: 'expected lane file missing: $p',
        );
      }
    });
  });
}
