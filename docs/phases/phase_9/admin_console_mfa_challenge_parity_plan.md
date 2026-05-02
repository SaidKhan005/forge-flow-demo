# Admin Console MFA Challenge Parity Plan

Status: Active hotfix slice.
Owner lane: Phase 9 auth behavior, consumed by Phase 11A Operations Console.
Worktree: `.claude/worktrees/admin-mfa-challenge-parity`.

## Decision

Admin console sign-in must complete Firebase TOTP MFA challenges for users who
already have MFA enrolled. This is login parity, not mandatory admin-tier MFA
enforcement.

Mandatory admin-tier MFA enrollment/enforcement remains deferred until the
post-launch `9-future-8` decision gate. This slice only unblocks sign-in for an
admin/support user whose Firebase account already returns a multi-factor
challenge after email/password.

## Current Gap

- The operator/mobile login flow already supports `AuthSessionMfaChallenge` and
  `completeTotpChallenge`.
- The admin console has only loading, unauthenticated, forbidden, and
  authenticated states.
- `FirebaseAdminAuthSource` imports `package:firebase_auth` directly and calls
  `signInWithEmailAndPassword`; it does not catch
  `FirebaseAuthMultiFactorException`.
- The reusable `FirebaseAuthClient` seam already models
  `FirebaseAuthSignInRequiresMfa` and stores SDK resolver handles in memory.
- The mobile MFA screen contains reusable visual pieces, but the full screen is
  coupled to operator session state and restaurant-admin support copy.

## Engineering Standard

Use shared implementation where it is a true shared concern:

- Reuse the Firebase MFA engine via `FirebaseAuthClient` and
  `FirebaseAuthSdkClient`.
- Extract the visual TOTP challenge page into a shared presentational widget.
- Keep mobile and admin state adapters separate.

Do not couple the admin console to `AuthSessionNotifier`,
`FirebaseAuthLoginService`, operator/location session projection, or mobile
support routing. Admin auth projects only admin custom claims and admits only
`super_admin` / `ff_support`.

## Implementation Scope

### 1. Shared challenge view

Create `lib/screens/auth/totp_challenge_view.dart` and move the reusable
presentational UI from `MfaChallengeScreen` into it:

- Branded page frame.
- Six-digit TOTP field.
- Verify button.
- Error banner.
- Optional informational/help banner.
- Optional help action.
- Sign-out/cancel action.

The shared widget owns only text entry and presentation state. Callers provide:

- Email.
- Error text.
- Help/info message.
- Submit callback.
- Help callback or null.
- Cancel callback.
- Copy strings appropriate to the app surface.

### 2. Mobile adapter

Refactor `lib/screens/auth/mfa_challenge_screen.dart` so it remains the
operator/mobile adapter:

- Reads `AuthSessionNotifier`.
- Requires `AuthSessionMfaChallenge`.
- Calls `AuthSessionNotifier.completeTotpChallenge`.
- Keeps operator-specific recovery request behavior and copy.
- Delegates rendering to `TotpChallengeView`.

### 3. Admin auth state

Extend `lib/admin/admin_auth_gate.dart`:

- Add `AdminAuthMfaChallenge`.
- Add `completeTotpChallenge` to `AdminAuthSource`.
- Add an admin MFA screen branch in `AdminAuthGate`.
- Add demo/test support for emitting MFA states without live Firebase.

### 4. Admin Firebase adapter

Rework live admin auth onto `FirebaseAuthClient`:

- `FirebaseAdminAuthSource` accepts a `FirebaseAuthClient`.
- Sign-in maps `FirebaseAuthSignInSucceeded` to an admin session projection.
- Sign-in maps `FirebaseAuthSignInRequiresMfa` to `AdminAuthMfaChallenge`.
- `completeTotpChallenge` maps success/failure the same way.
- `signOut` calls the client.

If needed, extend `FirebaseAuthCredential` with optional `email` and
`displayName` so admin session projection does not need direct Firebase SDK
access.

### 5. Admin entrypoint

Update `lib/main_admin.dart`:

- Initialize Firebase as today.
- Create one `FirebaseAuthSdkClient`.
- Pass it to `FirebaseAdminAuthSource`.
- Use the same client for admin gateway bearer tokens via `currentIdToken()`.
- Remove direct Firebase Auth usage from admin entry/gate code outside the
  approved SDK adapter file.

### 6. Tests

Update or add focused tests:

- Admin gate renders MFA challenge.
- Empty code does not call the source.
- Submit calls `completeTotpChallenge`.
- Successful completion admits super-admin/support.
- Failed completion stays on challenge and renders the error.
- Cancel signs out.
- Mobile `MfaChallengeScreen` still renders and submits through its notifier.
- Shared TOTP view keeps existing keys used by tests.

### 7. Docs/tracker

Route this as an active P0 hotfix in `PROJECT_TRACKER.md`. Do not update
`docs/POST_HARDENING_FOLLOWUPS.md`; the parallel L5 MFA service-test lane owns
that file.

## Verification

Run from this worktree:

```powershell
flutter analyze --fatal-infos `
  lib/admin/admin_auth_gate.dart `
  lib/main_admin.dart `
  lib/screens/auth/mfa_challenge_screen.dart `
  lib/screens/auth/totp_challenge_view.dart `
  lib/services/auth/firebase_auth_client.dart `
  lib/services/auth/firebase_auth_client_sdk.dart `
  test/admin_auth_gate_test.dart `
  test/auth_session_test.dart `
  test/mfa_test.dart

flutter test test/admin_auth_gate_test.dart test/auth_session_test.dart test/mfa_test.dart
```

If the local browser/dev server is still available, smoke the staging admin
console after tests:

- Email/password on an MFA-enrolled admin account yields challenge screen.
- Valid TOTP lands in the admin shell.
- Invalid TOTP remains on challenge with safe error copy.
- Sign out returns to the admin sign-in card.
