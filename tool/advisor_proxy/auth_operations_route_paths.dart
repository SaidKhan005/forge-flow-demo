// Wave 2 W-3 — auth-ops route-path canonicalisation.
//
// Extracted from `advisor_proxy.dart` so the bleed-stop ceiling at
// `tool/advisor_proxy_size_lint.dart` stays honest while the W-3
// self-service profile editor lands. The function below is pure
// string manipulation; pulling it into a sibling file does not
// change its semantics. The proxy imports the function and the
// constants it needs unchanged.
//
// Why this helper exists
// ----------------------
// The proxy accepts two URL shapes for the same admin-auth operation:
//
//   * `/v1/admin/auth/<resource>...` — the canonical admin form,
//     used by the F&F Ops Console.
//   * `/v1/auth/team/<resource>...` — the operator-self-service form,
//     used by the operator-web Settings → Team UX.
//
// The dispatcher canonicalises the team-side path into the admin-side
// shape so a single branch handles both. Translation table mirrors
// the path-prefix constants in `advisor_proxy.dart`.

/// Path translation table the dispatcher hands in. Order = (team
/// path, admin canonical) pairs; for exact-match entries the second
/// is the replacement; for prefix entries the third is `true` so the
/// suffix is preserved when rewriting.
typedef AuthOperationPathTranslationEntry = ({
  String teamPath,
  String adminPath,
  bool isPrefix,
});

/// Translate a `/v1/auth/team/...` operator-self-service path into the
/// canonical `/v1/admin/auth/...` form. Admin-side paths pass through
/// unchanged. The dispatcher hands in the translation table so this
/// sibling file does not need to re-declare every path constant.
String canonicalAuthOperationPath(
  String path,
  List<AuthOperationPathTranslationEntry> table,
) {
  for (final entry in table) {
    if (entry.isPrefix) {
      if (path.startsWith(entry.teamPath)) {
        return '${entry.adminPath}${path.substring(entry.teamPath.length)}';
      }
    } else {
      if (path == entry.teamPath) return entry.adminPath;
    }
  }
  return path;
}
