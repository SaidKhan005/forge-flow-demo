// A5+A8 audit-log mutation lint.
//
// The audit_logs table is append-only evidence. This lint walks SQL under
// db/migrations/** and fails when a migration updates audit_logs unless the
// file is explicitly listed in tool/audit_logs_update_allowlist.txt.

import 'dart:io';

const String defaultAuditLogsUpdateAllowlistPath =
    'tool/audit_logs_update_allowlist.txt';
const String defaultAuditLogsUpdateMigrationsDir = 'db/migrations';

final RegExp _auditLogsUpdatePattern = RegExp(
  r'\bupdate\s+(?:only\s+)?(?:(?:"public"|public)\s*\.\s*)?(?:"audit_logs"|audit_logs)\b',
  caseSensitive: false,
);

class AuditLogsUpdateViolation {
  const AuditLogsUpdateViolation({
    required this.path,
    required this.line,
    required this.snippet,
  });

  final String path;
  final int line;
  final String snippet;

  @override
  String toString() => '$path:$line updates audit_logs: $snippet';
}

class AuditLogsUpdateLintResult {
  const AuditLogsUpdateLintResult({
    required this.violations,
    required this.scannedFileCount,
    required this.allowlistedFileCount,
  });

  final List<AuditLogsUpdateViolation> violations;
  final int scannedFileCount;
  final int allowlistedFileCount;

  bool get isClean => violations.isEmpty;
}

class AuditLogsUpdateLintRunner {
  AuditLogsUpdateLintRunner({required this.files, required this.allowlist});

  final Map<String, String> files;
  final Set<String> allowlist;

  AuditLogsUpdateLintResult run() {
    final violations = <AuditLogsUpdateViolation>[];
    var allowlistedFileCount = 0;
    for (final entry in files.entries) {
      final path = _normalizePath(entry.key);
      if (_isAllowlisted(path)) {
        allowlistedFileCount++;
        continue;
      }
      violations.addAll(_scanFile(path, entry.value));
    }
    return AuditLogsUpdateLintResult(
      violations: List<AuditLogsUpdateViolation>.unmodifiable(violations),
      scannedFileCount: files.length,
      allowlistedFileCount: allowlistedFileCount,
    );
  }

  bool _isAllowlisted(String path) {
    final normalizedAllowlist = allowlist.map(_normalizePath).toSet();
    return normalizedAllowlist.contains(path) ||
        normalizedAllowlist.contains(_basename(path));
  }

  Iterable<AuditLogsUpdateViolation> _scanFile(String path, String body) sync* {
    final scanBody = stripSqlCommentsPreservingOffsets(body);
    for (final match in _auditLogsUpdatePattern.allMatches(scanBody)) {
      yield AuditLogsUpdateViolation(
        path: path,
        line: _lineForOffset(scanBody, match.start),
        snippet: _trimSnippet(match.group(0) ?? ''),
      );
    }
  }
}

String stripSqlCommentsPreservingOffsets(String input) {
  final buffer = StringBuffer();
  var index = 0;
  var inSingleQuote = false;
  var inDoubleQuote = false;

  while (index < input.length) {
    final char = input[index];
    final next = index + 1 < input.length ? input[index + 1] : '';

    if (!inSingleQuote && !inDoubleQuote && char == '-' && next == '-') {
      buffer.write('  ');
      index += 2;
      while (index < input.length && input[index] != '\n') {
        buffer.write(' ');
        index++;
      }
      continue;
    }

    if (!inSingleQuote && !inDoubleQuote && char == '/' && next == '*') {
      buffer.write('  ');
      index += 2;
      while (index < input.length) {
        final blockChar = input[index];
        final blockNext = index + 1 < input.length ? input[index + 1] : '';
        if (blockChar == '*' && blockNext == '/') {
          buffer.write('  ');
          index += 2;
          break;
        }
        buffer.write(blockChar == '\n' ? '\n' : ' ');
        index++;
      }
      continue;
    }

    if (!inDoubleQuote && char == "'") {
      buffer.write(char);
      if (inSingleQuote && next == "'") {
        buffer.write(next);
        index += 2;
        continue;
      }
      inSingleQuote = !inSingleQuote;
      index++;
      continue;
    }

    if (!inSingleQuote && char == '"') {
      buffer.write(char);
      if (inDoubleQuote && next == '"') {
        buffer.write(next);
        index += 2;
        continue;
      }
      inDoubleQuote = !inDoubleQuote;
      index++;
      continue;
    }

    buffer.write(char);
    index++;
  }

  return buffer.toString();
}

