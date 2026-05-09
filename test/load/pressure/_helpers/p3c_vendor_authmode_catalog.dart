// Phase 3C OAuth refresh storm — vendor authMode catalog.
//
// Enumerates every Phase 8 vendor with the value its adapter declares
// in `capabilityProfile.authMode`, as observed in
// `lib/integrations/{pos,reservation,labor}/<vendor>_*_adapter.dart`.
// Used by the closure-registry coverage check to compare the worker's
// `kVendorsWithoutRefreshClosure` constant + the wired registry from
// `buildProductionRefreshClosures` against the actual adapter
// declarations — and against the audit's "Confirmed-clean" claim in
// `docs/POST_HARDENING_FOLLOWUPS.md`.
//
// Why a static map?
//
// Importing every adapter to read `.capabilityProfile.authMode`
// dynamically would drag in the full Phase 8 transport graph (Postgres
// sinks, HTTP clients, signature verifiers) which is unnecessary for
// a pure registry-coverage check. The catalog is hand-mirrored from
// the adapter declarations and verified by the runner test asserting
// each entry matches its source-of-truth file.

/// What the audit's `docs/POST_HARDENING_FOLLOWUPS.md` "Confirmed-
/// clean (re-verified 2026-05-08)" section claimed about each of the
/// 6 non-OAuth vendors. The harness records mismatches against the
/// adapter's actual declared authMode as findings.
const Map<String, String> kAuditClaimedNonOauthReason = <String, String>{
  'adp': 'mTLS',
  'tock': 'static API key',
  'push_operations': 'bearer',
  'opentable': 'internal',
  'sevenrooms': 'transport',
  'agendrix': 'static API key',
};

/// Adapter-declared `capabilityProfile.authMode` values. Mirrored from
/// the source files; the runner test contains a sanity check pinning
/// each entry to its file:line source.
///
/// Values are the stringified VendorAuthMode names: `oauth`,
/// `keyPaste`, `oauthOrKeyPaste`.
const Map<String, String> kAdapterAuthModes = <String, String>{
  // POS (7)
  'toast': 'oauth',
  'square': 'oauth',
  'clover': 'oauth',
  'lightspeed_lsk': 'oauth',
  'aloha_ncr_voyix': 'oauth',
  'oracle_micros_simphony': 'oauth',
  'revel': 'oauth',
  // Reservation (4)
  'libro': 'oauth',
  'tock': 'keyPaste',
  'opentable': 'oauth',
  'sevenrooms': 'oauthOrKeyPaste',
  // Labor (6)
  'quickbooks_time': 'oauth',
  'adp': 'oauth',
  'seven_shifts': 'oauth',
  'humanity': 'keyPaste',
  'agendrix': 'oauth',
  'push_operations': 'keyPaste',
};

/// Returns true when [authMode] is one of the OAuth-flavored values
/// the worker should be able to refresh. `oauthOrKeyPaste` is included
/// because the operator may have chosen the OAuth side at connect
/// time and a refresh would still apply.
bool isOauthFlavored(String authMode) =>
    authMode == 'oauth' || authMode == 'oauthOrKeyPaste';

/// All 17 vendor ids. Useful for iteration in the closure-coverage
/// check so the harness sees every vendor exactly once.
List<String> get allVendorIds => kAdapterAuthModes.keys.toList(growable: false);
