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
//
//   * Share preview (opt-in only). `--dart-define=ADMIN_SHARE_PREVIEW=true`
//     starts signed in as read-only F&F support against seeded fixture
//     data. No Firebase, no proxy, no live staging data, and no login
//     screen are exposed.
//
//   G5 fail-closed guard: in a non-debug (release/profile) build, demo
//   or share-preview auth is REFUSED at runtime unless the explicit,
//   default-false `--dart-define=ADMIN_ALLOW_PUBLIC_FIXTURE_AUTH=true`
//   opt-in is also passed. This is real runtime code (not an `assert`,
//   which is stripped in release), so a forgotten fixture flag can
//   never publish bypass auth on a public `--allow-unauthenticated`
//   Cloud Run service. Debug-mode local dev is unaffected.

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'admin/admin_app.dart';
import 'admin/admin_auth_gate.dart';
import 'admin/admin_routes.dart';
import 'admin/services/admin_account_gateway.dart';
import 'admin/services/admin_audit_chain_anchors_gateway.dart';
import 'admin/services/admin_business_timing_profiles_gateway.dart';
import 'admin/services/admin_business_timing_resolution_gateway.dart';
import 'admin/services/admin_http_timeout.dart';
import 'admin/services/admin_notification_preferences_gateway.dart';
import 'admin/services/admin_permission_snapshot_loader.dart';
import 'admin/services/admin_security_gateway.dart';
import 'admin/services/admin_sessions_gateway.dart';
import 'admin/services/admin_vendor_connections_gateway.dart';
import 'admin/services/corpus_admin_gateway.dart';
import 'admin/services/data_accuracy_admin_gateway.dart';
import 'admin/services/debug_console_admin_gateway.dart';
import 'admin/services/default_role_catalog_admin_gateway.dart';
import 'admin/services/demo_vendor_connections_admin_gateway.dart';
import 'admin/services/feature_flags_admin_gateway.dart';
import 'admin/services/health_admin_gateway.dart';
import 'admin/services/integration_admin_gateway.dart';
import 'admin/services/members_admin_gateway.dart';
import 'admin/services/observability_admin_gateway.dart';
import 'admin/services/operator_location_admin_gateway.dart';
import 'admin/services/pricing_tier_admin_gateway.dart';
import 'admin/services/audited_support_actions_admin_gateway.dart';
import 'admin/services/roles_hierarchy_sessions_admin_gateway.dart';
import 'admin/services/vendor_applicability_admin_gateway.dart';
import 'integrations/ui/vendor_connections/vendor_connections_gateway.dart';
import 'services/auth/firebase_auth_client.dart';
import 'services/auth/firebase_auth_client_sdk.dart';
import 'services/auth/timeout_firebase_auth_client.dart';
import 'theme/app_theme.dart';

/// Opt-in demo switch. **Must default to false** so a forgotten flag
/// can never publish demo auth on a public Cloud Run service.
const bool _kAdminDemoAuth = bool.fromEnvironment('ADMIN_DEMO_AUTH');

/// Public share-preview switch. This is deliberately separate from
/// [ADMIN_DEMO_AUTH]: demo auth can still show a fixture sign-in
/// card, while share preview opens directly into read-only fixture
/// data for emailed review links.
const bool _kAdminSharePreview = bool.fromEnvironment('ADMIN_SHARE_PREVIEW');

/// G5 (cross-surface parity audit) — the ONLY compile-time opt-in that
/// permits fixture/demo/share-preview auth to run in a non-debug
/// (release/profile) build. **Must default to false.** Its name is
/// deliberately alarming: turning it on means a publicly-routed
/// `--allow-unauthenticated` Cloud Run build could serve a full-write
/// fixture super_admin with no Firebase in the loop.
///
/// Why a separate flag (not a relaxation of [ADMIN_DEMO_AUTH] /
/// [ADMIN_SHARE_PREVIEW]): those two are routinely set by local dev
/// scripts and the emailed-review-link deploy, so a release build that
/// merely carries one of them must still fail closed. Only an explicit,
/// unmistakable `--dart-define=ADMIN_ALLOW_PUBLIC_FIXTURE_AUTH=true`
/// (combined with one of the fixture flags) lets fixture auth survive
/// the release-mode guard in [main]. `kDebugMode` local dev never needs
/// this flag — it is unaffected by the guard.
const bool _kAdminAllowPublicFixtureAuth = bool.fromEnvironment(
  'ADMIN_ALLOW_PUBLIC_FIXTURE_AUTH',
);

