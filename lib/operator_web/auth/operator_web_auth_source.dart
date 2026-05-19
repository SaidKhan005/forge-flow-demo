// Phase 11W — Operator Web Console auth source.
//
// G24/G3 S3′ (operator decision 2026-05-16): the operator-web invite
// model is the **existing Firebase password-reset email**. The
// invitee receives a reset email (sent server-side by
// `repository_auth_operations_gateway.dart` `createInvite`), sets a
// password on Firebase's hosted page, then signs in here with their
// email + password through the standard
// `signInWithEmailPassword` → `_completeCredential` path. The G66
// invite-activation decorator flips `users.status` invited→active on
// that first sign-in.
//
// There is no magic-link / custom-token surface and no onboarding
// click path (set-password / MFA-during-onboarding / ToS). MFA, when
// required, is handled AFTER sign-in by the existing post-login
// challenge + account-MFA surfaces — not as an onboarding stage.
//
// Two implementations:
//
//   * [DemoOperatorWebAuthSource] — fixture-driven walkthrough source.
//     Lets widget tests + the local-dev demo walkthrough exercise the
//     sign-in + post-login surfaces without minting real Firebase
//     users or hitting the proxy.
//   * [FirebaseOperatorWebAuthSource] — live source. Wraps the
//     shared `FirebaseAuthClient` adapter (already used by the mobile
//     operator app and the admin console) so the live wiring is
//     additive rather than a parallel auth stack. Sign-in + password
//     reset land on the existing Phase 9 proxy routes
//     (`/v1/auth/password/*`, `/v1/auth/mfa/*`); the gateway seam
//     keeps them mockable. The deploy script refuses to publish a
//     non-demo build that would silently fall back to fixtures
//     (mirrors `scripts/deploy_admin_console.ps1`).

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../auth/permission_keys.dart';

// Per-Daypart Targets V1 / Slice 2 (Gap 35): operator-web Benchmarks
// override gateway import removed; surface cut entirely.

/// Identity payload for an authenticated operator-web user. Carries
/// only what the shell + screens need; not a full Firebase user
/// object.
@immutable
class OperatorWebSession {
  const OperatorWebSession({
    required this.uid,
    required this.email,
    required this.displayName,
    required this.operatorId,
    required this.businessName,
    required this.primaryLocationName,
    this.primaryLocationId,
    this.roles = const <String>[],
    this.permissions = const <String>{},
    this.phone,
    this.mfaEnrolled = false,
    this.logoUrl,
    this.currencyCode,
    this.localeTag,
    this.weekStartDay,
    this.rolloverHour,
    this.primaryLocationTimezone,
  });

  /// Firebase user UID (or a synthetic id under demo mode).
  final String uid;

  /// Email returned by Firebase / proxy.
  final String email;

  /// Display name. Falls back to email-localpart.
  final String displayName;

  /// Operator (tenant) the session belongs to.
  final String operatorId;

  /// Display name of the operator's business. Drives the welcome /
  /// T&Cs copy ("Sign in for [Business Name]") and the Account
  /// screen's business identity field.
  final String businessName;

  /// Primary location id for the operator. Used to seed the default
  /// `/locations/:location_id/vendor-connections` deep link.
  ///
  /// `null` (or an empty string after trimming) indicates the session
  /// is **not** pinned to a single location — e.g. a multi-unit owner
  /// whose default management scope is "All locations". Consumers that
  /// need a non-nullable `String` should fall back to `?? ''`; the
  /// router + scope-aware screens already gate on
  /// `trim().isNotEmpty` so an empty value is treated as "business
  /// scope". Drives the OW-4 inverse demo scenario where the Locations
  /// nav item appears in the left rail because the session is not
  /// location-scoped.
  final String? primaryLocationId;

  /// Display name of the primary location.
  final String primaryLocationName;

  /// Phase 9 role claims projected for the operator-web gate.
  /// `console.web` permission is gated on these roles via the proxy;
  /// the client uses them for read-only UI affordances.
  final List<String> roles;

  /// Server-resolved permission keys allowed for this user. Live mode
  /// hydrates this from `/v1/auth/permissions/snapshot`; demo mode
  /// leaves it empty and continues to use role fixtures.
  final Set<String> permissions;

  /// Optional phone-on-file for the operator user. Null when the
  /// proxy has no phone for the account; the My account screen
  /// renders "Not on file" with a copy pointer to the operator
  /// mobile app for edits. Read-only at V1 per the lean cut.
  final String? phone;

