// In-app text-size stepper for the Barrio shell (accessibility pass,
// operator-approved rec #12, 2026-07-24).
//
// Three quiet steps (Standard / Large / Extra large) persisted locally
// via shared_preferences, applied as a MediaQuery textScaler override
// on the Barrio shell only (see BarrioTextScale in
// ../widgets/barrio_text_scale.dart).
//
// Composition contract (documented here, tested in
// test/barrio_text_size_stepper_test.dart): the step multiplier
// COMPOSES with the system text-size setting, it never replaces it.
// The effective scaled font size is
//
//     system textScaler output  x  Barrio step multiplier
//
// so a reader who runs the phone at 1.3x and picks Extra large (1.3x)
// reads at 1.69x. The Barrio surface is audited (widget tests at 390x844)
// through 2.0x combined scale.
//
// All state is LOCAL to the device, same lightweight store the streak
// and reading-memory services use. A platform without a working
// preferences store reads as Standard and writes are no-ops.

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The three operator-facing text-size steps.
enum BarrioTextSize {
  standard(multiplier: 1.0, label: 'Standard'),
  large(multiplier: 1.15, label: 'Large'),
  extraLarge(multiplier: 1.3, label: 'Extra large');

  /// Multiplier applied ON TOP of the system text scaler (see the
  /// composition contract in the library comment).
  final double multiplier;

  /// Plain-English option label (UX writing standard).
  final String label;

  const BarrioTextSize({required this.multiplier, required this.label});
}

/// Loads, holds, and persists the chosen step. One process-wide
/// notifier: the shell listens and rebuilds the MediaQuery override.
class BarrioTextSizeController {
  BarrioTextSizeController._();

  /// Preference key holding the chosen step's enum name.
  static const String prefsKey = 'barrio_text_size';

  /// The current step. Defaults to Standard until [load] resolves.
  static final ValueNotifier<BarrioTextSize> notifier =
      ValueNotifier<BarrioTextSize>(BarrioTextSize.standard);

  static bool _loadKicked = false;

  /// Loads the persisted step once per process. Safe to call from
  /// multiple mount points; only the first call reads the store.
  static Future<void> load() async {
    if (_loadKicked) return;
    _loadKicked = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(prefsKey);
      if (stored == null) return;
      for (final size in BarrioTextSize.values) {
        if (size.name == stored) {
          notifier.value = size;
          return;
        }
      }
    } catch (_) {
      // Persistence unavailable: stay at Standard.
    }
  }

  /// Applies and persists a new step.
  static Future<void> set(BarrioTextSize size) async {
    notifier.value = size;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, size.name);
    } catch (_) {
      // Persistence unavailable: the choice still applies this session.
    }
  }

  /// Test hook: resets the in-memory state so each test starts fresh.
  @visibleForTesting
  static void resetForTest() {
    _loadKicked = false;
    notifier.value = BarrioTextSize.standard;
  }
}

/// A [TextScaler] that multiplies whatever the system scaler produces
/// by the Barrio step multiplier (the composition contract above).
/// Keeping the system scaler inside preserves any nonlinear system
/// scaling curve instead of flattening it to one linear factor.
class BarrioComposedTextScaler extends TextScaler {
  final TextScaler system;
  final double multiplier;

  const BarrioComposedTextScaler({
    required this.system,
    required this.multiplier,
  });

  static const double _referenceFontSize = 16.0;

  @override
  double scale(double fontSize) => system.scale(fontSize) * multiplier;

  @override
  // ignore: deprecated_member_use - TextScaler still declares this
  // abstract getter, so a subclass MUST override it until the SDK
  // removes it; computed via scale() so no deprecated member is read.
  double get textScaleFactor =>
      scale(_referenceFontSize) / _referenceFontSize;

  @override
  bool operator ==(Object other) {
    return other is BarrioComposedTextScaler &&
        other.system == system &&
        other.multiplier == multiplier;
  }

  @override
  int get hashCode => Object.hash(system, multiplier);
}
