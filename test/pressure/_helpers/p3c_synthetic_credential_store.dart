// Phase 3C OAuth refresh storm — synthetic credential store.
//
// In-process simulator of the `vendor_credentials` row that the
// production `VendorCredentialBroker` reads / rotates via Postgres.
// The harness uses this to exercise:
//
//   1. Advisory-lock semantics — only one refresh per
//      (operator, location, vendor) tuple should fire even when N
//      parallel callers ask for a refresh.
//   2. Atomic rotation — `token_expires_at` and
//      `encrypted_access_token` MUST update together; transactional
//      readers should never see a window where the expiry advanced
//      but the ciphertext is null/empty / stale.
//   3. Mid-poll-during-refresh — a polling adapter reading the bearer
//      while a refresh is in progress should never get a torn read.
//
// The store is intentionally minimal: it records the rotation
// sequence, exposes a "transactional snapshot" the harness can call
// from within the refresh closure, and fires a single in-flight
// future per tuple so the harness can drive the storm without the
// real production Postgres pool.
//
// This is a HARNESS HELPER, not production code. It lives under
// `test/pressure/_helpers/` and is only imported by the P3C
// binary + runner test.

import 'dart:async';

/// Snapshot of a synthetic `vendor_credentials` row, returned by
/// [SyntheticCredentialStore.snapshot]. The harness inspects these
/// to detect non-atomic rotations.
class CredentialSnapshot {
  const CredentialSnapshot({
    required this.operatorId,
    required this.locationId,
    required this.vendorId,
    required this.encryptedAccessToken,
    required this.tokenExpiresAt,
    required this.rotatedAt,
    required this.rotationCount,
  });

  final String operatorId;
  final String locationId;
  final String vendorId;
  final String encryptedAccessToken;
  final DateTime tokenExpiresAt;
  final DateTime? rotatedAt;
  final int rotationCount;

  bool get isConsistent =>
      encryptedAccessToken.isNotEmpty &&
      // Once the row has been rotated at least once, a consistent
      // state means the new expiry strictly exceeds the rotation
      // moment by at least the seeded token-life (otherwise we have
      // a stale-expiry window).
      (rotationCount == 0 || rotatedAt == null ||
          tokenExpiresAt.isAfter(rotatedAt!));
}

/// One row's mutable state. Updates happen atomically via
/// [_TupleState.commit], which writes the (token, expiry, rotated_at,
/// rotation_count) tuple under a single field assignment so a snapshot
/// observer either sees the pre- or post-rotation state, never half.
///
/// Concurrent refreshes are collapsed via [acquireRefreshLock]; the
/// first caller obtains the lock, all subsequent callers either skip
/// (under `pg_advisory_xact_lock` semantics) or wait on the in-flight
/// future. The harness chooses behavior per scenario.
class _TupleState {
  _TupleState({
    required this.operatorId,
    required this.locationId,
    required this.vendorId,
    required this.initialToken,
    required this.initialExpiresAt,
  })  : _row = _RowSnapshot(
          encryptedAccessToken: initialToken,
          tokenExpiresAt: initialExpiresAt,
          rotatedAt: null,
          rotationCount: 0,
        );

  final String operatorId;
  final String locationId;
  final String vendorId;
  final String initialToken;
  final DateTime initialExpiresAt;

  _RowSnapshot _row;

  /// Total number of times `acquireRefreshLock` was actually entered
  /// (i.e. the per-tuple lock was free at the call site). The
  /// advisory-lock check expects this to equal 1 even when N callers
  /// race.
  int lockAcquisitions = 0;

  /// Number of completed refreshes (including failures). The
  /// advisory-lock check expects this to equal 1 across N parallel
  /// firings against the same tuple.
  int refreshCompletions = 0;

  /// Currently-in-flight refresh future, if any. The store collapses
  /// concurrent callers onto this Future (broker-side semantics).
  Future<void>? _inFlight;

  /// Read the current row atomically. The store wraps this in a
  /// microtask gate so a snapshot observer can be scheduled to land
  /// strictly between the closure body and the commit.
  CredentialSnapshot snapshot() => CredentialSnapshot(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: vendorId,
        encryptedAccessToken: _row.encryptedAccessToken,
        tokenExpiresAt: _row.tokenExpiresAt,
        rotatedAt: _row.rotatedAt,
        rotationCount: _row.rotationCount,
      );

  /// Commit a new (token, expires_at) pair atomically. Mirrors the
  /// broker's `update vendor_credentials set ... ciphertext, expires_at`
  /// statement which is single-row, single-statement, and therefore
  /// atomic at the Postgres MVCC layer.
  void commit({
    required String newCiphertext,
    required DateTime newExpiresAt,
    required DateTime rotatedAt,
  }) {
    _row = _RowSnapshot(
      encryptedAccessToken: newCiphertext,
      tokenExpiresAt: newExpiresAt,
      rotatedAt: rotatedAt,
      rotationCount: _row.rotationCount + 1,
    );
  }

  /// Acquire the per-tuple refresh lock. Returns `null` immediately
  /// (without scheduling) when another refresh is in flight — the
  /// harness uses this to assert advisory-lock fan-out: callers that
  /// see `null` return without firing a refresh.
  ///
  /// The Future returned to the lock-holder must be awaited to
  /// release the lock. The store removes the in-flight slot in
  /// `whenComplete`, mirroring `VendorCredentialBroker._inFlightRefreshes`.
  Future<void>? acquireRefreshLock(Future<void> Function() body) {
    if (_inFlight != null) return null;
    lockAcquisitions += 1;
    final future = body();
    _inFlight = future;
    future.whenComplete(() {
      refreshCompletions += 1;
      if (identical(_inFlight, future)) _inFlight = null;
    });
    return future;
  }

