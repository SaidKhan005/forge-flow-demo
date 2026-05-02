// HARD-G observability — typed dependency-timeout signal.
//
// Outbound clients (Postgres, Firebase, HIBP, …) wrap their I/O calls
// in `.timeout(Duration)`. When the timer elapses, the wrapper catches
// the raw [TimeoutException], emits one `request.dependency_timeout`
// JSON log line with `surface`, `operation`, and `elapsed_ms`, and
// throws this typed exception.
//
// The advisor proxy's outermost route handler catches
// [DependencyTimeoutException] distinctly so the client response uses
// the contract-pinned envelope:
//   { "error": "dependency_timeout", "surface": "...",
//     "message": "Upstream dependency timed out; please retry" }
// instead of a surface-specific `*_unavailable` code.

class DependencyTimeoutException implements Exception {
  const DependencyTimeoutException({
    required this.surface,
    required this.operation,
    required this.elapsedMs,
  });

  /// Outbound surface that timed out — `postgres`, `firebase`, `hibp`,
  /// `voyage`, `secret_manager`, etc.
  final String surface;

  /// Operation name within the surface (e.g. `query`, `execute`,
  /// `acquire_connection`, `range_fetch`).
  final String operation;

  /// Configured timeout in milliseconds. The contract requires this
  /// in every `request.dependency_timeout` log line so operators can
  /// distinguish a legitimate slow-path timeout from a misconfigured
  /// short timeout.
  final int elapsedMs;

  @override
  String toString() =>
      'DependencyTimeoutException(surface: $surface, '
      'operation: $operation, elapsed_ms: $elapsedMs)';
}
