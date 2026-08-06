// Guard for the Wave 3 token sweep (premium + performance audit B5-B8).
//
// The sweep replaced four raw colour literals that had been copy-pasted
// across the Barrio module with named tokens in
// `widgets/barrio_destination_scaffold.dart`. Tokens only stay adopted if
// something fails when a literal comes back, so this test scans the module
// source and rejects any re-introduction.
//
// Two deliberate design choices, both about not being a vacuous test:
//
//  1. The expected hex strings below are written out BY HAND. They are not
//     read from `BarrioColors`. A guard whose expected value is produced by
//     the same constant it is policing still passes after that constant
//     drifts, which is exactly the failure mode it is supposed to catch.
//     `tokenValueCrossCheck` then asserts the hand-written hex still equals
//     the live token, so a deliberate re-tint fails loudly here and has to
//     be acknowledged rather than silently widening the guard.
//
//  2. Every scan asserts it actually matched something. A typo in a pattern
//     or a wrong directory would otherwise make the whole file pass by
//     finding nothing at all.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_destination_scaffold.dart';

/// The literals the sweep removed, mapped to the fix a future author needs.
///
/// Keys are matched case-insensitively, so `0xff2ecc71` is caught too.
const Map<String, String> kBannedLiterals = <String, String>{
  '0xFF2ECC71': 'use BarrioColors.success (or BarrioColors.accentPlaybook '
      'when it is an identity colour, not a status)',
  '0xFF10151F': 'use barrioOnAccent(accent); never hardcode the dark side',
  '0x1A1A2456': 'use BarrioPremiumBackground, which owns BarrioColors.navyBloom',
  '0x2216243B': 'use BarrioColors.hairline',
};

/// The single file allowed to spell those literals: the token declarations.
const String kTokenFileName = 'barrio_destination_scaffold.dart';

/// A `static const Color foo = Color(0x........);` declaration line.
final RegExp kTokenDeclaration = RegExp(
  r'^\s*static const Color \w+\s*=\s*Color\(0x[0-9A-Fa-f]{8}\);',
);

List<File> _barrioSources() => Directory('lib/internal/barrio')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .toList();

void main() {
  group('Barrio token adoption (audit B5-B8)', () {
    test('the scan reaches the real module source', () {
      // Anti-vacuity: if the path or the extension filter ever breaks, every
      // other test in this file would pass by scanning nothing.
      final sources = _barrioSources();
      expect(sources.length, greaterThan(40),
          reason: 'expected the Barrio module, got ${sources.length} files');
      expect(
        sources.where((f) => f.path.endsWith(kTokenFileName)),
        isNotEmpty,
        reason: 'the token file must be inside the scanned tree',
      );
    });

    test('tokenValueCrossCheck: hand-written hex still matches the tokens', () {
      // Independent of the scan: these compare the live token objects with
      // hex the test author typed, so the guard cannot drift silently along
      // with a re-tint.
      expect(BarrioColors.success.toARGB32(), 0xFF2ECC71);
      expect(BarrioColors.accentPlaybook.toARGB32(), 0xFF2ECC71);
      expect(BarrioColors.onAccentDark.toARGB32(), 0xFF10151F);
      expect(BarrioColors.navyBloom.toARGB32(), 0x1A1A2456);
      expect(BarrioColors.hairline.toARGB32(), 0x2216243B);
    });

    test('no banned colour literal outside the token declarations', () {
      final sources = _barrioSources();
      final offenders = <String>[];
      // Per literal: how many times it was seen on a real declaration line.
      final declared = <String, int>{for (final k in kBannedLiterals.keys) k: 0};

      for (final file in sources) {
        final isTokenFile = file.path.endsWith(kTokenFileName);
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          // Both sides are uppercased, so the `0x` prefix becomes `0X` on
          // both and the comparison still lines up. Uppercasing only the
          // source line silently matches nothing.
          final upper = line.toUpperCase();
          for (final entry in kBannedLiterals.entries) {
            if (!upper.contains(entry.key.toUpperCase())) continue;
            if (isTokenFile && kTokenDeclaration.hasMatch(line)) {
              declared[entry.key] = declared[entry.key]! + 1;
              continue;
            }
            offenders.add(
              '${file.path}:${i + 1}  ${entry.key}  ->  ${entry.value}\n'
              '    ${line.trim()}',
            );
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason: 'Raw colour literals are back in the Barrio module. The '
            'tokens in $kTokenFileName are the single source of truth:\n'
            '${offenders.join('\n')}',
      );

      // Anti-vacuity: each literal must still be found at its declaration.
      // Without this, a mistyped key would match nothing anywhere and the
      // emptiness of `offenders` would prove nothing.
      for (final entry in declared.entries) {
        expect(
          entry.value,
          greaterThan(0),
          reason: '${entry.key} was not found on any token declaration line '
              'in $kTokenFileName. Either the token was renamed or removed, '
              'or this guard is no longer matching anything.',
        );
      }
    });

    test('the navy bloom gradient is declared in exactly one place', () {
      // B7 specifically: five screens used to re-declare the bloom stop
      // rather than compose BarrioPremiumBackground.
      final withBloom = _barrioSources()
          .where((f) => f.readAsStringSync().contains('BarrioColors.navyBloom'))
          .map((f) => f.path)
          .toList();
      expect(withBloom, hasLength(1),
          reason: 'BarrioColors.navyBloom should only be referenced by '
              'BarrioPremiumBackground, found: $withBloom');
      expect(withBloom.single, endsWith(kTokenFileName));
    });
  });
}
