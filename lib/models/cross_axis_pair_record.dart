// 7.58.cross-axis.0 — recurring CPLH x SPLH pair pattern record.
//
// One entry per cell in the cross-axis matrix that the analyzer
// observes recurring across the closed-shift history window. The
// `pairId` matches a `CrossAxisPairData.id` in
// `lib/data/cross_axis_pair_catalog.dart`; consumers resolve the
// catalog entry through `CrossAxisPairs.lookup`.
//
// Authority: `docs/contracts/phase_7_58_primary_driver_contract.md`
// "Depth Surfaces" addendum + `docs/phases/phase_7_58/
// phase_7_58_depth_wave_plan.md` `7.58.cross-axis.0` row.

class CrossAxisPairRecord {
  final String pairId;
  final int count;
  final List<String> topDayparts;

  const CrossAxisPairRecord({
    required this.pairId,
    required this.count,
    required this.topDayparts,
  });
}
