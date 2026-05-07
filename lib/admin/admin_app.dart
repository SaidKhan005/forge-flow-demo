// Phase 11A.0 - Admin MaterialApp.
//
// Top-level Flutter Web app for the F&F Operations Console. Wraps
// the AdminAuthGate so the entire surface area lives behind the
// fail-closed admin role gate. Brand styling is reused verbatim
// from `lib/theme/app_theme.dart` per the 11A non-negotiable
// "brand styling identical to operator app".

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'admin_auth_gate.dart';
import 'admin_button_styles.dart';
import 'admin_routes.dart';
import 'admin_shell.dart';

class AdminConsoleApp extends StatefulWidget {
  const AdminConsoleApp({
    super.key,
    required this.authSource,
    this.routes = kAdminRoutes,
    this.sharePreviewMode = false,
  });

  final AdminAuthSource authSource;
  final List<AdminRoute> routes;
  final bool sharePreviewMode;

  @override
  State<AdminConsoleApp> createState() => _AdminConsoleAppState();
}

class _AdminConsoleAppState extends State<AdminConsoleApp> {
  @override
  void dispose() {
    widget.authSource.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Forge & Flow Admin Console',
      debugShowCheckedModeBanner: false,
      theme: AdminButtonStyles.applyTo(AppTheme.themeData),
      home: AdminAuthGate(
        source: widget.authSource,
        adminShellBuilder: (context, session) => AdminShell(
          session: session,
          authSource: widget.authSource,
          routes: widget.routes,
          sharePreviewMode: widget.sharePreviewMode,
        ),
      ),
    );
  }
}
