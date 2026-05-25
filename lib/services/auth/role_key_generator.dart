/// Generates backend role keys from operator/admin-facing role names.
///
/// Role keys stay in the transport and database contract, but role creation
/// surfaces should ask humans for a display name only.
String generateRoleKeyFromDisplayName(
  String displayName, {
  Set<String> existingKeys = const <String>{},
}) {
  var base = _slugBase(displayName);
  if (base.length < 3) {
    base = '${base}_role';
  }
  base = _trimRoleKey(base);
  if (!existingKeys.contains(base)) return base;

  for (var suffix = 2; suffix < 10000; suffix += 1) {
    final suffixText = '_$suffix';
    final candidate =
        '${_trimRoleKey(base, reserve: suffixText.length)}'
        '$suffixText';
    if (!existingKeys.contains(candidate)) return candidate;
  }

  final fallbackSuffix = DateTime.now()
      .toUtc()
      .millisecondsSinceEpoch
      .remainder(1000000)
      .toString();
  return '${_trimRoleKey(base, reserve: fallbackSuffix.length + 1)}'
      '_$fallbackSuffix';
}

String _slugBase(String displayName) {
  final lowered = displayName.toLowerCase();
  final sanitized = StringBuffer();
  var lastWasUnderscore = false;
  for (final code in lowered.codeUnits) {
    final char = String.fromCharCode(code);
    final isAlpha = code >= 0x61 && code <= 0x7a;
    final isDigit = code >= 0x30 && code <= 0x39;
    if (isAlpha || isDigit) {
      sanitized.write(char);
      lastWasUnderscore = false;
    } else if (!lastWasUnderscore && sanitized.isNotEmpty) {
      sanitized.write('_');
      lastWasUnderscore = true;
    }
  }
  var key = sanitized.toString();
  while (key.endsWith('_')) {
    key = key.substring(0, key.length - 1);
  }
  if (key.isEmpty || !RegExp(r'^[a-z]').hasMatch(key)) {
    key = 'role_${key.isEmpty ? 'custom' : key}';
  }
  return key;
}

String _trimRoleKey(String key, {int reserve = 0}) {
  final limit = 64 - reserve;
  var out = key.length > limit ? key.substring(0, limit) : key;
  while (out.endsWith('_') && out.isNotEmpty) {
    out = out.substring(0, out.length - 1);
  }
  return out.isEmpty ? 'role_custom' : out;
}
