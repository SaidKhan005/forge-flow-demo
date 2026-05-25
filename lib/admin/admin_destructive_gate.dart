// UX-parity Slice E4 — composed gate for DESTRUCTIVE admin actions.
//
// Extracted from `admin_routes.dart` (which is at its frozen
// refactor-phase size ceiling) so the monolith shrinks rather than
// grows. The destructive per-action route flags
// (`canEditSeededRoles`, `canResetMfaFactors`, `canIssuePairedErasure`)
// are computed as
// `adminCanEdit(session, requiredKey: <key>) && <MFA-fresh>`.

import 'admin_auth_gate.dart';
import 'admin_capability_gate.dart';

/// Composed DESTRUCTIVE-action gate: the per-action capability key
/// (key-first with the `super_admin` role fallback, via [adminCanEdit])
/// AND the MFA-freshness dimension [mfaFresh] (the caller resolves
/// freshness through the unchanged `_isAdminMfaFresh` /
/// `FreshMfaResolver` path so this helper stays pure / I/O-free).
///
/// With an EMPTY permissions set `adminCanEdit` falls back to the coarse
/// `super_admin` role check, so the result collapses to the pre-slice
/// `super_admin && mfaFresh` decision (byte-identical) under the
/// screen's `editingEnabled && <flag>` conjunction. Once a live
/// `/v1/auth/permissions/snapshot` hydrates the session, the per-action
/// key gates the specific destructive affordance. The proxy
/// `PermissionResolver` re-checks both dimensions server-side.
bool adminCanEditDestructive(
  AdminAuthSession? session, {
  required String requiredKey,
  required bool mfaFresh,
}) => adminCanEdit(session, requiredKey: requiredKey) && mfaFresh;
