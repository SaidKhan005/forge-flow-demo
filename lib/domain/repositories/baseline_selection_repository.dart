abstract class BaselineSelectionRepository {
  Future<Set<String>> getSelectedRecordKeys(String restaurantId);
  Future<void> replaceSelectedRecordKeys(
      String restaurantId, Set<String> keys);
}
