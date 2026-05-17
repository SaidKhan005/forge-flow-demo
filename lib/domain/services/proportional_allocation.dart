// Per-Daypart Targets V1 (bottom-up locked snapshot) — shared
// proportional-allocation helper.
//
// This is the single source of truth for largest-remainder integer
// allocation. The locked weekly-plan snapshot writer
// (`weekly_plan_snapshot_service.dart`) and the daypart plan allocator
// (`daypart_plan_allocator.dart`) both delegate here so a day's
// forecast covers split across service periods exactly once, the same
// way, with `Σ(parts) == total` guaranteed by construction.
//
// Pure: no I/O, no globals, deterministic. The core
// (`_largestRemainderCore`) is ported byte-for-byte from the original
// allocator implementation so behaviour is identical to the prior
// Schedule distribution math.
library;

/// Largest-remainder allocation of [total] across integer [weights].
///
/// Floors `total * w / Σweights` for each weight, then distributes the
/// leftover units to the slots with the largest fractional parts.
///
/// Guarantees `sum(result) == total`. Returns a list of zeros (same
/// length as [weights]) when all weights are zero, so a degenerate
/// no-evidence period set never invents covers.
List<int> allocateLargestRemainderInt(int total, List<int> weights) {
  final weightSum = weights.fold<int>(0, (s, v) => s + v);
  if (weightSum == 0) return List.filled(weights.length, 0);
  final fractional = weights.map((w) => total * w / weightSum).toList();
  return largestRemainderCore(total, fractional);
}

/// Largest-remainder allocation of [total] across double [shares].
///
/// Same construction as [allocateLargestRemainderInt] but weighted by
/// arbitrary non-negative doubles (e.g. per-period sales when BOH hours
/// follow sales, not covers). Guarantees `sum(result) == total`.
List<int> allocateLargestRemainderByDouble(int total, List<double> shares) {
  final shareSum = shares.fold<double>(0, (s, v) => s + v);
  if (shareSum == 0) return List.filled(shares.length, 0);
  final fractional = shares.map((s) => total * s / shareSum).toList();
  return largestRemainderCore(total, fractional);
}

/// Proportional double split of [total] across integer [weights].
///
/// Returns doubles that sum exactly to [total] (subject to
/// floating-point precision) by assigning the rounding remainder to the
/// final slot.
List<double> allocateProportionalDoubles(double total, List<int> weights) {
  final weightSum = weights.fold<int>(0, (s, v) => s + v);
  if (weightSum == 0 || total == 0) {
    return List.filled(weights.length, 0.0);
  }
  final values = List<double>.filled(weights.length, 0.0);
  double assigned = 0;
  for (var i = 0; i < weights.length; i++) {
    if (i == weights.length - 1) {
      values[i] = total - assigned;
    } else {
      final share = total * weights[i] / weightSum;
      values[i] = share;
      assigned += share;
    }
  }
  return values;
}

/// Core largest-remainder: floor each fractional value, then
/// distribute remaining units to the slots with the largest fractional
/// parts.
///
/// Ported byte-for-byte from
/// `daypart_plan_allocator.dart#_largestRemainderCore` so the shared
/// helper and the legacy allocator stay behaviourally identical.
List<int> largestRemainderCore(int total, List<double> fractional) {
  final floors = fractional.map((f) => f.floor()).toList();
  var remainder = total - floors.fold<int>(0, (s, v) => s + v);
  final remainders = List.generate(
      fractional.length, (i) => (i, fractional[i] - floors[i]));
  remainders.sort((a, b) => b.$2.compareTo(a.$2));
  for (final entry in remainders) {
    if (remainder <= 0) break;
    floors[entry.$1] += 1;
    remainder -= 1;
  }
  return floors;
}
