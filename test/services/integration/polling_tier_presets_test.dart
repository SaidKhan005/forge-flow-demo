// Phase 8 Wave B `8.spine-bridge.0a` polling tier presets tests +
// per-lane V1 lean cut 2 banned-items grep (acceptance item F).
//
// Two responsibilities:
//   1. Sanity-check the `kStandardTierPresets` / `kPremiumTierPresets`
//      maps against the binding contract:
//        - Cover exactly the five poll-only vendors (Oracle MICROS
//          Simphony, QuickBooks Time, Humanity, Agendrix, Push
//          Operations).
//        - Every preset value is within the framework cadence range
//          [60, 3600]. (Vendor minimums above 60 are vendor-specific
//          and asserted in the resolver tests, not here.)
//        - Standard tier honours the "vendor minimum" rule for
//          poll-only vendors.
//        - Premium tier honours the "60s where vendor allows; vendor
//          minimum where not" rule (Oracle stays at 300; the other
//          four run 60).
//   2. Banned-token grep over the two new lane source files. Strips
//      Dart `//` line comments before grepping so contextual prose
//      ("no KMS at V1") in headers does not trip the matcher; only
//      executable code is enforced.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/integration/polling_tier_presets.dart';

const Set<String> _pollOnlyVendorIds = <String>{
  'oracle_micros_simphony',
  'quickbooks_time',
  'humanity',
  'agendrix',
  'push_operations',
};

const List<String> _laneSourceFiles = <String>[
  'lib/services/integration/polling_cadence_resolver.dart',
  'lib/services/integration/polling_tier_presets.dart',
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
  // Three additional ledger tokens checked across spine-bridge.0:
  _BannedToken('strict replay 5min',
      RegExp(r'kStrictReplayFiveMinute', caseSensitive: false)),
  _BannedToken('inbound webhook DLQ tile',
      RegExp(r'inboundWebhookDLQTile', caseSensitive: false)),
  _BannedToken('package:postgres', RegExp(r"package\s*:\s*postgres")),
];

String _stripDartLineComments(String content) {
  final out = StringBuffer();
  for (final line in content.split('\n')) {
    final idx = line.indexOf('//');
    out.writeln(idx < 0 ? line : line.substring(0, idx));
  }
  return out.toString();
}

void main() {
  group('kStandardTierPresets', () {
    test('keys cover the five poll-only vendors exactly', () {
      expect(kStandardTierPresets.keys.toSet(), _pollOnlyVendorIds);
    });

    test('every value sits inside [60, 3600]', () {
      for (final entry in kStandardTierPresets.entries) {
        expect(entry.value >= 60 && entry.value <= 3600, isTrue,
            reason: 'standard preset for ${entry.key} = ${entry.value}s '
                'outside framework range');
      }
    });

    test('every poll-only vendor uses the vendor-minimum cadence', () {
      // Per the contract: standard tier puts every poll-only vendor at
      // its documented vendor minimum. Oracle Simphony is the strictest
      // floor at 300s; the other four also run 300s by convention even
      // though their vendor minimums are loose.
      expect(kStandardTierPresets['oracle_micros_simphony'], 300);
      expect(kStandardTierPresets['quickbooks_time'], 300);
      expect(kStandardTierPresets['humanity'], 300);
      expect(kStandardTierPresets['agendrix'], 300);
      expect(kStandardTierPresets['push_operations'], 300);
    });
  });

  group('kPremiumTierPresets', () {
    test('keys cover the five poll-only vendors exactly', () {
      expect(kPremiumTierPresets.keys.toSet(), _pollOnlyVendorIds);
    });

    test(
        'oracle_micros_simphony stays at 300 (vendor minimum)',
        () {
      expect(kPremiumTierPresets['oracle_micros_simphony'], 300);
    });

    test('every other poll-only vendor runs at 60s', () {
      expect(kPremiumTierPresets['quickbooks_time'], 60);
      expect(kPremiumTierPresets['humanity'], 60);
      expect(kPremiumTierPresets['agendrix'], 60);
      expect(kPremiumTierPresets['push_operations'], 60);
    });
  });

  group('kFrameworkMaximumCadenceSeconds', () {
    test('matches the contract\'s 1-hour cap', () {
      expect(kFrameworkMaximumCadenceSeconds, 3600);
    });
  });

  group('Phase 8 spine-bridge.0a — V1 lean cut 2 banned items grep '
      '(acceptance item F)', () {
    for (final relativePath in _laneSourceFiles) {
      test('$relativePath carries no banned tokens in executable code',
          () {
        final file = File(relativePath);
        expect(file.existsSync(), isTrue,
            reason: 'tests must run from repository root; expected '
                '$relativePath to exist');
        final stripped = _stripDartLineComments(file.readAsStringSync());
        final hits = <String>[];
        for (final token in _bannedTokens) {
          if (token.pattern.hasMatch(stripped)) {
            hits.add(token.label);
          }
        }
        expect(hits, isEmpty,
            reason: '$relativePath contains banned tokens in executable '
                'code (comments stripped before grep): $hits');
      });
    }
  });
}
