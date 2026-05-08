// Phase 11A.0 - Admin MaterialApp.
//
// Top-level Flutter Web app for the F&F Operations Console. Wraps
// the AdminAuthGate so the entire surface area lives behind the
// fail-closed admin role gate. Brand styling is reused verbatim
// from `lib/theme/app_theme.dart` per the 11A non-negotiable
// "brand styling identical to operator app".

import 'package:flutter/material.dart';

import '../auth/mfa_freshness_redirect_listener.dart';
import '../theme/app_theme.dart';
import 'admin_auth_gate.dart';
import 'admin_button_styles.dart';
import 'admin_routes.dart';
import 'admin_shell.dart';
import 'services/admin_http_timeout.dart';

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
  void initState() {
    super.initState();
    // CODE_OPS_DEBT carry-over #1 — register the admin shell's auth
    // source as the process-wide listener for the proxy's
    // `mfa_freshness_required` 403 redirect. Every admin gateway
    // funnels through `sendAdminHttpRequest`, which dispatches to
    // this listener before the gateway's own status-code branch
    // throws. The auth source signs out and emits an
    // [AdminAuthUnauthenticated] state with the proxy-supplied
    // `redirect_uri` hint so the gate widget renders the sign-in
    // card with a friendly explanation.
    AdminHttpFreshnessRedirectDispatcher.listener = widget.authSource;
  }

  @override
  void dispose() {
    // Reset the dispatcher so a tear-down + re-mount does not leak
    // the disposed auth source. The default no-op listener absorbs
    // any in-flight 403s harmlessly.
    AdminHttpFreshnessRedirectDispatcher.listener =
        const NoopMfaFreshnessRedirectListener();
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
