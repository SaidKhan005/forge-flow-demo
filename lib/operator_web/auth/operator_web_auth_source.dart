// Phase 11W.0 — Operator Web Console auth source.
//
// The operator-web shell drives the onboarding click path
// (welcome → password → MFA → T&Cs → dashboard) off a single state
// stream so the router can decide what to render without scattering
// `if (alreadyHasMfa)` flags across the screens. The shape mirrors
// `AdminAuthSource` (Phase 11A `lib/admin/admin_auth_gate.dart`) but
// adds onboarding stages because the operator shell ships the full
// first-login flow, while the admin shell only ships the post-login
// gate.
//
// Two implementations land with `11W.0`:
//
//   * [DemoOperatorWebAuthSource] — fixture-driven walkthrough source.
//     Lets widget tests + the local-dev demo walkthrough (
//     `scripts/run_operator_web_dev.ps1` in a follow-up) exercise the
//     whole onboarding click path without minting real Firebase users
//     or hitting the proxy.
//   * [FirebaseOperatorWebAuthSource] — live source. Wraps the
//     shared `FirebaseAuthClient` adapter (already used by the mobile
//     operator app and the admin console) so the live wiring is
//     additive rather than a parallel auth stack. The actual magic-link
//     verify / password / MFA-enroll / T&Cs-accept calls land on the
//     existing Phase 9 proxy routes (`/v1/auth/magic-link`,
//     `/v1/auth/password/*`, `/v1/auth/mfa/*`,
//     `/v1/auth/tos/accept`); the gateway seam keeps them mockable.
//
// Slice scope: `11W.0` ships the shell + onboarding click path. The
// live HTTP wiring against the proxy lands as a thin gateway in a
// follow-up `11W.0.live` slice — exactly the same pattern Phase 11A
// used (gate widget shipped first, HTTP gateway followed). Until that
// lands, the deploy script refuses to publish a non-demo build that
// would silently fall back to fixtures (mirrors
// `scripts/deploy_admin_console.ps1`).

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/operator_web_benchmarks_gateway.dart';

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
    required this.primaryLocationId,
    required this.primaryLocationName,
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
  final String primaryLocationId;

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

/// Onboarding stage the screen-router keys off. Linear progression
/// (welcome → password → MFA → T&Cs → completed) plus terminal
/// states for signed-out and forbidden.
enum OnboardingStage {
  /// Bootstrap — auth source has not yet emitted its first state.
  loading,

  /// Magic-link landing has not produced a verified Firebase session
  /// yet. The router renders the welcome screen with the token field.
  needsToken,

  /// Live mode: no Firebase session exists yet. The router renders
  /// an email/password sign-in form rather than the demo magic-link
  /// walkthrough.
  signingIn,

  /// Live mode: Firebase accepted email/password but requires a TOTP
  /// challenge before it will issue an ID token.
  mfaChallenge,

  /// Magic-link token verified; operator must set their password.
  settingPassword,

  /// Password set; operator must enroll MFA.
  enrollingMfa,

  /// MFA enrolled; operator must accept the inbound-vendor T&Cs.
  acceptingTos,

  /// Onboarding complete; the shell renders the post-onboarding
  /// surfaces (Account placeholder, Vendor Connections placeholder).
  completed,

  /// Authenticated but the role catalog does not include
  /// `operator_admin` / `operator_owner` / `location_manager`. The
  /// operator-web console is for operator-side senior roles only —
  /// staff hit the forbidden surface.
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

class OperatorWebNeedsToken extends OperatorWebAuthState {
  const OperatorWebNeedsToken({this.lastErrorMessage});
  @override
  OnboardingStage get stage => OnboardingStage.needsToken;
  @override
  OperatorWebSession? get session => null;
  @override
  final String? lastErrorMessage;
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

class OperatorWebSettingPassword extends OperatorWebAuthState {
  const OperatorWebSettingPassword({
    required this.session,
    this.lastErrorMessage,
  });
  @override
  OnboardingStage get stage => OnboardingStage.settingPassword;
  @override
  final OperatorWebSession session;
  @override
  final String? lastErrorMessage;
}

class OperatorWebEnrollingMfa extends OperatorWebAuthState {
  const OperatorWebEnrollingMfa({required this.session, this.lastErrorMessage});
  @override
  OnboardingStage get stage => OnboardingStage.enrollingMfa;
  @override
  final OperatorWebSession session;
  @override
  final String? lastErrorMessage;
}

class OperatorWebAcceptingTos extends OperatorWebAuthState {
  const OperatorWebAcceptingTos({
    required this.session,
    required this.tosVersion,
    required this.tosBodyMarkdown,
    this.lastErrorMessage,
  });
  @override
  OnboardingStage get stage => OnboardingStage.acceptingTos;
  @override
  final OperatorWebSession session;

