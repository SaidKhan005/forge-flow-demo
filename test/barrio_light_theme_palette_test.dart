// Regression lock for the Barrio light theme (app-icon palette:
// warm cream page, deep navy text, teal accents).
//
// Barrio was re-themed from its original dark navy shell to a light
// theme in 2026-07. These assertions fail loudly if the central
// palette ever regresses back to a dark shell (dark background /
// light text), so a future edit cannot silently undo the light theme.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_destination_scaffold.dart';

/// WCAG relative-luminance contrast ratio between two opaque colors.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('Barrio light theme palette', () {
    test('the page base (shellDeep) is a light, warm cream surface', () {
      // A dark shell here is exactly the regression this test guards.
      expect(BarrioColors.shellDeep.computeLuminance(), greaterThan(0.7),
          reason: 'shellDeep must be a light page base, not a dark shell');
      expect(BarrioColors.shellDeep, const Color(0xFFF7F3EA),
          reason: 'shellDeep is the app-icon cream');
    });

    test('the card surface (shellMid) is near-white', () {
      expect(BarrioColors.shellMid.computeLuminance(), greaterThan(0.85));
    });

    test('primary text (textPrimary) is a deep navy ink', () {
      expect(BarrioColors.textPrimary.computeLuminance(), lessThan(0.1),
          reason: 'textPrimary must be dark ink for a light theme');
      expect(BarrioColors.textPrimary, const Color(0xFF16243B),
          reason: 'textPrimary is the app-icon deep navy');
    });

    test('secondary and muted text stay dark on the cream page', () {
      expect(BarrioColors.textSecondary.computeLuminance(), lessThan(0.25));
      expect(BarrioColors.textMuted.computeLuminance(), lessThan(0.35));
    });

    test('body text passes WCAG AA contrast on the cream page', () {
      // Navy-on-cream is the primary reading pairing; it must clear the
      // 4.5:1 normal-text bar.
      expect(_contrast(BarrioColors.textPrimary, BarrioColors.shellDeep),
          greaterThan(4.5),
          reason: 'primary text on the cream page must be WCAG-AA legible');
    });

    test('tealDeep is a darker, text-safe teal than the bright tealWarm fill',
        () {
      // tealWarm stays the bright fill/accent; tealDeep is the legible
      // teal used for text and thin borders on cream.
      expect(BarrioColors.tealDeep.computeLuminance(),
          lessThan(BarrioColors.tealWarm.computeLuminance()),
          reason: 'tealDeep must be darker than the bright tealWarm accent');
    });
  });
}
