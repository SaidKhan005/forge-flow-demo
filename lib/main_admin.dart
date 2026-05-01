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

import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'admin/admin_app.dart';
import 'admin/admin_auth_gate.dart';
import 'admin/admin_routes.dart';
import 'admin/services/corpus_admin_gateway.dart';
import 'admin/services/operator_location_admin_gateway.dart';
import 'admin/services/pricing_tier_admin_gateway.dart';
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
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final source = await _resolveAuthSource();
    final gateway = _resolveOperatorLocationGateway();
    final pricingGateway =
        gateway == null ? null : _resolvePricingTierAdminGateway();
    final corpusGateway =
        gateway == null ? null : _resolveCorpusAdminGateway();
    final adminApp = AdminConsoleApp(authSource: source);
    // Always wrap with `AdminConsoleServicesScope` so the Pricing /
    // Corpus routes can read `adminAuthSource` and switch to the
    // read-only branch for `ff_support`. Live gateways are still null
    // in demo mode; the route accessors fall back to the seeded
    // in-memory demo gateways in `admin_routes.dart`.
    runApp(
      AdminConsoleServicesScope(
        operatorLocationGateway: gateway,
        pricingTierGateway: pricingGateway,
        corpusAdminGateway: corpusGateway,
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

Future<AdminAuthSource> _resolveAuthSource() async {
  if (_kAdminDemoAuth) {
    return DemoAdminAuthSource.signedOut();
  }
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(options: kAdminFirebaseOptions);
  }
  return FirebaseAdminAuthSource();
}

/// Resolves the operator/location admin gateway for the live
/// console. Production runs bind the HTTP-backed gateway with a
/// Firebase ID-token bearer source. Demo mode returns null, which
/// lets the route fall back to the seeded in-memory demo gateway in
/// `admin_routes.dart`.
OperatorLocationAdminGateway? _resolveOperatorLocationGateway() {
  if (_kAdminDemoAuth) return null;
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
    bearerTokenProvider: _firebaseIdTokenProvider,
  );
}

/// Phase 11A.2 — pricing tier admin gateway. Lives on the same admin
/// proxy base URI as the operator/location gateway. Demo mode returns
/// null and the route falls back to the seeded in-memory pricing
/// gateway in `admin_routes.dart`.
PricingTierAdminGateway? _resolvePricingTierAdminGateway() {
  if (_kAdminDemoAuth) return null;
  final rawBaseUri = _kAdminProxyBaseUri.trim();
  if (rawBaseUri.isEmpty) return null;
  final baseUri = Uri.parse(rawBaseUri);
  if (!baseUri.hasScheme || !baseUri.hasAuthority) return null;
  return HttpPricingTierAdminGateway(
    baseUri: baseUri,
    bearerTokenProvider: _firebaseIdTokenProvider,
  );
}

/// Phase 11A.3a — corpus admin gateway. Same admin proxy base URI as
/// the pricing gateway. Demo mode returns null and the route falls
/// back to the seeded in-memory corpus gateway in `admin_routes.dart`.
CorpusAdminGateway? _resolveCorpusAdminGateway() {
  if (_kAdminDemoAuth) return null;
  final rawBaseUri = _kAdminProxyBaseUri.trim();
  if (rawBaseUri.isEmpty) return null;
  final baseUri = Uri.parse(rawBaseUri);
  if (!baseUri.hasScheme || !baseUri.hasAuthority) return null;
  return HttpCorpusAdminGateway(
    baseUri: baseUri,
    bearerTokenProvider: _firebaseIdTokenProvider,
  );
}

Future<String> _firebaseIdTokenProvider() async {
  final user = fb.FirebaseAuth.instance.currentUser;
  if (user == null) {
    throw StateError(
      'admin proxy call attempted without a signed-in Firebase user',
    );
  }
  final token = await user.getIdToken();
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