  /// Whether the operator has an active MFA factor enrolled. Drives
  /// the My account screen's MFA section CTA: false then "Enroll
  /// MFA"; true then "View backup codes". Mirrored from the proxy's
  /// `auth.users.mfa_enrolled` projection on the session payload.
  final bool mfaEnrolled;

  /// Optional https URL for the operator's logo. Null when the
  /// operator has not uploaded one. Surfaced on the Account screen
  /// (business identity editor) and as the brand mark on the shell.
  final String? logoUrl;

  /// ISO 4217 currency code (e.g. `USD`, `CAD`, `EUR`). Null when
  /// the proxy has not yet projected a value for this operator;
  /// surfaces falls back to `USD` for display only.
  final String? currencyCode;

  /// BCP 47 locale tag (e.g. `en-US`, `fr-CA`). Null when the proxy
  /// has not yet projected a value; UI defaults to `en-US`.
  final String? localeTag;

  /// Week-start day. One of: `monday`, `tuesday`, `wednesday`,
  /// `thursday`, `friday`, `saturday`, `sunday`. Null when not yet
  /// projected.
  final String? weekStartDay;

  /// Hour-of-day (0..23, restaurant local time) at which the
  /// business day rolls over. Null when not yet projected.
  final int? rolloverHour;

  /// Wave 2 W-6 — IANA timezone of the primary location (e.g.
  /// `America/Toronto`, `Europe/London`). This is the location's
  /// `locations.timezone` column, projected onto the session payload
  /// so the Account screen can render + edit it without an extra
  /// proxy round-trip on first load.
  ///
  /// Null when the proxy has not projected a value for this operator
  /// yet (older session payloads, or live sources that have not been
  /// updated). The Account screen renders "Not on file" in that case
  /// and the operator can still set a value through the editor.
  final String? primaryLocationTimezone;
}

/// Auth stage the screen-router keys off. The invitee onboarding
/// model is the Firebase password-reset email (set via the hosted
/// page, then email+password sign-in here) so there is no onboarding
/// click path — only sign-in, an optional post-sign-in MFA
/// challenge, and the completed/forbidden/signed-out terminals.
enum OnboardingStage {
  /// Bootstrap — auth source has not yet emitted its first state.
  loading,

  /// No Firebase session exists yet. The router renders an
  /// email/password sign-in form. New invitees set their password
  /// via the Firebase reset email first, then sign in here.
  signingIn,

  /// Live mode: Firebase accepted email/password but requires a TOTP
  /// challenge before it will issue an ID token.
  mfaChallenge,

  /// Sign-in complete; the shell renders the post-sign-in surfaces
  /// (Account, Vendor Connections, etc.).
  completed,

  /// Authenticated but the role catalog does not include
  /// `operator_owner` / `operator_general_manager` / `location_manager`.
  /// The operator-web console is for operator-side leadership roles
  /// only. Other roles hit the forbidden surface.
  forbidden,

  /// No session / signed out / token revoked. Router redirects to
  /// `/onboarding/welcome`.
  signedOut,
}

/// Sealed state machine the gate switches on. Mirrors
/// `AdminAuthState` from `lib/admin/admin_auth_gate.dart`.
@immutable
sealed class OperatorWebAuthState {
  const OperatorWebAuthState();

  OnboardingStage get stage;
  OperatorWebSession? get session;
  String? get lastErrorMessage;
}

class OperatorWebLoading extends OperatorWebAuthState {
  const OperatorWebLoading();
  @override
  OnboardingStage get stage => OnboardingStage.loading;
  @override
  OperatorWebSession? get session => null;
  @override
  String? get lastErrorMessage => null;
}

class OperatorWebNeedsSignIn extends OperatorWebAuthState {
  const OperatorWebNeedsSignIn({
    this.lastErrorMessage,
    this.lastInfoMessage,
    this.redirectUri,
  });
  @override
  OnboardingStage get stage => OnboardingStage.signingIn;
  @override
  OperatorWebSession? get session => null;
  @override
  final String? lastErrorMessage;

  /// Non-error confirmation copy, e.g. after a password reset request.
  final String? lastInfoMessage;

  /// CODE_OPS_DEBT carry-over #1 — populated when the user landed on
  /// the sign-in surface because a backend route returned the
  /// `mfa_freshness_required` 403. The router consumes this hint
  /// after re-auth completes and navigates back to the originating
  /// surface (typically `/auth/login?reason=fresh_mfa_required`,
  /// which the router interprets as "show the login card with a
  /// returnTo hint").
  final String? redirectUri;
}

