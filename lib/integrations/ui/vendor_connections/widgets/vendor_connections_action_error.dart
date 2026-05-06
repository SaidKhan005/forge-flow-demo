// Phase 8.0 / Wave C1 — Structured error result for the shared Vendor
// Connections widget tree.
//
// Replaces the pre-Wave-C1 bare `catch (e)` swallow that lost the
// exception kind + remediation. Each factory logs via [debugPrint] so
// the underlying exception is visible in the runtime log without
// leaking a raw `print` to stdout, and surfaces a structured snackbar
// payload (`message` + `remediation`) the parent state can hand to
// the existing snackbar seam.

part of '../vendor_connections_widget.dart';

@immutable
class _VendorActionError {
  const _VendorActionError._({
    required this.kind,
    required this.message,
    required this.remediation,
  });

  /// Classify [cause] into a structured snackbar payload. Returns
  /// `null` when the exception is not a known transport-layer kind —
  /// callers should re-throw so `Error` subclasses (programming
  /// errors) keep surfacing in tests and crash reporters. Each branch
  /// logs via [debugPrint] so the underlying exception is visible in
  /// the runtime log without leaking a raw `print` to stdout.
  static _VendorActionError? fromException({
    required String operationLabel,
    required Object cause,
    required StackTrace stack,
  }) {
    if (cause is SocketException) {
      debugPrint(
        'VendorConnectionsWidget: SocketException while attempting to '
        '$operationLabel: $cause\n$stack',
      );
      return _VendorActionError._(
        kind: _VendorActionErrorKind.transport,
        message:
            'Could not reach the vendor service to $operationLabel. The '
            'network is unreachable right now.',
        remediation:
            'Check your internet connection and try again in a moment.',
      );
    }
    if (cause is TimeoutException) {
      debugPrint(
        'VendorConnectionsWidget: TimeoutException while attempting to '
        '$operationLabel: $cause\n$stack',
      );
      return _VendorActionError._(
        kind: _VendorActionErrorKind.timeout,
        message:
            'The request to $operationLabel took too long and was '
            'cancelled.',
        remediation:
            'Try again in a moment. If this keeps happening, the vendor '
            'service may be slow or unavailable.',
      );
    }
    if (cause is FormatException) {
      debugPrint(
        'VendorConnectionsWidget: FormatException while attempting to '
        '$operationLabel: $cause\n$stack',
      );
      return _VendorActionError._(
        kind: _VendorActionErrorKind.malformed,
        message:
            'The vendor service returned an unexpected response while '
            'attempting to $operationLabel.',
        remediation:
            'Try again. If the problem persists, contact support so we '
            'can investigate the response shape.',
      );
    }
    return null;
  }

  final _VendorActionErrorKind kind;
  final String message;
  final String remediation;
}

enum _VendorActionErrorKind { transport, timeout, malformed }
