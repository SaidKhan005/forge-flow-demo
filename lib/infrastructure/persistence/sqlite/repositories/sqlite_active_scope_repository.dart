import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../../domain/models/business_scope.dart';
import '../../../../domain/services/utc_metadata_timestamp.dart';
import '../../../../services/scope/business_scope_repository.dart';
import '../sqlite_database.dart';

class SqliteActiveScopeRepository implements ActiveBusinessScopeRepository {
  SqliteActiveScopeRepository._();

  static final SqliteActiveScopeRepository instance =
      SqliteActiveScopeRepository._();

  @override
  Future<BusinessScope?> getActiveScope(String userId) async {
    final db = await SqliteDatabase.instance.database;
    final rows = await db.query(
      'active_business_scopes',
      where: 'user_id = ?',
      whereArgs: <Object?>[userId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return BusinessScope.fromJson(rows.first);
  }

  @override
  Future<void> saveActiveScope({
    required String userId,
    required BusinessScope scope,
  }) async {
    final db = await SqliteDatabase.instance.database;
    await db.insert('active_business_scopes', <String, Object?>{
      'user_id': userId,
      ...scope.toJson(),
      'updated_at': nowIsoUtc(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> clearActiveScope(String userId) async {
    final db = await SqliteDatabase.instance.database;
    await db.delete(
      'active_business_scopes',
      where: 'user_id = ?',
      whereArgs: <Object?>[userId],
    );
  }
}
