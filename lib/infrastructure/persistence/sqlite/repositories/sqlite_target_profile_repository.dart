import '../../../../domain/models/active_target_profile.dart';
import '../../../../domain/models/target_profile_version.dart';
import '../../../../domain/repositories/target_profile_repository.dart';
import '../dao/target_profile_dao.dart';
import '../sqlite_database.dart';

class SqliteTargetProfileRepository implements TargetProfileRepository {
  SqliteTargetProfileRepository._();
  static final SqliteTargetProfileRepository instance =
      SqliteTargetProfileRepository._();

  TargetProfileDao? _dao;

  Future<TargetProfileDao> get _daoReady async {
    if (_dao != null) return _dao!;
    final db = await SqliteDatabase.instance.database;
    _dao = TargetProfileDao(db);
    return _dao!;
  }

  @override
  Future<ActiveTargetProfile?> getActiveTargetProfile(
      String restaurantId) async {
    final dao = await _daoReady;
    return dao.getActiveTargetProfile(restaurantId);
  }

  @override
  Future<void> upsertActiveTargetProfile(ActiveTargetProfile profile) async {
    final dao = await _daoReady;
    return dao.upsertActiveTargetProfile(profile);
  }

  @override
  Future<void> insertTargetProfileVersion(
      TargetProfileVersion version) async {
    final dao = await _daoReady;
    return dao.insertTargetProfileVersion(version);
  }

  @override
  Future<TargetProfileVersion?> getTargetProfileVersion(
      String restaurantId, String versionId) async {
    final dao = await _daoReady;
    return dao.getTargetProfileVersion(restaurantId, versionId);
  }
}
