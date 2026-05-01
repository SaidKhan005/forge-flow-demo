// Phase 9.UX.7 - password reset deep-link source.
//
// Abstracts the platform-side incoming-URL stream so the unauthenticated
// shell can navigate to [PasswordResetConfirmScreen] when the operator
// taps a `forgeflow://reset-password?oobCode=...` link from the
// Firebase action page (or any other source that hands the OS such a
// URI). Production wires [WidgetsBindingPasswordResetDeepLinkSource]
// which reads incoming routes through Flutter's built-in navigation
// channel; tests inject a controllable [InMemoryPasswordResetDeepLinkSource].

import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';

abstract class PasswordResetDeepLinkSource {
  /// Returns the URI the OS used to launch the app, if any. Resolves
  /// before the first frame so the bootstrap can decide whether to
  /// open the confirm screen during cold-start.
  Future<Uri?> initialLink();

  /// Stream of subsequent incoming URIs while the app is running.
  Stream<Uri> uriStream();
}

/// Default no-op source. Returns null + an empty stream so a build
/// without a real deep-link binding renders the login flow as today
/// without raising errors.
class NoIncomingPasswordResetDeepLinkSource
    implements PasswordResetDeepLinkSource {
  const NoIncomingPasswordResetDeepLinkSource();

  @override
  Future<Uri?> initialLink() async => null;

  @override
  Stream<Uri> uriStream() => const Stream<Uri>.empty();
}

/// Test-injectable source. Tests can publish URIs through
/// [emit] and pre-seed the cold-start link via [initial].
class InMemoryPasswordResetDeepLinkSource
    implements PasswordResetDeepLinkSource {
  InMemoryPasswordResetDeepLinkSource({Uri? initial}) : _initial = initial;

  final Uri? _initial;
  final StreamController<Uri> _controller = StreamController<Uri>.broadcast();

  @override
  Future<Uri?> initialLink() async => _initial;

  @override
  Stream<Uri> uriStream() => _controller.stream;

  void emit(Uri uri) => _controller.add(uri);

  Future<void> close() => _controller.close();
}

/// Production source backed by Flutter's built-in
/// [WidgetsBindingObserver.didPushRouteInformation] hook. Android's
/// intent-filter delivery + iOS universal-link handoff both flow
/// through the navigation channel — no third-party package needed
/// for the basic custom-scheme case.
///
/// Bind a single instance for the app lifetime and dispose it via
/// [stopListening] on shutdown.
class WidgetsBindingPasswordResetDeepLinkSource
    with WidgetsBindingObserver
    implements PasswordResetDeepLinkSource {
  WidgetsBindingPasswordResetDeepLinkSource({PlatformDispatcher? dispatcher})
    : _dispatcher = dispatcher ?? WidgetsBinding.instance.platformDispatcher;

  final PlatformDispatcher _dispatcher;
  final StreamController<Uri> _controller = StreamController<Uri>.broadcast();
  bool _attached = false;

  void startListening() {
    if (_attached) return;
    WidgetsBinding.instance.addObserver(this);
    _attached = true;
  }

  Future<void> stopListening() async {
    if (_attached) {
      WidgetsBinding.instance.removeObserver(this);
      _attached = false;
    }
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }

  @override
  Future<Uri?> initialLink() async {
    final raw = _dispatcher.defaultRouteName;
    return _safeParse(raw);
  }

  @override
  Stream<Uri> uriStream() => _controller.stream;

  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) {
    final uri = routeInformation.uri;
    _controller.add(uri);
    return Future.value(true);
  }

  static Uri? _safeParse(String? raw) {
    if (raw == null || raw.isEmpty || raw == '/') return null;
    try {
      return Uri.parse(raw);
    } on FormatException {
      return null;
    }
  }
}
