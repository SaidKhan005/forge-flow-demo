// Phase 8.0 — Shared Vendor Connections widget tree.
//
// Host-shell-agnostic. The same widget code mounts in:
//
//   * F&F Operations Console (Phase 11A) via
//     `lib/admin/screens/vendor_connections/vendor_connections_admin_mount.dart`.
//   * Operator Web Console (Phase 11W) via
//     `lib/operator_web/screens/vendor_connections_operator_mount.dart`
//     (lands in 11W.8).
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

import 'package:flutter/material.dart';

import 'in_memory_vendor_connections_gateway.dart';
import 'vendor_connections_gateway.dart';
import 'vendor_connections_models.dart';

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
    this.gateway,
    this.canMutate = true,
  });

  final String operatorId;
  final String locationId;

  /// Production wires the HTTP gateway; demo + tests fall back to
  /// [_defaultDemoGateway].
  final VendorConnectionsGateway? gateway;

  /// `false` for `ff_support` (read-only in F&F Ops Console). Hides
  /// connect / test / disconnect buttons but still renders status.
  final bool canMutate;

  @override
  State<VendorConnectionsWidget> createState() =>
      _VendorConnectionsWidgetState();
}

class _VendorConnectionsWidgetState extends State<VendorConnectionsWidget> {
  bool _loading = true;
  String? _error;
  VendorConnectionsBundle? _bundle;

  VendorConnectionsGateway get _gateway => widget.gateway ?? _defaultDemoGateway;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final bundle = await _gateway.loadBundle(
        operatorId: widget.operatorId,
        locationId: widget.locationId,
      );
      if (!mounted) return;
      setState(() {
        _bundle = bundle;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
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
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(locationName: bundle.locationName),
          const SizedBox(height: 16),
          _CategorySection(
            key: const Key('vendor_connections_section_pos'),
            label: 'Point-of-sale (POS)',
            categoryDescription:
                'Forge & Flow needs to read sales and order data from your POS to '
                'power your dashboard, baseline math, and Shift live view.',
            row: bundle.posConnection,
            isDemo: bundle.demoFlags[VendorCategory.pos] ?? true,
            category: VendorCategory.pos,
            canMutate: widget.canMutate,
            onConnect: _onConnect,
            onTest: _onTestConnection,
            onDisconnect: _onDisconnect,
            onLogs: _onViewLogs,
          ),
          const SizedBox(height: 16),
          _CategorySection(
            key: const Key('vendor_connections_section_reservation'),
            label: 'Reservations',
            categoryDescription:
                'Forge & Flow uses reservation data to forecast covers when your '
                'POS does not record them and to align Shift with confirmed pacing.',
            row: bundle.reservationConnection,
            isDemo: bundle.demoFlags[VendorCategory.reservation] ?? true,
            category: VendorCategory.reservation,
            canMutate: widget.canMutate,
            onConnect: _onConnect,
            onTest: _onTestConnection,
            onDisconnect: _onDisconnect,
            onLogs: _onViewLogs,
          ),
          const SizedBox(height: 16),
          _CategorySection(
            key: const Key('vendor_connections_section_labor'),
            label: 'Scheduling and labor',
            categoryDescription:
                'Forge & Flow reads punches and roles from your scheduling system '
                'to drive labor variance and the WTD picture.',
            row: bundle.laborConnection,
            isDemo: bundle.demoFlags[VendorCategory.labor] ?? true,
            category: VendorCategory.labor,
            canMutate: widget.canMutate,
            onConnect: _onConnect,
            onTest: _onTestConnection,
            onDisconnect: _onDisconnect,
            onLogs: _onViewLogs,
          ),
        ],
      ),
    );
  }

  Future<void> _onConnect(VendorCategory category) async {
    final entries = await _gateway.listAvailableVendors(category: category);
    if (!mounted) return;
    final picked = await showDialog<VendorPickerEntry>(
      context: context,
      builder: (_) => _VendorPickerDialog(
        category: category,
        entries: entries,
      ),
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
    try {
      await _gateway.startConnect(
        operatorId: widget.operatorId,
        locationId: widget.locationId,
        vendorId: picked.vendorId,
        module: module,
      );
      await _refresh();
    } on VendorConnectionsGatewayError catch (e) {
      _showError(e.message, remediation: e.remediation);
    } catch (e) {
      _showError('Could not start the connection: $e');
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
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      _showError('Test connection failed: $e');
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
    } catch (e) {
      _showError('Disconnect failed: $e');
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
    } catch (e) {
      _showError('Could not load sync logs: $e');
    }
  }

  void _showError(String message, {String? remediation}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          remediation == null ? message : '$message\n$remediation',
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.locationName});

  final String locationName;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Vendor connections',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 4),
        Text(
          'Connect $locationName to your point-of-sale, reservations, and '
          'scheduling vendors. We read your data and never push changes back '
          'to your vendor systems.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    );
  }
}

