// Phase 11A.UX.health (F.1) - Typed parsers for the proxy /health envelope.
//
// The proxy `/health` route ships a stable JSON envelope contracted by
// `docs/contracts/proxy_health_contract.md`:
//
//   {
//     "status": "ok|degraded|unavailable",
//     "severity": "green|yellow|red|unknown",
//     "contract": "proxy_health.v1",
//     "schema_version": 1,
//     "checked_at": "<RFC3339 UTC>",
//     "dependencies": { "postgres": {...}, "age": {...}, "pgvector": {...} },
//     "surfaces": { "<name>": { "status": ..., "metrics": [...], "owner": ... } },
//     "metrics": { "<key>": { "status": ..., "value": ..., "tier": ..., ... } },
//     "warnings": [...]
//   }
//
// The envelope MUST NOT carry tenant or operator identifiers - the
// admin Health surface is platform-wide and the contract is explicit
// about the absence of those identifiers. Parsing keeps that property:
// these models surface only the fields the contract declares.

import 'package:flutter/foundation.dart';

/// Severity buckets used both by the proxy contract and by tile/banner
/// rendering.
enum HealthSeverity { green, yellow, red, unknown }

HealthSeverity parseHealthSeverity(Object? raw) {
  if (raw is! String) return HealthSeverity.unknown;
  switch (raw.toLowerCase()) {
    case 'green':
    case 'ok':
      return HealthSeverity.green;
    case 'yellow':
    case 'degraded':
      return HealthSeverity.yellow;
    case 'red':
    case 'unavailable':
      return HealthSeverity.red;
    default:
      return HealthSeverity.unknown;
  }
}

/// Single dependency probe ([postgres], [age], [pgvector]). A failed
/// probe makes the response `unavailable` and the proxy returns 503;
/// the gateway promotes that to [HealthEnvelope.dependenciesUnavailable]
/// so the screen can render the top-of-page red banner regardless of
/// the body the proxy returned.
@immutable
class HealthDependency {
  const HealthDependency({
    required this.name,
    required this.status,
    required this.check,
    this.legacyKey,
  });

  final String name;
  final HealthSeverity status;
  final String check;
  final String? legacyKey;

  factory HealthDependency.fromJson(String name, Map<String, Object?> json) {
    return HealthDependency(
      name: name,
      status: parseHealthSeverity(json['status']),
      check: (json['check'] as String?) ?? '',
      legacyKey: json['legacy_key'] as String?,
    );
  }
}

/// Single metric tile in the Health surface. `tier` is read from
/// `metadata.tier` per the proxy contract - tier-1 producers drive
/// the red top-banner; tier-2 producers drive yellow tile chips;
/// tier-3 producers drive grey informational chips.
@immutable
class HealthMetric {
  const HealthMetric({
    required this.key,
    required this.status,
    required this.unit,
    required this.description,
    required this.owner,
    required this.tier,
    required this.value,
    this.source,
    this.observedAt,
    this.thresholds = const <String, Object?>{},
    this.metadata = const <String, Object?>{},
  });

  final String key;
  final HealthSeverity status;
  final String unit;
  final String description;
  final String owner;
  final int tier;
  final Object? value;
  final String? source;
  final DateTime? observedAt;
  final Map<String, Object?> thresholds;
  final Map<String, Object?> metadata;

  /// Tile chip colour rule from the F.1 prompt: tier 1 fail → red
  /// banner is rendered separately by the screen; tile chip itself is
  /// red for tier-1 fails so the operator can locate the failing
  /// signal inside the tab.
  bool get isFailing =>
      status == HealthSeverity.red || status == HealthSeverity.yellow;

  /// String form of [value] suitable for tile rendering. Falls through
  /// to `'-'` when the metric has not been populated yet (`null`) and
  /// to JSON-ish for maps/lists so parsing problems surface visibly.
  String get displayValue {
    final v = value;
    if (v == null) return '-';
    if (v is num) return v.toString();
    if (v is bool) return v ? 'true' : 'false';
    if (v is String) return v;
    return v.toString();
  }

  /// One-line threshold caption for the tile body.
  String? get thresholdCaption {
    if (thresholds.isEmpty) return null;
    final parts = <String>[];
    for (final entry in thresholds.entries) {
      parts.add('${entry.key}: ${entry.value}');
    }
    return parts.join(' · ');
  }

  factory HealthMetric.fromJson(String key, Map<String, Object?> json) {
    final metadata =
        (json['metadata'] as Map?)?.cast<String, Object?>() ??
        const <String, Object?>{};
    return HealthMetric(
      key: key,
      status: parseHealthSeverity(json['status']),
      unit: (json['unit'] as String?) ?? '',
      description: (json['description'] as String?) ?? '',
      owner: (json['owner'] as String?) ?? '',
      tier: _parseTier(metadata['tier']),
      value: json['value'],
      source: json['source'] as String?,
      observedAt: _parseUtc(json['observed_at']),
      thresholds:
          (json['thresholds'] as Map?)?.cast<String, Object?>() ??
          const <String, Object?>{},
      metadata: metadata,
    );
  }
}