class OperatorWebSignInMfaChallenge extends OperatorWebAuthState {
  const OperatorWebSignInMfaChallenge({
    required this.email,
    required this.mfaSessionToken,
    required this.factorIds,
    this.lastErrorMessage,
  });
  @override
  OnboardingStage get stage => OnboardingStage.mfaChallenge;
  @override
  OperatorWebSession? get session => null;

  final String email;
  final String mfaSessionToken;
  final List<String> factorIds;
  @override
  final String? lastErrorMessage;
}

class OperatorWebCompleted extends OperatorWebAuthState {
  const OperatorWebCompleted({required this.session});
  @override
  OnboardingStage get stage => OnboardingStage.completed;
  @override
  final OperatorWebSession session;
  @override
  String? get lastErrorMessage => null;
}

class OperatorWebForbidden extends OperatorWebAuthState {
  const OperatorWebForbidden({required this.session});
  @override
  OnboardingStage get stage => OnboardingStage.forbidden;
  @override
  final OperatorWebSession session;
  @override
  String? get lastErrorMessage => null;
}

class OperatorWebSignedOut extends OperatorWebAuthState {
  const OperatorWebSignedOut({this.lastErrorMessage});
  @override
  OnboardingStage get stage => OnboardingStage.signedOut;
  @override
  OperatorWebSession? get session => null;
  @override
  final String? lastErrorMessage;
}

/// Roles admitted to the operator-web console. Mirrors the v2 default
/// role catalog (`202605150000_phase_r2l_default_role_catalog_v2.sql`):
/// `operator_owner` gets full access, `operator_general_manager`
/// (v1 soft-deleted `operator_manager` → mapped per spec §3) and
/// `location_manager` (REAL v2 role) get read-only console access.
/// All other roles fail-close.
///
/// G7d (spec §2.B/§3): the phantom `'operator_admin'` literal is
/// dropped (folded into `operator_owner` — never seeded in v1/v2);
/// the soft-deleted v1 `'operator_manager'` literal is mapped to its
/// v2 constant rather than silently deleted (migration-window
/// robustness). Live-path neutral — real users carry the hydrated
/// permission snapshot and the per-screen `PermissionKeys.*` gates
/// (+ `_hasConsoleAccess` permission fallback) decide.
const Set<String> kOperatorWebAdmittedRoles = <String>{
  PermissionKeys.roleOperatorOwner,
  PermissionKeys.roleOperatorGeneralManager,
  PermissionKeys.roleLocationManager,
};

/// Source of the operator-web auth state machine. Both demo and live
/// implementations conform to this seam so the screens stay
/// implementation-blind.
///
/// G24/G3 S3′: the invitee onboarding model is the Firebase
/// password-reset email. There is no magic-link / set-password /
/// onboarding-MFA / ToS step on this seam — invitees set their
/// password on Firebase's hosted page and then sign in here via
/// [signInWithEmailPassword]. Post-sign-in MFA (challenge +
/// account-MFA enrollment) is handled by the existing post-login
/// surfaces, not as an onboarding stage.
abstract class OperatorWebAuthSource {
  Stream<OperatorWebAuthState> get stream;
  OperatorWebAuthState get current;

  /// Email/password sign-in. This is the single entry point for both
  /// returning users and new invitees (who set their password via the
  /// Firebase reset email before signing in here).
  Future<void> signInWithEmailPassword({
    required String email,
    required String password,
  }) {
    throw UnsupportedError('email/password sign-in is not wired');
  }

  /// Live MFA challenge completion for email/password sign-in.
  Future<void> completeSignInMfaChallenge({
    required String oneTimeCode,
    String? factorId,
  }) {
    throw UnsupportedError('sign-in MFA challenge is not wired');
  }

  /// Live password reset request through Firebase Auth. Implementations
  /// preserve account-existence privacy in user-facing copy.
  Future<void> requestPasswordReset({required String email}) {
    throw UnsupportedError('password reset request is not wired');
  }

  /// Sign out the current session.
  Future<void> signOut();

  /// Release the underlying stream controller.
  void dispose();
}

/// Factor catalog the MFA enrollment screen renders. Mirrors the
/// Phase 9 mobile MFA catalog — TOTP authenticator app + SMS.
enum MfaFactorType { totp, sms }

