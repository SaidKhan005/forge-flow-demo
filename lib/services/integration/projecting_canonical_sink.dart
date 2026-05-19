// Phase 8 `8.post-commit-projector-wire-in` — ProjectingCanonicalSink.
//
// Closes the gap where canonical fact writes never triggered
// `open_shift_snapshots` / `closed_shift_aggregates` projection in
// production. Wraps any [CanonicalSink] so that every successful
// canonical fact upsert + each batch-commit signal drains accumulated
// fact maps into [CanonicalFactPostCommitProjector.project].
//
// Design rationale (Authority Order #1 — active prompt):
//
//   * Option A from the prompt: synchronous wrapper around an existing
//     [CanonicalSink]. No new abstract surface on [CanonicalSink], no
//     observer streams, no polling watermarks.
//   * Underlying sink writes are forwarded verbatim. The wrapper only
//     side-effects after a successful underlying write — a thrown
//     underlying call short-circuits before any projector invocation.
//   * Projector failure is logged at WARNING but never propagated to
//     the caller. A single failed projection MUST NOT fail a canonical
//     fact write or the parent backfill / poll batch.
//   * Per-(operator, location, vendor, connection, category) buffers
//     guarantee tenant isolation (Hard Promise #4) — buffers never
//     cross tenant tuples even if the same wrapper instance is shared
//     across operators (the production binder shares one wrapper per
//     vendor sink across all operators).
//
// The wrapper requires a [CanonicalFactPeriodResolver] callback that
// converts a canonical fact map into a [CanonicalFactCommittedPeriod].
// The resolver is the only piece of context the wrapper cannot derive
// from the fact map alone (it owns service-period definitions, business
// timing profile id resolution, weekly week-id calc). Production wires a
// real resolver; tests inject a deterministic stub.

import 'dart:async';

import '../observability/log.dart';
import 'canonical_fact_post_commit_projector.dart';
import 'canonical_sink.dart';
import 'integration_adapter_common.dart';

/// Resolves a canonical fact map (the dictionary the adapter passes
/// into [CanonicalSink.upsertCoverFact] / `upsertLaborPunch` /
/// `upsertReservationFact`) into a [CanonicalFactCommittedPeriod] that
/// the post-commit projector can act on.
///
/// Returning `null` means the wrapper drops the fact from the
/// projection batch (e.g. the fact lacks `business_date` or
/// `service_period_key`). The wrapper does NOT throw on null — a null
/// resolver result is legitimate for backfill rows that the
/// post-commit projector cannot yet reason about.
typedef CanonicalFactPeriodResolver =
    FutureOr<CanonicalFactCommittedPeriod?> Function({
      required String operatorId,
      required String locationId,
      required IntegrationCategory category,
      required String vendorId,
      required String connectionId,
      required Map<String, Object?> canonicalFact,
    });

/// Resolves the canonical `restaurant_id` for an `(operatorId,
/// locationId)` tuple. The post-commit projector input requires it
/// alongside the operator/location pair. The resolver is a callback so
/// the wrapper has no Postgres dependency.
typedef CanonicalRestaurantIdResolver =
    FutureOr<String> Function({
      required String operatorId,
      required String locationId,
    });

/// Sync-log event kinds that signal "this batch committed". The
/// wrapper drains accumulated facts into the projector when the
/// underlying [CanonicalSink.appendSyncLog] is called with one of
/// these.
const Set<String> kProjectingCanonicalSinkCommitEventKinds = <String>{
  'backfill_success',
  'backfill_partial',
  'poll_success',
  'webhook_received',
};

/// Fact-write observer used by direct vendor sink methods that do not
/// enter through the unified [CanonicalSink] interface.
abstract interface class CanonicalFactProjectionTap {
  void recordCommittedCoverFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  });

  void recordCommittedLaborPunch({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalPunch,
  });

  void recordCommittedReservationFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalReservation,
  });

  Future<void> drainCommittedFacts({
    required String operatorId,
    required String locationId,
    required String connectionId,
  });
}

