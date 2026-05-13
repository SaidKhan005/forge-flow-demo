// Forge & Flow — MockReplayDataSourceProvider adapter.
//
// 7.57.3a foundation slice. Concrete `DataSourceProvider<MockReplayOutput>`
// that wraps the existing `MockIntegrationReplaySeed` writer behind the
// generic data-source interface.
//
// This slice is wrap-only: every value, list order, default business
// date, and replay output is whatever `MockIntegrationReplaySeed`
// produces today. Phase 8 vendor connectors will implement the same
// interface so `kDemoMode = true` -> this provider, `kDemoMode = false`
// -> a vendor provider, with no other code-path branching.

import '../dev/mock_integration_replay_seed.dart';
import '../domain/services/advisor_provider_constants.dart';
import '../domain/services/data_source_provider.dart';

/// Convenience alias for `DataSourceProvider<MockReplayOutput>`. Lets
/// downstream callers (e.g. `StaticShiftDataSource`) depend on the
/// provider seam without re-importing the seed file just to spell the
/// type parameter (7.57.3c).
typedef MockReplayProvider = DataSourceProvider<MockReplayOutput>;

class MockReplayDataSourceProvider
    implements DataSourceProvider<MockReplayOutput> {
  const MockReplayDataSourceProvider();

  @override
  String get providerId => AdvisorProviderConstants.mockReplayProviderId;

  @override
  String get sourceSystem => MockIntegrationReplaySeed.sourceSystem;

  /// Default business date the wrapped writer falls back to. Surfaced
  /// here so callers (and tests) do not have to import
  /// `MockIntegrationReplaySeed` directly through the provider seam.
  String get defaultBusinessDate =>
      MockIntegrationReplaySeed.defaultBusinessDate;

  @override
  Future<MockReplayOutput> fetch({String? businessDate}) async {
    final date = businessDate ?? MockIntegrationReplaySeed.defaultBusinessDate;
    return MockIntegrationReplaySeed.generateForDate(date);
  }
}
