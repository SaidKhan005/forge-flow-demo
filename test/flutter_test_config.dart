import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:path/path.dart' as p;

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();

  final dbDir =
      Directory(p.join(Directory.current.path, '.dart_tool', 'test_databases'));
  final dbPath = p.join(dbDir.path, 'forge_flow_v2_$pid.db');

  await dbDir.create(recursive: true);
  await _deleteSidecarFiles(dbPath);
  await SqliteDatabase.instance.useDatabasePath(dbPath);

  try {
    await testMain();
  } finally {
    await SqliteDatabase.instance.close();
    await _deleteSidecarFiles(dbPath);
  }
}

Future<void> _deleteSidecarFiles(String dbPath) async {
  final paths = <String>[
    dbPath,
    '$dbPath-shm',
    '$dbPath-wal',
  ];
  for (final path in paths) {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }
}