class _CategorySection extends StatelessWidget {
  const _CategorySection({
    super.key,
    required this.label,
    required this.categoryDescription,
    required this.row,
    required this.isDemo,
    required this.category,
    required this.canMutate,
    required this.onConnect,
    required this.onTest,
    required this.onDisconnect,
    required this.onLogs,
  });

  final String label;
  final String categoryDescription;
  final VendorConnectionRow? row;
  final bool isDemo;
  final VendorCategory category;
  final bool canMutate;
  final ValueChanged<VendorCategory> onConnect;
  final ValueChanged<VendorConnectionRow> onTest;
  final ValueChanged<VendorConnectionRow> onDisconnect;
  final ValueChanged<VendorConnectionRow> onLogs;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: row == null
            ? _EmptyState(
                label: label,
                categoryDescription: categoryDescription,
                isDemo: isDemo,
                category: category,
                canMutate: canMutate,
                onConnect: () => onConnect(category),
              )
            : _ConnectedCard(
                row: row!,
                canMutate: canMutate,
                onTest: () => onTest(row!),
                onDisconnect: () => onDisconnect(row!),
                onLogs: () => onLogs(row!),
              ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.label,
    required this.categoryDescription,
    required this.isDemo,
    required this.category,
    required this.canMutate,
    required this.onConnect,
  });

  final String label;
  final String categoryDescription;
  final bool isDemo;
  final VendorCategory category;
  final bool canMutate;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(width: 8),
            if (isDemo)
              Tooltip(
                message:
                    'This category is in demo mode. Live data only flows after '
                    'a vendor is connected for this location.',
                child: Chip(
                  key: Key(
                      'vendor_connections_demo_chip_${category.name}'),
                  label: const Text('Demo'),
                  visualDensity: VisualDensity.compact,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Connect your $label system',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        const SizedBox(height: 4),
        Text(
          '$categoryDescription Pick yours and we walk you through connecting it.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        if (canMutate)
          FilledButton.icon(
            key: Key('vendor_connections_connect_${category.name}'),
            onPressed: onConnect,
            icon: const Icon(Icons.link, size: 16),
            label: Text('Choose your ${_categoryShortLabel(category)}'),
          )
        else
          const Text(
            'You do not have permission to connect a vendor for this category.',
          ),
      ],
    );
  }

  String _categoryShortLabel(VendorCategory category) {
    switch (category) {
      case VendorCategory.pos:
        return 'POS';
      case VendorCategory.labor:
        return 'scheduling vendor';
      case VendorCategory.reservation:
        return 'reservations vendor';
    }
  }
}

class _ConnectedCard extends StatelessWidget {
  const _ConnectedCard({
    required this.row,
    required this.canMutate,
    required this.onTest,
    required this.onDisconnect,
    required this.onLogs,
  });

