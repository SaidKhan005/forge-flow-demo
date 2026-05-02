import 'dart:async';

/// Awaits health-check work with a wall-clock budget without abandoning
/// the original future.
///
/// Dart's [Future.timeout] is not cancellation: after it fires, the
/// underlying database transaction can keep running. Health checks run
/// multiple producers through a bounded worker lane, so returning early
/// from a timed-out future would let the worker schedule more database
/// work while the earlier transaction still owns a pooled connection.
///
/// This helper preserves the timeout signal for the caller, but if the
/// local budget is what fired, it first waits for the original operation
/// to settle. Production Postgres health queries also run with database
/// statement timeouts, so the settle path is bounded by the database
/// adapter rather than by an uncancellable Dart future.
Future<T> awaitHealthOperationWithBudget<T>(
  Future<T> operation, {
  required Duration budget,
}) async {
  var localBudgetExpired = false;
  try {
    return await operation.timeout(
      budget,
      onTimeout: () {
        localBudgetExpired = true;
        throw TimeoutException('health operation exceeded budget', budget);
      },
    );
  } on TimeoutException {
    if (localBudgetExpired) {
      try {
        await operation;
      } catch (_) {
        // Keep the public health signal classified as a timeout and
        // avoid leaking late exception text into the health envelope.
      }
    }
    rethrow;
  }
}
