// Phase 11W — Vendor test-connection button with state machine.
//
// Wraps test-connection calls in a timeout + spinner state machine.
// Shows a loading spinner during the test (max 10s), and presents
// operator-friendly error / success messages without raw HTTP codes.

import 'dart:async';

import 'package:flutter/material.dart';

/// State machine for test-connection flow.
enum VendorTestConnectionState { idle, testing, success, failure }

/// Result of a test-connection attempt.
class VendorTestConnectionResult {
  const VendorTestConnectionResult({
    required this.state,
    this.errorMessage,
  });

  final VendorTestConnectionState state;
  final String? errorMessage;

  bool get isIdle => state == VendorTestConnectionState.idle;
  bool get isTesting => state == VendorTestConnectionState.testing;
  bool get isSuccess => state == VendorTestConnectionState.success;
  bool get isFailure => state == VendorTestConnectionState.failure;
}

/// Stateful wrapper for test-connection button with spinner + timeout.
///
/// Manages the state machine: idle → testing (spinner) → success/failure.
/// Enforces a 10-second timeout and translates raw HTTP errors into
/// operator-friendly messages.
class VendorTestConnectionButton extends StatefulWidget {
  const VendorTestConnectionButton({
    super.key,
    required this.vendorName,
    required this.onTestConnection,
    this.onStateChanged,
  });

  /// Display name of the vendor (e.g., "Square", "Toast").
  final String vendorName;

  /// Callback invoked when the user taps the test button.
  /// Should initiate the test-connection flow. The caller is responsible
  /// for error handling and state cleanup.
  final Future<void> Function() onTestConnection;

  /// Optional callback fired when the state machine changes.
  /// Useful for parent screens to react to test state transitions.
  final void Function(VendorTestConnectionResult result)? onStateChanged;

  @override
  State<VendorTestConnectionButton> createState() =>
      _VendorTestConnectionButtonState();
}

class _VendorTestConnectionButtonState extends State<VendorTestConnectionButton> {
  VendorTestConnectionState _state = VendorTestConnectionState.idle;

  static const Duration _testTimeoutDuration = Duration(seconds: 10);

  @override
  Widget build(BuildContext context) {
    final isEnabled = _state == VendorTestConnectionState.idle;

    return ElevatedButton.icon(
      onPressed: isEnabled ? _handleTestConnection : null,
      icon: _buildIcon(),
      label: Text(_buildLabel()),
    );
  }

  Widget _buildIcon() {
    return switch (_state) {
      VendorTestConnectionState.idle =>
        const Icon(Icons.connect_without_contact_outlined),
      VendorTestConnectionState.testing =>
        const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      VendorTestConnectionState.success =>
        const Icon(Icons.check_circle_outline),
      VendorTestConnectionState.failure =>
        const Icon(Icons.error_outline),
    };
  }

  String _buildLabel() {
    return switch (_state) {
      VendorTestConnectionState.idle => 'Test connection',
      VendorTestConnectionState.testing => 'Testing...',
      VendorTestConnectionState.success => 'Connection verified',
      VendorTestConnectionState.failure => 'Test failed',
    };
  }

  Future<void> _handleTestConnection() async {
    _setState(VendorTestConnectionState.testing);

    try {
      // Enforce a 10-second timeout for the test.
      await widget.onTestConnection().timeout(
            _testTimeoutDuration,
            onTimeout: () {
              throw _TestConnectionTimeoutException(
                'Test connection timed out after ${_testTimeoutDuration.inSeconds} seconds. '
                'Please check your network connection and try again.',
              );
            },
          );
      _setState(VendorTestConnectionState.success);

      // Auto-reset to idle after a brief delay so the user sees the success
      // state before the button returns to normal.
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      if (mounted) {
        _setState(VendorTestConnectionState.idle);
      }
    } on _TestConnectionTimeoutException catch (e) {
      _setState(
        VendorTestConnectionState.failure,
        errorMessage: e.message,
      );
    } catch (e) {
      // Translate raw HTTP errors into operator-friendly messages.
      final message = _operatorFriendlyErrorMessage(e.toString());
      _setState(VendorTestConnectionState.failure, errorMessage: message);
    }
  }

  void _setState(
    VendorTestConnectionState state, {
    String? errorMessage,
  }) {
    if (!mounted) return;
    setState(() {
      _state = state;
    });
    widget.onStateChanged?.call(
      VendorTestConnectionResult(
        state: state,
        errorMessage: errorMessage,
      ),
    );
  }

  /// Translates raw HTTP error codes and transport errors into
  /// operator-friendly messages.
  String _operatorFriendlyErrorMessage(String rawError) {
    final lower = rawError.toLowerCase();

    // Network / transport errors
    if (lower.contains('connection refused') ||
        lower.contains('connection reset')) {
      return 'Could not reach ${widget.vendorName}. '
          'Please check that your credentials and network are set up correctly.';
    }
    if (lower.contains('socket exception') ||
        lower.contains('network error')) {
      return 'Network connection error. Please check your internet and try again.';
    }

    // HTTP status codes
    if (lower.contains('401') || lower.contains('unauthorized')) {
      return 'Authentication failed. Please verify your credentials and try again.';
    }
    if (lower.contains('403') || lower.contains('forbidden')) {
      return 'Access denied. Please check that your credentials have permission to connect.';
    }
    if (lower.contains('404') || lower.contains('not found')) {
      return '${widget.vendorName} endpoint not found. '
          'Please check your account details.';
    }
    if (lower.contains('429') || lower.contains('too many requests')) {
      return 'Too many requests. Please wait a moment and try again.';
    }
    if (lower.contains('500') ||
        lower.contains('502') ||
        lower.contains('503') ||
        lower.contains('504')) {
      return '${widget.vendorName} service is temporarily unavailable. '
          'Please try again in a few moments.';
    }

    // Fallback: generic error message
    return 'Test connection failed. '
        'Please check your credentials and try again.';
  }
}

/// Custom exception for test-connection timeouts.
class _TestConnectionTimeoutException implements Exception {
  const _TestConnectionTimeoutException(this.message);

  final String message;

  @override
  String toString() => message;
}
