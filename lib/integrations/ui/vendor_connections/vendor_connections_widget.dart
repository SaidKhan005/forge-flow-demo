// Phase 8.0 — Shared Vendor Connections widget tree.
//
// Host-shell-agnostic. The same widget code mounts in:
//
//   * F&F Operations Console (Phase 11A) via
//     `lib/admin/screens/vendor_connections/vendor_connections_admin_mount.dart`.
//   * Operator Web Console (Phase 11W) via
//     `lib/operator_web/screens/vendor_connections_screen.dart`.
//
// The widget reads (operator_id, location_id) from host context. RLS
// + repository scoping in the gateway enforces what the host context
// is allowed to see; this widget renders whatever the gateway
// returns.
//
// UX writing standard (per
// `docs/phases/phase_8/vendor_connections_admin_surface.md`): every
// button has a 1-line "what this is" header + 1–2 sentence "what
// happens when you click" explainer; status badges have tooltips
// with remediation; error messages explain what / why / what to do
// next; empty states explain context and suggest the next step;
// confirmations explain consequences as bullets.
//
// Wave C1 (code-health) extraction
// --------------------------------
// The widget tree was extracted from a single 2261-LOC file into
// focused part files under `widgets/`. The library shape is preserved
// — `VendorConnectionsWidget` remains the only public type exported
// from this file and its public API (constructor signature, fields,
// pinned widget keys) is unchanged. The four bare `catch (e)` blocks
// were replaced with typed handlers that surface a structured
// [_VendorActionError] result instead of a silent swallow. Transport
// failures (`SocketException`, `TimeoutException`, `FormatException`)
// land as honest snackbar copy with remediation; programming errors
// (`Error` subclasses) re-throw so they surface in tests.

import 'dart:async';
import 'dart:io' show SocketException;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../admin/admin_human_labels.dart';
import '../../../theme/app_theme.dart';
import 'in_memory_vendor_connections_gateway.dart';
import 'vendor_connections_gateway.dart';
import 'vendor_connections_models.dart';

part 'widgets/vendor_connections_action_error.dart';
part 'widgets/vendor_connections_api_key_dialog.dart';
part 'widgets/vendor_connections_brand.dart';
part 'widgets/vendor_connections_category_section.dart';
part 'widgets/vendor_connections_dialog_primitives.dart';
part 'widgets/vendor_connections_disconnect_dialog.dart';
part 'widgets/vendor_connections_logs_dialog.dart';
part 'widgets/vendor_connections_module_dialog.dart';
part 'widgets/vendor_connections_picker_dialog.dart';
part 'widgets/vendor_connections_picker_grid.dart';
part 'widgets/vendor_connections_status.dart';
part 'widgets/vendor_connections_test_dialog.dart';

/// Default in-memory gateway used when the host shell does not wire
/// a production gateway. Keeps walkthrough + widget tests
/// reproducible without a Cloud Run dependency.
final VendorConnectionsGateway _defaultDemoGateway =
    InMemoryVendorConnectionsGateway();

/// Dual-surface root widget. Mount this with [operatorId] +
/// [locationId] resolved by the host shell — F&F Ops Console reads
/// from the operator picker; Operator Web Console reads from the
/// signed-in user's session.
class VendorConnectionsWidget extends StatefulWidget {
  const VendorConnectionsWidget({
    super.key,
    required this.operatorId,
    required this.locationId,
    this.locationNameOverride,
    this.gateway,
    this.canMutate = true,
    this.headerLeading,
    this.onConnectFlowStarted,
  });

  final String operatorId;
  final String locationId;
  final String? locationNameOverride;

  /// Production wires the HTTP gateway; demo + tests fall back to
  /// [_defaultDemoGateway].
  final VendorConnectionsGateway? gateway;

  /// `false` for `ff_support` (read-only in F&F Ops Console). Hides
  /// connect / test / disconnect buttons but still renders status.
  final bool canMutate;
  final Widget? headerLeading;

  /// Optional host hook for OAuth/key-paste redirects. Web hosts can
  /// navigate the browser; test/demo hosts can leave it null and keep
  /// the in-memory flow on-page.
  final Future<void> Function(VendorConnectFlowStart flow)?
  onConnectFlowStarted;

