// Phase 9.4 - Recovery code generator.
//
// Generates the 10 single-use recovery codes per the decision lock.
// Format: `XXXX-XXXX-XXXX` using a base32-style alphabet (no `0` /
// `O` / `1` / `I` / `L` to avoid transcription errors when a user
// reads codes off a printout). Uses `Random.secure` for
// cryptographically-strong randomness.
//
// The plaintext codes leave this generator exactly once: the caller
// renders them in the display-once enrollment screen and immediately
// hands the hashed representations to the recovery-code store. The
// generator itself is stateless so the same instance is safe for
// repeated calls.

import 'dart:math';

class RecoveryCodeGenerator {
  RecoveryCodeGenerator({Random? random})
    : _random = random ?? Random.secure();

  final Random _random;

  /// Default count from the decision lock (10 codes per enrollment).
  static const int defaultCodeCount = 10;

  /// Default group/segment shape: three groups of four characters
  /// separated by `-`. Tunable via [generate] if a future UX change
  /// wants longer codes.
  static const int defaultGroupCount = 3;
  static const int defaultGroupLength = 4;

  /// Crockford-base32-ish alphabet: digits 2-9 + uppercase letters
  /// minus visually-confusable characters. 27 distinct symbols × 12
  /// chars per code = log2(27)*12 ≈ 57 bits per code, well above the
  /// recommended >= 50 bits for one-shot recovery secrets.
  static const String _alphabet = '23456789ABCDEFGHJKMNPQRSTUVWXYZ';

  /// Returns [count] freshly-generated recovery codes. Each code has
  /// [groupCount] groups of [groupLength] characters, joined by `-`.
  List<String> generate({
    int count = defaultCodeCount,
    int groupCount = defaultGroupCount,
    int groupLength = defaultGroupLength,
  }) {
    if (count <= 0) {
      throw ArgumentError.value(count, 'count', 'must be > 0');
    }
    if (groupCount <= 0) {
      throw ArgumentError.value(groupCount, 'groupCount', 'must be > 0');
    }
    if (groupLength <= 0) {
      throw ArgumentError.value(groupLength, 'groupLength', 'must be > 0');
    }
    final codes = <String>[];
    for (var i = 0; i < count; i++) {
      codes.add(_generateOne(groupCount: groupCount, groupLength: groupLength));
    }
    return codes;
  }

  String _generateOne({required int groupCount, required int groupLength}) {
    final groups = <String>[];
    for (var g = 0; g < groupCount; g++) {
      final buf = StringBuffer();
      for (var c = 0; c < groupLength; c++) {
        buf.write(_alphabet[_random.nextInt(_alphabet.length)]);
      }
      groups.add(buf.toString());
    }
    return groups.join('-');
  }

  /// Normalizes a user-typed code so the lookup matches what was
  /// generated. The display format is `XXXX-XXXX-XXXX`; users may
  /// type with mixed case, no dashes, or extra spaces. Normalization
  /// strips whitespace + dashes, uppercases, and refuses any
  /// character outside the alphabet (returns null).
  static String? normalize(String input) {
    final stripped = input
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll('-', '')
        .toUpperCase();
    for (final char in stripped.split('')) {
      if (!_alphabet.contains(char)) {
        return null;
      }
    }
    if (stripped.isEmpty) return null;
    return stripped;
  }
}
