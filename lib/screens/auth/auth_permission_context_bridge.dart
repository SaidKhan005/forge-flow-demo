import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../auth/auth_session.dart';
import '../../services/auth/proxy_permission_snapshot_loader.dart';
import '../../state/auth_session_notifier.dart';
import '../../state/permission_context.dart';

/// Loads the Phase 9 permission snapshot after login and exposes it to
/// permission-gated app surfaces. When no loader is wired, the child renders
/// without a [PermissionContext] so gates fail closed.
class AuthPermissionContextBridge extends StatefulWidget {
  const AuthPermissionContextBridge({
    super.key,
    required this.child,
    this.permissionContextLoader,
  });

  final Widget child;
  final PermissionContextLoader? permissionContextLoader;

  @override
  State<AuthPermissionContextBridge> createState() =>
      _AuthPermissionContextBridgeState();
}

class _AuthPermissionContextBridgeState
    extends State<AuthPermissionContextBridge> {
  PermissionContext? _permissionContext;
  String? _loadedKey;
  String? _loadingKey;

  @override
  void didUpdateWidget(covariant AuthPermissionContextBridge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.permissionContextLoader != widget.permissionContextLoader) {
      _permissionContext = null;
      _loadedKey = null;
      _loadingKey = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AuthSessionNotifier>().session;
    final loader = widget.permissionContextLoader;
    if (loader == null || session == null) {
      if (_permissionContext != null ||
          _loadedKey != null ||
          _loadingKey != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() {
            _permissionContext = null;
            _loadedKey = null;
            _loadingKey = null;
          });
        });
      }
      return widget.child;
    }

    final key = _keyFor(session);
    if (_loadedKey != key && _loadingKey != key) {
      _loadingKey = key;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _loadPermissionContext(loader, session, key);
      });
    }

    final permissionContext = _permissionContext;
    if (permissionContext == null || _loadedKey != key) {
      return widget.child;
    }
    return Provider<PermissionContext>.value(
      value: permissionContext,
      child: widget.child,
    );
  }

  Future<void> _loadPermissionContext(
    PermissionContextLoader loader,
    AuthSession session,
    String key,
  ) async {
    try {
      final loaded = await loader.load(session);
      if (!mounted || _loadingKey != key) return;
      setState(() {
        _permissionContext = loaded;
        _loadedKey = loaded == null ? null : key;
        _loadingKey = null;
      });
    } catch (error) {
      debugPrint('Permission snapshot load failed: $error');
      if (!mounted || _loadingKey != key) return;
      setState(() {
        _permissionContext = null;
        _loadedKey = null;
        _loadingKey = null;
      });
    }
  }

  static String _keyFor(AuthSession session) {
    return [
      session.userId,
      session.operatorId,
      session.locationId,
      session.roles.join(','),
      session.expiresAt.toIso8601String(),
    ].join('|');
  }
}
