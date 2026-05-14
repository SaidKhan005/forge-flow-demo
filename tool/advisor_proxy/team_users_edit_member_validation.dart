// W-1 (Wave 2 Lane W — Members edit-user write path) — server-side
// validation helpers for the PATCH `/v1/auth/team/users/:id` route +
// its `/v1/admin/auth/users/:id` canonical sibling.
//
// Lives in its own file so the bleed-stop ceiling at
// `tool/advisor_proxy_size_lint.dart` does not creep up. The PATCH
// route handler in `advisor_proxy.dart` imports this seam through the
// existing barrel-style top-of-file imports.
//
// Two narrow surfaces:
//
//   * [looksLikeEmailForEditMember] — accepts the value the operator
//     typed in the Edit member dialog when it has been trimmed by the
//     proxy `_nonBlankString` helper. Mirrors the operator-web /
//     admin dialog's `_looksLikeEmail` so the wire-side reject
//     matches the client-side reject (no surprise 400 after a
//     successful client validation pass).
//
// The check is deliberately lenient — RFC 5322 e-mail validation
// belongs to Firebase Identity Platform (which rejects malformed
// addresses with its own `INVALID_EMAIL` error). The proxy guard
// is here to reject obviously-bogus values cheaply (empty user
// part, missing `@`, missing dot in domain, embedded whitespace)
// before paying for the Firebase round-trip.

/// Returns true when [value] has the basic shape of a valid email
/// address (`<local>@<host>.<tld>`). Whitespace inside the address
/// rejects the value; the caller is expected to have already trimmed
/// leading/trailing whitespace via `_nonBlankString`.
bool looksLikeEmailForEditMember(String value) {
  if (value.contains(' ')) return false;
  final atIndex = value.indexOf('@');
  if (atIndex <= 0) return false;
  if (atIndex == value.length - 1) return false;
  // Multi-`@` is rejected — Firebase Identity Platform refuses to
  // store these too, but the proxy short-circuit is cheaper.
  if (value.indexOf('@', atIndex + 1) != -1) return false;
  final domain = value.substring(atIndex + 1);
  if (!domain.contains('.')) return false;
  // Reject leading/trailing dots in the domain part (e.g. `@.foo`,
  // `@foo.`). Firebase rejects those, and the proxy reject keeps the
  // error closer to the operator's edit form.
  if (domain.startsWith('.') || domain.endsWith('.')) return false;
  return true;
}

/// Result of the route-layer pre-flight for the PATCH `/v1/auth/team/
/// users/:id` (or admin sibling) edit-user route. Either [rejection]
/// is non-null (caller `_writeJson`s the rejection then returns) or
/// the trimmed `displayName` / `email` / `reason` triple is ready for
/// the gateway call.
class EditMemberRouteInputs {
  const EditMemberRouteInputs._({
    this.displayName,
    this.email,
    this.reason,
    this.rejection,
  });

  /// Final trimmed display-name value, or null if the operator did
  /// not patch this field.
  final String? displayName;

  /// Final trimmed email value, or null if the operator did not patch
  /// this field.
  final String? email;

  /// Mandatory audit reason. Null when [rejection] is non-null.
  final String? reason;

  /// Pre-flight rejection envelope (status code + body) ready to be
  /// surfaced via `_writeJson`. Null when the inputs pass validation.
  final EditMemberRouteRejection? rejection;
}

/// Pre-flight rejection envelope for the edit-member route.
class EditMemberRouteRejection {
  const EditMemberRouteRejection({
    required this.statusCode,
    required this.error,
    required this.message,
  });

  final int statusCode;
  final String error;
  final String message;
}

/// Validates the PATCH `/v1/auth/team/users/:id` body the route
/// handler hands in. Returns an [EditMemberRouteInputs] carrying
/// either the validated triple or a [EditMemberRouteRejection] the
/// caller surfaces verbatim. Lives here (not in `advisor_proxy.dart`)
/// so the bleed-stop ceiling at `tool/advisor_proxy_size_lint.dart`
/// stays honest.
EditMemberRouteInputs validateEditMemberRouteBody({
  required String? targetUserId,
  required String? Function(Object? raw) nonBlankString,
  required Object? rawDisplayName,
  required Object? rawEmail,
  required Object? rawReason,
  required Object? rawAdminReason,
}) {
  final displayName = nonBlankString(rawDisplayName);
  final email = nonBlankString(rawEmail);
  final reason = nonBlankString(rawAdminReason) ?? nonBlankString(rawReason);
  if (targetUserId == null || reason == null) {
    return const EditMemberRouteInputs._(
      rejection: EditMemberRouteRejection(
        statusCode: 400,
        error: 'missing_user_profile_fields',
        message: 'user id and admin_reason are required',
      ),
    );
  }
  if (displayName == null && email == null) {
    return const EditMemberRouteInputs._(
      rejection: EditMemberRouteRejection(
        statusCode: 400,
        error: 'missing_user_profile_fields',
        message: 'at least one of display_name or email is required',
      ),
    );
  }
  if (email != null && !looksLikeEmailForEditMember(email)) {
    return const EditMemberRouteInputs._(
      rejection: EditMemberRouteRejection(
        statusCode: 400,
        error: 'invalid_email',
        message: 'email must be a syntactically valid address',
      ),
    );
  }
  return EditMemberRouteInputs._(
    displayName: displayName,
    email: email,
    reason: reason,
  );
}