/// Share-preview role selector. When [ADMIN_SHARE_PREVIEW] is true, this
/// switch picks the fixture identity that's auto-signed-in:
///
///   * `false` (default) -> [DemoAdminAuthSource.signedInAsSupport]
///     (`support@forgeflow.test`, `ff_support` role, read-only). This is
///     the historical share-preview behavior used by the public emailed
///     review link deploy (`scripts/deploy_admin_console.ps1
///     -SharePreview`).
///   * `true` -> [DemoAdminAuthSource.signedInAsSuperAdmin]
///     (`demo.super.admin@forgeflow.test`, `super_admin` role, full
///     write access). Used by `scripts/run_admin_console_dev.ps1 -Mode
///     demo` so a local walkthrough exercises every admin surface
///     including the writes that read-only support cannot reach.
const bool _kAdminSharePreviewAsSuperAdmin = bool.fromEnvironment(
  'ADMIN_SHARE_PREVIEW_AS_SUPER_ADMIN',
);

/// Admin proxy base URL. `--dart-define=ADMIN_PROXY_BASE_URI=...`
/// points the live HTTP gateway at the F&F admin Cloud Run proxy
/// (e.g. `https://admin-proxy.forgeflow.app`). Live mode requires
/// this value and fails closed when it is missing; only demo mode may
/// fall back to the in-memory walkthrough gateway.
const String _kAdminProxyBaseUri = String.fromEnvironment(
  'ADMIN_PROXY_BASE_URI',
);

/// G5 (cross-surface parity audit) — message shown on the calm
/// `_AdminAuthInitFailedApp` surface when the release-mode fixture-auth
/// guard fires. Surfaced as a constant so a focused test can assert the
/// exact copy without reaching into widget internals.
@visibleForTesting
const String kAdminFixtureAuthBlockedMessage =
    'Fixture/demo/share-preview admin auth is blocked in a non-debug '
    'build. ADMIN_DEMO_AUTH / ADMIN_SHARE_PREVIEW were set, but '
    'ADMIN_ALLOW_PUBLIC_FIXTURE_AUTH was not. Fixture auth bypasses '
    'Firebase and must never ship on a public endpoint. If this is an '
    'intentional internal preview, rebuild with '
    '--dart-define=ADMIN_ALLOW_PUBLIC_FIXTURE_AUTH=true; otherwise drop '
    'the fixture flags and ship live Firebase auth.';

/// G5 (cross-surface parity audit) — pure decision for the real
/// runtime, release-mode fail-closed guard in [main].
///
/// Returns `true` when the app MUST refuse to wire auth and instead
/// land on the calm `_AdminAuthInitFailedApp` surface. The rule:
///
///   * Debug builds ([isDebugMode] true) are never blocked — local dev
///     and `flutter test` keep working.
///   * In a non-debug (release/profile) build, if any fixture flag
///     ([adminDemoAuth] or [adminSharePreview]) is set, the build is
///     blocked UNLESS the explicit, default-false
///     [adminAllowPublicFixtureAuth] opt-in is also set.
///   * The normal live path (no fixture flags) is never blocked, in
///     debug or release.
///
/// Extracted as a pure, parameterized, `@visibleForTesting` function so
/// the four-way matrix (debug, release+fixture, release+fixture+opt-in,
/// release+live) is testable without flipping `bool.fromEnvironment`
/// compile-time constants. [main] calls it with the real constants.
@visibleForTesting
bool adminFixtureAuthBlockedInRelease({
  required bool isDebugMode,
  required bool adminDemoAuth,
  required bool adminSharePreview,
  required bool adminAllowPublicFixtureAuth,
}) {
  if (isDebugMode) return false;
  final bool fixtureAuthRequested = adminDemoAuth || adminSharePreview;
  if (!fixtureAuthRequested) return false;
  return !adminAllowPublicFixtureAuth;
}