/// Drains the tap for the vendor that just committed a batch.
class CanonicalFactProjectionCommitDrainer {
  const CanonicalFactProjectionCommitDrainer({
    required Map<String, CanonicalFactProjectionTap> tapsByVendor,
  }) : _tapsByVendor = tapsByVendor;

  final Map<String, CanonicalFactProjectionTap> _tapsByVendor;

  int get tapCount => _tapsByVendor.length;

  bool hasTapForVendor(String vendorId) => _tapsByVendor.containsKey(vendorId);

  Future<void> drainIfCommitEvent({
    required String vendorId,
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String eventKind,
  }) async {
    if (!kProjectingCanonicalSinkCommitEventKinds.contains(eventKind)) {
      return;
    }
    final tap = _tapsByVendor[vendorId];
    if (tap == null) return;
    await tap.drainCommittedFacts(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
    );
  }
}

/// Standalone projection tap for direct vendor sink methods.
class BufferedCanonicalFactProjectionTap implements CanonicalFactProjectionTap {
  BufferedCanonicalFactProjectionTap({
    required CanonicalFactPostCommitProjector projector,
    required IntegrationCategory category,
    required String vendorId,
    required CanonicalFactPeriodResolver periodResolver,
    required CanonicalRestaurantIdResolver restaurantIdResolver,
    String? userIdOverride,
  }) : _projector = projector,
       _category = category,
       _vendorId = vendorId,
       _periodResolver = periodResolver,
       _restaurantIdResolver = restaurantIdResolver,
       _userIdOverride = userIdOverride;

  final CanonicalFactPostCommitProjector _projector;
  final IntegrationCategory _category;
  final String _vendorId;
  final CanonicalFactPeriodResolver _periodResolver;
  final CanonicalRestaurantIdResolver _restaurantIdResolver;
  final String? _userIdOverride;

  final Map<_BufferKey, _PendingFactBuffer> _buffers =
      <_BufferKey, _PendingFactBuffer>{};

