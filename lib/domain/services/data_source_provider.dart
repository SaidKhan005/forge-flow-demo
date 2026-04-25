// Forge & Flow — DataSourceProvider<T> interface.
//
// 7.57.3a foundation slice. Generic source abstraction so kDemoMode and
// future Phase 8 vendor connectors share a single seam.
//
// Today the only concrete implementation is `MockReplayDataSourceProvider`
// (kDemoMode = true). Phase 8 adds vendor connectors (e.g. Toast POS,
// 7shifts labor) implementing this same interface so screens never
// branch on `kDemoMode` — the writer is the only thing that changes.

abstract class DataSourceProvider<T> {
  /// Stable provider id (e.g. `mock_replay`, future `toast_pos`).
  /// Recorded on persisted source rows for provenance.
  String get providerId;

  /// Source-system identifier the provider populates SQLite with
  /// (e.g. `MockIntegrationReplaySeed.sourceSystem`).
  String get sourceSystem;

  /// Fetch the source-system output for the given business date.
  ///
  /// Implementations should default to a provider-defined "current"
  /// business date when [businessDate] is null. The mock-replay provider
  /// uses `MockIntegrationReplaySeed.defaultBusinessDate`; vendor
  /// providers will use the live restaurant business date once Phase 8
  /// wires them up.
  Future<T> fetch({String? businessDate});
}
