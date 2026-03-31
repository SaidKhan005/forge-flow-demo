import '../models/active_target_profile.dart';
import '../models/target_profile_version.dart';

abstract class TargetProfileRepository {
  Future<ActiveTargetProfile?> getActiveTargetProfile(String restaurantId);
  Future<void> upsertActiveTargetProfile(ActiveTargetProfile profile);
  Future<void> insertTargetProfileVersion(TargetProfileVersion version);
  Future<TargetProfileVersion?> getTargetProfileVersion(
      String restaurantId, String versionId);
}