  @override
  void recordCommittedCoverFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  }) {
    _accumulate(
      operatorId: operatorId,
      locationId: locationId,
      canonicalFact: canonicalFact,
      factType: 'cover_fact',
    );
  }

  @override
  void recordCommittedLaborPunch({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalPunch,
  }) {
    _accumulate(
      operatorId: operatorId,
      locationId: locationId,
      canonicalFact: canonicalPunch,
      factType: 'labor_punch',
    );
  }

  @override
  void recordCommittedReservationFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalReservation,
  }) {
    _accumulate(
      operatorId: operatorId,
      locationId: locationId,
      canonicalFact: canonicalReservation,
      factType: 'reservation_fact',
    );
  }

  @override
  Future<void> drainCommittedFacts({
    required String operatorId,
    required String locationId,
    required String connectionId,
  }) async {
    final buffers = <_PendingFactBuffer>[];
    final exact = _buffers.remove(
      _BufferKey(
        operatorId: operatorId,
        locationId: locationId,
        connectionId: connectionId,
      ),
    );
    if (exact != null) buffers.add(exact);
    if (connectionId.isNotEmpty) {
      final unkeyed = _buffers.remove(
        _BufferKey(
          operatorId: operatorId,
          locationId: locationId,
          connectionId: '',
        ),
      );
      if (unkeyed != null) buffers.add(unkeyed);
    }
    if (buffers.isEmpty || buffers.every((buffer) => buffer.facts.isEmpty)) {
      return;
    }
    final facts = <Map<String, Object?>>[
      for (final buffer in buffers) ...buffer.facts,
    ];
    try {
      final periods = <CanonicalFactCommittedPeriod>[];
      final openCurrentFacts = <Map<String, Object?>>[];
      final seenIdentities = <String>{};
      for (final fact in facts) {
        final period = await _periodResolver(
          operatorId: operatorId,
          locationId: locationId,
          category: _category,
          vendorId: _vendorId,
          connectionId: connectionId,
          canonicalFact: fact,
        );
        if (period == null) continue;
        if (seenIdentities.add(period.periodIdentity)) {
          periods.add(period);
        }
        if (period.state == CanonicalFactPeriodState.openCurrent) {
          openCurrentFacts.add(fact);
        }
      }
      if (periods.isEmpty) return;
      final restaurantId = await _restaurantIdResolver(
        operatorId: operatorId,
        locationId: locationId,
      );
      await _projector.project(
        CanonicalFactPostCommitInput(
          operatorId: operatorId,
          locationId: locationId,
          restaurantId: restaurantId,
          integrationCategory: _category,
          vendorId: _vendorId,
          connectionId: connectionId,
          changedPeriods: periods,
          openCurrentFactMaps: openCurrentFacts,
          userId: _userIdOverride,
        ),
      );
    } catch (error, stack) {
      log(
        LogSeverity.warning,
        'projecting_canonical_sink.projector_failed',
        fields: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'connection_id': connectionId,
          'integration_category': _category.name,
          'vendor_id': _vendorId,
          'error_class': error.runtimeType.toString(),
          'error_message': error.toString(),
          'stack_first_frame': firstStackFrame(stack),
          'fact_count': facts.length,
        },
      );
    }
  }

  void _accumulate({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
    required String factType,
  }) {
    final connectionId = _stringValue(canonicalFact['connection_id']) ?? '';
    final key = _BufferKey(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
    );
    final buffer = _buffers.putIfAbsent(key, _PendingFactBuffer.new);
    buffer.facts.add(
      Map<String, Object?>.unmodifiable(<String, Object?>{
        ...canonicalFact,
        'operator_id': canonicalFact['operator_id'] ?? operatorId,
        'location_id': canonicalFact['location_id'] ?? locationId,
        'connection_id': canonicalFact['connection_id'] ?? connectionId,
        'fact_type': canonicalFact['fact_type'] ?? factType,
        'source_system': canonicalFact['source_system'] ?? _vendorId,
      }),
    );
  }
}

