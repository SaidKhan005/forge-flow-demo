// Phase 11W - Operator Web Console entrypoint.
//
// Flutter Web entrypoint for the Operator Web Console at
// `app.forgeflow.app`. Lives on a separate Cloud Run service from the
// operator-app proxy and the F&F Operations Console (per
// `Dockerfile.operator_web` + `scripts/deploy_operator_web.ps1`).
//
// G24/G3 S3′ (operator decision 2026-05-16): the invitee onboarding
// model is the existing Firebase password-reset email. Invitees set
// their password on Firebase's hosted page, then sign in here with
// email + password. There is no magic-link / set-password /
// onboarding-MFA / ToS surface and no URL token to parse.
//
// Two run modes:
//
//   * Live (default for `flutter build web` and the deploy script).
//     Wires the live Firebase Auth web SDK (`firebase_auth_web` is in
//     `pubspec.yaml`) and a real `FirebaseOperatorWebAuthSource` that
//     calls the existing Phase 9 proxy routes for sign-in, password
//     reset, and post-login MFA.
//
//   * Demo (opt-in only). `--dart-define=OPERATOR_WEB_DEMO_AUTH=true`
//     swaps in `DemoOperatorWebAuthSource` for the slice walkthrough.
//     This is what `scripts/run_operator_web_dev.ps1` invokes for
//     local dev; the deploy script requires an explicit `-DemoMode`
//     switch with a loud warning to flip a Cloud Run deploy into
//     demo, because demo auth on a publicly-routed
//     `--allow-unauthenticated` Cloud Run service is a privilege
//     bypass.
//
// Web-only: this entrypoint must NOT import `dart:io` (transitively
// either) or `sqflite` / `sqflite_common_ffi`. The operator app
// (`lib/main_forgeflow.dart`) uses both extensively for offline
// caching; the operator-web build target re-uses brand theme + auth
// gateway only and reads/writes through the proxy via HTTPS.

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'operator_web/auth/firebase_operator_web_auth_source.dart';
import 'operator_web/auth/operator_web_auth_source.dart';
import 'operator_web/demo/operator_web_demo_scenario.dart';
import 'operator_web/operator_web_app.dart';
import 'operator_web/services/business_timing_gateway.dart';
import 'operator_web/services/business_logo_upload_gateway.dart';
import 'operator_web/services/demo_operator_web_write_gateways.dart';
import 'operator_web/services/demo_security_gateway.dart';
import 'operator_web/services/demo_team_audit_log_gateway.dart';
import 'operator_web/services/demo_team_fixtures.dart';
import 'operator_web/services/demo_team_hierarchy_gateway.dart';
import 'operator_web/services/demo_team_roles_gateway.dart';
import 'operator_web/services/demo_team_sessions_gateway.dart';
import 'operator_web/services/demo_team_users_gateway.dart';
import 'operator_web/services/http_business_timing_read_gateway.dart';
import 'operator_web/services/operator_web_proxy_client.dart';
import 'operator_web/services/operator_web_team_gateway_providers.dart';
import 'operator_web/services/web_account_gateway.dart';
import 'operator_web/services/web_business_timing_gateway.dart';
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

/// Demo scenario switch (Phase 2 walkthrough closure). Drives which
/// initial state + session + gateway seeding the demo auth source
/// emits. Production builds never read this — it's gated on
/// [_kOperatorWebDemoAuth] being true. The catalog of accepted values
/// + resolver lives in
/// `lib/operator_web/demo/operator_web_demo_scenario.dart` so it can
/// be unit-tested without pulling in `dart:html` from this entrypoint.
/// See [kOperatorWebDemoScenarios] for the full token list.
const String _kOperatorWebDemoScenario = String.fromEnvironment(
  'OPERATOR_WEB_DEMO_SCENARIO',
);

/// Operator-web proxy base URI. `--dart-define=OPERATOR_WEB_PROXY_BASE_URI=...`
/// points the live HTTP gateway at the F&F advisor proxy
/// (e.g. `https://proxy.forgeflow.app`). Live mode requires this
/// value and fails closed when it is missing; only demo mode may
/// fall back to the in-memory walkthrough source.
const String _kOperatorWebProxyBaseUri = String.fromEnvironment(
  'OPERATOR_WEB_PROXY_BASE_URI',
);

/// Release fail-closed copy for an accidental demo-auth build.
@visibleForTesting
const String kOperatorWebDemoAuthBlockedMessage =
    'Operator Web demo auth is blocked in a release build. '
    'OPERATOR_WEB_DEMO_AUTH was set, but demo auth bypasses Firebase '
    'and must never ship on a public endpoint. Drop the demo flag and '
    'ship live Firebase auth.';

