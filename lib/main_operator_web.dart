// Phase 11W.0 - Operator Web Console entrypoint.
//
// Flutter Web entrypoint for the Operator Web Console at
// `app.forgeflow.app`. Lives on a separate Cloud Run service from the
// operator-app proxy and the F&F Operations Console (per
// `Dockerfile.operator_web` + `scripts/deploy_operator_web.ps1`).
//
// Two run modes:
//
//   * Live (default for `flutter build web` and the deploy script).
//     Wires the live Firebase Auth web SDK (`firebase_auth_web` is in
//     `pubspec.yaml`) and a real `OperatorWebAuthSource` that calls
//     the existing Phase 9 proxy routes for magic-link verify,
//     password set, MFA enroll, and T&Cs accept.
//
//     The live source lands in a follow-up `11W.0.live` slice -
//     exactly the same pattern Phase 11A used (gate widget shipped
//     first, HTTP gateway followed). Until that lands, the deploy
//     script refuses to publish a non-demo build that would silently
//     fall back to fixtures.
//
//   * Demo (opt-in only). `--dart-define=OPERATOR_WEB_DEMO_AUTH=true`
//     swaps in `DemoOperatorWebAuthSource` for the slice walkthrough.
//     This is what `scripts/run_operator_web_dev.ps1` (follow-up)
//     invokes for local dev and the 11W.0 walkthrough; the deploy
//     script requires an explicit `-DemoMode` switch with a loud
//     warning to flip a Cloud Run deploy into demo, because demo auth
//     on a publicly-routed `--allow-unauthenticated` Cloud Run
//     service is a privilege bypass.
//
// Web-only: this entrypoint must NOT import `dart:io` (transitively
// either) or `sqflite` / `sqflite_common_ffi`. The operator app
// (`lib/main_forgeflow.dart`) uses both extensively for offline
// caching; the operator-web build target re-uses brand theme + auth
// gateway only and reads/writes through the proxy via HTTPS.

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'operator_web/auth/firebase_operator_web_auth_source.dart';
import 'operator_web/auth/operator_web_auth_source.dart';
import 'operator_web/operator_web_app.dart';
import 'operator_web/services/demo_security_gateway.dart';
import 'operator_web/services/demo_team_audit_log_gateway.dart';
import 'operator_web/services/demo_team_fixtures.dart';
import 'operator_web/services/demo_team_hierarchy_gateway.dart';
import 'operator_web/services/demo_team_roles_gateway.dart';
import 'operator_web/services/demo_team_sessions_gateway.dart';
import 'operator_web/services/demo_team_users_gateway.dart';
import 'operator_web/services/operator_web_proxy_client.dart';
import 'operator_web/services/operator_web_team_gateway_providers.dart';
import 'operator_web/services/web_security_gateway.dart';
import 'operator_web/services/web_team_audit_log_gateway.dart';
import 'operator_web/services/web_team_hierarchy_gateway.dart';
import 'operator_web/services/web_team_roles_gateway.dart';
import 'operator_web/services/web_team_sessions_gateway.dart';
import 'operator_web/services/web_team_users_gateway.dart';
import 'operator_web/widgets/init_failed_app.dart';
import 'services/auth/firebase_auth_client_sdk.dart';

/// Opt-in demo switch. **Must default to false** so a forgotten flag
/// can never publish demo auth on a public Cloud Run service.
const bool _kOperatorWebDemoAuth = bool.fromEnvironment(
  'OPERATOR_WEB_DEMO_AUTH',
);

/// Operator-web proxy base URI. `--dart-define=OPERATOR_WEB_PROXY_BASE_URI=...`
/// points the live HTTP gateway at the F&F advisor proxy
/// (e.g. `https://proxy.forgeflow.app`). Live mode requires this
/// value and fails closed when it is missing; only demo mode may
/// fall back to the in-memory walkthrough source.
const String _kOperatorWebProxyBaseUri = String.fromEnvironment(
  'OPERATOR_WEB_PROXY_BASE_URI',
);

/// Firebase web options for the operator-web staging project. Mirrors
/// `web/firebase-config.js`. FlutterFire Web does not read that file
/// automatically; the default app must be created with explicit
/// [FirebaseOptions] unless a JavaScript bootstrap has already
/// initialized it.
@visibleForTesting
const FirebaseOptions kOperatorWebFirebaseOptions = FirebaseOptions(
  apiKey: 'AIzaSyBeTA2ye7U1gsrwZyGcMVDOAfo7Seh2oqM',
  appId: '1:78630909582:web:d716c986475899f13a7bdf',
  messagingSenderId: '78630909582',
  projectId: 'forge-flow-staging',
  authDomain: 'forge-flow-staging.firebaseapp.com',
  storageBucket: 'forge-flow-staging.firebasestorage.app',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final source = await _resolveAuthSource();
    final magicLinkToken = _parseMagicLinkToken();
    runApp(
      OperatorWebApp(authSource: source, initialMagicLinkToken: magicLinkToken),
    );
  } catch (error, stack) {
    // Fail-closed: any wiring error (Firebase init failure, missing
    // proxy URI, etc.) lands on the calm "wiring failed" surface
    // rather than silently falling back to demo.
    runApp(OperatorWebInitFailedApp(error: error, stack: stack));
  }
}

