// Phase 11A.0 - Admin console entrypoint.
//
// Flutter Web entrypoint for the F&F Operations Console. Lives on a
// separate Cloud Run service from the operator-facing app (per the
// `Dockerfile.admin_console` + `scripts/deploy_admin_console.ps1`
// pair). Two run modes:
//
//   * Live (default for `flutter build web` and the deploy script).
//     Calls `Firebase.initializeApp(options: kAdminFirebaseOptions)`
//     with explicit Dart options mirrored from `web/firebase-config.js`,
//     then backs the gate with a real
//     [FirebaseAdminAuthSource]. The gate admits sessions whose
//     custom claims set `is_super_admin: true` or `is_ff_support:
//     true` - the locked Phase 9 claim shape - and fail-closes
//     everything else.
//
//   * Demo (opt-in only).  `--dart-define=ADMIN_DEMO_AUTH=true`
//     swaps in [DemoAdminAuthSource]. The fixtures
//     `super.admin@forgeflow.test`, `support@forgeflow.test`, and
//     `operator@forgeflow.test` exercise the admit / fail-closed
//     paths without provisioning Firebase. This is what
//     `scripts/run_admin_console_dev.ps1` invokes for local dev and
//     the 11A.0 walkthrough; the deploy script requires an explicit
//     `-DemoMode` switch with a loud warning to flip a Cloud Run
//     deploy into demo, because demo auth on a publicly-routed
//     `--allow-unauthenticated` Cloud Run service is a privilege
//     bypass.

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'admin/admin_app.dart';
import 'admin/admin_auth_gate.dart';
import 'admin/admin_routes.dart';
import 'admin/services/corpus_admin_gateway.dart';
import 'admin/services/data_accuracy_admin_gateway.dart';
import 'admin/services/debug_console_admin_gateway.dart';
import 'admin/services/feature_flags_admin_gateway.dart';
import 'admin/services/health_admin_gateway.dart';
import 'admin/services/integration_admin_gateway.dart';
import 'admin/services/members_admin_gateway.dart';
import 'admin/services/observability_admin_gateway.dart';
import 'admin/services/operator_location_admin_gateway.dart';
import 'admin/services/pricing_tier_admin_gateway.dart';
import 'admin/services/audited_support_actions_admin_gateway.dart';
import 'admin/services/roles_hierarchy_sessions_admin_gateway.dart';
import 'services/auth/firebase_auth_client.dart';
import 'services/auth/firebase_auth_client_sdk.dart';
import 'services/auth/timeout_firebase_auth_client.dart';
import 'theme/app_theme.dart';

/// Opt-in demo switch. **Must default to false** so a forgotten flag
/// can never publish demo auth on a public Cloud Run service.
const bool _kAdminDemoAuth = bool.fromEnvironment('ADMIN_DEMO_AUTH');

/// Admin proxy base URL. `--dart-define=ADMIN_PROXY_BASE_URI=...`
/// points the live HTTP gateway at the F&F admin Cloud Run proxy
/// (e.g. `https://admin-proxy.forgeflow.app`). Live mode requires
/// this value and fails closed when it is missing; only demo mode may
/// fall back to the in-memory walkthrough gateway.
const String _kAdminProxyBaseUri = String.fromEnvironment(
  'ADMIN_PROXY_BASE_URI',
);

/// Firebase web options for the admin console's staging project.
///
/// Keep this in sync with `web/firebase-config.js`. FlutterFire Web
/// does not read that file automatically; the default app must be
/// created with explicit [FirebaseOptions] unless a JavaScript
/// bootstrap has already initialized it.
@visibleForTesting
const FirebaseOptions kAdminFirebaseOptions = FirebaseOptions(
  apiKey: 'AIzaSyBeTA2ye7U1gsrwZyGcMVDOAfo7Seh2oqM',
  appId: '1:78630909582:web:d716c986475899f13a7bdf',
  messagingSenderId: '78630909582',
  projectId: 'forge-flow-staging',
  authDomain: 'forge-flow-staging.firebaseapp.com',
  storageBucket: 'forge-flow-staging.firebasestorage.app',
);

