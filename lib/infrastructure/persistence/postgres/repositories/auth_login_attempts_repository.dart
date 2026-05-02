// HARD-B - AuthLoginAttemptsRepository.
//
// Append-only writer + window-counter for `public.auth_login_attempts`,
// the lockout ledger landed in
// `db/migrations/202605020452_hardening_auth_login_attempts.sql`.
//
// Surface (per
// `docs/contracts/hardening_auth_protection_contract.md` "Lockout
// Behavior"):
//
//   * [recordAttempt]   - INSERT one row attributed to the resolved
//                         tenant when known, or anonymous when the
//                         lookup runs before tenant resolution.
//   * [countFailuresIn] - count `(failure, locked)` rows for the
//                         given `(user_email_hash, ip_hash)` pair
//                         within a rolling time window.
//   * [hashEmail]/[hashIp] - the canonical SHA-256 of the normalized
//                         inputs. Centralized here so producers cannot
//                         drift apart on whitespace/case handling.
//
// Two execution paths:
//
//   * Tenant-bound writes (`writeForTenant`) ride
//     `OperatorScopedRepository.withTenant` so per-tenant RLS pins the
//     row to the active operator.
//   * Anonymous writes / lookups (`writeAnonymous` / `countFailuresIn`)
//     ride `withSystem` because the inbound failure happens BEFORE the
//     proxy has resolved a tenant from the inbound credentials. The
//     `app.bypass_rls_audit = 'system:auth.lockout_*'` marker keeps
//     the system-scope path traceable in the audit trail.
//
// Sensitive-field discipline:
//   - The repository takes raw email + raw IP at the surface and hashes
//     them internally. Callers MUST NOT pass the raw values into the
//     payload of any audit row that consumes the result; the contract
//     forbids raw email / IP in `audit_logs`.

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../operator_scoped_repository.dart';
import '../tenant_context.dart';

class AuthLoginAttemptOutcome {
  static const String success = 'success';
  static const String failure = 'failure';
  static const String locked = 'locked';
}

/// Read projection of an `auth_login_attempts` row for the lockout
/// enforcer. Carries the SHA-256 hashes (32-byte `bytea` values) the
/// caller used at insert time so the enforcer can verify match shape
/// without re-hashing on the read path.
class AuthLoginAttemptsCount {
  const AuthLoginAttemptsCount({
    required this.failureCount,
    required this.locked,
  });

  /// Number of `(failure, locked)` rows in the queried window for the
  /// given `(user_email_hash, ip_hash)` pair.
  final int failureCount;

  /// True when the most recent threshold-reaching insert was an
  /// `outcome: locked` row. The route returns 423 in this case
  /// regardless of whether the count is exactly `5` or higher (a
  /// concurrent lock + a count race).
  final bool locked;
}

class AuthLoginAttemptsRepository extends OperatorScopedRepository {
  AuthLoginAttemptsRepository(super.tenantWrapper);

  /// SHA-256 of the normalized email. Trim + lowercase before hashing
  /// so `Foo@Bar.com `, `foo@bar.com`, and `foo@bar.com\n` collapse to
  /// one bucket. The contract's "anonymous lockout per
  /// (email_hash, ip_hash)" relies on this normalization.
  static List<int> hashEmail(String email) {
    final normalized = email.trim().toLowerCase();
    return sha256.convert(utf8.encode(normalized)).bytes;
  }

  /// SHA-256 of the inbound client IP. Caller passes the resolved IP
  /// string (the proxy already resolves IPv4/IPv6 via the dart:io
  /// connectionInfo path, and applies `X-Forwarded-For` only when
  /// `trustProxyAuditHeaders` is on).
  static List<int> hashIp(String ip) {
    return sha256.convert(utf8.encode(ip.trim())).bytes;
  }