/// Firebase web options for the admin console project.
///
/// Defaults mirror `web/firebase-config.js` (staging); production deploys
/// override these with dart-defines generated from
/// `web/firebase-config.production1.js`. FlutterFire Web does not read those
/// files automatically; the default app must be created with explicit
/// [FirebaseOptions] unless a JavaScript bootstrap has already initialized it.
@visibleForTesting
const FirebaseOptions kAdminFirebaseOptions = FirebaseOptions(
  apiKey: String.fromEnvironment(
    'FIREBASE_WEB_API_KEY',
    defaultValue: 'AIzaSyBeTA2ye7U1gsrwZyGcMVDOAfo7Seh2oqM',
  ),
  appId: String.fromEnvironment(
    'FIREBASE_WEB_APP_ID',
    defaultValue: '1:78630909582:web:d716c986475899f13a7bdf',
  ),
  messagingSenderId: String.fromEnvironment(
    'FIREBASE_MESSAGING_SENDER_ID',
    defaultValue: '78630909582',
  ),
  projectId: String.fromEnvironment(
    'FIREBASE_PROJECT_ID',
    defaultValue: 'forge-flow-staging',
  ),
  authDomain: String.fromEnvironment(
    'FIREBASE_AUTH_DOMAIN',
    defaultValue: 'forge-flow-staging.firebaseapp.com',
  ),
  storageBucket: String.fromEnvironment(
    'FIREBASE_STORAGE_BUCKET',
    defaultValue: 'forge-flow-staging.firebasestorage.app',
  ),
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
    if (!kDebugMode && _kAdminDemoAuth && !_kAdminSharePreview) {
      throw StateError(
        'ADMIN_DEMO_AUTH must not be true in a non-debug build. '
        'Demo auth bypasses Firebase and must never ship on a public endpoint.',
      );
    }
    return true;
  }());
  WidgetsFlutterBinding.ensureInitialized();
  // G5 (cross-surface parity audit) — REAL runtime, release-mode
  // fail-closed guard. Unlike the `assert` above (compiled out in
  // release, so it is dead code on the exact builds we worry about),
  // this branch executes in release/profile. If a non-debug build
  // carries any fixture/demo/share-preview auth flag WITHOUT the
  // explicit, unmistakable `ADMIN_ALLOW_PUBLIC_FIXTURE_AUTH` opt-in,
  // the app refuses to wire auth and lands on the calm
  // `_AdminAuthInitFailedApp` surface instead of proceeding into the
  // console as a fixture super_admin. `kDebugMode` local dev and
  // intentional internal preview keep working — debug is exempt, and a
  // deliberate preview deploy passes the opt-in. The default-false
  // opt-in means a forgotten flag can never publish fixture auth on a
  // public `--allow-unauthenticated` Cloud Run service.
  if (adminFixtureAuthBlockedInRelease(
    isDebugMode: kDebugMode,
    adminDemoAuth: _kAdminDemoAuth,
    adminSharePreview: _kAdminSharePreview,
    adminAllowPublicFixtureAuth: _kAdminAllowPublicFixtureAuth,
  )) {
    runApp(
      _AdminAuthInitFailedApp(
        error: StateError(kAdminFixtureAuthBlockedMessage),
        stack: StackTrace.current,
      ),
    );
    return;
  }
  try {
    final authBinding = await _resolveAuthSource();
    final source = authBinding.source;
    // G71 (cross-surface parity §0b) — admin parallel of the
    // mobile/op-web G61 "401 → force-refresh-ID-token → retry-once"
    // recovery. Register the live Firebase auth client's force-refresh
    // as the process-wide hook so a clock-skewed / mid-rotation bearer
    // no longer hard-fails destructive admin actions; every admin
    // gateway funnels through `sendAdminHttpRequest`, which consumes
    // this hook. Gated on a non-null live auth client EXACTLY like the
    // sibling `_resolve*Gateway` resolvers — demo / share-preview leave
    // it unset so the first 401 throws as before (no behaviour change
    // off the 401-recovery path). Mirrors the existing process-global
    // `AdminHttpFreshnessRedirectDispatcher` wiring shape.
    final liveAuthClient = authBinding.authClient;
    if (liveAuthClient != null) {
      AdminHttpTokenRefreshDispatcher.refreshIdToken = () async {
        final credential = await liveAuthClient.refreshIdToken();
        if (credential == null) return null;
        return liveAuthClient.currentIdToken();
      };
    }
    final gateway = _resolveOperatorLocationGateway(authBinding.authClient);
    final pricingGateway = gateway == null
        ? null
        : _resolvePricingTierAdminGateway(authBinding.authClient);
    final dataAccuracyGateway = gateway == null
        ? null
        : _resolveDataAccuracyAdminGateway(authBinding.authClient);
    final vendorApplicabilityGateway = gateway == null
        ? null
        : _resolveVendorApplicabilityAdminGateway(authBinding.authClient);
    final corpusGateway = gateway == null
        ? null
        : _resolveCorpusAdminGateway(authBinding.authClient);
    final integrationGateway = gateway == null
        ? null
        : _resolveIntegrationAdminGateway(authBinding.authClient);
    final vendorConnectionsGateway = _resolveVendorConnectionsGateway(
      authBinding.authClient,
    );
    final healthGateway = gateway == null ? null : _resolveHealthAdminGateway();
    final observabilityGateway = gateway == null
        ? null
        : _resolveObservabilityAdminGateway(authBinding.authClient);
    final featureFlagsGateway = gateway == null
        ? null
        : _resolveFeatureFlagsAdminGateway(authBinding.authClient);
    final defaultRoleCatalogAdminGateway = gateway == null
        ? null
        : _resolveDefaultRoleCatalogAdminGateway(authBinding.authClient);
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
    // G4 — admin self-service Security gateway (own MFA enroll/confirm
    // /recover + password change). Same admin proxy base URI + Firebase
    // ID-token bearer the sibling admin gateways use; demo / share-
    // preview leave it null so `admin_routes.dart` falls back to the
    // seeded in-memory gateway and the walkthrough renders backendless.
    final adminSecurityGateway = gateway == null
        ? null
        : _resolveAdminSecurityGateway(authBinding.authClient);
    // Wave 2 W-3 / G70 — admin "My Account" self-service identity-edit
    // gateway. Same admin proxy base URI + Firebase ID-token bearer the
    // sibling admin gateways use; demo / share-preview leave it null so
    // `admin_routes.dart` keeps `adminAccountGatewayOf` null and the
    // edit-identity affordance stays disabled (byte-equivalent today).
    final adminAccountGateway = gateway == null
        ? null
        : _resolveAdminAccountGateway(authBinding.authClient);
    // X-G71 — admin self-service notification-preferences gateway.
    // Same admin proxy base URI + Firebase ID-token bearer the sibling
    // admin gateways use; demo / share-preview leave it null so
    // `admin_routes.dart` falls back to the seeded in-memory gateway.
    final adminNotificationPreferencesGateway = gateway == null
        ? null
        : _resolveAdminNotificationPreferencesGateway(authBinding.authClient);
    // HP#11 S2/S4 — admin cross-tenant business-timing-resolution
    // gateway. Same admin proxy base URI + Firebase ID-token bearer the
    // sibling admin gateways use; demo / share-preview leave it null so
    // `admin_routes.dart` falls back to the seeded in-memory gateway and
    // the S4 Timing screens render the honest "no profile yet" state.
    final adminBusinessTimingResolutionGateway = gateway == null
        ? null
        : _resolveAdminBusinessTimingResolutionGateway(authBinding.authClient);
    // Timing-editable parity — admin cross-tenant business-timing
    // PROFILE WRITE gateway (create / patch). Same admin proxy base URI
    // + Firebase ID-token bearer the resolution sibling uses; demo /
    // share-preview leave it null so `admin_routes.dart` falls back to
    // the seeded in-memory gateway and the editor renders backendless.
    final adminBusinessTimingProfilesGateway = gateway == null
        ? null
        : _resolveAdminBusinessTimingProfilesGateway(authBinding.authClient);
    // Admin audit-integrity badge — admin cross-tenant
    // audit-chain-anchor read gateway. Same admin proxy base URI +
    // Firebase ID-token bearer the resolution sibling uses; demo /
    // share-preview leave it null so `admin_routes.dart` passes null to
    // the audit screen and the integrity badge renders the neutral
    // "unknown" state (never crashes).
    final adminAuditChainAnchorsGateway = gateway == null
        ? null
        : _resolveAdminAuditChainAnchorsGateway(authBinding.authClient);
    final adminApp = AdminConsoleApp(
      authSource: source,
      sharePreviewMode: _kAdminSharePreview,
    );
    // Always wrap with `AdminConsoleServicesScope` so the Pricing /
    // Corpus / Integrations / Feature Flags routes can read
    // `adminAuthSource` and switch to the read-only branch for
    // `ff_support`. Most live gateways are still null in demo mode; the
    // route accessors fall back to seeded in-memory demo gateways in
    // `admin_routes.dart`. Vendor connections is passed a seeded demo
    // gateway directly so it can render the full shared widget.
    runApp(
      AdminConsoleServicesScope(
        operatorLocationGateway: gateway,
        pricingTierGateway: pricingGateway,
        dataAccuracyAdminGateway: dataAccuracyGateway,
        vendorApplicabilityGateway: vendorApplicabilityGateway,
        corpusAdminGateway: corpusGateway,
        integrationGateway: integrationGateway,
        vendorConnectionsGateway: vendorConnectionsGateway,
        healthGateway: healthGateway,
        observabilityGateway: observabilityGateway,
        featureFlagsGateway: featureFlagsGateway,
        defaultRoleCatalogAdminGateway: defaultRoleCatalogAdminGateway,
        debugConsoleGateway: debugConsoleGateway,
        membersAdminGateway: membersAdminGateway,
        rolesHierarchySessionsAdminGateway: rolesHierarchySessionsAdminGateway,
        auditedSupportActionsAdminGateway: auditedSupportActionsAdminGateway,
        adminSessionsGateway: authBinding.sessionsGateway,
        adminSecurityGateway: adminSecurityGateway,
        adminAccountGateway: adminAccountGateway,
        adminNotificationPreferencesGateway:
            adminNotificationPreferencesGateway,
        timingResolutionGateway: adminBusinessTimingResolutionGateway,
        timingProfilesGateway: adminBusinessTimingProfilesGateway,
        auditChainAnchorsGateway: adminAuditChainAnchorsGateway,
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
  const _AdminAuthBinding({
    required this.source,
    required this.authClient,
    this.sessionsGateway,
  });

  final AdminAuthSource source;
  final FirebaseAuthClient? authClient;

  /// G2 (audit fix-first #2) — live admin Active Sessions gateway.
  /// Non-null only in the live branch; null in demo / share-preview so
  /// `admin_routes.dart` falls back to the seeded in-memory gateway.
  /// Built inside `_resolveAuthSource` so the SAME instance is wired
  /// both into [FirebaseAdminAuthSource] (G1 ledger writer) and into
  /// `AdminConsoleServicesScope` (G2 surface).
  final AdminSessionsGateway? sessionsGateway;
}

Future<_AdminAuthBinding> _resolveAuthSource() async {
  if (_kAdminSharePreview) {
    final demoSource = _kAdminSharePreviewAsSuperAdmin
        ? DemoAdminAuthSource.signedInAsSuperAdmin()
        : DemoAdminAuthSource.signedInAsSupport();
    return _AdminAuthBinding(source: demoSource, authClient: null);
  }
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
  // G1 + G2 — build the live admin sessions gateway against the same
  // admin proxy base URI + Firebase ID-token bearer the sibling admin
  // gateways use, then wire the SAME instance into the auth source
  // (ledger writer on sign-in/out) and the services scope (Active
  // Sessions surface). Fail-closed: outside demo/share-preview the
  // base URI is required, mirroring the other `_resolve*` resolvers.
  final sessionsGateway = _buildAdminSessionsGateway(authClient);
  // UX-parity Slice E0 — best-effort permission-snapshot loader on the
  // same admin proxy base URI + Firebase ID-token bearer. Wired into
  // the auth source so a live admin session hydrates
  // `AdminAuthSession.permissions`. Fail-safe: the loader returns an
  // empty set (never throws) on any error, so sign-in is never blocked
  // and the key-first editing gates fall back to the role check.
  final permissionSnapshotLoader = _buildAdminPermissionSnapshotLoader(
    authClient,
  );
  return _AdminAuthBinding(
    source: FirebaseAdminAuthSource(
      client: authClient,
      sessionLedger: sessionsGateway,
      permissionSnapshotLoader: permissionSnapshotLoader,
    ),
    authClient: authClient,
    sessionsGateway: sessionsGateway,
  );
}

/// G1 + G2 — admin auth-session ledger + Active Sessions gateway.
/// Lives on the same admin proxy base URI as the other admin surfaces
/// with the Firebase ID-token bearer provider already used by the
/// other `_resolve*` resolvers. Demo / share-preview return null so
/// the auth source is a no-op writer and `admin_routes.dart` falls
/// back to the seeded in-memory gateway.
AdminSessionsGateway? _buildAdminSessionsGateway(
  FirebaseAuthClient? authClient,
) {
  if (_kAdminDemoAuth || _kAdminSharePreview) return null;
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
  return HttpAdminSessionsGateway(
    baseUri: baseUri,
    bearerTokenProvider: () => _firebaseIdTokenProvider(liveAuthClient),
  );
}

/// UX-parity Slice E0 — best-effort permission-snapshot loader.
/// Lives on the same admin proxy base URI + Firebase ID-token bearer
/// the sibling admin gateways use. Demo / share-preview return null so
/// the auth source skips hydration entirely (`permissions` stays empty
/// → role fallback). Unlike the other `_build*`/`_resolve*` helpers
/// this is NEVER fail-closed: a missing / malformed base URI returns
/// null (skip hydration) rather than throwing, because the snapshot is
/// an additive affordance and must never block sign-in. The bearer
/// provider returns null on any token error so the loader resolves to
/// an empty set (fail-safe) instead of throwing.
AdminPermissionSnapshotLoader? _buildAdminPermissionSnapshotLoader(
  FirebaseAuthClient? authClient,
) {
  if (_kAdminDemoAuth || _kAdminSharePreview) return null;
  if (authClient == null) return null;
  final rawBaseUri = _kAdminProxyBaseUri.trim();
  if (rawBaseUri.isEmpty) return null;
  final baseUri = Uri.parse(rawBaseUri);
  if (!baseUri.hasScheme || !baseUri.hasAuthority) return null;
  return HttpAdminPermissionSnapshotLoader(
    baseUri: baseUri,
    bearerTokenProvider: () async {
      try {
        return await authClient.currentIdToken();
      } catch (_) {
        // Fail-safe: a token error resolves to "no hydration" rather
        // than blocking sign-in. Role fallback.
        return null;
      }
    },
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
  if (_kAdminDemoAuth || _kAdminSharePreview) return null;
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
  if (_kAdminDemoAuth || _kAdminSharePreview) return null;
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
  if (_kAdminDemoAuth || _kAdminSharePreview) return null;
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
VendorApplicabilityAdminGateway? _resolveVendorApplicabilityAdminGateway(
  FirebaseAuthClient? authClient,
) {
  if (_kAdminDemoAuth || _kAdminSharePreview) return null;
  final liveAuthClient = _requireLiveAuthClient(authClient);
  final rawBaseUri = _kAdminProxyBaseUri.trim();
  if (rawBaseUri.isEmpty) return null;
  final baseUri = Uri.parse(rawBaseUri);
  if (!baseUri.hasScheme || !baseUri.hasAuthority) return null;
  return HttpVendorApplicabilityAdminGateway(
    baseUri: baseUri,
    bearerTokenProvider: () => _firebaseIdTokenProvider(liveAuthClient),
  );
}

CorpusAdminGateway? _resolveCorpusAdminGateway(FirebaseAuthClient? authClient) {
  if (_kAdminDemoAuth || _kAdminSharePreview) return null;
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
  if (_kAdminDemoAuth || _kAdminSharePreview) return null;
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

/// Slice 9 - per-location vendor connections admin gateway. Demo and
/// share-preview builds get the seeded Admin fixture so the walkthrough
/// renders the same mixed vendor-state story as Operator Web / Mobile.
/// Live mode still returns null when `ADMIN_PROXY_BASE_URI` is missing,
/// so production wiring failures stay loud on the route.
VendorConnectionsGateway? _resolveVendorConnectionsGateway(
  FirebaseAuthClient? authClient,
) {
  if (_kAdminDemoAuth || _kAdminSharePreview) {
    return AdminDemoVendorConnectionsFixture.gateway();
  }
  final liveAuthClient = _requireLiveAuthClient(authClient);
  final rawBaseUri = _kAdminProxyBaseUri.trim();
  if (rawBaseUri.isEmpty) return null;
  final baseUri = Uri.parse(rawBaseUri);
  if (!baseUri.hasScheme || !baseUri.hasAuthority) return null;
  return AdminHttpVendorConnectionsGateway(
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
  if (_kAdminDemoAuth || _kAdminSharePreview) return null;
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
  if (_kAdminDemoAuth || _kAdminSharePreview) return null;
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
  if (_kAdminDemoAuth || _kAdminSharePreview) return null;
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

/// Lane B B2.2 — Default Role catalog admin gateway. The publish
/// route requires an `Idempotency-Key` header; the resolver builds a
/// monotonically-increasing UTC microsecond + counter string. Demo
/// mode falls back to the seeded in-memory gateway in
/// `admin_routes.dart`.
int _defaultRoleCatalogIdempotencyCounter = 0;
String _mintDefaultRoleCatalogIdempotencyKey() {
  _defaultRoleCatalogIdempotencyCounter += 1;
  final micros = DateTime.now().toUtc().microsecondsSinceEpoch;
  return 'admin-default-role-catalog-$micros-'
      '$_defaultRoleCatalogIdempotencyCounter';
}

DefaultRoleCatalogAdminGateway? _resolveDefaultRoleCatalogAdminGateway(
  FirebaseAuthClient? authClient,
) {
  if (_kAdminDemoAuth || _kAdminSharePreview) return null;
  final liveAuthClient = _requireLiveAuthClient(authClient);
  final rawBaseUri = _kAdminProxyBaseUri.trim();
  if (rawBaseUri.isEmpty) return null;
  final baseUri = Uri.parse(rawBaseUri);
  if (!baseUri.hasScheme || !baseUri.hasAuthority) return null;
  return HttpDefaultRoleCatalogAdminGateway(
    baseUri: baseUri,
    bearerTokenProvider: () => _firebaseIdTokenProvider(liveAuthClient),
    idempotencyKeyProvider: _mintDefaultRoleCatalogIdempotencyKey,
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
  if (_kAdminDemoAuth || _kAdminSharePreview) return null;
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
  if (_kAdminDemoAuth || _kAdminSharePreview) return null;
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
  if (_kAdminDemoAuth || _kAdminSharePreview) return null;
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
  if (_kAdminDemoAuth || _kAdminSharePreview) return null;
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

/// G4 (cross-surface parity finding) — admin self-service Security
/// gateway. Lives on the SAME admin proxy base URI as the other admin
/// surfaces with the Firebase ID-token bearer the sibling `_resolve*`
/// resolvers use; demo / share-preview return null so
/// `admin_routes.dart` falls back to the seeded in-memory gateway.
/// Mirrors `_resolveMembersAdminGateway` exactly.
AdminSecurityGateway? _resolveAdminSecurityGateway(
  FirebaseAuthClient? authClient,
) {
  if (_kAdminDemoAuth || _kAdminSharePreview) return null;
  final liveAuthClient = _requireLiveAuthClient(authClient);
  final rawBaseUri = _kAdminProxyBaseUri.trim();
  if (rawBaseUri.isEmpty) return null;
  final baseUri = Uri.parse(rawBaseUri);
  if (!baseUri.hasScheme || !baseUri.hasAuthority) return null;
  return HttpAdminSecurityGateway(
    baseUri: baseUri,
    bearerTokenProvider: () => _firebaseIdTokenProvider(liveAuthClient),
  );
}

/// Wave 2 W-3 / G70 — admin "My Account" self-service identity-edit
/// gateway. Lives on the SAME admin proxy base URI as the other admin
/// surfaces with the Firebase ID-token bearer the sibling `_resolve*`
/// resolvers use; demo / share-preview return null so
/// `admin_routes.dart` leaves `adminAccountGatewayOf` null and
/// `my_account_admin_screen.dart` keeps the edit-identity affordance
/// disabled (byte-equivalent to today). Mirrors
/// `_resolveAdminNotificationPreferencesGateway` exactly. The proxy
/// resolves the actor from the verified bearer token, so this calls
/// the SAME existing `PATCH /v1/auth/self/profile` route the
/// operator-web side uses (no new backend route). Wiring this binding
/// is the only missing hop that makes G70's caller-stable
/// idempotency key actually run on the live PATCH.
AdminAccountGateway? _resolveAdminAccountGateway(
  FirebaseAuthClient? authClient,
) {
  if (_kAdminDemoAuth || _kAdminSharePreview) return null;
  final liveAuthClient = _requireLiveAuthClient(authClient);
  final rawBaseUri = _kAdminProxyBaseUri.trim();
  if (rawBaseUri.isEmpty) return null;
  final baseUri = Uri.parse(rawBaseUri);
  if (!baseUri.hasScheme || !baseUri.hasAuthority) return null;
  return HttpAdminAccountGateway(
    baseUri: baseUri,
    bearerTokenProvider: () => _firebaseIdTokenProvider(liveAuthClient),
  );
}

/// X-G71 (cross-surface parity register §0b) — admin self-service
/// notification-preferences gateway. Lives on the SAME admin proxy
/// base URI as the other admin surfaces with the Firebase ID-token
/// bearer the sibling `_resolve*` resolvers use; demo / share-preview
/// return null so `admin_routes.dart` falls back to the seeded
/// in-memory gateway and the walkthrough renders backendless. Mirrors
/// `_resolveAdminSecurityGateway` exactly. The proxy resolves the
/// actor from the verified bearer token, so this calls the SAME
/// existing `/v1/operator/notification-preferences` route the
/// operator-web side uses (no new backend route).
AdminNotificationPreferencesGateway?
_resolveAdminNotificationPreferencesGateway(FirebaseAuthClient? authClient) {
  if (_kAdminDemoAuth || _kAdminSharePreview) return null;
  final liveAuthClient = _requireLiveAuthClient(authClient);
  final rawBaseUri = _kAdminProxyBaseUri.trim();
  if (rawBaseUri.isEmpty) return null;
  final baseUri = Uri.parse(rawBaseUri);
  if (!baseUri.hasScheme || !baseUri.hasAuthority) return null;
  return HttpAdminNotificationPreferencesGateway(
    baseUri: baseUri,
    bearerTokenProvider: () => _firebaseIdTokenProvider(liveAuthClient),
  );
}

/// HP#11 S2/S4 — admin cross-tenant business-timing-resolution gateway.
/// Lives on the SAME admin proxy base URI as the other admin surfaces
/// with the Firebase ID-token bearer the sibling `_resolve*` resolvers
/// use; demo / share-preview return null so `admin_routes.dart` falls
/// back to the seeded in-memory gateway and the walkthrough renders
/// backendless. Mirrors `_resolveAdminNotificationPreferencesGateway`
/// exactly. The proxy resolves the actor from the verified bearer
/// token, so this calls the merged, operator-approved S2 cross-tenant
/// route `/v1/admin/operators/<op>/locations/<loc>/business-timing-resolution`
/// (no new backend route).
AdminBusinessTimingResolutionGateway?
_resolveAdminBusinessTimingResolutionGateway(FirebaseAuthClient? authClient) {
  if (_kAdminDemoAuth || _kAdminSharePreview) return null;
  final liveAuthClient = _requireLiveAuthClient(authClient);
  final rawBaseUri = _kAdminProxyBaseUri.trim();
  if (rawBaseUri.isEmpty) return null;
  final baseUri = Uri.parse(rawBaseUri);
  if (!baseUri.hasScheme || !baseUri.hasAuthority) return null;
  return HttpAdminBusinessTimingResolutionGateway(
    baseUri: baseUri,
    bearerTokenProvider: () => _firebaseIdTokenProvider(liveAuthClient),
  );
}

/// Timing-editable parity — admin cross-tenant business-timing PROFILE
/// WRITE gateway (create / patch). Lives on the SAME admin proxy base
/// URI as the other admin surfaces with the Firebase ID-token bearer the
/// sibling `_resolve*` resolvers use; demo / share-preview return null so
/// `admin_routes.dart` falls back to the seeded in-memory gateway and the
/// Timing editor renders backendless. Byte-mirrors
/// `_resolveAdminBusinessTimingResolutionGateway`. The proxy resolves the
/// actor from the verified bearer token, so this calls the
/// operator-approved admin cross-tenant routes
/// `/v1/admin/operators/<op>/business-timing-profiles[/<id>]` (writes
/// require `admin_reason` + an idempotency key, both enforced server-side).
AdminBusinessTimingProfilesGateway? _resolveAdminBusinessTimingProfilesGateway(
  FirebaseAuthClient? authClient,
) {
  if (_kAdminDemoAuth || _kAdminSharePreview) return null;
  final liveAuthClient = _requireLiveAuthClient(authClient);
  final rawBaseUri = _kAdminProxyBaseUri.trim();
  if (rawBaseUri.isEmpty) return null;
  final baseUri = Uri.parse(rawBaseUri);
  if (!baseUri.hasScheme || !baseUri.hasAuthority) return null;
  return HttpAdminBusinessTimingProfilesGateway(
    baseUri: baseUri,
    bearerTokenProvider: () => _firebaseIdTokenProvider(liveAuthClient),
  );
}

/// Admin audit-integrity badge — admin cross-tenant audit-chain-anchor
/// READ gateway. Lives on the SAME admin proxy base URI as the other
/// admin surfaces with the Firebase ID-token bearer the sibling
/// `_resolve*` resolvers use; demo / share-preview return null so
/// `admin_routes.dart` passes null to the audit screen and the
/// integrity badge renders the neutral "unknown" state. Byte-mirrors
/// `_resolveAdminBusinessTimingResolutionGateway`. The proxy resolves
/// the actor from the verified bearer token and gates the route to
/// super_admin / ff_support, then reads ANOTHER tenant's anchor row
/// through the sanctioned `runAsSystem` admin bypass (no new backend
/// route beyond the one this slice adds).
AdminAuditChainAnchorsGateway? _resolveAdminAuditChainAnchorsGateway(
  FirebaseAuthClient? authClient,
) {
  if (_kAdminDemoAuth || _kAdminSharePreview) return null;
  final liveAuthClient = _requireLiveAuthClient(authClient);
  final rawBaseUri = _kAdminProxyBaseUri.trim();
  if (rawBaseUri.isEmpty) return null;
  final baseUri = Uri.parse(rawBaseUri);
  if (!baseUri.hasScheme || !baseUri.hasAuthority) return null;
  return HttpAdminAuditChainAnchorsGateway(
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