/// Artifact returned by the post-login account-MFA enrollment path
/// ([OperatorWebAccountActions.beginAccountMfaEnrollment]). TOTP
/// enrollment carries the otpauth secret + QR text; SMS enrollment
/// carries a challenge id only.
@immutable
class MfaEnrollmentArtifact {
  const MfaEnrollmentArtifact({
    required this.enrollmentId,
    required this.factorType,
    this.totpSharedSecret,
    this.totpQrUri,
    this.smsMaskedNumber,
  });

  final String enrollmentId;
  final MfaFactorType factorType;

  /// Base32 shared secret for TOTP enrollment. Null when
  /// [factorType] is SMS.
  final String? totpSharedSecret;

  /// `otpauth://` URI the screen renders as a QR code. Null when
  /// [factorType] is SMS.
  final String? totpQrUri;

  /// Masked phone number for SMS enrollment (e.g. `••• ••• 1234`).
  /// Null when [factorType] is TOTP.
  final String? smsMaskedNumber;
}

/// Demo source — exercises the sign-in + post-sign-in surfaces with a
/// single fixture operator. Walkthrough copy assumes this source.
///
/// G24/G3 S3′: there is no onboarding click path. The demo sign-in
/// accepts any non-empty email/password and lands on the completed
/// shell, mirroring the production "set password via Firebase reset
/// email, then sign in with email + password" model.
class DemoOperatorWebAuthSource implements OperatorWebAuthSource {
  DemoOperatorWebAuthSource({
    OperatorWebAuthState? initial,
    bool emitNeedsSignInOnSignOut = false,
  }) : _state = initial ?? const OperatorWebSignedOut(),
       _emitNeedsSignInOnSignOut = emitNeedsSignInOnSignOut {
    _controller.add(_state);
  }

  /// Demo scenario knob: when true, [signOut] emits
  /// [OperatorWebNeedsSignIn] instead of [OperatorWebSignedOut] so the
  /// demo renders the live `OperatorWebSignInScreen` (the U-1 demo
  /// scenario "signed-out-live").
  final bool _emitNeedsSignInOnSignOut;

  /// Convenience factory: starts signed out.
  factory DemoOperatorWebAuthSource.signedOut() =>
      DemoOperatorWebAuthSource(initial: const OperatorWebSignedOut());

  /// Convenience factory: starts on the sign-in surface so the
  /// walkthrough can drive the email/password card directly.
  factory DemoOperatorWebAuthSource.atWelcome() =>
      DemoOperatorWebAuthSource(initial: const OperatorWebNeedsSignIn());

  /// Convenience factory: starts on the post-onboarding surface so
  /// router tests can assert /account + /vendor-connections without
  /// re-running the click path.
  factory DemoOperatorWebAuthSource.completed() => DemoOperatorWebAuthSource(
    initial: OperatorWebCompleted(session: kDemoOperatorWebSession),
  );

  /// Convenience factory: starts on the post-onboarding surface as a
  /// `location_manager` so the `11W.7` Account screen walkthrough +
  /// permission-gate tests can exercise the read-only branch (Profile
  /// visible; MFA + Password CTAs disabled with friendly-error
  /// tooltip copy).
  factory DemoOperatorWebAuthSource.completedAsLocationManager() =>
      DemoOperatorWebAuthSource(
        initial: const OperatorWebCompleted(
          session: kDemoOperatorWebLocationManagerSession,
        ),
      );

  /// Convenience factory: starts on the forbidden surface so router
  /// tests can assert the fail-closed branch.
  factory DemoOperatorWebAuthSource.forbidden() => DemoOperatorWebAuthSource(
    initial: const OperatorWebForbidden(
      session: OperatorWebSession(
        uid: 'demo-staff',
        email: 'demo.staff@forgeflow.test',
        displayName: 'Demo Staff',
        operatorId: 'demo-operator',
        businessName: 'Demo Restaurant Group',
        primaryLocationId: 'demo-location',
        primaryLocationName: 'Demo Main Street',
        roles: <String>['staff'],
      ),
    ),
  );

  final StreamController<OperatorWebAuthState> _controller =
      StreamController<OperatorWebAuthState>.broadcast();
  OperatorWebAuthState _state;

  // Per-Daypart Targets V1 / Slice 2 (Gap 35): the `benchmarksGateway`
  // field was removed along with the operator-web Benchmarks override
  // surface. Mobile Baseline Manager star-shift selection is the only
  // override path.

