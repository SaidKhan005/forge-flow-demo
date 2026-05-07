// Phase 8.0 (V1 lean cut 2) — MetricState + MetricProvenance.
//
// Per `docs/contracts/metric_card_honesty_contract.md`. Every load-
// bearing operator-trust metric (CPLH / SPLH / PPA / blended wage /
// covers / hours / sales / labor dollars) carries a [MetricState] +
// `provenance` string alongside the numeric value so renderers can
// switch on state instead of silently rendering phantom zeroes.
//
// Pure data; I/O free. Producers (`shift_fact_builder.dart`,
// `shift_dashboard_read_model.dart`) populate; consumers
// (`shift_dashboard.dart`, variance tabs) read state + dispatch
// to either the normal `MetricCardWidget` (live / partial /
// fallback all render the number, identical chrome) or
// `MetricCardNotYetAvailable` (unavailable).

/// Closed cardinality. State + provenance pairing rules per the
/// contract:
///
///   * `live`        ⟹ provenance names a vendor.
///   * `partial`     ⟹ provenance names a vendor + partial qualifier.
///   * `fallback`    ⟹ provenance names the substitution source.
///   * `unavailable` ⟹ provenance is `provenanceNone`.
///
/// Additional states for [MetricPill] widget surface:
///   * `stale`       ⟹ data previously live; vendor sync lapsed.
///   * `empty`       ⟹ vendor connected but no rows yet (new operator).
///   * `demo`        ⟹ demo / seed data, not real operator numbers.
enum MetricState {
  /// Vendor data flowing, all required inputs present, computation
  /// is the real number.
  live,

  /// Some inputs present, some missing or in-flight (e.g., 6 of 8
  /// shifts pulled). Computation is the real number for the inputs
  /// we have. Rendered identical to `live` on the card; only the
  /// dashboard pill summarises the gap.
  partial,

  /// Required inputs not exposed by the vendor; we substituted from
  /// app forecast or target snapshot. Computation is an estimate.
  /// Rendered identical to `live` on the card; pill summarises.
  fallback,

  /// No inputs present, computation is undefined. The renderer MUST
  /// switch to `MetricCardNotYetAvailable` / `MetricPill` empty state.
  /// Never a phantom zero.
  unavailable,

  // ── Additional states used by [MetricPill] ───────────────────────

  /// Data was previously live but the vendor sync has lapsed (e.g.,
  /// last successful pull > threshold ago). The stale value is still
  /// shown but visually flagged; never silently treated as fresh.
  stale,

  /// Vendor is connected and healthy but has returned zero rows for
  /// this metric (e.g., a brand-new operator who opened yesterday).
  /// Distinct from [unavailable]: the pipeline is wired; the data
  /// simply has not accumulated yet. Renders "No data yet" — never
  /// a numeric zero.
  empty,

  /// Value comes from seeded demo data, not from real operator
  /// operations. Renders the number with a visible "Demo" chip so
  /// the operator is never confused about provenance.
  demo,
}

/// Sentinel provenance for `unavailable` state.
const String provenanceNone = 'none';

/// Metric value + state + provenance triple. Producers emit one of
/// these per metric they expose at the read-model boundary;
/// renderers consume it.
///
/// `value` is null when [state] == [MetricState.unavailable] —
/// renderers MUST honor that by switching to
/// `MetricCardNotYetAvailable`. The numeric type is intentionally
/// `num?` (not `double`) so integer-valued metrics like covers /
/// hours stay integers; renderers format on display.
class MetricProvenance {
  const MetricProvenance({
    required this.value,
    required this.state,
    required this.provenance,
  })  : assert(
          (state == MetricState.unavailable && value == null) ||
              (state != MetricState.unavailable && value != null),
          'value must be null iff state == unavailable',
        ),
        assert(
          (state == MetricState.unavailable && provenance == provenanceNone) ||
              (state != MetricState.unavailable &&
                  provenance != provenanceNone),
          'provenance must be `none` iff state == unavailable',
        );

  /// Convenience constructor for the `unavailable` shape. Mirrors
  /// the `LeverCardNotYetAvailable` sentinel pattern from 7.58.
  const MetricProvenance.unavailable()
      : value = null,
        state = MetricState.unavailable,
        provenance = provenanceNone;

  /// Convenience constructor for the `live` shape.
  const MetricProvenance.live({
    required num this.value,
    required this.provenance,
  })  : state = MetricState.live,
        assert(provenance != provenanceNone, 'live must name a vendor');

  /// Convenience constructor for the `partial` shape.
  const MetricProvenance.partial({
    required num this.value,
    required this.provenance,
  })  : state = MetricState.partial,
        assert(
          provenance != provenanceNone,
          'partial must name a vendor + partial qualifier',
        );

  /// Convenience constructor for the `fallback` shape.
  const MetricProvenance.fallback({
    required num this.value,
    required this.provenance,
  })  : state = MetricState.fallback,
        assert(
          provenance != provenanceNone,
          'fallback must name the substitution source',
        );

  final num? value;
  final MetricState state;

  /// Open enum (free-form short string). Examples per the contract:
  ///
  ///   * `vendor_lightspeed_lsk`
  ///   * `vendor_square_with_forecast_covers`
  ///   * `vendor_quickbooks_time_partial_sync`
  ///   * `app_forecast_60_day_avg`
  ///   * `target_snapshot`
  ///   * `none`
  ///
  /// Used by Codex review, debugging tools, and the future advisor;
  /// not rendered on operator dashboards except inside the
  /// `DataSourceHealthPill` detail sheet.
  final String provenance;

  /// True when the contract says "render the number, clean, brand
  /// color, normal weight" — that is, every state except
  /// `unavailable`.
  bool get rendersNumber => state != MetricState.unavailable;

  /// True when the contract says the dashboard pill MUST mention
  /// this metric.
  bool get isDegraded => state != MetricState.live;

  @override
  String toString() =>
      'MetricProvenance(state=${state.name}, provenance=$provenance, value=$value)';

  @override
  bool operator ==(Object other) {
    return other is MetricProvenance &&
        other.value == value &&
        other.state == state &&
        other.provenance == provenance;
  }

  @override
  int get hashCode => Object.hash(value, state, provenance);
}