  /// Active T&Cs version the click-through writes against.
  final TosVersion tosVersion;

  /// Markdown body of the T&Cs — rendered in the click-through
  /// scrollable region. Sourced from `tos_versions.body_markdown`.
  final String tosBodyMarkdown;

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

/// Roles admitted to the operator-web console. Mirrors the Phase 9
/// auth catalog: `operator_admin` and `operator_owner` get full
/// access, `location_manager` gets read-only. All other roles
/// fail-close.
const Set<String> kOperatorWebAdmittedRoles = <String>{
  'operator_owner',
  'operator_admin',
  'operator_manager',
  'location_manager',
};

/// Active T&Cs version metadata, returned by the proxy in
/// `GET /v1/auth/tos/active?scope=inbound_vendor_universal`.
@immutable
class TosVersion {
  const TosVersion({
    required this.versionId,
    required this.scope,
    required this.versionNumber,
    required this.effectiveDate,
  });

  final String versionId;
  final String scope;
  final String versionNumber;
  final DateTime effectiveDate;
}

/// Source of the operator-web auth state machine. Both demo and live
/// implementations conform to this seam so the screens stay
/// implementation-blind.
abstract class OperatorWebAuthSource {
  Stream<OperatorWebAuthState> get stream;
  OperatorWebAuthState get current;

  /// Live sign-in path. Demo implementations keep the magic-link
  /// walkthrough and may leave this unsupported.
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

  /// Phase 11W.0 — magic-link landing. The welcome screen passes the
  /// `?token=` query param here. Implementations call the proxy
  /// `/v1/auth/magic-link/verify` endpoint and establish a Firebase
  /// session on success.
  Future<void> verifyMagicLinkToken(String token);

  /// Phase 11W.0 — password setup. Validates against HIBP +
  /// `password_policy.dart` server-side; the demo source mirrors the
  /// same minimum (≥12 chars, not in last 5 hashes).
  Future<void> submitPassword({
    required String password,
    required String confirmation,
  });

  /// Phase 11W.0 — MFA enrollment. The operator picks a factor type
  /// (TOTP or SMS); the source returns the enrollment artifact (QR
  /// secret or SMS challenge id). The walkthrough calls
  /// [confirmMfaEnrollment] with the verification code to finish.
  Future<MfaEnrollmentArtifact> beginMfaEnrollment({
    required MfaFactorType factorType,
    String? phoneNumber,
  });

  /// Phase 11W.0 — confirm MFA enrollment with the operator's
  /// verification code. On success the source advances to
  /// [OnboardingStage.acceptingTos].
  Future<void> confirmMfaEnrollment({
    required String enrollmentId,
    required String oneTimeCode,
  });

  /// Phase 11W.0 — universal T&Cs click-through. Writes a row to
  /// `tos_acceptances` (Phase 9.8 schema) and advances to
  /// [OnboardingStage.completed].
  Future<void> acceptTos({required String versionId, required String scope});

  /// Sign out the current session.
  Future<void> signOut();

