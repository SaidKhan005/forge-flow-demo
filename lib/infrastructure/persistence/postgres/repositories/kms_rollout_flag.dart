// Phase 11A.4c — per-lane KMS rollout feature flag.
//
// Drives [KmsLaneRouter] (in `lib/infrastructure/kms/kms_lane_router.dart`).
// One feature-flag row per logical key kind:
//
//   kms_real_provider_anthropic_enabled
//   kms_real_provider_voyage_enabled
//   kms_real_provider_gemini_enabled
//   kms_real_provider_azure_db_enabled
//
// When the flag is ON for a given lane, the router dispatches that
// lane's `writeSecret` to the production
// `GcpSecretManagerKmsProvider`. When OFF (or the row is missing —
// the default), the router falls back to `KmsStubProvider`.
//
// Default OFF policy
// ------------------
// Unlike the audit-logs cutover (which defaults TRUE because the
// fan-out is being rolled forward across all writes), the KMS
// rollout defaults FALSE per lane. Production stays on the stub
// until the operator explicitly flips a row to ON. This keeps the
// pre-rotation posture (the stub) live until the GCP-side wiring
// has been verified for that specific lane, and lets the lanes flip
// over independently.
//
// Read pattern
// ------------
// Every call runs a single SELECT against `public.feature_flags`
// inside the caller's transaction. No caching: a flag flip takes
// effect on the next rotation request, no proxy restart needed.
// Mirrors `FeatureFlagsTableAuditLogsCutoverFlag`'s posture so the
// two cutovers behave the same way operationally.

import '../postgres_executor.dart';

/// Per-lane gate for the GCP Secret Manager rollout. When the flag
/// row for `kms_real_provider_<keyKind>_enabled` is true, the
/// `KmsLaneRouter` dispatches `writeSecret` to the production
/// `GcpSecretManagerKmsProvider`. When false (or row missing —
/// default OFF), it falls back to `KmsStubProvider`.
abstract class KmsRolloutFlag {
  /// Returns true when the real KMS provider should serve [keyKind].
  /// [exec] is the surrounding transaction's executor; the impl runs
  /// a single SELECT against `feature_flags` within the caller's
  /// scope.
  Future<bool> isEnabledFor(String keyKind, PostgresExecutor exec);
}

/// Constructor-injected fixed value. Used in tests + scaffolds where
/// the deploy doesn't need to consult the DB.
class FixedKmsRolloutFlag implements KmsRolloutFlag {
  /// All lanes off — production-shaped default.
  const FixedKmsRolloutFlag.allDisabled() : _enabledKinds = const <String>{};

  /// All lanes on — handy for scaffolds that want to exercise the
  /// real-provider branch without a per-kind allowlist.
  const FixedKmsRolloutFlag.allEnabled() : _enabledKinds = null;

  /// Selectively enable a subset of lanes; everything outside [kinds]
  /// stays on the stub.
  const FixedKmsRolloutFlag.enabledFor(Set<String> kinds)
    : _enabledKinds = kinds;

  /// `null` sentinel = "all enabled". Distinguished from an empty
  /// set so we can disable everything without having to enumerate.
  final Set<String>? _enabledKinds;

  @override
  Future<bool> isEnabledFor(String keyKind, PostgresExecutor exec) async {
    if (_enabledKinds == null) return true;
    return _enabledKinds.contains(keyKind);
  }
}

/// Production-grade impl. Reads the per-lane row from
/// `public.feature_flags` on every call (no caching — flag flips
/// take effect on the next rotation request, no proxy restart).
///
/// Defaults to FALSE when the row is missing — see file header for
/// why this differs from the audit-logs cutover's TRUE default.
class FeatureFlagsTableKmsRolloutFlag implements KmsRolloutFlag {
  const FeatureFlagsTableKmsRolloutFlag();

  /// Builds the `feature_flags.flag_name` value for [keyKind]. Public
  /// + static so production wiring (migrations, admin UX) and tests
  /// can compute the same name without re-deriving the convention.
  static String flagNameFor(String keyKind) =>
      'kms_real_provider_${keyKind}_enabled';

  @override
  Future<bool> isEnabledFor(String keyKind, PostgresExecutor exec) async {
    final flagName = flagNameFor(keyKind);
    final rows = await exec.query(
      'select enabled from public.feature_flags '
      'where flag_name = @flag_name '
      'and operator_id = public.feature_flag_system_wide_operator_id() '
      'and location_id is null '
      'limit 1',
      parameters: <String, Object?>{'flag_name': flagName},
    );
    if (rows.isEmpty) return false; // missing row = default OFF
    final raw = rows.first['enabled'];
    if (raw is bool) return raw;
    if (raw is num) return raw != 0;
    if (raw is String) {
      final lower = raw.toLowerCase();
      return lower == 'true' || lower == 't' || raw == '1';
    }
    return false;
  }
}
