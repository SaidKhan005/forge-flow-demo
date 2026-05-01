// Phase 9.UX.7 - password reset deep-link handler.
//
// Listens to a [PasswordResetDeepLinkSource] and pushes
// [PasswordResetConfirmScreen] onto the active navigator when the
// incoming URI matches the reset-password contract:
//
//   - scheme:           forgeflow (custom scheme registered in
//                        AndroidManifest.xml + iOS Info.plist), or
//                        any HTTPS host the proxy / Firebase action
//                        page redirects through.
//   - path / host:       reset-password
//   - required query:    oobCode  (Firebase action code)
//   - optional query:    mode     (must equal "resetPassword" when
//                                  forwarded from the Firebase action
//                                  page; absent when the proxy
//                                  forwards the deep-link itself)
//
// Without a matching URI the handler is inert and renders [child].

import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/auth/password_reset_deep_link_source.dart';
import '../../services/auth/password_reset_gateway.dart';
import 'password_reset_confirm_screen.dart';

class PasswordResetDeepLinkHandler extends StatefulWidget {
  const PasswordResetDeepLinkHandler({
    super.key,
    required this.source,
    required this.gateway,
    required this.child,
  });

  final PasswordResetDeepLinkSource source;
  final PasswordResetGateway gateway;
  final Widget child;

  /// Returns the `oobCode` carried by [uri] when it matches the
  /// reset-password deep-link contract; null otherwise.
  static String? extractOobCode(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    final segments = uri.pathSegments;
    final host = uri.host.toLowerCase();
    final mode = uri.queryParameters['mode'];
    final firstSegment = segments.isEmpty ? '' : segments.first.toLowerCase();
    final isForgeflowScheme = scheme == 'forgeflow';
    final hostMatches =
        host == 'reset-password' || firstSegment == 'reset-password';
    final modeMatches =
        mode == null || mode.isEmpty || mode == 'resetPassword';
    if (!isForgeflowScheme || !hostMatches || !modeMatches) return null;
    final oobCode = uri.queryParameters['oobCode'];
    if (oobCode == null || oobCode.trim().isEmpty) return null;
    return oobCode.trim();
  }

  @override
  State<PasswordResetDeepLinkHandler> createState() =>
      _PasswordResetDeepLinkHandlerState();
}

class _PasswordResetDeepLinkHandlerState
    extends State<PasswordResetDeepLinkHandler> {
  StreamSubscription<Uri>? _subscription;
  bool _initialChecked = false;

  @override
  void initState() {
    super.initState();
    _subscription = widget.source.uriStream().listen(_onUri);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (_initialChecked) return;
      _initialChecked = true;
      final uri = await widget.source.initialLink();
      if (uri != null) _onUri(uri);
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _onUri(Uri uri) {
    if (!mounted) return;
    final oobCode = PasswordResetDeepLinkHandler.extractOobCode(uri);
    if (oobCode == null) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => PasswordResetConfirmScreen(
          gateway: widget.gateway,
          oobCode: oobCode,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