  final VendorConnectionRow row;
  final bool canMutate;
  final VoidCallback onTest;
  final VoidCallback onDisconnect;
  final VoidCallback onLogs;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                row.displayName,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            _StatusBadge(status: row.status, message: row.lastErrorMessage),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          _summaryLine(row),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (row.webhookUrl != null) ...<Widget>[
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              Expanded(
                child: SelectableText(
                  'Webhook URL: ${row.webhookUrl}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              IconButton(
                key: Key('vendor_connections_copy_webhook_${row.vendorId}'),
                tooltip: 'Copy the webhook URL into your '
                    '${row.displayName} portal',
                onPressed: () {
                  // Copy is a no-op stub at the widget layer; production
                  // wires Clipboard.setData behind a feature plug.
                },
                icon: const Icon(Icons.copy, size: 16),
              ),
            ],
          ),
        ],
        if (row.lastErrorMessage != null) ...<Widget>[
          const SizedBox(height: 8),
          _ErrorRemediation(message: row.lastErrorMessage!),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            if (canMutate)
              OutlinedButton.icon(
                key: Key('vendor_connections_test_${row.vendorId}'),
                onPressed: onTest,
                icon: const Icon(Icons.fact_check_outlined, size: 16),
                label: const Text('Test connection'),
              ),
            OutlinedButton.icon(
              key: Key('vendor_connections_logs_${row.vendorId}'),
              onPressed: onLogs,
              icon: const Icon(Icons.list_alt, size: 16),
              label: const Text('View logs'),
            ),
            if (canMutate)
              OutlinedButton.icon(
                key: Key('vendor_connections_disconnect_${row.vendorId}'),
                onPressed: onDisconnect,
                icon: const Icon(Icons.link_off, size: 16),
                label: const Text('Disconnect'),
              ),
          ],
        ),
      ],
    );
  }

  String _summaryLine(VendorConnectionRow row) {
    final lastSync = row.lastSyncAt;
    if (lastSync == null) {
      return 'No data received yet. The first poll runs in the next few minutes.';
    }
    final ago = DateTime.now().toUtc().difference(lastSync);
    final unit = ago.inMinutes < 60
        ? '${ago.inMinutes} min ago'
        : ago.inHours < 24
            ? '${ago.inHours} hr ago'
            : '${ago.inDays} days ago';
    final records = row.recordsLast24h ?? 0;
    final errors = row.errorsLast24h ?? 0;
    return 'Last sync: $unit · $records records · $errors errors (24h)';
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status, this.message});

  final VendorConnectionStatus status;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final tip = _tooltipFor(status, message);
    final color = _colorFor(context, status);
    final label = _labelFor(status);
    return Tooltip(
      message: tip,
      child: Chip(
        key: Key('vendor_connections_status_$label'),
        label: Text(label),
        backgroundColor: color.withValues(alpha: 0.12),
        side: BorderSide(color: color),
      ),
    );
  }

  String _labelFor(VendorConnectionStatus status) {
    switch (status) {
      case VendorConnectionStatus.connected:
        return 'connected';
      case VendorConnectionStatus.disconnected:
        return 'disconnected';
      case VendorConnectionStatus.error:
        return 'error';
    }
  }

  String _tooltipFor(VendorConnectionStatus status, String? message) {
    switch (status) {
      case VendorConnectionStatus.connected:
        return 'Live data is flowing. Sync is healthy.';
      case VendorConnectionStatus.disconnected:
        return 'Sync is paused. Historical data stays. Click Reconnect to resume.';
      case VendorConnectionStatus.error:
        return message ??
            'Something is wrong. Most often the vendor revoked our access. '
                'Click Reconnect and sign back in.';
    }
  }

  Color _colorFor(BuildContext context, VendorConnectionStatus status) {
    switch (status) {
      case VendorConnectionStatus.connected:
        return Colors.green;
      case VendorConnectionStatus.disconnected:
        return Colors.grey;
      case VendorConnectionStatus.error:
        return Colors.red;
    }
  }
}

