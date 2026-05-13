// Lane B B8 — `audit_log_hierarchy_filter_p95_ms` perf probe.
//
// Predicate-style probe (NOT a full soak harness — the bucketing
// math is the artifact, the harness is one-shot from a runbook).
// Production wires [AuditLogHierarchyLatencyRecorder] to this
// recorder so every successful 200 from
// `GET /v1/admin/auth/audit-log/hierarchy` records one observation
// in the per-(operator_id, location_count_bucket) bucket. The deep
// `/health` envelope (or a future export slice) reads
// [AuditLogHierarchyLatencyRecorder.snapshot] to publish the gauge.
//
// Bucketing posture:
//   * `location_count` is the distinct count of `audit_logs.location_id`
//     values visible in the result page. A page that touches one
//     location buckets to 1; a page that touches 50 buckets to 50
//     (within bucket precision). This gives p95 a denominator the
//     operator can correlate with hierarchy depth.
//   * Buckets are powers of two so a 100-location operator does not
//     dilute the 1-location bucket. The default bucket boundaries are
//     `[1, 2, 4, 8, 16, 32, 64, 128, 256+]`.
//
// Determinism:
//   * The recorder takes an injectable `clock` so widget tests can
//     advance time without real waits.
//   * The recorder is process-local (no I/O, no Postgres). A future
//     slice may aggregate to a cluster-wide gauge; that work is out
//     of scope for B8.

/// Default location-count bucket boundaries. A measurement with
/// `location_count = 0` rolls into bucket "0"; `location_count = 1`
/// into bucket "1"; `location_count = 3` into bucket "4"; etc. The
/// last bucket ("256+") catches every count above 256 so a
/// pathological scope cannot flood a single bucket key.
const List<int> kAuditLogHierarchyLocationCountBuckets = <int>[
  1,
  2,
  4,
  8,
  16,
  32,
  64,
  128,
  256,
];

/// Resolves the bucket name for a given distinct-location count.
/// Returns `"0"` for zero, `"<boundary>"` for any positive count
/// that fits at or below a boundary, and `"<largest_boundary>+"` for
/// counts above the largest boundary. Public so unit tests can
/// assert the math directly.
String auditLogHierarchyLocationCountBucket(int count) {
  if (count <= 0) return '0';
  for (final boundary in kAuditLogHierarchyLocationCountBuckets) {
    if (count <= boundary) return boundary.toString();
  }
  final largest = kAuditLogHierarchyLocationCountBuckets.last;
  return '$largest+';
}

/// One observation captured by [AuditLogHierarchyLatencyRecorder].
class AuditLogHierarchyLatencySample {
  const AuditLogHierarchyLatencySample({
    required this.operatorId,
    required this.locationCountBucket,
    required this.elapsedMs,
    required this.recordedAt,
  });

  final String operatorId;
  final String locationCountBucket;
  final int elapsedMs;
  final DateTime recordedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'operator_id': operatorId,
        'location_count_bucket': locationCountBucket,
        'elapsed_ms': elapsedMs,
        'recorded_at': recordedAt.toUtc().toIso8601String(),
      };
}

/// Snapshot of the recorder's accumulated p95 / count per
/// (operator_id, location_count_bucket) bucket. The deep `/health`
/// envelope projects this onto the
/// `audit_log_hierarchy_filter_p95_ms{operator_id, location_count}`
/// gauge.
class AuditLogHierarchyLatencyBucketSnapshot {
  const AuditLogHierarchyLatencyBucketSnapshot({
    required this.operatorId,
    required this.locationCountBucket,
    required this.count,
    required this.p50Ms,
    required this.p95Ms,
    required this.maxMs,
  });

  final String operatorId;
  final String locationCountBucket;
  final int count;
  final int p50Ms;
  final int p95Ms;
  final int maxMs;

  Map<String, Object?> toJson() => <String, Object?>{
        'operator_id': operatorId,
        'location_count_bucket': locationCountBucket,
        'count': count,
        'p50_ms': p50Ms,
        'p95_ms': p95Ms,
        'max_ms': maxMs,
      };
}

