// Phase 9.7 - PermissionGate widget.
//
// Renders [child] only when the current [PermissionContext] grants
// [permissionKey]. Otherwise renders [denied] (defaulting to a
// zero-size SizedBox so unpermitted destinations vanish from the
// hub instead of showing a "you can't do this" badge — matches the
// Phase 9.7 acceptance "Barrio routes hidden for unpermitted users").
//
// For sensitive keys (those marked `requires_mfa = true` in the
// catalog), the gate also requires that the [AuthSessionNotifier]
// reports `isAuthFresh` — otherwise the action is treated as
// denied and the caller can re-prompt for step-up MFA before
// re-rendering.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/auth_session_notifier.dart';
import '../../state/permission_context.dart';

class PermissionGate extends StatelessWidget {
  const PermissionGate({
    super.key,
    required this.permissionKey,
    required this.child,
    this.denied,
  });

  final String permissionKey;
  final Widget child;

  /// Rendered when the current context denies [permissionKey].
  /// Defaults to a zero-size widget so unpermitted surfaces
  /// disappear from layout entirely.
  final Widget? denied;

  @override
  Widget build(BuildContext context) {
    PermissionContext? permissionContext;
    try {
      permissionContext = Provider.of<PermissionContext>(context, listen: true);
    } on ProviderNotFoundException {
      permissionContext = null;
    }
    if (permissionContext == null) {
      // No context installed — fail closed: hide the surface. Tests /
      // dev shells can wrap their tree in a Provider<PermissionContext>
      // value with a synthetic snapshot to opt in.
      return denied ?? const SizedBox.shrink();
    }
    if (!permissionContext.hasPermission(permissionKey)) {
      return denied ?? const SizedBox.shrink();
    }
    if (permissionContext.requiresFreshAuth(permissionKey)) {
      AuthSessionNotifier? notifier;
      try {
        notifier = Provider.of<AuthSessionNotifier>(context, listen: true);
      } on ProviderNotFoundException {
        notifier = null;
      }
      if (notifier == null || !notifier.isAuthFresh) {
        return denied ?? const SizedBox.shrink();
      }
    }
    return child;
  }
}
