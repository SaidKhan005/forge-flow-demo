import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

/// Handles incoming deep links from both the legacy custom scheme
/// (`forgeflow://`) and HTTPS Universal Links / App Links
/// (`https://app.forgeflow.app/...`).
///
/// The service normalises both forms into a canonical path+query so the
/// router does not need to know which scheme arrived.
///
/// Consumers subscribe to [links] and react to [Uri] values. The first link
/// (cold-start) is emitted from [getInitialLink] via the `_emitInitial`
/// helper on [initialize].
class DeepLinkService {
  DeepLinkService({AppLinks? appLinks})
      : _appLinks = appLinks ?? AppLinks();

  final AppLinks _appLinks;
  final StreamController<Uri> _controller =
      StreamController<Uri>.broadcast();

  StreamSubscription<Uri>? _subscription;

  /// Emits every incoming deep-link URI, normalised to a canonical form.
  Stream<Uri> get links => _controller.stream;

  /// Start listening. Call once at app launch.
  Future<void> initialize() async {
    // Cold-start / terminated-state link.
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) {
        _emit(initial);
      }
    } catch (_) {
      // Best-effort; if there is no initial link the stream simply has no
      // first event.
    }

    // Warm-start / in-app links.
    _subscription = _appLinks.uriLinkStream.listen(
      _emit,
      onError: (_) {}, // swallow; link errors must not crash the app.
    );
  }

  void _emit(Uri uri) {
    if (!_controller.isClosed) {
      _controller.add(_normalise(uri));
    }
  }

  /// Normalises a deep link URI.
  ///
  /// `https://app.forgeflow.app/path?query` → `forgeflow://path?query`
  /// `forgeflow://path?query`               → unchanged
  Uri _normalise(Uri uri) {
    if (uri.scheme == 'https' &&
        uri.host == 'app.forgeflow.app') {
      return uri.replace(scheme: 'forgeflow', host: uri.path.isNotEmpty
          ? uri.path.split('/').firstWhere(
              (s) => s.isNotEmpty,
              orElse: () => '',
            )
          : '');
    }
    return uri;
  }

  @mustCallSuper
  Future<void> dispose() async {
    await _subscription?.cancel();
    await _controller.close();
  }
}