@immutable
class HealthSurface {
  const HealthSurface({
    required this.name,
    required this.status,
    required this.metricKeys,
    required this.owner,
  });

  final String name;
  final HealthSeverity status;
  final List<String> metricKeys;
  final String owner;

  factory HealthSurface.fromJson(String name, Map<String, Object?> json) {
    final raw = (json['metrics'] as List?) ?? const <Object?>[];
    return HealthSurface(
      name: name,
      status: parseHealthSeverity(json['status']),
      metricKeys: <String>[
        for (final m in raw)
          if (m is String) m,
      ],
      owner: (json['owner'] as String?) ?? '',
    );
  }
}

/// Whole `/health` envelope as the admin screen needs it.
///
/// [dependenciesUnavailable] is `true` when the gateway saw an HTTP
/// 503 - the screen renders a top-of-page red "Dependencies
/// unavailable" banner regardless of which dependency probe was the
/// failure (and the `metrics`/`surfaces` maps may still have data the
/// proxy assembled before the failing dependency tipped the response
/// to 503; the screen still renders them).
@immutable
class HealthEnvelope {
  const HealthEnvelope({
    required this.status,
    required this.severity,
    required this.contract,
    required this.schemaVersion,
    required this.checkedAt,
    required this.dependencies,
    required this.surfaces,
    required this.metrics,
    required this.dependenciesUnavailable,
  });

  final String status;
  final HealthSeverity severity;
  final String contract;
  final int schemaVersion;
  final DateTime? checkedAt;
  final List<HealthDependency> dependencies;
  final Map<String, HealthSurface> surfaces;
  final Map<String, HealthMetric> metrics;

  /// True iff the gateway saw HTTP 503 on the most recent fetch.
  /// Drives the screen's top "Dependencies unavailable" banner.
  final bool dependenciesUnavailable;

  /// Returns metrics whose [HealthMetric.tier] matches [tier]. Used by
  /// the top-of-page banner ("any tier-1 fail") and by tile chips.
  Iterable<HealthMetric> metricsAtTier(int tier) =>
      metrics.values.where((m) => m.tier == tier);

  /// Convenience: the screen renders the red banner whenever
  /// dependencies are unavailable OR any tier-1 metric is failing.
  bool get hasTier1Failure {
    if (dependenciesUnavailable) return true;
    for (final dep in dependencies) {
      if (dep.status == HealthSeverity.red ||
          dep.status == HealthSeverity.yellow) {
        return true;
      }
    }
    return metricsAtTier(1).any((m) => m.isFailing);
  }

  bool get hasTier2Failure => metricsAtTier(2).any((m) => m.isFailing);

  factory HealthEnvelope.fromJson(
    Map<String, Object?> json, {
    bool dependenciesUnavailable = false,
  }) {
    final depsRaw =
        (json['dependencies'] as Map?)?.cast<String, Object?>() ??
        const <String, Object?>{};
    final surfRaw =
        (json['surfaces'] as Map?)?.cast<String, Object?>() ??
        const <String, Object?>{};
    final metricsRaw =
        (json['metrics'] as Map?)?.cast<String, Object?>() ??
        const <String, Object?>{};
    return HealthEnvelope(
      status: (json['status'] as String?) ?? 'unknown',
      severity: parseHealthSeverity(json['severity']),
      contract: (json['contract'] as String?) ?? '',
      schemaVersion: _parseInt(json['schema_version']) ?? 0,
      checkedAt: _parseUtc(json['checked_at']),
      dependencies: <HealthDependency>[
        for (final entry in depsRaw.entries)
          if (entry.value is Map)
            HealthDependency.fromJson(
              entry.key,
              (entry.value! as Map).cast<String, Object?>(),
            ),
      ],
      surfaces: <String, HealthSurface>{
        for (final entry in surfRaw.entries)
          if (entry.value is Map)
            entry.key: HealthSurface.fromJson(
              entry.key,
              (entry.value! as Map).cast<String, Object?>(),
            ),
      },
      metrics: <String, HealthMetric>{
        for (final entry in metricsRaw.entries)
          if (entry.value is Map)
            entry.key: HealthMetric.fromJson(
              entry.key,
              (entry.value! as Map).cast<String, Object?>(),
            ),
      },
      dependenciesUnavailable: dependenciesUnavailable,
    );
  }
}

int? _parseInt(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw);
  return null;
}

int _parseTier(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw) ?? 3;
  return 3;
}

DateTime? _parseUtc(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  final parsed = DateTime.tryParse(raw);
  return parsed?.toUtc();
}