  /// Release the underlying stream controller.
  void dispose();
}

/// Factor catalog the MFA enrollment screen renders. Mirrors the
/// Phase 9 mobile MFA catalog — TOTP authenticator app + SMS.
enum MfaFactorType { totp, sms }

/// Artifact returned by [OperatorWebAuthSource.beginMfaEnrollment].
/// TOTP enrollment carries the otpauth secret + QR text; SMS
/// enrollment carries a challenge id only.
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

/// Demo source — drives the full onboarding click path with a single
/// fixture operator. Walkthrough copy assumes this source.
class DemoOperatorWebAuthSource
    implements OperatorWebAuthSource, OperatorWebBenchmarksGatewayProvider {
  DemoOperatorWebAuthSource({OperatorWebAuthState? initial})
    : _state = initial ?? const OperatorWebSignedOut() {
    _controller.add(_state);
  }

  /// Convenience factory: starts on the magic-link landing surface
  /// so the walkthrough can drive token entry first.
  factory DemoOperatorWebAuthSource.signedOut() =>
      DemoOperatorWebAuthSource(initial: const OperatorWebSignedOut());

  /// Convenience factory: starts already on the welcome screen, ready
  /// to verify the demo token (`demo-magic-link-token`).
  factory DemoOperatorWebAuthSource.atWelcome() =>
      DemoOperatorWebAuthSource(initial: const OperatorWebNeedsToken());

  /// Convenience factory: starts on the post-onboarding surface so
  /// router tests can assert /account + /vendor-connections without
  /// re-running the click path.
  factory DemoOperatorWebAuthSource.completed() => DemoOperatorWebAuthSource(
    initial: OperatorWebCompleted(session: kDemoOperatorWebSession),
  );

  /// Convenience factory: starts on the post-onboarding surface as a
  /// `location_manager` so the `11W.7` Account screen walkthrough +
  /// permission-gate tests can exercise the read-only branch (Profile
  /// + T&Cs visible; MFA + Password CTAs disabled with friendly-
  /// error tooltip copy).
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

  /// Demo magic-link token the walkthrough uses. Any other token
  /// fails verification.
  static const String kDemoMagicLinkToken = 'demo-magic-link-token';

  /// Demo TOS version the click-through writes against. `static
  /// final` (not const) because [DateTime.utc] is not a const
  /// constructor; the body markdown is large enough that storing the
  /// fixture as a single struct is easier to read than building the
  /// version + body in two places.
  static final TosVersionFixture kDemoTosVersion = TosVersionFixture(
    version: TosVersion(
      versionId: 'demo-tos-v1',
      scope: 'inbound_vendor_universal',
      versionNumber: '1.0.0',
      effectiveDate: _kDemoTosEffectiveDate,
    ),
    bodyMarkdown:
        '# Forge & Flow — Authorization to Access Your Business Data\n\n'
        'To run Forge & Flow, we need permission to read data from your '
        'existing systems. By continuing, you authorize Forge & Flow Inc. '
        'to do the following on your behalf for **Demo Restaurant Group**:\n\n'
        '- Connect to your POS, reservation, and scheduling systems when '
        'you click "Connect" on each one.\n'
        '- Read sales, covers, reservation, and labor data.\n'
        '- Store this data in a secure database operated by F&F (Microsoft '
        'Azure, Canada Central) for use in the F&F product.\n'
        '- Stop reading data and delete what we\'ve stored within 30 days '
        'of your written request.\n\n'
        'We will never:\n\n'
        '- Write back to your systems without a separate, explicit '
        'approval flow.\n'
        '- Sell your data, share it with third parties for marketing '
        'purposes, or use it to train AI models for other customers.\n'
        '- Access guest names, emails, or other personally identifiable '
        'details unless you opt in to that feature later.\n\n'
        'This authorization continues until you revoke it. You can revoke '
        'at any time from Settings → Account → Privacy.',
  );

  static final DateTime _kDemoTosEffectiveDate = DateTime.utc(2026, 5, 3);

  final StreamController<OperatorWebAuthState> _controller =
      StreamController<OperatorWebAuthState>.broadcast();
  OperatorWebAuthState _state;

  @override
  final OperatorWebBenchmarksGateway benchmarksGateway =
      DemoOperatorWebBenchmarksGateway();

  @override
  Stream<OperatorWebAuthState> get stream => _controller.stream;

  @override
  OperatorWebAuthState get current => _state;

  @override
  Future<void> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    _emit(
      const OperatorWebNeedsToken(
        lastErrorMessage:
            'Demo mode uses the invite-code walkthrough. Enter demo-magic-link-token to continue.',
      ),
    );
  }

  @override
  Future<void> completeSignInMfaChallenge({
    required String oneTimeCode,
    String? factorId,
  }) async {
    _emit(
      const OperatorWebNeedsToken(
        lastErrorMessage:
            'Demo mode uses onboarding MFA after the invite code, not sign-in MFA.',
      ),
    );
  }

  @override
  Future<void> requestPasswordReset({required String email}) async {
    _emit(
      const OperatorWebNeedsToken(
        lastErrorMessage:
            'Demo mode does not send email. Use demo-magic-link-token to continue.',
      ),
    );
  }

  @override
  Future<void> verifyMagicLinkToken(String token) async {
    final trimmed = token.trim();
    if (trimmed.isEmpty) {
      _emit(
        const OperatorWebNeedsToken(
          lastErrorMessage:
              'Paste the link from your invite email. The link includes '
              'a single-use code that signs you in.',
        ),
      );
      return;
    }
    if (trimmed != kDemoMagicLinkToken) {
      _emit(
        const OperatorWebNeedsToken(
          lastErrorMessage:
              'That code did not match an active invite. Open the most '
              'recent invite email and try the link again, or ask Forge '
              '& Flow support to resend the invite.',
        ),
      );
      return;
    }
    _emit(OperatorWebSettingPassword(session: kDemoOperatorWebSession));
  }

