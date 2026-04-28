// Phase 9.5 - NIST SP 800-63B-4 password validator.
//
// Encodes the password rules from the decision lock + plan:
//
//   * Length: 8-64+ characters (15+ recommended).
//   * All printable Unicode allowed (no character-class restrictions).
//   * No composition rules ("must include uppercase + digit + symbol").
//   * No forced rotation unless breach evidence (this validator does
//     not enforce expiry — the proxy's freshness check does).
//   * No security questions / password hints (out of scope here).
//
// The validator returns a structured result so the UI can show every
// violation at once instead of drip-feeding fix-this-then-that loops
// (which NIST 800-63B-4 specifically discourages). Composition with
// HIBP screening + history reuse check happens in
// `password_change_service.dart` once the proxy lands; this file is
// pure data.
//
// Why no `dart:crypto` here: SHA-1 hashing for HIBP lives in
// `hibp_pwned_password_screener.dart`. This validator is shape-only
// so tests run without any IO.

/// One specific reason a candidate password failed [PasswordPolicy.validate].
enum PasswordViolation {
  tooShort,
  tooLong,
  containsControlChars,
  containsLeadingOrTrailingSpace,
}

/// Aggregated result of validating a candidate password.
class PasswordPolicyResult {
  PasswordPolicyResult({
    required this.violations,
    required this.length,
  });

  final Set<PasswordViolation> violations;
  final int length;

  bool get isValid => violations.isEmpty;
}

abstract class PasswordPolicy {
  PasswordPolicy._();

  /// NIST SP 800-63B-4 minimum: 8 characters. The proxy and clients
  /// surface a "≥ 15 recommended" hint in the UI, but the policy
  /// itself only refuses below 8.
  static const int minLength = 8;

  /// NIST SP 800-63B-4 maximum: 64 characters at minimum (Verifiers
  /// SHALL accept all printing characters; we cap at 256 to defend
  /// against pathological inputs).
  static const int maxLength = 256;

  /// Validates [candidate] against the locked policy. Returns every
  /// violation that applied so the UI can surface them all at once.
  static PasswordPolicyResult validate(String candidate) {
    final violations = <PasswordViolation>{};
    final length = candidate.runes.length;

    if (length < minLength) {
      violations.add(PasswordViolation.tooShort);
    }
    if (length > maxLength) {
      violations.add(PasswordViolation.tooLong);
    }
    if (_containsControlChars(candidate)) {
      violations.add(PasswordViolation.containsControlChars);
    }
    if (_hasEdgeWhitespace(candidate)) {
      violations.add(PasswordViolation.containsLeadingOrTrailingSpace);
    }

    return PasswordPolicyResult(violations: violations, length: length);
  }

  static bool _containsControlChars(String candidate) {
    for (final rune in candidate.runes) {
      // C0 control characters (0x00-0x1F) and DEL (0x7F). Tabs and
      // newlines are control chars and are intentionally rejected
      // because they cause inconsistent rendering across stores
      // (some strip them on display, some preserve them, leading
      // to login failures at the boundary).
      if (rune < 0x20 || rune == 0x7F) {
        return true;
      }
    }
    return false;
  }

  static bool _hasEdgeWhitespace(String candidate) {
    if (candidate.isEmpty) return false;
    return candidate.startsWith(' ') || candidate.endsWith(' ');
  }
}