class _ErrorRemediation extends StatelessWidget {
  const _ErrorRemediation({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.05),
        border: Border.all(color: Colors.red.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Vendor revoked our access',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(
            'This usually means someone changed the vendor password or revoked '
            "an integration in your vendor's portal. Your historical data is "
            'safe.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Text(
            'Click Reconnect and sign in with your current password. We will '
            'fill any gap from when sync broke.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Text(
            'Vendor message: $message',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      color: Colors.red.withValues(alpha: 0.1),
      child: Text(message, style: Theme.of(context).textTheme.bodyMedium),
    );
  }
}

class _VendorPickerDialog extends StatefulWidget {
  const _VendorPickerDialog({required this.category, required this.entries});

  final VendorCategory category;
  final List<VendorPickerEntry> entries;

  @override
  State<_VendorPickerDialog> createState() => _VendorPickerDialogState();
}

class _VendorPickerDialogState extends State<_VendorPickerDialog> {
  String? _picked;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('vendor_connections_picker_dialog'),
      title: Text(_titleFor(widget.category)),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            DropdownButtonFormField<String>(
              key: const Key('vendor_connections_picker_dropdown'),
              initialValue: _picked,
              items: <DropdownMenuItem<String>>[
                for (final entry in widget.entries)
                  DropdownMenuItem<String>(
                    value: entry.vendorId,
                    child: Text(
                      _labelFor(entry),
                    ),
                  ),
              ],
              onChanged: (v) => setState(() => _picked = v),
              decoration: const InputDecoration(
                labelText: 'Vendor',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Some vendors are still being onboarded with us. We mark those '
              "as 'coming soon' in the dropdown — the Connect button activates "
              'as soon as production credentials are live.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('vendor_connections_picker_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('vendor_connections_picker_continue'),
          onPressed: _picked == null
              ? null
              : () {
                  final entry = widget.entries.firstWhere(
                    (e) => e.vendorId == _picked,
                  );
                  Navigator.of(context).pop(entry);
                },
          child: const Text('Continue'),
        ),
      ],
    );
  }

  String _titleFor(VendorCategory category) {
    switch (category) {
      case VendorCategory.pos:
        return 'Which POS does this location use?';
      case VendorCategory.labor:
        return 'Which scheduling system does this location use?';
      case VendorCategory.reservation:
        return 'Which reservation system does this location use?';
    }
  }

  String _labelFor(VendorPickerEntry entry) {
    final tags = <String>[];
    switch (entry.lifecycle) {
      case VendorLifecycle.documented:
        tags.add('coming soon');
        break;
      case VendorLifecycle.sandboxVerified:
        tags.add('coming soon — sandbox verified');
        break;
      case VendorLifecycle.productionCredentialed:
      case VendorLifecycle.liveWithOperators:
        break;
    }
    if (entry.requiresModule) tags.add('asks for module');
    if (!entry.coversFieldExposed && entry.category == VendorCategory.pos) {
      tags.add('no covers');
    }
    return tags.isEmpty
        ? entry.displayName
        : '${entry.displayName} (${tags.join(' · ')})';
  }
}

class _ModuleDisambiguationDialog extends StatelessWidget {
  const _ModuleDisambiguationDialog({required this.entry});

  final VendorPickerEntry entry;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('vendor_connections_module_dialog'),
      title: Text('Which ${entry.displayName} product does this location use?'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final module in entry.modules)
              TextButton(
                key: Key('vendor_connections_module_${entry.vendorId}_$module'),
                onPressed: () => Navigator.of(context).pop(
                  _isSupportedModule(entry.vendorId, module)
                      ? module
                      : 'unsupported',
                ),
                child: Text(_moduleLabel(entry.vendorId, module)),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('vendor_connections_module_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  bool _isSupportedModule(String vendorId, String module) {
    if (vendorId == 'quickbooks_time') return module == 'time';
    if (vendorId == 'adp') return module != 'run';
    return true;
  }

  String _moduleLabel(String vendorId, String module) {
    if (vendorId == 'quickbooks_time') {
      switch (module) {
        case 'time':
          return 'QuickBooks Time';
        case 'accounting':
          return 'QuickBooks Accounting (use the Connected services tab instead)';
        case 'payroll':
          return 'QuickBooks Payroll - not supported';
      }
    }
    if (vendorId == 'adp') {
      switch (module) {
        case 'workforce_now':
          return 'ADP Workforce Now';
        case 'workforce_manager':
          return 'ADP Workforce Manager';
        case 'run':
          return 'ADP RUN - not supported';
      }
    }
    return module;
  }
}

class _UnsupportedModuleDialog extends StatelessWidget {
  const _UnsupportedModuleDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('vendor_connections_unsupported_module_dialog'),
      title: const Text('That module is not supported'),
      content: const Text(
        'Forge & Flow does not support that vendor module today. '
        'Pick a different scheduling vendor or contact support if you '
        'need help mapping your data.',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    );
  }
}