Future<void> main() async {
  // B1.A5 — Release-build demo-auth assertion.
  // `assert` bodies are dead code in release builds (Dart compiles them out),
  // so the check runs only in debug/profile mode where a developer might have
  // accidentally left the flag on. In profile or release mode the constant
  // `_kAdminDemoAuth` is always false (fromEnvironment defaults to false at
  // build time unless explicitly overridden), so the check is a belt-and-
  // suspenders guard for CI environments that pass the flag.
  assert(() {
    if (!kDebugMode && _kAdminDemoAuth) {
      throw StateError(
        'ADMIN_DEMO_AUTH must not be true in a non-debug build. '
        'Demo auth bypasses Firebase and must never ship on a public endpoint.',
      );
    }
    return true;
  }());
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final authBinding = await _resolveAuthSource();
    final source = authBinding.source;
    final gateway = _resolveOperatorLocationGateway(authBinding.authClient);
    final pricingGateway = gateway == null
        ? null
        : _resolvePricingTierAdminGateway(authBinding.authClient);
    final dataAccuracyGateway = gateway == null
        ? null
        : _resolveDataAccuracyAdminGateway(authBinding.authClient);
    final corpusGateway = gateway == null
        ? null
        : _resolveCorpusAdminGateway(authBinding.authClient);
    final integrationGateway = gateway == null
        ? null
        : _resolveIntegrationAdminGateway(authBinding.authClient);
    final healthGateway = gateway == null ? null : _resolveHealthAdminGateway();
    final observabilityGateway = gateway == null
        ? null
        : _resolveObservabilityAdminGateway(authBinding.authClient);
    final featureFlagsGateway = gateway == null
        ? null
        : _resolveFeatureFlagsAdminGateway(authBinding.authClient);
    final debugConsoleGateway = gateway == null
        ? null
        : _resolveDebugConsoleAdminGateway(authBinding.authClient);
    final membersAdminGateway = gateway == null
        ? null
        : _resolveMembersAdminGateway(authBinding.authClient);
    final rolesHierarchySessionsAdminGateway = gateway == null
        ? null
        : _resolveRolesHierarchySessionsAdminGateway(authBinding.authClient);
    final auditedSupportActionsAdminGateway = gateway == null
        ? null
        : _resolveAuditedSupportActionsAdminGateway(authBinding.authClient);
    final adminApp = AdminConsoleApp(authSource: source);
    // Always wrap with `AdminConsoleServicesScope` so the Pricing /
    // Corpus / Integrations / Feature Flags routes can read
    // `adminAuthSource` and switch to the read-only branch for
    // `ff_support`. Live gateways are still null in demo mode; the
    // route accessors fall back to the seeded in-memory demo gateways
    // in `admin_routes.dart`.
    runApp(
      AdminConsoleServicesScope(
        operatorLocationGateway: gateway,
        pricingTierGateway: pricingGateway,
        dataAccuracyAdminGateway: dataAccuracyGateway,
        corpusAdminGateway: corpusGateway,
        integrationGateway: integrationGateway,
        healthGateway: healthGateway,
        observabilityGateway: observabilityGateway,
        featureFlagsGateway: featureFlagsGateway,
        debugConsoleGateway: debugConsoleGateway,
        membersAdminGateway: membersAdminGateway,
        rolesHierarchySessionsAdminGateway:
            rolesHierarchySessionsAdminGateway,
        auditedSupportActionsAdminGateway:
            auditedSupportActionsAdminGateway,
        adminAuthSource: source,
        child: adminApp,
      ),
    );
  } catch (error, stack) {
    // Fail-closed: any wiring error (Firebase init failure, missing
    // web config, etc.) lands on the calm "auth wiring failed"
    // surface rather than silently falling back to demo.
    runApp(_AdminAuthInitFailedApp(error: error, stack: stack));
  }
}

class _AdminAuthBinding {
  const _AdminAuthBinding({required this.source, required this.authClient});

  final AdminAuthSource source;
  final FirebaseAuthClient? authClient;
}

Future<_AdminAuthBinding> _resolveAuthSource() async {
  if (_kAdminDemoAuth) {
    return _AdminAuthBinding(
      source: DemoAdminAuthSource.signedOut(),
      authClient: null,
    );
  }
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(options: kAdminFirebaseOptions);
  }
  final authClient = TimeoutFirebaseAuthClient(
    delegate: FirebaseAuthSdkClient(),
  );
  return _AdminAuthBinding(
    source: FirebaseAdminAuthSource(client: authClient),
    authClient: authClient,
  );
}

