// Phase 8.0 / Wave C1 — Module disambiguation + unsupported-module
// dialogs for the shared Vendor Connections widget tree.
//
// Extracted from `vendor_connections_widget.dart` (Wave C1 code-health
// pass). Behavior is byte-stable.

part of '../vendor_connections_widget.dart';

class _ModuleDisambiguationDialog extends StatelessWidget {
  const _ModuleDisambiguationDialog({required this.entry});

  final VendorPickerEntry entry;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('vendor_connections_module_dialog'),
      title: Text('Choose the ${entry.displayName} product'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'This vendor has more than one product. Pick the one that owns scheduling and labor data for this location.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            for (final module in entry.modules)
              Padding(
                key: Key('vendor_connections_module_${entry.vendorId}_$module'),
                padding: const EdgeInsets.only(bottom: 8),
                child: _DialogChoiceTile(
                  leading: Icon(
                    _moduleIcon(entry.vendorId, module),
                    color: _isSupportedModule(entry.vendorId, module)
                        ? AppColors.peacockDark
                        : AppColors.textMuted,
                  ),
                  title: _moduleLabel(entry.vendorId, module),
                  subtitle: _moduleHelp(entry.vendorId, module),
                  tags: _isSupportedModule(entry.vendorId, module)
                      ? const <String>['Supported']
                      : const <String>['Coming soon'],
                  onTap: () => Navigator.of(context).pop(
                    _isSupportedModule(entry.vendorId, module)
                        ? module
                        : 'unsupported',
                  ),
                ),
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

  IconData _moduleIcon(String vendorId, String module) {
    if (vendorId == 'quickbooks_time') {
      switch (module) {
        case 'time':
          return Icons.schedule_outlined;
        case 'accounting':
          return Icons.receipt_long_outlined;
        case 'payroll':
          return Icons.payments_outlined;
      }
    }
    return Icons.account_tree_outlined;
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

  String _moduleHelp(String vendorId, String module) {
    if (vendorId == 'quickbooks_time') {
      switch (module) {
        case 'time':
          return 'Use this for timesheets, punches, and labor timing.';
        case 'accounting':
          return 'Accounting data belongs in the internal connected services area.';
        case 'payroll':
          return 'Payroll setup is not part of the current vendor integration flow.';
      }
    }
    if (vendorId == 'adp') {
      switch (module) {
        case 'workforce_now':
          return 'Use this for ADP scheduling and workforce data.';
        case 'workforce_manager':
          return 'Use this for ADP manager scheduling and time data.';
        case 'run':
          return 'ADP RUN is not supported in this flow yet.';
      }
    }
    return 'Use this product for the selected vendor connection.';
  }
}

class _UnsupportedModuleDialog extends StatelessWidget {
  const _UnsupportedModuleDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('vendor_connections_unsupported_module_dialog'),
      title: const Text('That module is not supported'),
      content: _DialogNotice(
        icon: Icons.info_outline,
        title: 'Choose a supported product for now',
        body:
            'Forge & Flow cannot connect that module yet. Pick a supported scheduling product, or contact support if this operator needs a custom mapping.',
        color: AppColors.warning,
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