/// In-process recorder. Bounded: each bucket retains the most-recent
/// [retainSamplesPerBucket] observations (default 1024) so a noisy
/// operator cannot grow the recorder's heap without bound. The
/// retained window also doubles as the rolling p95 input.
class AuditLogHierarchyLatencyRecorder {
  AuditLogHierarchyLatencyRecorder({
    DateTime Function()? clock,
    this.retainSamplesPerBucket = 1024,
  }) : _clock = clock ?? DateTime.now {
    if (retainSamplesPerBucket <= 0) {
      throw ArgumentError.value(
        retainSamplesPerBucket,
        'retainSamplesPerBucket',
        'must be positive',
      );
    }
  }

  final DateTime Function() _clock;
  final int retainSamplesPerBucket;

  // Keyed by "<operator_id>|<location_count_bucket>" — the composite
  // key keeps the snapshot iterator simple without nesting maps.
  final Map<String, List<int>> _bucketSamples = <String, List<int>>{};

  /// Record one observation. Public seam called by the production
  /// hook in `audit_log_hierarchy_routes.dart`.
  void record({
    required String operatorId,
    required int locationCount,
    required Duration elapsed,
  }) {
    final bucket = auditLogHierarchyLocationCountBucket(locationCount);
    final key = '$operatorId|$bucket';
    final bucketList = _bucketSamples.putIfAbsent(key, () => <int>[]);
    bucketList.add(elapsed.inMilliseconds);
    if (bucketList.length > retainSamplesPerBucket) {
      // Drop the oldest sample so the rolling window stays bounded.
      bucketList.removeAt(0);
    }
  }

  /// Project the current recorder state into per-bucket snapshots.
  /// Buckets with zero observations are omitted so a `/health`
  /// projection does not include phantom p95s.
  List<AuditLogHierarchyLatencyBucketSnapshot> snapshot() {
    final out = <AuditLogHierarchyLatencyBucketSnapshot>[];
    for (final entry in _bucketSamples.entries) {
      final samples = entry.value;
      if (samples.isEmpty) continue;
      final key = entry.key.split('|');
      if (key.length != 2) continue;
      final sorted = List<int>.from(samples)..sort();
      out.add(AuditLogHierarchyLatencyBucketSnapshot(
        operatorId: key[0],
        locationCountBucket: key[1],
        count: sorted.length,
        p50Ms: _percentileMs(sorted, 50),
        p95Ms: _percentileMs(sorted, 95),
        maxMs: sorted.last,
      ));
    }
    // Stable ordering: by operator, then bucket-as-int (ascending).
    out.sort((a, b) {
      final opCmp = a.operatorId.compareTo(b.operatorId);
      if (opCmp != 0) return opCmp;
      return _bucketSortKey(a.locationCountBucket)
          .compareTo(_bucketSortKey(b.locationCountBucket));
    });
    return out;
  }

  /// Reset every bucket. Useful for tests + admin debug paths.
  void clear() {
    _bucketSamples.clear();
  }

  /// Inspect the recorder's clock — surfaced so tests can build an
  /// [AuditLogHierarchyLatencySample] timestamp matching the bucket
  /// without reading `DateTime.now()` directly.
  DateTime now() => _clock();
}

/// Compute the percentile value (in ms) from a SORTED list of
/// observations. Uses linear interpolation between samples per the
/// inclusive p95 definition; returns 0 on an empty list.
int _percentileMs(List<int> sortedSamples, int percentile) {
  if (sortedSamples.isEmpty) return 0;
  if (sortedSamples.length == 1) return sortedSamples.first;
  final rank = (percentile / 100.0) * (sortedSamples.length - 1);
  final lowerIndex = rank.floor();
  final upperIndex = rank.ceil();
  if (lowerIndex == upperIndex) return sortedSamples[lowerIndex];
  final lower = sortedSamples[lowerIndex];
  final upper = sortedSamples[upperIndex];
  final fraction = rank - lowerIndex;
  return (lower + (upper - lower) * fraction).round();
}

/// Stable sort key for a bucket label. `"0"` < `"1"` < `"2"` < … <
/// `"256+"`. The trailing `+` is treated as the largest sort
/// position so it always lands at the end of an operator's row group.
int _bucketSortKey(String label) {
  if (label.endsWith('+')) return 1 << 30;
  return int.tryParse(label) ?? 0;
}