/// Resolves the operator/location admin gateway for the live
/// console. Production runs bind the HTTP-backed gateway with a
/// Firebase ID-token bearer source. Demo mode returns null, which
/// lets the route fall back to the seeded in-memory demo gateway in
/// `admin_routes.dart`.
OperatorLocationAdminGateway? _resolveOperatorLocationGateway(
  FirebaseAuthClient? authClient,
) {
  if (_kAdminDemoAuth) return null;
  final liveAuthClient = _requireLiveAuthClient(authClient);
  final rawBaseUri = _kAdminProxyBaseUri.trim();
  if (rawBaseUri.isEmpty) {
    throw StateError(
      'ADMIN_PROXY_BASE_URI is required when ADMIN_DEMO_AUTH is false',
    );
  }
  final baseUri = Uri.parse(rawBaseUri);
  if (!baseUri.hasScheme || !baseUri.hasAuthority) {
    throw StateError('ADMIN_PROXY_BASE_URI must be an absolute URI');
  }
  return HttpOperatorLocationAdminGateway(
    baseUri: baseUri,
    bearerTokenProvider: () => _firebaseIdTokenProvider(liveAuthClient),
  );
}

/// Phase 11A.2 — pricing tier admin gateway. Lives on the same admin
/// proxy base URI as the operator/location gateway. Demo mode returns
/// null and the route falls back to the seeded in-memory pricing
/// gateway in `admin_routes.dart`.
PricingTierAdminGateway? _resolvePricingTierAdminGateway(
  FirebaseAuthClient? authClient,
) {
  if (_kAdminDemoAuth) return null;
  final liveAuthClient = _requireLiveAuthClient(authClient);
  final rawBaseUri = _kAdminProxyBaseUri.trim();
  if (rawBaseUri.isEmpty) return null;
  final baseUri = Uri.parse(rawBaseUri);
  if (!baseUri.hasScheme || !baseUri.hasAuthority) return null;
  return HttpPricingTierAdminGateway(
    baseUri: baseUri,
    bearerTokenProvider: () => _firebaseIdTokenProvider(liveAuthClient),
  );
}

/// Phase 8 spine-bridge .C — Data Accuracy + Polling & Pricing live
/// gateway. Uses the same admin proxy base URI as the existing admin
/// surfaces. Demo mode returns null and `admin_routes.dart` supplies
/// the seeded in-memory walkthrough gateway.
DataAccuracyAdminGateway? _resolveDataAccuracyAdminGateway(
  FirebaseAuthClient? authClient,
) {
  if (_kAdminDemoAuth) return null;
  final liveAuthClient = _requireLiveAuthClient(authClient);
  final rawBaseUri = _kAdminProxyBaseUri.trim();
  if (rawBaseUri.isEmpty) return null;
  final baseUri = Uri.parse(rawBaseUri);
  if (!baseUri.hasScheme || !baseUri.hasAuthority) return null;
  return HttpDataAccuracyAdminGateway(
    baseUri: baseUri,
    bearerTokenProvider: () => _firebaseIdTokenProvider(liveAuthClient),
  );
}

/// Phase 11A.3a — corpus admin gateway. Same admin proxy base URI as
/// the pricing gateway. Demo mode returns null and the route falls
/// back to the seeded in-memory corpus gateway in `admin_routes.dart`.
CorpusAdminGateway? _resolveCorpusAdminGateway(FirebaseAuthClient? authClient) {
  if (_kAdminDemoAuth) return null;
  final liveAuthClient = _requireLiveAuthClient(authClient);
  final rawBaseUri = _kAdminProxyBaseUri.trim();
  if (rawBaseUri.isEmpty) return null;
  final baseUri = Uri.parse(rawBaseUri);
  if (!baseUri.hasScheme || !baseUri.hasAuthority) return null;
  return HttpCorpusAdminGateway(
    baseUri: baseUri,
    bearerTokenProvider: () => _firebaseIdTokenProvider(liveAuthClient),
  );
}

/// Phase 11A.4 — integration management admin gateway. Lives on the
/// same admin proxy base URI; demo mode falls back to the seeded
/// in-memory gateway in `admin_routes.dart`.
IntegrationAdminGateway? _resolveIntegrationAdminGateway(
  FirebaseAuthClient? authClient,
) {
  if (_kAdminDemoAuth) return null;
  final liveAuthClient = _requireLiveAuthClient(authClient);
  final rawBaseUri = _kAdminProxyBaseUri.trim();
  if (rawBaseUri.isEmpty) return null;
  final baseUri = Uri.parse(rawBaseUri);
  if (!baseUri.hasScheme || !baseUri.hasAuthority) return null;
  return HttpIntegrationAdminGateway(
    baseUri: baseUri,
    bearerTokenProvider: () => _firebaseIdTokenProvider(liveAuthClient),
  );
}