  @override
  Stream<OperatorWebAuthState> get stream => _controller.stream;

  @override
  OperatorWebAuthState get current => _state;

  @override
  Future<void> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    if (email.trim().isEmpty || password.isEmpty) {
      _emit(
        const OperatorWebNeedsSignIn(
          lastErrorMessage: 'Enter your email and password to continue.',
        ),
      );
      return;
    }
    // Demo mirrors the production model: any new invitee sets their
    // password via the Firebase reset email, then signs in here with
    // email + password. The demo accepts any non-empty credentials
    // and lands on the completed shell.
    _emit(const OperatorWebCompleted(session: kDemoOperatorWebSession));
  }

  @override
  Future<void> completeSignInMfaChallenge({
    required String oneTimeCode,
    String? factorId,
  }) async {
    final current = _state;
    if (current is! OperatorWebSignInMfaChallenge) {
      _emit(
        const OperatorWebNeedsSignIn(
          lastErrorMessage: 'The verification session expired. Sign in again.',
        ),
      );
      return;
    }
    if (oneTimeCode.trim() != '123456') {
      _emit(
        OperatorWebSignInMfaChallenge(
          email: current.email,
          mfaSessionToken: current.mfaSessionToken,
          factorIds: current.factorIds,
          lastErrorMessage:
              'That code did not match. Codes refresh every 30 seconds. '
              'If your authenticator app shows a different code now, type '
              'the new one and try again.',
        ),
      );
      return;
    }
    _emit(const OperatorWebCompleted(session: kDemoOperatorWebSession));
  }

  @override
  Future<void> requestPasswordReset({required String email}) async {
    final normalizedEmail = email.trim();
    if (normalizedEmail.isEmpty) {
      _emit(
        const OperatorWebNeedsSignIn(
          lastErrorMessage:
              'Enter your email first, then request a reset link.',
        ),
      );
      return;
    }
    _emit(
      OperatorWebNeedsSignIn(
        lastInfoMessage:
            'If $normalizedEmail is registered, a password reset email is '
            'on the way. Open it to set your password, then sign in here.',
      ),
    );
  }

  @override
  Future<void> signOut() async {
    if (_emitNeedsSignInOnSignOut) {
      // U-1 demo scenario: sign-out lands on the live LoginScreen
      // surface (`OperatorWebNeedsSignIn`) so the walkthrough can
      // exercise the live email/password card without flipping
      // `OPERATOR_WEB_DEMO_AUTH` off. Production live source emits
      // `OperatorWebNeedsSignIn` after sign-out; this matches.
      _emit(const OperatorWebNeedsSignIn());
      return;
    }
    _emit(const OperatorWebSignedOut());
  }

  /// Test helper: pin a state directly without driving through the
  /// sign-in path.
  @visibleForTesting
  void emitForTesting(OperatorWebAuthState state) => _emit(state);

  void _emit(OperatorWebAuthState next) {
    _state = next;
    _controller.add(next);
  }

  @override
  void dispose() {
    _controller.close();
  }
}

/// Wave 2 W-5 — demo placeholder logo URL.
///
/// Demo mode invariant (HP #2): the reader code path is identical in
/// demo and live. The shell's `_OperatorBrandMark` reads
/// `session.logoUrl` and renders it via `Image.network` with the
/// F&F splash icon as a graceful fallback. Setting a demo URL here
/// exercises the propagation path end-to-end during the demo
/// walkthrough; if the URL fails to load (browser offline, CORS,
/// etc.) the shell falls back to the splash and the walkthrough
/// stays usable.
///
/// We use a `data:image/png;base64,...` URI so the demo logo
/// renders without any network round-trip — the demo walkthrough
/// works on a fresh laptop with no internet. The encoded image is a
/// 16x16 sunset-coloured PNG (F&F brand orange). This is NOT a
/// `kDemoMode` reader-side carve-out: production operators see
/// their uploaded URL through the exact same `session.logoUrl`
/// projection.
const String kDemoOperatorWebPlaceholderLogoUrl =
    'data:image/png;base64,'
    'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAQAAAC1+jfqAAAAOklEQVR42mNk+M9A'
    'C2AcNWjUoFGDRg0aNWjUoFGDhrJBjP8ZGGgADIyMjAyMjGz/Gf8z/B8FowAA1l8C'
    'TyFprO0AAAAASUVORK5CYII=';