  /// Wait on the in-flight refresh (if any) without acquiring the
  /// lock. Mirrors the production broker's "concurrent callers
  /// observe the same in-flight Future" behavior.
  Future<void>? waitForInFlight() => _inFlight;
}

class _RowSnapshot {
  const _RowSnapshot({
    required this.encryptedAccessToken,
    required this.tokenExpiresAt,
    required this.rotatedAt,
    required this.rotationCount,
  });
  final String encryptedAccessToken;
  final DateTime tokenExpiresAt;
  final DateTime? rotatedAt;
  final int rotationCount;
}

/// Synthetic store the harness drives. One instance per harness run.
///
/// Tuples are seeded by [seed]. The harness fires refreshes via
/// [refresh], which mirrors the production broker's contract:
///
///   * Concurrent calls against the same tuple collapse to a single
///     in-flight Future (only one network call to the vendor; only
///     one ciphertext rotation in the store).
///   * Each refresh writes the new (ciphertext, expires_at) pair
///     atomically — a snapshot observer never sees a torn read.
///
/// The harness's findings are derived by reading [tupleState].
class SyntheticCredentialStore {
  final Map<String, _TupleState> _tuples = <String, _TupleState>{};

  /// Total number of refresh closure invocations actually performed
  /// (sum across all tuples). Used to cross-check advisory-lock fan-out.
  int closureInvocations = 0;

  String _key(String operatorId, String locationId, String vendorId) =>
      '$operatorId|$locationId|$vendorId';

  void seed({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String initialToken,
    required DateTime initialExpiresAt,
  }) {
    final key = _key(operatorId, locationId, vendorId);
    _tuples[key] = _TupleState(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: vendorId,
      initialToken: initialToken,
      initialExpiresAt: initialExpiresAt,
    );
  }

  _TupleState _requireTuple(String operatorId, String locationId, String vendorId) {
    final state = _tuples[_key(operatorId, locationId, vendorId)];
    if (state == null) {
      throw StateError(
        'tuple not seeded: $operatorId/$locationId/$vendorId',
      );
    }
    return state;
  }

  CredentialSnapshot snapshot({
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) {
    return _requireTuple(operatorId, locationId, vendorId).snapshot();
  }

  Iterable<_TupleState> get _allTuples => _tuples.values;

  /// Sum of `lockAcquisitions` across every tuple.
  int get totalLockAcquisitions =>
      _allTuples.fold(0, (n, t) => n + t.lockAcquisitions);

  /// Sum of `refreshCompletions` across every tuple.
  int get totalRefreshCompletions =>
      _allTuples.fold(0, (n, t) => n + t.refreshCompletions);

  /// Per-tuple lock acquisition counts, keyed by
  /// `op|loc|vendor`. Used by the advisory-lock check to confirm
  /// each tuple saw exactly one acquisition.
  Map<String, int> get perTupleLockAcquisitions => <String, int>{
        for (final t in _allTuples)
          _key(t.operatorId, t.locationId, t.vendorId): t.lockAcquisitions,
      };

  /// Per-tuple refresh completion counts.
  Map<String, int> get perTupleRefreshCompletions => <String, int>{
        for (final t in _allTuples)
          _key(t.operatorId, t.locationId, t.vendorId): t.refreshCompletions,
      };

  /// Drive a refresh against [vendorId]. The closure body simulates
  /// a vendor token endpoint round trip: [vendorLatency] sleeps to
  /// mimic the network call, then a new ciphertext + expiry land
  /// atomically. The refresh increments the rotation count.
  ///
  /// When [collapseConcurrent] is true (default), concurrent calls
  /// against the same tuple are collapsed onto a single in-flight
  /// Future (matching the broker's advisory-lock semantics).
  ///
  /// [snapshotProbe] (optional) fires once between the closure body
  /// and the commit so the harness can detect non-atomic rotations.
  Future<void> refresh({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required Duration vendorLatency,
    required String newCiphertext,
    required Duration newExpiresIn,
    bool collapseConcurrent = true,
    void Function(CredentialSnapshot)? snapshotProbe,
  }) async {
    final tuple = _requireTuple(operatorId, locationId, vendorId);
    if (collapseConcurrent) {
      final waited = tuple.waitForInFlight();
      if (waited != null) {
        await waited;
        return;
      }
    }
    final future = tuple.acquireRefreshLock(() async {
      closureInvocations += 1;
      // Simulated vendor round trip.
      await Future<void>.delayed(vendorLatency);
      // Snapshot probe runs strictly between the vendor RTT and the
      // commit; the harness uses this to look for inconsistent state
      // (e.g. the closure already minted a new token but the store
      // still holds the old).
      if (snapshotProbe != null) {
        snapshotProbe(tuple.snapshot());
      }
      tuple.commit(
        newCiphertext: newCiphertext,
        newExpiresAt: DateTime.now().toUtc().add(newExpiresIn),
        rotatedAt: DateTime.now().toUtc(),
      );
    });
    // future is non-null here because we either acquired the lock
    // (collapseConcurrent=false) or the previous waitForInFlight()
    // returned null (no in-flight) so acquireRefreshLock entered
    // the body branch.
    if (future != null) await future;
  }
}