/// Phase 11A.UX.health (F.1) — proxy `/health` envelope gateway. The
/// advisor proxy binary serves both `/v1/admin/*` (admin-gated) and
/// `/health` (public unauthenticated) on the same Cloud Run service,
/// so the health gateway reuses the admin proxy base URI. Demo mode
/// returns null and the route falls back to the seeded in-memory
/// envelope in `admin_routes.dart`.
HealthAdminGateway? _resolveHealthAdminGateway() {
  if (_kAdminDemoAuth) return null;
  final rawBaseUri = _kAdminProxyBaseUri.trim();
  if (rawBaseUri.isEmpty) return null;
  final baseUri = Uri.parse(rawBaseUri);
  if (!baseUri.hasScheme || !baseUri.hasAuthority) return null;
  return HttpHealthAdminGateway(baseUri: baseUri);
}

/// Phase 11A.6 — observability admin gateway. Lives on the same
/// admin proxy base URI as the other admin surfaces. The route hits
/// `GET /v1/admin/observability` with the signed-in admin's bearer
/// token; demo mode returns null and the route falls back to the
/// seeded in-memory envelope in `admin_routes.dart`.
ObservabilityAdminGateway? _resolveObservabilityAdminGateway(
  FirebaseAuthClient? authClient,
) {
  if (_kAdminDemoAuth) return null;
  final liveAuthClient = _requireLiveAuthClient(authClient);
  final rawBaseUri = _kAdminProxyBaseUri.trim();
  if (rawBaseUri.isEmpty) return null;
  final baseUri = Uri.parse(rawBaseUri);
  if (!baseUri.hasScheme || !baseUri.hasAuthority) return null;
  return HttpObservabilityAdminGateway(
    baseUri: baseUri,
    bearerTokenProvider: () => _firebaseIdTokenProvider(liveAuthClient),
  );
}

/// Phase 11A.7 — feature flags admin gateway. Same admin proxy base
/// URI as the other admin surfaces; demo mode falls back to the
/// seeded in-memory gateway in `admin_routes.dart`.
FeatureFlagsAdminGateway? _resolveFeatureFlagsAdminGateway(
  FirebaseAuthClient? authClient,
) {
  if (_kAdminDemoAuth) return null;
  final liveAuthClient = _requireLiveAuthClient(authClient);
  final rawBaseUri = _kAdminProxyBaseUri.trim();
  if (rawBaseUri.isEmpty) return null;
  final baseUri = Uri.parse(rawBaseUri);
  if (!baseUri.hasScheme || !baseUri.hasAuthority) return null;
  return HttpFeatureFlagsAdminGateway(
    baseUri: baseUri,
    bearerTokenProvider: () => _firebaseIdTokenProvider(liveAuthClient),
  );
}

/// Phase 11A.5 — debug console admin gateway. Same admin proxy base
/// URI as the other admin surfaces. Live mode wires the HTTP gateway
/// so the per-operator request log is sourced from the real proxy
/// `proxy_requests` projection — the seeded in-memory walkthrough
/// fixtures must NEVER reach a live deploy. Demo mode (or a missing
/// `ADMIN_PROXY_BASE_URI`) falls back to the in-memory demo gateway
/// in `admin_routes.dart`.
DebugConsoleAdminGateway? _resolveDebugConsoleAdminGateway(
  FirebaseAuthClient? authClient,
) {
  if (_kAdminDemoAuth) return null;
  final liveAuthClient = _requireLiveAuthClient(authClient);
  final rawBaseUri = _kAdminProxyBaseUri.trim();
  if (rawBaseUri.isEmpty) return null;
  final baseUri = Uri.parse(rawBaseUri);
  if (!baseUri.hasScheme || !baseUri.hasAuthority) return null;
  return HttpDebugConsoleAdminGateway(
    baseUri: baseUri,
    bearerTokenProvider: () => _firebaseIdTokenProvider(liveAuthClient),
  );
}