Set<String> readAuditLogsUpdateAllowlist(String path) {
  final file = File(path);
  if (!file.existsSync()) return <String>{};
  return file
      .readAsLinesSync()
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty && !line.startsWith('#'))
      .map(_normalizePath)
      .toSet();
}

Map<String, String> readMigrationSqlFiles(String migrationsDir) {
  final root = Directory(migrationsDir);
  final files = <String, String>{};
  for (final file
      in root.listSync(recursive: true, followLinks: false).whereType<File>()) {
    if (!file.path.toLowerCase().endsWith('.sql')) continue;
    final relativePath = _relativeSqlPath(root, file);
    files[relativePath] = file.readAsStringSync();
  }
  return Map<String, String>.fromEntries(
    files.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
  );
}

Future<void> main(List<String> args) async {
  final migrationsDir = _argOrDefault(
    args,
    '--migrations=',
    defaultAuditLogsUpdateMigrationsDir,
  );
  final allowlistPath = _argOrDefault(
    args,
    '--allowlist=',
    defaultAuditLogsUpdateAllowlistPath,
  );

  if (!Directory(migrationsDir).existsSync()) {
    stderr.writeln(
      'audit_logs_update_lint: migrations dir not found at $migrationsDir',
    );
    exitCode = 2;
    return;
  }

  final files = readMigrationSqlFiles(migrationsDir);
  final allowlist = readAuditLogsUpdateAllowlist(allowlistPath);
  final result = AuditLogsUpdateLintRunner(
    files: files,
    allowlist: allowlist,
  ).run();

  stdout.writeln(
    'audit_logs_update_lint: scanned ${result.scannedFileCount} SQL file(s); '
    '${result.allowlistedFileCount} allowlisted.',
  );
  if (result.isClean) {
    stdout.writeln(
      'audit_logs_update_lint: clean - no unallowlisted UPDATE audit_logs.',
    );
    return;
  }

  stderr.writeln(
    'audit_logs_update_lint: ${result.violations.length} violation(s):',
  );
  for (final violation in result.violations) {
    stderr.writeln('  - $violation');
  }
  stderr.writeln(
    'Fix: split audit_logs backfills into an operator-gated post_deploy '
    'migration or add a reviewed path to $allowlistPath.',
  );
  exitCode = 1;
}

String _argOrDefault(List<String> args, String prefix, String fallback) {
  for (final arg in args) {
    if (arg.startsWith(prefix)) {
      return arg.substring(prefix.length);
    }
  }
  return fallback;
}

String _basename(String path) {
  final normalized = _normalizePath(path);
  final slash = normalized.lastIndexOf('/');
  return slash == -1 ? normalized : normalized.substring(slash + 1);
}

String _normalizePath(String path) => path.replaceAll('\\', '/');

String _relativeSqlPath(Directory root, File file) {
  final rootPath = _normalizePath(root.absolute.path);
  final filePath = _normalizePath(file.absolute.path);
  final suffix = filePath.startsWith('$rootPath/')
      ? filePath.substring(rootPath.length + 1)
      : _basename(filePath);
  return '${_normalizePath(root.path)}/$suffix';
}

int _lineForOffset(String body, int offset) {
  var line = 1;
  for (var i = 0; i < offset && i < body.length; i++) {
    if (body.codeUnitAt(i) == 10) line++;
  }
  return line;
}

String _trimSnippet(String raw) {
  final collapsed = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  return collapsed.length > 100
      ? '${collapsed.substring(0, 97)}...'
      : collapsed;
}
