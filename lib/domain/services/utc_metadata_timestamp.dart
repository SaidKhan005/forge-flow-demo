/// Shared helper for audit metadata timestamps.
///
/// All audit metadata (createdAt, updatedAt, generatedAt, lockedAt) should
/// be stored as UTC ISO 8601 strings. This helper ensures consistency across
/// the touched runtime and seed writers without hidden timezone conversion.
///
/// Phase 7.55n.6 — metadata timestamp normalization.
///
/// This does NOT apply to:
/// - businessDate (operational anchor, not UTC metadata)
/// - builtAt, startedAt, completedAt, lastEventAt (separate metadata families)
/// - vendor/source timestamps
library;

/// Returns the current UTC time as an ISO 8601 string.
///
/// Use this for audit metadata columns: createdAt, updatedAt, generatedAt,
/// lockedAt. Do not use this for business-date fields.
String nowIsoUtc() => DateTime.now().toUtc().toIso8601String();
