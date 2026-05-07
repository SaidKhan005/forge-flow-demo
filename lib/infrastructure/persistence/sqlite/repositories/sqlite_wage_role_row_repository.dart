import '../../../../domain/models/wage_role_row.dart';
import '../dao/wage_role_row_dao.dart';
import '../sqlite_database.dart';

class SqliteWageRoleRowRepository {
  SqliteWageRoleRowRepository._();
  static final SqliteWageRoleRowRepository instance =
      SqliteWageRoleRowRepository._();

  WageRoleRowDao? _dao;

  Future<WageRoleRowDao> get _daoReady async {
    if (_dao != null) return _dao!;
    final db = await SqliteDatabase.instance.database;
    _dao = WageRoleRowDao(db);
    return _dao!;
  }

  Future<List<WageRoleRow>> getRows(String restaurantId) async {
    final dao = await _daoReady;
    return dao.getRows(restaurantId);
  }

  Future<void> upsertRow(WageRoleRow row) async {
    final dao = await _daoReady;
    return dao.upsertRow(row);
  }

  Future<bool> replaceAll(String restaurantId, List<WageRoleRow> rows) async {
    final dao = await _daoReady;
    return dao.replaceAll(restaurantId, rows);
  }

  Future<void> deleteRow(int id) async {
    final dao = await _daoReady;
    return dao.deleteRow(id);
  }

  Future<void> deleteAll(String restaurantId) async {
    final dao = await _daoReady;
    return dao.deleteAll(restaurantId);
  }

  Future<void> wipeForOtherScopes(String keepRestaurantId) async {
    final dao = await _daoReady;
    return dao.wipeForOtherScopes(keepRestaurantId);
  }
}
