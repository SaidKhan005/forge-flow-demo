import 'package:flutter/material.dart';
import 'services/auth/password_reset_deep_link_source.dart';
import 'services/auth/password_reset_gateway.dart';
import 'services/auth/proxy_permission_snapshot_loader.dart';
import 'screens/auth/auth_permission_context_bridge.dart';
import 'screens/auth/auth_gate.dart';
import 'theme/app_theme.dart';
import 'internal/barrio/screens/barrio_home_screen.dart';
import 'internal/barrio/widgets/barrio_text_scale.dart';

class BarrioApp extends StatelessWidget {
  const BarrioApp({
    super.key,
    this.requireAuth = false,
    this.permissionContextLoader,
    this.passwordResetGateway,
    this.passwordResetDeepLinkSource,
  });

  final bool requireAuth;
  final PermissionContextLoader? permissionContextLoader;
  final PasswordResetGateway? passwordResetGateway;
  final PasswordResetDeepLinkSource? passwordResetDeepLinkSource;

  @override
  Widget build(BuildContext context) {
    const home = BarrioHomeScreen();
    return MaterialApp(
      title: 'Barrio',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeData,
      // Accessibility pass (rec #12): the in-app text-size stepper
      // composes with the system text scaler for every Barrio route.
      // At the Standard step this is a pass-through (no override).
      builder: (context, child) =>
          BarrioTextScale(child: child ?? const SizedBox.shrink()),
      home: requireAuth
          ? AuthGate(
              passwordResetGateway: passwordResetGateway,
              passwordResetDeepLinkSource: passwordResetDeepLinkSource,
              authenticatedChild: AuthPermissionContextBridge(
                permissionContextLoader: permissionContextLoader,
                child: home,
              ),
            )
          : home,
    );
  }
}