/// Wraps a [CanonicalSink] so successful canonical fact writes drive
/// [CanonicalFactPostCommitProjector] invocation after each batch
/// commit. See file-header for the contract.
class ProjectingCanonicalSink
    implements CanonicalSink, CanonicalFactProjectionTap {
  ProjectingCanonicalSink({
    required CanonicalSink underlying,
    required CanonicalFactPostCommitProjector projector,
    required IntegrationCategory category,
    required String vendorId,
    required CanonicalFactPeriodResolver periodResolver,
    required CanonicalRestaurantIdResolver restaurantIdResolver,
    String? userIdOverride,
  }) : _underlying = underlying,
       _projector = projector,
       _category = category,
       _vendorId = vendorId,
       _periodResolver = periodResolver,
       _restaurantIdResolver = restaurantIdResolver,
       _userIdOverride = userIdOverride;

  final CanonicalSink _underlying;
  final CanonicalFactPostCommitProjector _projector;
  final IntegrationCategory _category;
  final String _vendorId;
  final CanonicalFactPeriodResolver _periodResolver;
  final CanonicalRestaurantIdResolver _restaurantIdResolver;
  final String? _userIdOverride;

  /// Per-(operator, location, connection) accumulator buffers. The
  /// wrapper drains a buffer when the underlying sink reports a batch
  /// commit (via [appendSyncLog] with a commit-signal event kind) or
  /// when [flush] is called explicitly (test seam).
  final Map<_BufferKey, _PendingFactBuffer> _buffers =
      <_BufferKey, _PendingFactBuffer>{};

  /// Underlying sink the wrapper composes. Test-only accessor.
  CanonicalSink get underlying => _underlying;

  @override
  Future<bool> upsertCoverFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  }) async {
    final wrote = await _underlying.upsertCoverFact(
      operatorId: operatorId,
      locationId: locationId,
      canonicalFact: canonicalFact,
    );
    if (wrote) {
      _accumulate(
        operatorId: operatorId,
        locationId: locationId,
        canonicalFact: canonicalFact,
        factType: 'cover_fact',
      );
    }
    return wrote;
  }

  @override
  Future<bool> upsertLaborPunch({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalPunch,
  }) async {
    final wrote = await _underlying.upsertLaborPunch(
      operatorId: operatorId,
      locationId: locationId,
      canonicalPunch: canonicalPunch,
    );
    if (wrote) {
      _accumulate(
        operatorId: operatorId,
        locationId: locationId,
        canonicalFact: canonicalPunch,
        factType: 'labor_punch',
      );
    }
    return wrote;
  }

  @override
  Future<bool> upsertReservationFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalReservation,
  }) async {
    final wrote = await _underlying.upsertReservationFact(
      operatorId: operatorId,
      locationId: locationId,
      canonicalReservation: canonicalReservation,
    );
    if (wrote) {
      _accumulate(
        operatorId: operatorId,
        locationId: locationId,
        canonicalFact: canonicalReservation,
        factType: 'reservation_fact',
      );
    }
    return wrote;
  }

  @override
  Future<void> advanceWatermark({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
  }) {
    return _underlying.advanceWatermark(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
      cursorToken: cursorToken,
      lastModifiedSeen: lastModifiedSeen,
    );
  }

  @override
  Future<void> appendSyncLog({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String eventKind,
    String? errorMessage,
    int? recordsCount,
    Map<String, Object?>? payloadPreview,
  }) async {
    await _underlying.appendSyncLog(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
      eventKind: eventKind,
      errorMessage: errorMessage,
      recordsCount: recordsCount,
      payloadPreview: payloadPreview,
    );
    if (kProjectingCanonicalSinkCommitEventKinds.contains(eventKind)) {
      await _drain(
        operatorId: operatorId,
        locationId: locationId,
        connectionId: connectionId,
      );
    }
  }

  @override
  Future<void> evaluateDemoFlip({
    required String operatorId,
    required String locationId,
    required IntegrationCategory category,
    required ConnectionStatus connectionStatus,
    required bool firstBackfillCommitted,
    required int backfillRecordsWritten,
    required String connectionId,
  }) {
    return _underlying.evaluateDemoFlip(
      operatorId: operatorId,
      locationId: locationId,
      category: category,
      connectionStatus: connectionStatus,
      firstBackfillCommitted: firstBackfillCommitted,
      backfillRecordsWritten: backfillRecordsWritten,
      connectionId: connectionId,
    );
  }

  /// Test seam — drains the buffer for a specific connection. The
  /// production path drains automatically on [appendSyncLog] commit
  /// signals; tests use this to assert projector invocation without
  /// needing to call appendSyncLog.
  Future<void> flush({
    required String operatorId,
    required String locationId,
    required String connectionId,
  }) {
    return drainCommittedFacts(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
    );
  }

  @override
  void recordCommittedCoverFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  }) {
    _accumulate(
      operatorId: operatorId,
      locationId: locationId,
      canonicalFact: canonicalFact,
      factType: 'cover_fact',
    );
  }

  @override
  void recordCommittedLaborPunch({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalPunch,
  }) {
    _accumulate(
      operatorId: operatorId,
      locationId: locationId,
      canonicalFact: canonicalPunch,
      factType: 'labor_punch',
    );
  }

  @override
  void recordCommittedReservationFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalReservation,
  }) {
    _accumulate(
      operatorId: operatorId,
      locationId: locationId,
      canonicalFact: canonicalReservation,
      factType: 'reservation_fact',
    );
  }

  @override
  Future<void> drainCommittedFacts({
    required String operatorId,
    required String locationId,
    required String connectionId,
  }) {
    return _drain(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
    );
  }

  void _accumulate({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
    required String factType,
  }) {
    final connectionId = _stringValue(canonicalFact['connection_id']) ?? '';
    final key = _BufferKey(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
    );
    final buffer = _buffers.putIfAbsent(key, _PendingFactBuffer.new);
    buffer.facts.add(
      Map<String, Object?>.unmodifiable(<String, Object?>{
        ...canonicalFact,
        'operator_id': canonicalFact['operator_id'] ?? operatorId,
        'location_id': canonicalFact['location_id'] ?? locationId,
        'connection_id': canonicalFact['connection_id'] ?? connectionId,
        'fact_type': canonicalFact['fact_type'] ?? factType,
        'source_system': canonicalFact['source_system'] ?? _vendorId,
      }),
    );
  }

  Future<void> _drain({
    required String operatorId,
    required String locationId,
    required String connectionId,
  }) async {
    final buffers = <_PendingFactBuffer>[];
    final exact = _buffers.remove(
      _BufferKey(
        operatorId: operatorId,
        locationId: locationId,
        connectionId: connectionId,
      ),
    );
    if (exact != null) buffers.add(exact);
    if (connectionId.isNotEmpty) {
      final unkeyed = _buffers.remove(
        _BufferKey(
          operatorId: operatorId,
          locationId: locationId,
          connectionId: '',
        ),
      );
      if (unkeyed != null) buffers.add(unkeyed);
    }
    if (buffers.isEmpty || buffers.every((buffer) => buffer.facts.isEmpty)) {
      return;
    }
    final facts = <Map<String, Object?>>[
      for (final buffer in buffers) ...buffer.facts,
    ];
    try {
      final periods = <CanonicalFactCommittedPeriod>[];
      final openCurrentFacts = <Map<String, Object?>>[];
      final seenIdentities = <String>{};
      for (final fact in facts) {
        final period = await _periodResolver(
          operatorId: operatorId,
          locationId: locationId,
          category: _category,
          vendorId: _vendorId,
          connectionId: connectionId,
          canonicalFact: fact,
        );
        if (period == null) continue;
        if (seenIdentities.add(period.periodIdentity)) {
          periods.add(period);
        }
        if (period.state == CanonicalFactPeriodState.openCurrent) {
          openCurrentFacts.add(fact);
        }
      }
      if (periods.isEmpty) {
        return;
      }
      final restaurantId = await _restaurantIdResolver(
        operatorId: operatorId,
        locationId: locationId,
      );
      final input = CanonicalFactPostCommitInput(
        operatorId: operatorId,
        locationId: locationId,
        restaurantId: restaurantId,
        integrationCategory: _category,
        vendorId: _vendorId,
        connectionId: connectionId,
        changedPeriods: periods,
        openCurrentFactMaps: openCurrentFacts,
        userId: _userIdOverride,
      );
      await _projector.project(input);
    } catch (error, stack) {
      // Failed projection MUST NOT fail the underlying write or the
      // batch. Log at WARNING with enough context to triage.
      log(
        LogSeverity.warning,
        'projecting_canonical_sink.projector_failed',
        fields: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'connection_id': connectionId,
          'integration_category': _category.name,
          'vendor_id': _vendorId,
          'error_class': error.runtimeType.toString(),
          'error_message': error.toString(),
          'stack_first_frame': firstStackFrame(stack),
          'fact_count': facts.length,
        },
      );
    }
  }
}

String? _stringValue(Object? value) {
  if (value == null) return null;
  final text = value.toString();
  return text.isEmpty ? null : text;
}

class _BufferKey {
  const _BufferKey({
    required this.operatorId,
    required this.locationId,
    required this.connectionId,
  });

  final String operatorId;
  final String locationId;
  final String connectionId;

  @override
  bool operator ==(Object other) =>
      other is _BufferKey &&
      other.operatorId == operatorId &&
      other.locationId == locationId &&
      other.connectionId == connectionId;

  @override
  int get hashCode => Object.hash(operatorId, locationId, connectionId);
}

class _PendingFactBuffer {
  final List<Map<String, Object?>> facts = <Map<String, Object?>>[];
}