/// Shared demo session so `signedOut → completed` factories return the
/// same identity payload — important because widget tests assert on
/// the fields.
///
/// `U-FU-hp11-account-demo-defaults` (2026-05-14): currency / locale /
/// week-start / rollover / timezone are populated so the Account
/// screen's Hierarchy scope notices interpolate to real values
/// ("CAD / en-CA", "04:00 local") instead of literal "null". Mirrors
/// the Business setup demo (`America/Toronto`, Monday-start, 04:00).
const OperatorWebSession kDemoOperatorWebSession = OperatorWebSession(
  uid: 'demo-operator-owner',
  email: 'owner@demo.forgeflow.test',
  displayName: 'Demo Operator Owner',
  operatorId: 'demo-operator',
  businessName: 'Demo Restaurant Group',
  primaryLocationId: 'demo-location',
  primaryLocationName: 'Demo Main Street',
  roles: <String>['operator_owner'],
  // Wave 2 W-5 — demo placeholder logo. See
  // [kDemoOperatorWebPlaceholderLogoUrl] for the demo-mode rationale.
  logoUrl: kDemoOperatorWebPlaceholderLogoUrl,
  currencyCode: 'CAD',
  localeTag: 'en-CA',
  weekStartDay: 'monday',
  rolloverHour: 4,
  primaryLocationTimezone: 'America/Toronto',
);

/// Demo session for the OW-4 inverse: an owner with no pinned
/// location (`primaryLocationId == null`). Drives the demo scenario
/// `owner-business`, where the left-nav surfaces the Locations item
/// because the management scope defaults to the operator (business)
/// scope rather than a location leaf.
const OperatorWebSession kDemoOperatorWebBusinessSession = OperatorWebSession(
  uid: 'demo-operator-owner-business',
  email: 'owner@demo.forgeflow.test',
  displayName: 'Demo Operator Owner',
  operatorId: 'demo-operator',
  businessName: 'Demo Restaurant Group',
  primaryLocationId: null,
  primaryLocationName: 'Demo Restaurant Group',
  roles: <String>['operator_owner'],
  logoUrl: kDemoOperatorWebPlaceholderLogoUrl,
  currencyCode: 'CAD',
  localeTag: 'en-CA',
  weekStartDay: 'monday',
  rolloverHour: 4,
  primaryLocationTimezone: 'America/Toronto',
);

/// Demo session for OW-8c `MfaCardStage.enrolled` walkthrough: same
/// owner-at-location identity as [kDemoOperatorWebSession] but with
/// `mfaEnrolled: true` so the My account MFA card lands on the
/// post-enrollment CTA branch (view recovery codes / manage 2FA)
/// without first running the post-login MFA enrollment flow.
const OperatorWebSession kDemoOperatorWebMfaEnrolledSession =
    OperatorWebSession(
      uid: 'demo-operator-owner',
      email: 'owner@demo.forgeflow.test',
      displayName: 'Demo Operator Owner',
      operatorId: 'demo-operator',
      businessName: 'Demo Restaurant Group',
      primaryLocationId: 'demo-location',
      primaryLocationName: 'Demo Main Street',
      roles: <String>['operator_owner'],
      mfaEnrolled: true,
      logoUrl: kDemoOperatorWebPlaceholderLogoUrl,
      currencyCode: 'CAD',
      localeTag: 'en-CA',
      weekStartDay: 'monday',
      rolloverHour: 4,
      primaryLocationTimezone: 'America/Toronto',
    );

/// Demo session for the `location_manager` read-only branch. Drives
/// the `11W.7` Account screen permission-gate walkthrough — same
/// operator + location as the owner session so the walkthrough's
/// "switch sessions" step lands on the same business in the side nav.
const OperatorWebSession kDemoOperatorWebLocationManagerSession =
    OperatorWebSession(
      uid: 'demo-location-manager',
      email: 'manager@demo.forgeflow.test',
      displayName: 'Demo Location Manager',
      operatorId: 'demo-operator',
      businessName: 'Demo Restaurant Group',
      primaryLocationId: 'demo-location',
      primaryLocationName: 'Demo Main Street',
      roles: <String>['location_manager'],
      logoUrl: kDemoOperatorWebPlaceholderLogoUrl,
      currencyCode: 'CAD',
      localeTag: 'en-CA',
      weekStartDay: 'monday',
      rolloverHour: 4,
      primaryLocationTimezone: 'America/Toronto',
    );