class _TestConnectionLoadingDialog extends StatelessWidget {
  const _TestConnectionLoadingDialog();

  @override
  Widget build(BuildContext context) {
    return const AlertDialog(
      key: Key('vendor_connections_test_loading_dialog'),
      title: Text('Testing connection...'),
      content: SizedBox(
        height: 60,
        child: Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

class _TestConnectionResultDialog extends StatelessWidget {
  const _TestConnectionResultDialog({required this.row, required this.result});

  final VendorConnectionRow row;
  final VendorTestConnectionResult result;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('vendor_connections_test_result_dialog'),
      title: Text('Test connection - ${row.displayName}'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              result.authValid
                  ? '✓ Auth valid'
                  : '✗ Auth invalid - reconnect to fix',
            ),
            const SizedBox(height: 4),
            Text('✓ Sample pulled in ${result.elapsedMs}ms'),
            const SizedBox(height: 8),
            const Text('Sample:'),
            Text(result.sampleSummary),
            const SizedBox(height: 8),
            const Text('Field mapping:'),
            for (final entry in result.fieldMapping.entries)
              Text('  ${entry.key} -> ${entry.value}'),
            if (result.note != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(result.note!),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('vendor_connections_test_close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _DisconnectConfirmDialog extends StatelessWidget {
  const _DisconnectConfirmDialog({required this.row});

  final VendorConnectionRow row;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('vendor_connections_disconnect_dialog'),
      title: Text('Disconnect ${row.displayName}?'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const <Widget>[
            Text('When you confirm:'),
            SizedBox(height: 4),
            Text(
              '• Your historical data stays in Forge & Flow. Nothing is deleted.',
            ),
            Text(
              '• Live sync stops immediately. New events from the vendor will not appear in your dashboard.',
            ),
            Text(
              '• We wipe the credentials we have for this vendor and tell the vendor to stop sending us your data.',
            ),
            Text(
              '• If you reconnect later, we resume from where we left off, so you do not need to re-pull 60 days.',
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('vendor_connections_disconnect_cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('vendor_connections_disconnect_confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text('Yes, disconnect ${row.displayName}'),
        ),
      ],
    );
  }
}

class _SyncLogsDialog extends StatelessWidget {
  const _SyncLogsDialog({required this.row, required this.entries});

  final VendorConnectionRow row;
  final List<VendorSyncLogEntry> entries;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('vendor_connections_logs_dialog'),
      title: Text('Sync logs - ${row.displayName}'),
      content: SizedBox(
        width: 480,
        height: 360,
        child: entries.isEmpty
            ? const Center(child: Text('No sync events recorded yet.'))
            : ListView.separated(
                itemCount: entries.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  final ts = entry.occurredAt.toIso8601String();
                  final body = entry.errorMessage != null
                      ? '${entry.eventKind} - ${entry.errorMessage}'
                      : entry.recordsCount != null
                          ? '${entry.eventKind} - ${entry.recordsCount} records'
                          : entry.eventKind;
                  return ListTile(
                    dense: true,
                    title: Text(ts),
                    subtitle: Text(body),
                  );
                },
              ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('vendor_connections_logs_close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
