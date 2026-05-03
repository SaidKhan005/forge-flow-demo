// Phase 8.0 — Per-vendor timestamp policy declarations.
//
// Scenario E from the binding A-F test set: "ambiguous vendor
// timestamp (no tz info)". Vendors emit timestamps in three shapes:
//
//   1. ISO-8601 with explicit `Z` or offset — unambiguous (Toast,
//      Lightspeed K-Series, Square, Revel, Clover).
//   2. ISO-8601 with no `Z` and no offset — ambiguous; the adapter
//      MUST declare its convention (treat as UTC, treat as
//      location-local, or refuse).
//   3. Vendor-shape timestamp (e.g., epoch millis, custom string) —
//      adapter declares the parser via [TimestampPolicy.customParser].
//
// Each adapter binds its declaration via the [vendorTimestampPolicy]
// catalog. The framework refuses to ingest a vendor event whose
// timestamp shape is not declared in the policy — silent fallback to
// "treat as UTC" is exactly the bug Scenario E is designed to catch.

/// Conventions a vendor's adapter can declare for ambiguous
/// timestamps (no `Z`, no offset).
enum AmbiguousTimestampConvention {
  /// Treat ambiguous timestamps as UTC instants (the JSON `Z` was
  /// omitted by the vendor but the spec says UTC). E.g., Lightspeed
  /// K-Series order timestamps in `2024-08-15T14:32:18` form.
  asUtc,

  /// Treat ambiguous timestamps as local wall-clock in the
  /// restaurant's configured timezone. E.g., Aloha business-day
  /// helpers that emit `2024-08-15 14:32:18` with no tz hint.
  asLocationLocal,

  /// Refuse to parse. The adapter records the event in the dead-
  /// letter table with a reason. Default for vendors whose policy
  /// has not been verified at sandbox time.
  refuse,
}

/// One vendor's timestamp policy declaration. Pure data; the
/// adapter wires this into [vendorTimestampPolicy].
class TimestampPolicy {
  const TimestampPolicy({
    required this.vendorId,
    required this.ambiguousConvention,
    this.customParserDocId,
    this.documentationNote,
  });

  /// Stable vendor identifier matching `connector_connection.vendor_id`.
  final String vendorId;

  /// What to do when the vendor emits a timestamp with no `Z` and
  /// no offset.
  final AmbiguousTimestampConvention ambiguousConvention;

  /// Doc id of the per-vendor parser when [ambiguousConvention] is
  /// not enough. Reserved for vendors that emit epoch millis,
  /// vendor-encoded strings, etc. The actual parser lives in the
  /// per-vendor adapter file (e.g.
  /// `lib/integrations/pos/aloha_pos_adapter.dart`); this constant
  /// just records that the policy is "see vendor file".
  final String? customParserDocId;

  /// Human-readable note explaining why the policy is set this way
  /// (e.g., "Lightspeed K-Series spec says timestamps are UTC; the
  /// `Z` is dropped in some endpoints but the convention is fixed").
  final String? documentationNote;
}

/// Catalog of declared per-vendor timestamp policies. The wave-1
/// reference adapters (`8.LSK`, `8R.LB`, `8.S.QBT`) populate the
/// initial set as no-op stubs in this file; subsequent slices
/// register their real policy when the per-vendor adapter file
/// lands. The framework refuses to ingest a vendor event for a
/// vendor that has no entry here.
const Map<String, TimestampPolicy> vendorTimestampPolicy =
    <String, TimestampPolicy>{
      'lightspeed_lsk': TimestampPolicy(
        vendorId: 'lightspeed_lsk',
        ambiguousConvention: AmbiguousTimestampConvention.asUtc,
        documentationNote:
            'Lightspeed K-Series order/event timestamps are UTC instants. '
            'Some endpoints drop the trailing Z; the convention is fixed UTC.',
      ),
      'libro': TimestampPolicy(
        vendorId: 'libro',
        ambiguousConvention: AmbiguousTimestampConvention.asLocationLocal,
        documentationNote:
            'Libro reservation timestamps are restaurant-local wall clock '
            'with no tz hint. Treat as location-local; the IANA converter '
            'projects to instant via `restaurantTimezone`.',
      ),
      'quickbooks_time': TimestampPolicy(
        vendorId: 'quickbooks_time',
        ambiguousConvention: AmbiguousTimestampConvention.asUtc,
        documentationNote:
            'Intuit QuickBooks Time timecard timestamps are UTC; the `Z` is '
            'always present in current API responses, but the policy stays '
            'declarative so a future API change does not silently break '
            'business-date bucketing.',
      ),
    };

/// Lookup helper. Returns null when no policy is declared (the
/// framework treats this as "refuse and dead-letter").
TimestampPolicy? lookupVendorTimestampPolicy(String vendorId) {
  return vendorTimestampPolicy[vendorId];
}
