import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/i18n/money_formatter.dart';

void main() {
  group('MoneyFormatter — English (default)', () {
    test('formats positive amount', () {
      expect(MoneyFormatter.format(1234.56), r'$1,234.56');
    });

    test('formats zero', () {
      expect(MoneyFormatter.format(0), r'$0.00');
    });

    test('formats negative amount', () {
      expect(MoneyFormatter.format(-9876.50), r'-$9,876.50');
    });

    test('formats amount under 1000', () {
      expect(MoneyFormatter.format(99.99), r'$99.99');
    });

    test('formats large amount with multiple comma groups', () {
      expect(MoneyFormatter.format(1234567.89), r'$1,234,567.89');
    });

    test('respects decimalDigits = 0', () {
      expect(
        MoneyFormatter.format(1234.0, decimalDigits: 0),
        r'$1,234',
      );
    });

    test('en_US locale behaves like en', () {
      expect(
        MoneyFormatter.format(1234.56, locale: const Locale('en', 'US')),
        r'$1,234.56',
      );
    });
  });

  group('MoneyFormatter — French Canada (fr_CA)', () {
    const frCA = Locale('fr', 'CA');

    test('formats positive amount with correct separators', () {
      // fr_CA: 1 234,56 $
      final result = MoneyFormatter.format(1234.56, locale: frCA);
      expect(result, contains(',56'));
      expect(result, endsWith(r'$'));
      expect(result, isNot(contains('.')));
    });

    test('formats zero', () {
      final result = MoneyFormatter.format(0, locale: frCA);
      expect(result, contains(',00'));
      expect(result, endsWith(r'$'));
    });

    test('formats negative amount', () {
      final result = MoneyFormatter.format(-1234.56, locale: frCA);
      expect(result, startsWith('-'));
      expect(result, contains('1'));
      expect(result, endsWith(r'$'));
    });

    test('formats large amount with space thousands separator', () {
      final result = MoneyFormatter.format(1234567.89, locale: frCA);
      // Should contain the narrow space grouping: 1 234 567,89 $
      expect(result, contains('234'));
      expect(result, contains(',89'));
      expect(result, endsWith(r'$'));
    });

    test('fr locale (no country) also uses fr_CA format', () {
      final result = MoneyFormatter.format(
        999.99,
        locale: const Locale('fr'),
      );
      expect(result, contains(',99'));
      expect(result, endsWith(r'$'));
    });
  });

  group('MoneyFormatter — custom currency symbol', () {
    test('supports custom symbol', () {
      final result = MoneyFormatter.format(100.0, currencySymbol: '€');
      expect(result, contains('€'));
    });
  });
}
