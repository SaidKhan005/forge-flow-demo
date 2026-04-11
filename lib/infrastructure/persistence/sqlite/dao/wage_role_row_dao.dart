import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../../../domain/models/wage_role_row.dart';

class WageRoleRowDao {
  final Database _db;
  const WageRoleRowDao(this._db);

  Future<List<WageRoleRow>> getRows(String restaurantId) async {
    final rows = await _db.query(
      'wage_role_rows',
      where: 'restaurant_id = ?',
      whereArgs: [restaurantId],
      orderBy: 'labor_bucket, role_name',
    );
    return rows.map(WageRoleRow.fromMap).toList();
  }

  Future<void> upsertRow(WageRoleRow row) async {
    await _db.insert(
      'wage_role_rows',
      row.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteRow(int id) async {
    await _db.delete(
      'wage_role_rows',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteAll(String restaurantId) async {
    await _db.delete(
      'wage_role_rows',
      where: 'restaurant_id = ?',
      whereArgs: [restaurantId],
    );
  }
}