  /// INSERT one row attributed to the resolved tenant. The row carries
  /// `(operator_id, location_id)` and the per-tenant RLS policy admits
  /// it. Returns the freshly generated `attempt_id`.
  Future<String> writeForTenant({
    required String operatorId,
    required String locationId,
    required String? actorUserId,
    required List<int> userEmailHash,
    required List<int> ipHash,
    required String outcome,
    String? userAgentClass,
  }) {
    _validateOutcome(outcome);
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<String>(ctx, (exec) async {
      final rows = await exec.query(
        'insert into public.auth_login_attempts ('
        'operator_id, user_email_hash, ip_hash, outcome, '
        'attempted_at, attempted_date, user_agent_class) '
        'values (@operator_id::uuid, @user_email_hash::bytea, '
        '@ip_hash::bytea, @outcome, '
        "@attempted_at::timestamptz, "
        "(@attempted_at::timestamptz at time zone 'UTC')::date, "
        '@user_agent_class) '
        'returning attempt_id::text as attempt_id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'user_email_hash': userEmailHash,
          'ip_hash': ipHash,
          'outcome': outcome,
          'attempted_at': DateTime.now().toUtc(),
          'user_agent_class': userAgentClass,
        },
      );
      if (rows.isEmpty) {
        throw StateError(
          'auth_login_attempts insert returned no rows - RLS may have '
          'blocked the row even though SET LOCAL ran',
        );
      }
      final id = rows.single['attempt_id'];
      if (id is! String || id.isEmpty) {
        throw StateError(
          'auth_login_attempts insert returned a malformed attempt_id',
        );
      }
      return id;
    });
  }

  /// INSERT one anonymous-scope row (operator_id IS NULL). Used by the
  /// proxy login route on failures that arrive before Firebase resolves
  /// a tenant. The row goes through `withSystem` so the forge_admin
  /// BYPASSRLS path can write a row whose tenant slot is intentionally
  /// null.
  Future<String> writeAnonymous({
    required List<int> userEmailHash,
    required List<int> ipHash,
    required String outcome,
    String? userAgentClass,
    required String adminReason,
  }) {
    _validateOutcome(outcome);
    return withSystem<String>(
      (exec) async {
        final rows = await exec.query(
          'insert into public.auth_login_attempts ('
          'operator_id, user_email_hash, ip_hash, outcome, '
          'attempted_at, attempted_date, user_agent_class) '
          'values (null, @user_email_hash::bytea, '
          '@ip_hash::bytea, @outcome, '
          "@attempted_at::timestamptz, "
          "(@attempted_at::timestamptz at time zone 'UTC')::date, "
          '@user_agent_class) '
          'returning attempt_id::text as attempt_id',
          parameters: <String, Object?>{
            'user_email_hash': userEmailHash,
            'ip_hash': ipHash,
            'outcome': outcome,
            'attempted_at': DateTime.now().toUtc(),
            'user_agent_class': userAgentClass,
          },
        );
        if (rows.isEmpty) {
          throw StateError(
            'auth_login_attempts anonymous insert returned no rows',
          );
        }
        final id = rows.single['attempt_id'];
        if (id is! String || id.isEmpty) {
          throw StateError(
            'auth_login_attempts anonymous insert returned a malformed '
            'attempt_id',
          );
        }
        return id;
      },
      reason: adminReason,
    );
  }

  /// Counts `(failure, locked)` rows in the window starting at
  /// `now - window` for the given `(user_email_hash, ip_hash)`
  /// pair. Runs `withSystem` because the lockout enforcer fires
  /// BEFORE Firebase resolves a tenant from the inbound credentials.
  ///
  /// Per the contract "Successful login within window resets failure
  /// count": only failures *after the latest success in the window*
  /// participate in the count. A success row inside the window
  /// effectively zeroes the slot, so an attacker who burns 4
  /// failures, races a legitimate login through, then resumes
  /// attacking still gets a fresh 5 attempts. The success row stays
  /// in the audit trail (the per-tenant audit-review surface still
  /// sees it), it just no longer participates in the lockout count.
  ///
  /// The `attempted_date >= ...` clause is included so partition
  /// pruning narrows the scan to the day(s) the window crosses;
  /// the inner subquery for `last_success_at` reuses the same
  /// `(user_email_hash, ip_hash)` index leading column.
  Future<AuthLoginAttemptsCount> countFailuresIn({
    required List<int> userEmailHash,
    required List<int> ipHash,
    required Duration window,
    required String adminReason,
  }) {
    final windowStart = DateTime.now().toUtc().subtract(window);
    return withSystem<AuthLoginAttemptsCount>(
      (exec) async {
        final rows = await exec.query(
          'select count(*)::int as failure_count, '
          "bool_or(outcome = 'locked') as has_locked "
          'from public.auth_login_attempts '
          'where user_email_hash = @user_email_hash::bytea '
          'and ip_hash = @ip_hash::bytea '
          'and attempted_at >= @window_start::timestamptz '
          "and attempted_date >= "
          "(@window_start::timestamptz at time zone 'UTC')::date "
          "and outcome in ('failure','locked') "
          // Latest-success cutoff per the contract reset semantics.
          // COALESCE handles "no success in window" by falling back
          // to one microsecond before window_start so every failure
          // in the window participates.
          'and attempted_at > coalesce('
          '(select max(attempted_at) '
          'from public.auth_login_attempts '
          'where user_email_hash = @user_email_hash::bytea '
          'and ip_hash = @ip_hash::bytea '
          'and attempted_at >= @window_start::timestamptz '
          "and attempted_date >= "
          "(@window_start::timestamptz at time zone 'UTC')::date "
          "and outcome = 'success'), "
          "@window_start::timestamptz - interval '1 microsecond')",
          parameters: <String, Object?>{
            'user_email_hash': userEmailHash,
            'ip_hash': ipHash,
            'window_start': windowStart,
          },
        );
        if (rows.isEmpty) {
          return const AuthLoginAttemptsCount(
            failureCount: 0,
            locked: false,
          );
        }
        final row = rows.single;
        final count = row['failure_count'];
        final locked = row['has_locked'];
        return AuthLoginAttemptsCount(
          failureCount: count is int ? count : 0,
          locked: locked is bool && locked,
        );
      },
      reason: adminReason,
    );
  }

  static void _validateOutcome(String outcome) {
    if (outcome != AuthLoginAttemptOutcome.success &&
        outcome != AuthLoginAttemptOutcome.failure &&
        outcome != AuthLoginAttemptOutcome.locked) {
      throw ArgumentError.value(
        outcome,
        'outcome',
        'must be one of: success, failure, locked',
      );
    }
  }
}
