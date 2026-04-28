// Phase 9.5 - Password history reuse check.
//
// `password_history` (Phase 9.0 schema) keeps the last 5 hashes per
// user. The check rejects a new password whose normalized form
// matches any of those hashes. The actual hash comparison happens
// server-side via the proxy + Postgres binding (the hashes never
// leave Postgres); this seam is what the password-change service
// calls.
//
// Production binding will look up the user's last-5 hash rows
// inside an `OperatorScopedRepository.withTenant` block (Phase 9.2).
// The fail-closed default refuses the change — for password
// reuse the conservative default is to refuse rather than admit a
// silently-allowed reuse.

abstract class PasswordHistoryCheck {
  /// Returns true iff [candidate] matches one of [userId]'s last-N
  /// stored password hashes. The hash + comparison happens
  /// server-side; this is the seam the proxy implements.
  Future<bool> isReusedPassword({
    required String userId,
    required String candidate,
  });
}

/// Hard-fail-closed default. Throws so a deploy that forgets to
/// wire the real history check refuses every password change with
/// a clear error rather than silently letting reuse through.
class ScaffoldFailingPasswordHistoryCheck implements PasswordHistoryCheck {
  const ScaffoldFailingPasswordHistoryCheck();

  @override
  Future<bool> isReusedPassword({
    required String userId,
    required String candidate,
  }) async {
    throw StateError(
      '9.5 scaffold: real PasswordHistoryCheck is not wired — bind a '
      '`password_history` repository (Phase 9.2 + Postgres binding) '
      'before serving password-change traffic.',
    );
  }
}
