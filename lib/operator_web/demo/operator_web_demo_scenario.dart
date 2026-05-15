// Phase 2 closure - demo-fidelity scenario switch.
//
// `--dart-define=OPERATOR_WEB_DEMO_SCENARIO=<value>` drives which
// initial state + session payload + gateway seeding the demo auth
// source emits. Production builds never read this — it's gated on
// `_kOperatorWebDemoAuth` being true in `main_operator_web.dart`.
// Lives in its own library (no `dart:html` transitive imports) so
// VM-side tests can verify resolver behavior without importing the
// web entrypoint.
//
// Scenario catalog:
//   owner-location           — default; Owner-at-location, Welcome screen
//   owner-location-completed — Owner-at-location, post-onboarding shell
//   owner-business           — Owner with primaryLocationId=null, OW-4 inverse
//   manager-once             — LocationManager, RP-15 cap walkthrough
//   mfa-enrolled             — Owner with mfaEnrolled=true, OW-8c
//   mfa-pending-removal      — Owner + pending-removal seeded, OW-8c sub-state
//   signed-out-live          — sign-out lands on live LoginScreen, U-1
//
// Unknown / empty values fall back to `owner-location` with no error
// so a typo never ships a silently-broken walkthrough.

/// Whitelist of supported scenario tokens. Mirrors the doc comment on
/// [resolveOperatorWebDemoScenario]; centralized so the resolver and
/// the entrypoint wiring agree on the catalog.
const Set<String> kOperatorWebDemoScenarios = <String>{
  'owner-location',
  'owner-location-completed',
  'owner-business',
  'manager-once',
  'mfa-enrolled',
  'mfa-pending-removal',
  'signed-out-live',
};

/// Default scenario token when [OPERATOR_WEB_DEMO_SCENARIO] is unset
/// or carries an unknown value. Pins the historical Welcome /
/// NeedsToken landing posture.
const String kOperatorWebDemoScenarioDefault = 'owner-location';

/// Normalizes a raw [OPERATOR_WEB_DEMO_SCENARIO] env value to a
/// canonical token from [kOperatorWebDemoScenarios]. Trims whitespace,
/// lowercases, and falls back to [kOperatorWebDemoScenarioDefault]
/// for empty / unknown values.
String resolveOperatorWebDemoScenario(String raw) {
  final value = raw.trim().toLowerCase();
  if (value.isEmpty || !kOperatorWebDemoScenarios.contains(value)) {
    return kOperatorWebDemoScenarioDefault;
  }
  return value;
}