Future<OperatorWebAuthSource> _resolveAuthSource() async {
  if (_kOperatorWebDemoAuth) {
    // Demo flavor: extend the demo auth source so the router can pick
    // up the in-memory `DemoWebTeamUsersGateway` +
    // `DemoWebTeamRolesGateway` + `DemoWebTeamHierarchyGateway` +
    // `DemoWebTeamSessionsGateway` via the matching provider mixins.
    // Live flavor wires `package:http`-backed gateways against the
    // same proxy client in the `11W.x.live` follow-ups (mirrors the
    // gateway-follows-shell pattern Phase 11A used).
    return _DemoOperatorWebAuthSourceWithTeamSurfaces();
  }
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(options: kOperatorWebFirebaseOptions);
  }
  final rawBaseUri = _kOperatorWebProxyBaseUri.trim();
  if (rawBaseUri.isEmpty) {
    throw StateError(
      'OPERATOR_WEB_PROXY_BASE_URI is required when '
      'OPERATOR_WEB_DEMO_AUTH is false. Pass '
      '--dart-define=OPERATOR_WEB_PROXY_BASE_URI=https://proxy.forgeflow.app '
      'or set OPERATOR_WEB_DEMO_AUTH=true for the local-dev walkthrough.',
    );
  }
  final baseUri = Uri.parse(rawBaseUri);
  if (!baseUri.hasScheme || !baseUri.hasAuthority) {
    throw StateError('OPERATOR_WEB_PROXY_BASE_URI must be an absolute URI');
  }
  // `11W.0.live` slice (matches the Phase 11A.0 → 11A.1 cadence). The
  return FirebaseOperatorWebAuthSource(
    authClient: FirebaseAuthSdkClient(),
    proxyClient: OperatorWebProxyClient(baseUri: baseUri),
  );
}

/// Parses the magic-link token off `Uri.base`. The welcome screen
/// pre-fills its token field with the result so a deep-link
/// `/onboarding/welcome?token=...` lands the operator one tap away
/// from password setup.
String? _parseMagicLinkToken() {
  try {
    final base = Uri.base;
    final token = base.queryParameters['token'];
    if (token == null || token.trim().isEmpty) return null;
    return token.trim();
  } catch (_) {
    return null;
  }
}

/// Demo flavor wrapper that mixes
/// [OperatorWebTeamUsersGatewayProvider] +
/// [OperatorWebTeamRolesGatewayProvider] +
/// [OperatorWebTeamHierarchyGatewayProvider] +
/// [OperatorWebTeamSessionsGatewayProvider] +
/// [OperatorWebTeamAuditLogGatewayProvider] +
/// [OperatorWebSecurityGatewayProvider] onto the demo auth source.
/// The router reads each gateway off these interfaces so the
/// Members + Roles + Locations + Sessions + Audit Log + Security
/// surfaces share the demo fixture data set during the walkthrough.
/// Live mode binds the live HTTP impls in their `11W.x.live`
/// follow-ups.
class _DemoOperatorWebAuthSourceWithTeamSurfaces
    extends DemoOperatorWebAuthSource
    implements
        OperatorWebTeamUsersGatewayProvider,
        OperatorWebTeamRolesGatewayProvider,
        OperatorWebTeamHierarchyGatewayProvider,
        OperatorWebTeamSessionsGatewayProvider,
        OperatorWebTeamAuditLogGatewayProvider,
        OperatorWebSecurityGatewayProvider {
  _DemoOperatorWebAuthSourceWithTeamSurfaces()
      : teamUsersGateway = DemoWebTeamUsersGateway(),
        teamRolesGateway = DemoWebTeamRolesGateway(),
        teamHierarchyGateway = DemoWebTeamHierarchyGateway(),
        teamSessionsGateway = DemoWebTeamSessionsGateway(),
        teamAuditLogGateway = DemoWebTeamAuditLogGateway(),
        securityGateway = DemoWebSecurityGateway(),
        super(initial: const OperatorWebNeedsToken());

  @override
  final WebTeamUsersGateway teamUsersGateway;

  @override
  final WebTeamRolesGateway teamRolesGateway;

  @override
  final WebTeamHierarchyGateway teamHierarchyGateway;

  @override
  final WebTeamSessionsGateway teamSessionsGateway;

  @override
  final WebTeamAuditLogGateway teamAuditLogGateway;

  @override
  final WebSecurityGateway securityGateway;

  /// Demo walkthrough pins the operator-web row to the fixture id so
  /// `(this session)` lights up on a known row. Live mode hydrates
  /// this from the auth source in the `11W.4.live` follow-up.
  @override
  String? get currentSessionId => kDemoTeamSessionThisSessionId;
}

