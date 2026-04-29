import 'package:flutter/material.dart';
import 'services/auth/proxy_permission_snapshot_loader.dart';
import 'screens/auth/auth_permission_context_bridge.dart';
import 'screens/auth/auth_gate.dart';
import 'theme/app_theme.dart';
import 'internal/barrio/screens/barrio_home_screen.dart';

class BarrioApp extends StatelessWidget {
  const BarrioApp({
    super.key,
    this.requireAuth = false,
    this.permissionContextLoader,
  });

  final bool requireAuth;
  final PermissionContextLoader? permissionContextLoader;

  @override
  Widget build(BuildContext context) {
    const home = BarrioHomeScreen();
    return MaterialApp(
      title: 'Barrio',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeData,
      home: requireAuth
          ? AuthGate(
              authenticatedChild: AuthPermissionContextBridge(
                permissionContextLoader: permissionContextLoader,
                child: home,
              ),
            )
          : home,
    );
  }
}