/// Phase 11A.12 - members + invites admin gateway. Same admin proxy
/// base URI as the other admin surfaces; demo mode falls back to the
/// seeded in-memory gateway in `admin_routes.dart` so the kDemoMode
/// walkthrough works without a backend.
MembersAdminGateway? _resolveMembersAdminGateway(
  FirebaseAuthClient? authClient,
) {
  if (_kAdminDemoAuth) return null;
  final liveAuthClient = _requireLiveAuthClient(authClient);
  final rawBaseUri = _kAdminProxyBaseUri.trim();
  if (rawBaseUri.isEmpty) return null;
  final baseUri = Uri.parse(rawBaseUri);
  if (!baseUri.hasScheme || !baseUri.hasAuthority) return null;
  return HttpMembersAdminGateway(
    baseUri: baseUri,
    bearerTokenProvider: () => _firebaseIdTokenProvider(liveAuthClient),
  );
}

/// Phase 11A.13 - Roles + Hierarchy + Sessions admin gateway. Lives
/// on the same admin proxy base URI as the other admin surfaces; demo
/// mode falls back to the seeded in-memory gateway in
/// `admin_routes.dart`.
RolesHierarchySessionsAdminGateway? _resolveRolesHierarchySessionsAdminGateway(
  FirebaseAuthClient? authClient,
) {
  if (_kAdminDemoAuth) return null;
  final liveAuthClient = _requireLiveAuthClient(authClient);
  final rawBaseUri = _kAdminProxyBaseUri.trim();
  if (rawBaseUri.isEmpty) return null;
  final baseUri = Uri.parse(rawBaseUri);
  if (!baseUri.hasScheme || !baseUri.hasAuthority) return null;
  return HttpRolesHierarchySessionsAdminGateway(
    baseUri: baseUri,
    bearerTokenProvider: () => _firebaseIdTokenProvider(liveAuthClient),
  );
}

/// Phase 11A.14 - Audited support actions admin gateway. Lives on
/// the same admin proxy base URI as the other admin surfaces; demo
/// mode falls back to the seeded in-memory gateway in
/// `admin_routes.dart`.
AuditedSupportActionsAdminGateway? _resolveAuditedSupportActionsAdminGateway(
  FirebaseAuthClient? authClient,
) {
  if (_kAdminDemoAuth) return null;
  final liveAuthClient = _requireLiveAuthClient(authClient);
  final rawBaseUri = _kAdminProxyBaseUri.trim();
  if (rawBaseUri.isEmpty) return null;
  final baseUri = Uri.parse(rawBaseUri);
  if (!baseUri.hasScheme || !baseUri.hasAuthority) return null;
  return HttpAuditedSupportActionsAdminGateway(
    baseUri: baseUri,
    bearerTokenProvider: () => _firebaseIdTokenProvider(liveAuthClient),
  );
}

FirebaseAuthClient _requireLiveAuthClient(FirebaseAuthClient? authClient) {
  if (authClient == null) {
    throw StateError('live admin auth client is required outside demo mode');
  }
  return authClient;
}

Future<String> _firebaseIdTokenProvider(FirebaseAuthClient authClient) async {
  final token = await authClient.currentIdToken();
  if (token == null || token.isEmpty) {
    throw StateError('Firebase did not return an ID token for the admin user');
  }
  return token;
}

class _AdminAuthInitFailedApp extends StatelessWidget {
  const _AdminAuthInitFailedApp({required this.error, required this.stack});

  final Object error;
  final StackTrace stack;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Forge & Flow - Operations Console',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeData,
      home: Scaffold(
        backgroundColor: AppColors.backgroundDeep,
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.backgroundSurface,
                    border: Border.all(color: AppColors.borderSubtle, width: 1),
                  ),
                  padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Admin live wiring failed',
                        style: AppTextStyles.mono15(
                          color: AppColors.textPrimary,
                          weight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Admin console live wiring could not initialize. '
                        'The admin console fails closed by design - '
                        'fix `kAdminFirebaseOptions` / '
                        '`web/firebase-config.js` (project id / api key '
                        '/ auth domain), set `ADMIN_PROXY_BASE_URI`, '
                        'or relaunch with '
                        '`--dart-define=ADMIN_DEMO_AUTH=true` for the '
                        'fixture-login walkthrough.',
                        style: AppTextStyles.body13(
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '$error',
                        style: AppTextStyles.mono10(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
