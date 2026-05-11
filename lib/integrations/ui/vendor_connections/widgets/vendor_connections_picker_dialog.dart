// Phase 8.0 / Wave C1 — Vendor catalog picker dialog (selection seam +
// lifecycle gating) for the shared Vendor Connections widget tree.
//
// Extracted from `vendor_connections_widget.dart` (Wave C1 code-health
// pass). Behavior is byte-stable. Title, grid, card, and selected
// panel chrome live in the sibling `vendor_connections_picker_grid`
// part file.

part of '../vendor_connections_widget.dart';

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
    final viewport = MediaQuery.sizeOf(context);
    final dialogWidth = (viewport.width - 48).clamp(280.0, 860.0).toDouble();
    final dialogMaxHeight = (viewport.height * 0.76)
        .clamp(320.0, 720.0)
        .toDouble();
    final selected = _picked == null
        ? null
        : widget.entries.firstWhere((entry) => entry.vendorId == _picked);
    final canContinue = selected != null && _isApiReachable(selected.lifecycle);
    return AlertDialog(
      key: const Key('vendor_connections_picker_dialog'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 18),
      title: _VendorPickerTitle(
        category: widget.category,
        title: _titleFor(widget.category),
        count: widget.entries.length,
      ),
      content: SizedBox(
        width: dialogWidth,
        height: dialogMaxHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              _introFor(widget.category),
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 6),
            Text(
              'Vendors marked API pending are visible before reachable '
              'production access has been verified.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: SingleChildScrollView(
                key: const Key('vendor_connections_picker_scroll_area'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _VendorPickerGrid(
                      entries: widget.entries,
                      pickedVendorId: _picked,
                      summaryFor: _vendorSummaryFor,
                      tagsFor: _tagsFor,
                      onPick: (entry) =>
                          setState(() => _picked = entry.vendorId),
                    ),
                    if (selected != null) ...<Widget>[
                      const SizedBox(height: 14),
                      _SelectedVendorPanel(
                        entry: selected,
                        canContinue: canContinue,
                        reason: canContinue
                            ? _connectableReasonFor(selected)
                            : _unavailableReasonFor(selected.lifecycle),
                      ),
                    ],
                  ],
                ),
              ),
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
          onPressed: !canContinue
              ? null
              : () {
                  Navigator.of(context).pop(selected);
                },
          child: const Text('Continue'),
        ),
      ],
    );
  }

  bool _isApiReachable(VendorLifecycle lifecycle) {
    switch (lifecycle) {
      case VendorLifecycle.documented:
      case VendorLifecycle.sandboxVerified:
        return false;
      case VendorLifecycle.productionCredentialed:
      case VendorLifecycle.liveWithOperators:
        return true;
    }
  }

  String _unavailableReasonFor(VendorLifecycle lifecycle) {
    switch (lifecycle) {
      case VendorLifecycle.documented:
        return 'The adapter exists, but F&F has not verified reachable production API access yet.';
      case VendorLifecycle.sandboxVerified:
        return 'Sandbox validation is complete, but reachable production API access is still pending.';
      case VendorLifecycle.productionCredentialed:
      case VendorLifecycle.liveWithOperators:
        return 'API access is reachable and this vendor can be connected now.';
    }
  }

  String _connectableReasonFor(VendorPickerEntry entry) {
    switch (entry.lifecycle) {
      case VendorLifecycle.productionCredentialed:
        return '${entry.displayName} has reachable API access for this connection flow.';
      case VendorLifecycle.liveWithOperators:
        return '${entry.displayName} is already live with at least one operator, so API access is reachable here.';
      case VendorLifecycle.documented:
      case VendorLifecycle.sandboxVerified:
        return _unavailableReasonFor(entry.lifecycle);
    }
  }

  String _titleFor(VendorCategory category) {
    switch (category) {
      case VendorCategory.pos:
        return 'Choose the POS vendor';
      case VendorCategory.labor:
        return 'Choose the scheduling vendor';
      case VendorCategory.reservation:
        return 'Choose the reservations vendor';
    }
  }

  String _introFor(VendorCategory category) {
    switch (category) {
      case VendorCategory.pos:
        return 'Pick the system that owns sales, checks, and cover counts for this location.';
      case VendorCategory.labor:
        return 'Pick the system that owns schedules, punches, and role data for this location.';
      case VendorCategory.reservation:
        return 'Pick the system that owns bookings, party sizes, and reservation pacing for this location.';
    }
  }

  String _vendorSummaryFor(VendorPickerEntry entry) {
    switch (entry.category) {
      case VendorCategory.pos:
        return entry.coversFieldExposed
            ? 'Reads closed checks, sales, timing, and cover counts.'
            : 'Reads sales data. Cover counts may need a separate source.';
      case VendorCategory.labor:
        return 'Reads schedules, time punches, and team role data.';
      case VendorCategory.reservation:
        return 'Reads bookings, party sizes, and reservation timing.';
    }
  }

  List<String> _tagsFor(VendorPickerEntry entry) {
    final tags = <String>[];
    final lifecycleTag = _lifecycleTagFor(entry.lifecycle);
    if (lifecycleTag != null) tags.add(lifecycleTag);
    if (entry.requiresModule) tags.add('Pick a product');
    if (!entry.coversFieldExposed && entry.category == VendorCategory.pos) {
      tags.add('No cover count');
    }
    tags.add(_authModeLabel(entry.authMode));
    return tags;
  }

  String? _lifecycleTagFor(VendorLifecycle lifecycle) {
    switch (lifecycle) {
      case VendorLifecycle.documented:
        return 'API pending';
      case VendorLifecycle.sandboxVerified:
        return 'Sandbox API verified';
      case VendorLifecycle.productionCredentialed:
      case VendorLifecycle.liveWithOperators:
        return null;
    }
  }

  String _authModeLabel(VendorAuthMode mode) {
    switch (mode) {
      case VendorAuthMode.oauth:
        return 'Secure sign-in';
      case VendorAuthMode.keyPaste:
        return 'API key';
      case VendorAuthMode.oauthOrKeyPaste:
        return 'Sign-in or API key';
    }
  }
}