  @override
  State<VendorConnectionsWidget> createState() =>
      _VendorConnectionsWidgetState();
}

class _VendorConnectionsWidgetState extends State<VendorConnectionsWidget> {
  bool _loading = true;
  String? _error;
  VendorConnectionsBundle? _bundle;
  int _loadGeneration = 0;

  VendorConnectionsGateway get _gateway =>
      widget.gateway ?? _defaultDemoGateway;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant VendorConnectionsWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.operatorId != widget.operatorId ||
        oldWidget.locationId != widget.locationId ||
        oldWidget.gateway != widget.gateway) {
      _refresh();
    }
  }

  Future<void> _refresh() async {
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final bundle = await _gateway.loadBundle(
        operatorId: widget.operatorId,
        locationId: widget.locationId,
      );
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _bundle = bundle;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _error = 'Could not load vendor connections: $error';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _bundle == null) {
      return const Center(
        key: Key('vendor_connections_loading'),
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error != null) {
      return _ErrorBanner(
        key: const Key('vendor_connections_error'),
        message: _error!,
      );
    }
    final bundle = _bundle!;
    return ColoredBox(
      color: AppColors.backgroundDeep,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Header(
                  locationName:
                      widget.locationNameOverride ?? bundle.locationName,
                  leading: widget.headerLeading,
                ),
                const SizedBox(height: 16),
                _CategorySection(
                  key: const Key('vendor_connections_section_pos'),
                  label: 'Point-of-sale',
                  categoryDescription:
                      'Sales, checks, covers, and closed-order timing feed the dashboard and baseline math.',
                  row: bundle.posConnection,
                  isDemo: bundle.demoFlags[VendorCategory.pos] ?? true,
                  category: VendorCategory.pos,
                  canMutate: widget.canMutate,
                  onConnect: _onConnect,
                  onTest: _onTestConnection,
                  onDisconnect: _onDisconnect,
                  onLogs: _onViewLogs,
                ),
                const SizedBox(height: 14),
                _CategorySection(
                  key: const Key('vendor_connections_section_labor'),
                  label: 'Scheduling and labor',
                  categoryDescription:
                      'Schedules, punches, and roles power labor variance and week-to-date operating views.',
                  row: bundle.laborConnection,
                  isDemo: bundle.demoFlags[VendorCategory.labor] ?? true,
                  category: VendorCategory.labor,
                  canMutate: widget.canMutate,
                  onConnect: _onConnect,
                  onTest: _onTestConnection,
                  onDisconnect: _onDisconnect,
                  onLogs: _onViewLogs,
                ),
                const SizedBox(height: 14),
                _CategorySection(
                  key: const Key('vendor_connections_section_reservation'),
                  label: 'Reservations',
                  categoryDescription:
                      'Bookings and party sizes help forecast covers and compare actual pacing against expected demand.',
                  row: bundle.reservationConnection,
                  isDemo: bundle.demoFlags[VendorCategory.reservation] ?? true,
                  category: VendorCategory.reservation,
                  canMutate: widget.canMutate,
                  onConnect: _onConnect,
                  onTest: _onTestConnection,
                  onDisconnect: _onDisconnect,
                  onLogs: _onViewLogs,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _onConnect(VendorCategory category) async {
    final entries = await _gateway.listAvailableVendors(category: category);
    if (!mounted) return;
    final picked = await showDialog<VendorPickerEntry>(
      context: context,
      builder: (_) => _VendorPickerDialog(category: category, entries: entries),
    );
    if (picked == null || !mounted) return;
    String? module;
    if (picked.requiresModule) {
      module = await showDialog<String>(
        context: context,
        builder: (_) => _ModuleDisambiguationDialog(entry: picked),
      );
      // ADP RUN / QuickBooks Payroll is rejected before OAuth.
      if (module == null) return;
      if (module == 'unsupported') {
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (_) => const _UnsupportedModuleDialog(),
        );
        return;
      }
    }
    if (picked.authMode == VendorAuthMode.keyPaste) {
      await _runApiKeyPasteFlow(entry: picked, module: module);
      return;
    }
    try {
      final flow = await _gateway.startConnect(
        operatorId: widget.operatorId,
        locationId: widget.locationId,
        vendorId: picked.vendorId,
        module: module,
      );
      await widget.onConnectFlowStarted?.call(flow);
      await _refresh();
    } on VendorConnectionsGatewayError catch (e) {
      _showError(e.message, remediation: e.remediation);
    } catch (e, stack) {
      _handleTransportError(
        operationLabel: 'start the connection',
        cause: e,
        stack: stack,
      );
    }
  }

  /// Capture credentials for a key-paste vendor and POST them to the
  /// proxy. Stays on-page (no OAuth redirect) — the dialog handles
  /// validation, the gateway handles persistence, and a successful
  /// response refreshes the bundle so the connected card appears.
  Future<void> _runApiKeyPasteFlow({
    required VendorPickerEntry entry,
    required String? module,
  }) async {
    final credentials = await showDialog<_VendorApiKeyPasteResult>(
      context: context,
      builder: (_) => _VendorApiKeyPasteDialog(entry: entry),
    );
    if (credentials == null || !mounted) return;
    try {
      await _gateway.connectWithApiKey(
        operatorId: widget.operatorId,
        locationId: widget.locationId,
        vendorId: entry.vendorId,
        apiKey: credentials.apiKey,
        apiSecret: credentials.apiSecret,
        module: module,
      );
      await _refresh();
    } on VendorConnectionsGatewayError catch (e) {
      _showError(e.message, remediation: e.remediation);
    } catch (e, stack) {
      _handleTransportError(
        operationLabel: 'connect this vendor',
        cause: e,
        stack: stack,
      );
    }
  }

  Future<void> _onTestConnection(VendorConnectionRow row) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _TestConnectionLoadingDialog(),
    );
    try {
      final result = await _gateway.testConnection(
        operatorId: widget.operatorId,
        locationId: widget.locationId,
        vendorId: row.vendorId,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      await showDialog<void>(
        context: context,
        builder: (_) => _TestConnectionResultDialog(row: row, result: result),
      );
    } on VendorConnectionsGatewayError catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      _showError(
        'Test connection failed: ${e.message}',
        remediation: e.remediation,
      );
    } catch (e, stack) {
      if (mounted) Navigator.of(context).pop();
      _handleTransportError(
        operationLabel: 'test the connection',
        cause: e,
        stack: stack,
      );
    }
  }

  Future<void> _onDisconnect(VendorConnectionRow row) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _DisconnectConfirmDialog(row: row),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _gateway.disconnect(
        operatorId: widget.operatorId,
        locationId: widget.locationId,
        vendorId: row.vendorId,
        reason: 'operator_action',
      );
      await _refresh();
    } on VendorConnectionsGatewayError catch (e) {
      _showError('Disconnect failed: ${e.message}', remediation: e.remediation);
    } catch (e, stack) {
      _handleTransportError(
        operationLabel: 'disconnect this vendor',
        cause: e,
        stack: stack,
      );
    }
  }

  Future<void> _onViewLogs(VendorConnectionRow row) async {
    try {
      final logs = await _gateway.loadLogs(
        operatorId: widget.operatorId,
        locationId: widget.locationId,
        vendorId: row.vendorId,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => _SyncLogsDialog(row: row, entries: logs),
      );
    } on VendorConnectionsGatewayError catch (e) {
      _showError(
        'Could not load sync logs: ${e.message}',
        remediation: e.remediation,
      );
    } catch (e, stack) {
      _handleTransportError(
        operationLabel: 'load sync logs',
        cause: e,
        stack: stack,
      );
    }
  }

  /// Maps a non-gateway-error caught from the gateway boundary onto a
  /// structured [_VendorActionError]. Re-throws anything that is not a
  /// recognised transport-layer kind so `Error` subclasses (i.e.
  /// programming errors) keep surfacing in tests and crash reporters
  /// instead of being silently swallowed.
  void _handleTransportError({
    required String operationLabel,
    required Object cause,
    required StackTrace stack,
  }) {
    final mapped = _VendorActionError.fromException(
      operationLabel: operationLabel,
      cause: cause,
      stack: stack,
    );
    if (mapped == null) {
      Error.throwWithStackTrace(cause, stack);
    }
    _showError(mapped.message, remediation: mapped.remediation);
  }

  void _showError(String message, {String? remediation}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(remediation == null ? message : '$message\n$remediation'),
      ),
    );
  }
}
