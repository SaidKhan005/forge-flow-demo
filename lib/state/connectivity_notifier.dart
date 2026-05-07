// A9.SY1 — Connectivity state for V1 mobile read-only enforcement.
//
// Uses dart:io InternetAddress.lookup as a lightweight heartbeat —
// no third-party package required (connectivity_plus is not in
// pubspec; adding a package for this slim surface isn't warranted for
// V1). The probe targets 'example.com' which is a guaranteed-stable
// RFC 2606 delegation; any non-throw reply means DNS is reachable and
// we consider the device online.
//
// Callers that need to react to connectivity changes listen to this
// notifier via Provider/ChangeNotifierProvider. The banner in
// ForgeFlowApp and the ConnectivityRequiredButton widget both consume
// it.
//
// For tests that cannot use dart:io network calls, inject a
// [FakeConnectivityNotifier] instead.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Observable connectivity state used by the A9.SY1 offline enforcement
/// layer. Fires [notifyListeners] whenever the online/offline transition
/// crosses in either direction.
class ConnectivityNotifier extends ChangeNotifier {
  ConnectivityNotifier({
    Duration pollInterval = const Duration(seconds: 15),
    Future<bool> Function()? probe,
  }) : _pollInterval = pollInterval,
       _probe = probe ?? _defaultProbe {
    _start();
  }

  /// Internal constructor used by [FakeConnectivityNotifier] to skip
  /// starting the polling timer. Must only be called from subclasses.
  ConnectivityNotifier._noTimer()
    : _pollInterval = const Duration(days: 365),
      _probe = _defaultProbe;

  final Duration _pollInterval;
  final Future<bool> Function() _probe;

  bool _isOnline = true;
  Timer? _timer;

  /// True when the last connectivity probe succeeded.
  bool get isOnline => _isOnline;

  void _start() {
    // Run an immediate probe then schedule recurring checks.
    _runProbe();
    _timer = Timer.periodic(_pollInterval, (_) => _runProbe());
  }

  Future<void> _runProbe() async {
    final result = await _probe();
    if (result != _isOnline) {
      _isOnline = result;
      notifyListeners();
    }
  }

  static Future<bool> _defaultProbe() async {
    try {
      final result = await InternetAddress.lookup('example.com')
          .timeout(const Duration(seconds: 5));
      return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}

/// Test double — connectivity state set manually without any background
/// timer. Safe to use inside flutter_test's fake-async environment.
///
/// Usage:
/// ```dart
/// final notifier = FakeConnectivityNotifier(initiallyOnline: true);
/// addTearDown(notifier.dispose);
/// ```
class FakeConnectivityNotifier extends ConnectivityNotifier {
  FakeConnectivityNotifier({bool initiallyOnline = true})
    : super._noTimer() {
    _isOnline = initiallyOnline;
  }

  void setOnline(bool value) {
    if (value == _isOnline) return;
    _isOnline = value;
    notifyListeners();
  }
}
