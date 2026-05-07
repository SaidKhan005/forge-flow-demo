import 'dart:ui' show Locale;

/// Locale-aware currency formatter.
///
/// Produces operator-legible currency strings without requiring the full
/// `intl` NumberFormat infrastructure in call sites.
///
/// | Locale   | Example output |
/// |----------|----------------|
/// | en       | $1,234.56      |
/// | en_US    | $1,234.56      |
/// | fr_CA    | 1 234,56 $     |
///
/// The formatter is intentionally a pure-Dart, no-plugin helper so it can
/// be used in widget tests without native bindings.
class MoneyFormatter {
  const MoneyFormatter._();

  /// Format [amount] as a currency string for the given [locale].
  ///
  /// [currencySymbol] defaults to `$` (CAD / USD). Pass an explicit symbol
  /// for other currencies.
  ///
  /// [decimalDigits] defaults to `2`.
  static String format(
    double amount, {
    Locale locale = const Locale('en'),
    String currencySymbol = r'$',
    int decimalDigits = 2,
  }) {
    final languageTag =
        '${locale.languageCode}${locale.countryCode != null ? '_${locale.countryCode}' : ''}';
    return switch (languageTag) {
      'fr_CA' || 'fr' => _formatFrCA(
          amount,
          currencySymbol: currencySymbol,
          decimalDigits: decimalDigits,
        ),
      _ => _formatEn(
          amount,
          currencySymbol: currencySymbol,
          decimalDigits: decimalDigits,
        ),
    };
  }

  // ── English / default: $1,234.56 ─────────────────────────────────────────

  static String _formatEn(
    double amount, {
    required String currencySymbol,
    required int decimalDigits,
  }) {
    final negative = amount < 0;
    final absAmount = amount.abs();
    final formatted = _groupThousands(absAmount, '.', ',', decimalDigits);
    return negative
        ? '-$currencySymbol$formatted'
        : '$currencySymbol$formatted';
  }

  // ── French (Canada): 1 234,56 $ ──────────────────────────────────────────

  static String _formatFrCA(
    double amount, {
    required String currencySymbol,
    required int decimalDigits,
  }) {
    final negative = amount < 0;
    final absAmount = amount.abs();
    // fr_CA uses a narrow no-break space (U+202F) as thousands separator.
    const narrowNbsp = ' ';
    final formatted = _groupThousands(absAmount, ',', narrowNbsp, decimalDigits);
    final withSymbol = '$formatted $currencySymbol';
    return negative ? '-$withSymbol' : withSymbol;
  }

  // ── shared grouping helper ────────────────────────────────────────────────

  static String _groupThousands(
    double value,
    String decimalSeparator,
    String groupSeparator,
    int decimalDigits,
  ) {
    final fixed = value.toStringAsFixed(decimalDigits);
    final parts = fixed.split('.');
    final intPart = _insertGroupSeparators(parts[0], groupSeparator);
    if (decimalDigits == 0 || parts.length < 2) return intPart;
    return '$intPart$decimalSeparator${parts[1]}';
  }

  static String _insertGroupSeparators(String intPart, String sep) {
    final buffer = StringBuffer();
    final length = intPart.length;
    for (var i = 0; i < length; i++) {
      if (i > 0 && (length - i) % 3 == 0) {
        buffer.write(sep);
      }
      buffer.write(intPart[i]);
    }
    return buffer.toString();
  }
}