  @override
  Future<void> submitPassword({
    required String password,
    required String confirmation,
  }) async {
    final current = _state;
    if (current is! OperatorWebSettingPassword) {
      throw StateError(
        'submitPassword requires OperatorWebSettingPassword state',
      );
    }
    if (password.length < 12) {
      _emit(
        OperatorWebSettingPassword(
          session: current.session,
          lastErrorMessage:
              'Use at least 12 characters. A short phrase from a song or '
              'book is easier to remember than a string of random '
              'characters.',
        ),
      );
      return;
    }
    if (password != confirmation) {
      _emit(
        OperatorWebSettingPassword(
          session: current.session,
          lastErrorMessage:
              'The two passwords didn\'t match. Type the same password in '
              'both fields and try again.',
        ),
      );
      return;
    }
    _emit(OperatorWebEnrollingMfa(session: current.session));
  }

  @override
  Future<MfaEnrollmentArtifact> beginMfaEnrollment({
    required MfaFactorType factorType,
    String? phoneNumber,
  }) async {
    final current = _state;
    if (current is! OperatorWebEnrollingMfa) {
      throw StateError(
        'beginMfaEnrollment requires OperatorWebEnrollingMfa state',
      );
    }
    if (factorType == MfaFactorType.sms &&
        (phoneNumber == null || phoneNumber.trim().isEmpty)) {
      _emit(
        OperatorWebEnrollingMfa(
          session: current.session,
          lastErrorMessage:
              'Enter the mobile number where you want the verification '
              'code sent. SMS factors need a number Forge & Flow can text.',
        ),
      );
      throw StateError('SMS enrollment requires a phone number');
    }
    return MfaEnrollmentArtifact(
      enrollmentId: 'demo-enrollment-${factorType.name}',
      factorType: factorType,
      totpSharedSecret: factorType == MfaFactorType.totp
          ? 'JBSWY3DPEHPK3PXP'
          : null,
      totpQrUri: factorType == MfaFactorType.totp
          ? 'otpauth://totp/Forge%20%26%20Flow:${current.session.email}?'
                'secret=JBSWY3DPEHPK3PXP&issuer=Forge%20%26%20Flow'
          : null,
      smsMaskedNumber: factorType == MfaFactorType.sms
          ? _maskPhoneNumber(phoneNumber!)
          : null,
    );
  }

  @override
  Future<void> confirmMfaEnrollment({
    required String enrollmentId,
    required String oneTimeCode,
  }) async {
    final current = _state;
    if (current is! OperatorWebEnrollingMfa) {
      throw StateError(
        'confirmMfaEnrollment requires OperatorWebEnrollingMfa state',
      );
    }
    if (oneTimeCode != '123456') {
      _emit(
        OperatorWebEnrollingMfa(
          session: current.session,
          lastErrorMessage:
              'That code did not match. Codes refresh every 30 seconds. '
              'If your authenticator app shows a different code now, type '
              'the new one and try again.',
        ),
      );
      return;
    }
    _emit(
      OperatorWebAcceptingTos(
        session: current.session,
        tosVersion: kDemoTosVersion.version,
        tosBodyMarkdown: kDemoTosVersion.bodyMarkdown,
      ),
    );
  }

  @override
  Future<void> acceptTos({
    required String versionId,
    required String scope,
  }) async {
    final current = _state;
    if (current is! OperatorWebAcceptingTos) {
      throw StateError('acceptTos requires OperatorWebAcceptingTos state');
    }
    if (versionId != current.tosVersion.versionId ||
        scope != current.tosVersion.scope) {
      _emit(
        OperatorWebAcceptingTos(
          session: current.session,
          tosVersion: current.tosVersion,
          tosBodyMarkdown: current.tosBodyMarkdown,
          lastErrorMessage:
              'The version of these terms changed while you were reading. '
              'We refreshed the page so you see the latest version. Read '
              'and accept again to continue.',
        ),
      );
      return;
    }
    _emit(OperatorWebCompleted(session: current.session));
  }

  @override
  Future<void> signOut() async {
    _emit(const OperatorWebSignedOut());
  }

  /// Test helper: pin a state directly without driving through the
  /// click path.
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

/// Bundled version metadata + body so tests can drive the T&Cs screen
/// against a stable fixture.
@immutable
class TosVersionFixture {
  const TosVersionFixture({required this.version, required this.bodyMarkdown});

  final TosVersion version;
  final String bodyMarkdown;
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

String _maskPhoneNumber(String raw) {
  final digits = raw.replaceAll(RegExp(r'\D'), '');
  if (digits.length < 4) return raw;
  final last4 = digits.substring(digits.length - 4);
  return '••• ••• $last4';
}