/// Pure decision for the real runtime guard in [main].
///
/// Only **release** builds with `OPERATOR_WEB_DEMO_AUTH=true` are blocked:
/// the Cloud Run deploy script ships release artifacts, so that is the
/// real public-endpoint hazard. Debug builds are unblocked (local dev)
/// and profile builds are unblocked because the operator-web QA runbook
/// builds with `--profile` to bypass the DDC debug client — that is a
/// local-QA-only build target and never the deploy artifact. See
/// `docs/_audits/operator_web_demo_boot_2026_05_27.md` for the
/// regression that motivated tightening the predicate.
@visibleForTesting
bool operatorWebDemoAuthBlockedInRelease({
  required bool isDebugMode,
  required bool isProfileMode,
  required bool operatorWebDemoAuth,
}) {
  if (isDebugMode) return false;
  if (isProfileMode) return false;
  return operatorWebDemoAuth;
}

/// Firebase web options for the operator web project.
///
/// Defaults mirror `web/firebase-config.js` (staging); production deploys
/// override these with dart-defines generated from
/// `web/firebase-config.production1.js`. FlutterFire Web does not read those
/// files automatically; the default app must be created with explicit
/// [FirebaseOptions] unless a JavaScript bootstrap has already initialized it.
@visibleForTesting
const FirebaseOptions kOperatorWebFirebaseOptions = FirebaseOptions(
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
  // B1.A5 — Debug-time assertion for local smoke, kept as a belt-and-
  // suspenders signal. The real release/profile guard below is runtime
  // code because asserts are stripped from release artifacts.
  assert(() {
    if (!kDebugMode && _kOperatorWebDemoAuth) {
      throw StateError(
        'OPERATOR_WEB_DEMO_AUTH must not be true in a non-debug build. '
        'Demo auth bypasses Firebase and must never ship on a public endpoint.',
      );
    }
    return true;
  }());
  WidgetsFlutterBinding.ensureInitialized();
  // Bundled Google Fonts policy (parity with the mobile bootstrap in
  // `forge_flow_bootstrap.dart`, which this web target cannot import
  // because that file is dart:io-transitive): this console's theme
  // never calls GoogleFonts on web (AppTextStyles falls back to
  // Arial), so nothing is fetched today; the flag makes any future
  // accidental GoogleFonts use fail loudly instead of silently
  // downloading fonts at runtime. The bundled families' OFL licenses
  // surface on the standard license page.
  GoogleFonts.config.allowRuntimeFetching = false;
  LicenseRegistry.addLicense(() async* {
    const licenseAssetsByFamily = <String, String>{
      'Playfair Display': 'google_fonts/OFL_PlayfairDisplay.txt',
      'IBM Plex Sans': 'google_fonts/OFL_IBMPlexSans.txt',
      'IBM Plex Mono': 'google_fonts/OFL_IBMPlexMono.txt',
    };
    for (final entry in licenseAssetsByFamily.entries) {
      final license = await rootBundle.loadString(entry.value);
      yield LicenseEntryWithLineBreaks(<String>[entry.key], license);
    }
  });
  if (operatorWebDemoAuthBlockedInRelease(
    isDebugMode: kDebugMode,
    isProfileMode: kProfileMode,
    operatorWebDemoAuth: _kOperatorWebDemoAuth,
  )) {
    final error = StateError(kOperatorWebDemoAuthBlockedMessage);
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: StackTrace.current,
        library: 'operator_web',
        context: ErrorDescription('during operator-web startup'),
      ),
    );
    runApp(OperatorWebInitFailedApp(error: error, stack: StackTrace.current));
    return;
  }
  try {
    final source = await _resolveAuthSource();
    runApp(OperatorWebApp(authSource: source));
  } catch (error, stack) {
    // OW-G74 — record the full error + stack for our engineers BEFORE
    // we render the operator-facing surface. The init-failed screen no
    // longer shows the raw stack trace (engineering noise an operator
    // should never read); this is the engineering log path that keeps
    // the technical detail available. `FlutterError.reportError` routes
    // to the Flutter error console / any registered error reporter and
    // is never shown in the user UI.
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'operator_web',
        context: ErrorDescription('during operator-web startup'),
      ),
    );
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
    final scenario = resolveOperatorWebDemoScenario(_kOperatorWebDemoScenario);
    return _DemoOperatorWebAuthSourceWithTeamSurfaces(scenario: scenario);
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
///
/// The optional [scenario] selector picks the initial state +
/// session payload + gateway seeding so the walkthrough can land on
/// a specific demo posture without manual click-through. See
/// [_kOperatorWebDemoScenario] for the full scenario catalog.
class _DemoOperatorWebAuthSourceWithTeamSurfaces
    extends DemoOperatorWebAuthSource
    implements
        OperatorWebTeamUsersGatewayProvider,
        OperatorWebTeamRolesGatewayProvider,
        OperatorWebTeamHierarchyGatewayProvider,
        OperatorWebTeamSessionsGatewayProvider,
        OperatorWebTeamAuditLogGatewayProvider,
        OperatorWebSecurityGatewayProvider,
        OperatorWebAccountGatewayProvider,
        OperatorWebBusinessLogoUploadGatewayProvider,
        OperatorWebBusinessTimingGatewayProvider,
        OperatorWebBusinessTimingWriteGatewayProvider {
  factory _DemoOperatorWebAuthSourceWithTeamSurfaces({
    String scenario = kOperatorWebDemoScenarioDefault,
  }) {
    final securityGateway = DemoWebSecurityGateway();
    final initial = _initialStateForScenario(scenario);
    final emitNeedsSignInOnSignOut = scenario == 'signed-out-live';
    if (scenario == 'mfa-pending-removal') {
      // Seed the gateway directly so the OW-8c
      // `MfaCardStage.removalRequested` surface renders on first paint
      // with a 18h remaining badge instead of requiring the operator
      // to first revoke the factor.
      securityGateway.seedPendingFactorRemoval(
        factorId: kDemoSecurityExistingFactorId,
        delay: const Duration(hours: 18),
      );
    }
    final businessTimingWriteGateway =
        DemoOperatorWebBusinessTimingWriteGateway();
    return _DemoOperatorWebAuthSourceWithTeamSurfaces._(
      teamUsersGateway: DemoWebTeamUsersGateway(),
      teamRolesGateway: DemoWebTeamRolesGateway(),
      teamHierarchyGateway: DemoWebTeamHierarchyGateway(),
      teamSessionsGateway: DemoWebTeamSessionsGateway(),
      teamAuditLogGateway: DemoWebTeamAuditLogGateway(
        clock: DateTime.utc(2026, 5, 6),
      ),
      securityGateway: securityGateway,
      accountGateway: DemoOperatorWebAccountGateway(
        logoUrl: kDemoOperatorWebPlaceholderLogoUrl,
      ),
      businessLogoUploadGateway: DemoBusinessLogoUploadGateway(),
      businessTimingGateway: HttpBusinessTimingReadGateway(
        gateway: businessTimingWriteGateway,
      ),
      businessTimingWriteGateway: businessTimingWriteGateway,
      initial: initial,
      emitNeedsSignInOnSignOut: emitNeedsSignInOnSignOut,
    );
  }

  _DemoOperatorWebAuthSourceWithTeamSurfaces._({
    required this.teamUsersGateway,
    required this.teamRolesGateway,
    required this.teamHierarchyGateway,
    required this.teamSessionsGateway,
    required this.teamAuditLogGateway,
    required this.securityGateway,
    required this.accountGateway,
    required this.businessLogoUploadGateway,
    required this.businessTimingGateway,
    required this.businessTimingWriteGateway,
    required OperatorWebAuthState initial,
    required super.emitNeedsSignInOnSignOut,
  }) : super(initial: initial);

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

  @override
  final WebAccountGateway accountGateway;

  @override
  final BusinessLogoUploadGateway businessLogoUploadGateway;

  @override
  final BusinessTimingGateway businessTimingGateway;

  @override
  final WebBusinessTimingGateway businessTimingWriteGateway;

  /// Demo walkthrough pins the operator-web row to the fixture id so
  /// `(this session)` lights up on a known row. Live mode hydrates
  /// this from the auth source in the `11W.4.live` follow-up.
  @override
  String? get currentSessionId => kDemoTeamSessionThisSessionId;

  /// Maps a normalized scenario token to the initial auth state the
  /// demo source should emit. Unknown / unset tokens fall back to the
  /// sign-in screen (G24/G3 S3′ — no onboarding click path).
  static OperatorWebAuthState _initialStateForScenario(String scenario) {
    switch (scenario) {
      case 'owner-location-completed':
        return const OperatorWebCompleted(session: kDemoOperatorWebSession);
      case 'owner-business':
        return const OperatorWebCompleted(
          session: kDemoOperatorWebBusinessSession,
        );
      case 'manager-once':
        return const OperatorWebCompleted(
          session: kDemoOperatorWebLocationManagerSession,
        );
      case 'mfa-enrolled':
      case 'mfa-pending-removal':
        return const OperatorWebCompleted(
          session: kDemoOperatorWebMfaEnrolledSession,
        );
      case 'signed-out-live':
      case 'owner-location':
      default:
        return const OperatorWebNeedsSignIn();
    }
  }
}
