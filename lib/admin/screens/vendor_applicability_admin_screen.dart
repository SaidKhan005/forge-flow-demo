// B10.2 - F&F admin editor for vendor_applicability.
//
// This screen is intentionally gateway-driven. B10.1 owns schema,
// repository, proxy routes, idempotency, and audit writes; the UI only
// reads current/history rows and sends admin-reviewed temporal writes.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:forge_and_flow/widgets/console/console_screen_header.dart';
import 'package:forge_and_flow/widgets/console/console_surface.dart';

import '../../services/settings/applicability_metadata_schemas.dart';
import '../../theme/app_theme.dart';
import '../admin_button_styles.dart';
import '../services/vendor_applicability_admin_gateway.dart';

class VendorApplicabilityAdminScreen extends StatefulWidget {
  const VendorApplicabilityAdminScreen({
    super.key,
    required this.gateway,
    this.editingEnabled = true,
    this.initialSettingKind = VendorApplicabilitySettingKind.wage,
  });

  final VendorApplicabilityAdminGateway gateway;
  final bool editingEnabled;
  final String initialSettingKind;

  @override
  State<VendorApplicabilityAdminScreen> createState() =>
      _VendorApplicabilityAdminScreenState();
}

class _VendorApplicabilityAdminScreenState
    extends State<VendorApplicabilityAdminScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  bool _loading = true;
  bool _saving = false;
  String? _loadError;
  String? _actionError;
  List<VendorApplicabilityAdminRow> _rows =
      const <VendorApplicabilityAdminRow>[];
  int _loadGeneration = 0;
  int _idempotencyCounter = 0;

  static const List<_SettingKindSpec> _tabs = <_SettingKindSpec>[
    _SettingKindSpec(
      kind: VendorApplicabilitySettingKind.wage,
      label: 'Wage',
      copy: 'Which vendors can act as the wage source?',
    ),
    _SettingKindSpec(
      kind: VendorApplicabilitySettingKind.covers,
      label: 'Covers',
      copy: 'Which vendors can act as the covers source?',
    ),
    _SettingKindSpec(
      kind: VendorApplicabilitySettingKind.polling,
      label: 'Polling',
      copy: 'Which vendors can use each polling setup?',
    ),
  ];

  String get _selectedKind => _tabs[_tabController.index].kind;

  @override
  void initState() {
    super.initState();
    final initialIndex = _tabs.indexWhere(
      (tab) => tab.kind == widget.initialSettingKind,
    );
    _tabController =
        TabController(
          length: _tabs.length,
          vsync: this,
          initialIndex: initialIndex < 0 ? 0 : initialIndex,
        )..addListener(() {
          if (!_tabController.indexIsChanging) _refresh();
        });
    _refresh();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _loadError = null;
      _actionError = null;
    });
    try {
      final rows = await widget.gateway.list(
        filter: VendorApplicabilityAdminFilter(
          settingKind: _selectedKind,
          currentOnly: false,
        ),
      );
      rows.sort((a, b) {
        final setting = a.settingKey.compareTo(b.settingKey);
        if (setting != 0) return setting;
        final vendor = a.vendorSlug.compareTo(b.vendorSlug);
        if (vendor != 0) return vendor;
        return b.effectiveFrom.compareTo(a.effectiveFrom);
      });
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _rows = rows;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loadError = 'Could not load vendor applicability: $error';
        _loading = false;
      });
    }
  }

  String _newIdempotencyKey(String action) {
    _idempotencyCounter += 1;
    return 'admin-vendor-applicability-$action-'
        '${DateTime.now().microsecondsSinceEpoch}-$_idempotencyCounter';
  }

  Future<void> _openAddDialog() async {
    final draft = await showDialog<_VendorApplicabilityDraft>(
      context: context,
      builder: (_) =>
          _VendorApplicabilityEditDialog(settingKind: _selectedKind),
    );
    if (draft == null) return;
    await _upsertDraft(draft);
  }

  Future<void> _openEditDialog(VendorApplicabilityAdminRow row) async {
    final draft = await showDialog<_VendorApplicabilityDraft>(
      context: context,
      builder: (_) => _VendorApplicabilityEditDialog(
        settingKind: row.settingKind,
        initial: row,
      ),
    );
    if (draft == null) return;
    await _upsertDraft(draft);
  }

  Future<void> _toggleRow(VendorApplicabilityAdminRow row, bool value) async {
    if (!widget.editingEnabled || _saving || row.effectiveUntil != null) return;
    final reason = await _askReason(
      title: value ? 'Enable ${row.vendorSlug}?' : 'Disable ${row.vendorSlug}?',
      helper:
          'This creates a new temporal row and keeps the previous row in history.',
    );
    if (reason == null) return;
    await _upsertDraft(
      _VendorApplicabilityDraft(
        operatorId: row.operatorId,
        settingKind: row.settingKind,
        settingKey: row.settingKey,
        vendorSlug: row.vendorSlug,
        enabled: value,
        metadata: row.metadata,
        reasonNote: reason,
      ),
    );
  }

  Future<void> _endRow(VendorApplicabilityAdminRow row) async {
    if (!widget.editingEnabled || _saving || row.effectiveUntil != null) return;
    final reason = await _askReason(
      title: 'End ${row.vendorSlug}?',
      helper: 'Ending a row sets effective_until. It does not delete history.',
    );
    if (reason == null) return;
    setState(() {
      _saving = true;
      _actionError = null;
    });
    try {
      await widget.gateway.end(
        VendorApplicabilityEndCommand(
          operatorId: row.operatorId,
          settingKind: row.settingKind,
          settingKey: row.settingKey,
          vendorSlug: row.vendorSlug,
          adminReason: 'admin.vendor_applicability.end',
          reasonNote: reason,
          idempotencyKey: _newIdempotencyKey('end'),
        ),
      );
      await _refresh();
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = 'Could not end row: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _upsertDraft(_VendorApplicabilityDraft draft) async {
    setState(() {
      _saving = true;
      _actionError = null;
    });
    try {
      await widget.gateway.upsert(
        VendorApplicabilityUpsertCommand(
          operatorId: draft.operatorId,
          settingKind: draft.settingKind,
          settingKey: draft.settingKey,
          vendorSlug: draft.vendorSlug,
          enabled: draft.enabled,
          metadata: draft.metadata,
          adminReason: 'admin.vendor_applicability.upsert',
          reasonNote: draft.reasonNote,
          idempotencyKey: _newIdempotencyKey('upsert'),
        ),
      );
      await _refresh();
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = 'Could not save row: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<String?> _askReason({required String title, required String helper}) {
    return showDialog<String>(
      context: context,
      builder: (_) => _ReasonDialog(title: title, helper: helper),
    );
  }

  @override
  Widget build(BuildContext context) {
    final spec = _tabs[_tabController.index];
    return Container(
      key: const Key('admin_vendor_applicability_screen'),
      color: AppColors.backgroundDeep,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const OperatorWebScreenHeader(
              icon: Icons.rule_outlined,
              title: 'Vendor Applicability',
              collapseBelowWidth: 0,
              subtitle:
                  'Choose which vendors are allowed to power wage, covers, and polling settings.',
            ),
            const SizedBox(height: 14),
            if (!widget.editingEnabled)
              const _InlineBanner(
                key: Key('admin_vendor_applicability_readonly'),
                icon: Icons.lock_outline,
                message:
                    'Only super admins can change vendor applicability. This view is read-only for support.',
              ),
            if (_actionError != null)
              _InlineBanner(
                key: const Key('admin_vendor_applicability_action_error'),
                icon: Icons.warning_amber_rounded,
                message: _actionError!,
                isError: true,
              ),
            Container(
              decoration: BoxDecoration(
                color: AppColors.backgroundSurface,
                border: Border.all(color: AppColors.borderSubtle, width: 1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: TabBar(
                controller: _tabController,
                labelColor: AppColors.textPrimary,
                unselectedLabelColor: AppColors.textMuted,
                indicatorColor: AppColors.sunsetDark,
                tabs: [for (final tab in _tabs) Tab(text: tab.label)],
              ),
            ),
            const SizedBox(height: 12),
            _Toolbar(
              copy: spec.copy,
              saving: _saving,
              editingEnabled: widget.editingEnabled,
              onAdd: _openAddDialog,
              onRefresh: _refresh,
            ),
            const SizedBox(height: 12),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        key: Key('admin_vendor_applicability_loading'),
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: AppColors.sunsetDark,
        ),
      );
    }
    if (_loadError != null) {
      return _InlineBanner(
        key: const Key('admin_vendor_applicability_load_error'),
        icon: Icons.warning_amber_rounded,
        message: _loadError!,
        isError: true,
      );
    }
    if (_rows.isEmpty) {
      return const _EmptyState();
    }
    // The table fills the remaining pane height and scrolls internally
    // (bidirectional). It is intentionally NOT wrapped in an
    // OperatorWebPanel: the panel renders its body in a non-flex Column,
    // which removes the bounded height the vertical scroll view needs and
    // overflows the fixed-height function pane at the 800x600 widget-test
    // viewport. The shared-kit adoption lands on the header, banners, and
    // dialogs, matching the Launch controls sibling's body treatment.
    return Scrollbar(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SingleChildScrollView(
          child: DataTable(
            key: const Key('admin_vendor_applicability_table'),
            headingTextStyle: AppTextStyles.mono12(
              color: AppColors.textMuted,
              weight: FontWeight.w700,
            ),
            dataTextStyle: AppTextStyles.body12(color: AppColors.textPrimary),
            columns: const <DataColumn>[
              DataColumn(label: Text('Vendor')),
              DataColumn(label: Text('Setting key')),
              DataColumn(label: Text('Scope')),
              DataColumn(label: Text('Enabled')),
              DataColumn(label: Text('Effective from')),
              DataColumn(label: Text('Effective until')),
              DataColumn(label: Text('Metadata JSON')),
              DataColumn(label: Text('Actions')),
            ],
            rows: [
              for (final row in _rows)
                DataRow(
                  key: ValueKey('vendor_applicability_${row.id}'),
                  cells: [
                    DataCell(Text(row.vendorSlug)),
                    DataCell(Text(row.settingKey)),
                    DataCell(Text(row.operatorId ?? 'F&F default')),
                    DataCell(
                      Switch(
                        key: Key(
                          'admin_vendor_applicability_toggle_'
                          '${row.settingKind}_${row.settingKey}_'
                          '${row.vendorSlug}',
                        ),
                        value: row.enabled,
                        onChanged:
                            widget.editingEnabled &&
                                row.effectiveUntil == null &&
                                !_saving
                            ? (value) => _toggleRow(row, value)
                            : null,
                      ),
                    ),
                    DataCell(Text(_formatDate(row.effectiveFrom))),
                    DataCell(Text(_formatDate(row.effectiveUntil))),
                    DataCell(
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 360),
                        child: Text(
                          _prettyJson(row.metadata),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    DataCell(
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            key: Key(
                              'admin_vendor_applicability_edit_${row.id}',
                            ),
                            tooltip: 'Edit metadata',
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            onPressed: widget.editingEnabled && !_saving
                                ? () => _openEditDialog(row)
                                : null,
                          ),
                          IconButton(
                            key: Key(
                              'admin_vendor_applicability_end_${row.id}',
                            ),
                            tooltip: 'End row',
                            icon: const Icon(
                              Icons.event_busy_outlined,
                              size: 18,
                            ),
                            onPressed:
                                widget.editingEnabled &&
                                    row.effectiveUntil == null &&
                                    !_saving
                                ? () => _endRow(row)
                                : null,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingKindSpec {
  const _SettingKindSpec({
    required this.kind,
    required this.label,
    required this.copy,
  });

  final String kind;
  final String label;
  final String copy;
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.copy,
    required this.saving,
    required this.editingEnabled,
    required this.onAdd,
    required this.onRefresh,
  });

  final String copy;
  final bool saving;
  final bool editingEnabled;
  final VoidCallback onAdd;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    // Kept as a compact single-row surface (not an OperatorWebPanel): the
    // admin route is built at the default 800x600 widget-test viewport
    // where the function pane is only ~239 dp tall, and a panel's section
    // heading + accent rule + copy block overflows the screen's static
    // Column there. The OperatorWebPanel adoption lands on the data table
    // and dialogs instead, where it fits.
    return Container(
      key: const Key('admin_vendor_applicability_toolbar'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              copy,
              style: AppTextStyles.body14(color: AppColors.textPrimary),
            ),
          ),
          IconButton(
            key: const Key('admin_vendor_applicability_refresh'),
            tooltip: 'Refresh',
            onPressed: saving ? null : onRefresh,
            icon: const Icon(Icons.refresh_outlined),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            key: const Key('admin_vendor_applicability_add'),
            style: AdminButtonStyles.primary,
            onPressed: editingEnabled && !saving ? onAdd : null,
            icon: const Icon(Icons.add_outlined, size: 18),
            label: Text(saving ? 'Saving...' : 'Add vendor'),
          ),
        ],
      ),
    );
  }
}

class _VendorApplicabilityDraft {
  const _VendorApplicabilityDraft({
    required this.operatorId,
    required this.settingKind,
    required this.settingKey,
    required this.vendorSlug,
    required this.enabled,
    required this.metadata,
    required this.reasonNote,
  });

  final String? operatorId;
  final String settingKind;
  final String settingKey;
  final String vendorSlug;
  final bool enabled;
  final Map<String, Object?> metadata;
  final String reasonNote;
}

class _VendorApplicabilityEditDialog extends StatefulWidget {
  const _VendorApplicabilityEditDialog({
    required this.settingKind,
    this.initial,
  });

  final String settingKind;
  final VendorApplicabilityAdminRow? initial;

  @override
  State<_VendorApplicabilityEditDialog> createState() =>
      _VendorApplicabilityEditDialogState();
}

class _VendorApplicabilityEditDialogState
    extends State<_VendorApplicabilityEditDialog> {
  static final RegExp _slugPattern = RegExp(r'^[a-z][a-z0-9_]{0,63}$');

  late final TextEditingController _operatorId = TextEditingController(
    text: widget.initial?.operatorId ?? '',
  );
  late final TextEditingController _settingKey = TextEditingController(
    text: widget.initial?.settingKey ?? 'default',
  );
  late final TextEditingController _vendorSlug = TextEditingController(
    text: widget.initial?.vendorSlug ?? '',
  );
  late final TextEditingController _metadata = TextEditingController(
    text: _prettyJson(widget.initial?.metadata ?? const <String, Object?>{}),
  );
  final TextEditingController _reason = TextEditingController();
  late bool _enabled = widget.initial?.enabled ?? true;
  String? _error;

  @override
  void dispose() {
    _operatorId.dispose();
    _settingKey.dispose();
    _vendorSlug.dispose();
    _metadata.dispose();
    _reason.dispose();
    super.dispose();
  }

  void _submit() {
    final operatorId = _operatorId.text.trim();
    final settingKey = _settingKey.text.trim();
    final vendorSlug = _vendorSlug.text.trim();
    final reason = _reason.text.trim();
    if (!_slugPattern.hasMatch(settingKey)) {
      setState(() => _error = 'Setting key must be a lowercase slug.');
      return;
    }
    if (!_slugPattern.hasMatch(vendorSlug)) {
      setState(() => _error = 'Vendor slug must be a lowercase slug.');
      return;
    }
    if (reason.isEmpty) {
      setState(() => _error = 'Reason is required for the audit log.');
      return;
    }
    late final Map<String, Object?> metadata;
    try {
      final parsed = jsonDecode(
        _metadata.text.trim().isEmpty ? '{}' : _metadata.text.trim(),
      );
      if (parsed is! Map) {
        setState(() => _error = 'Metadata JSON must be an object.');
        return;
      }
      metadata = parsed.cast<String, Object?>();
      assertApplicabilityMetadataValid(
        settingKind: widget.settingKind,
        metadata: metadata,
      );
    } on FormatException catch (error) {
      setState(() => _error = 'Metadata JSON is invalid: ${error.message}');
      return;
    } on ApplicabilityMetadataValidationException catch (error) {
      setState(() => _error = error.message);
      return;
    }
    Navigator.of(context).pop(
      _VendorApplicabilityDraft(
        operatorId: operatorId.isEmpty ? null : operatorId,
        settingKind: widget.settingKind,
        settingKey: settingKey,
        vendorSlug: vendorSlug,
        enabled: _enabled,
        metadata: metadata,
        reasonNote: reason,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.initial != null;
    return OperatorWebDialog(
      key: const Key('admin_vendor_applicability_edit_dialog'),
      title: editing
          ? 'Edit vendor applicability'
          : 'Add vendor applicability',
      maxWidth: 560,
      actions: [
        TextButton(
          key: const Key('admin_vendor_applicability_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_vendor_applicability_submit'),
          style: AdminButtonStyles.primary,
          onPressed: _submit,
          child: Text(editing ? 'Save row' : 'Add row'),
        ),
      ],
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('admin_vendor_applicability_operator_id'),
              controller: _operatorId,
              decoration: const InputDecoration(
                labelText: 'Operator id (blank for F&F default)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('admin_vendor_applicability_setting_key'),
              controller: _settingKey,
              decoration: const InputDecoration(
                labelText: 'Setting key',
                helperText: 'Use default unless a setting has named variants.',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('admin_vendor_applicability_vendor_slug'),
              controller: _vendorSlug,
              decoration: const InputDecoration(
                labelText: 'Vendor slug',
                helperText: 'Example: toast, seven_shifts, libro.',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            SwitchListTile(
              key: const Key('admin_vendor_applicability_enabled'),
              value: _enabled,
              contentPadding: EdgeInsets.zero,
              title: const Text('Enabled'),
              onChanged: (value) => setState(() => _enabled = value),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('admin_vendor_applicability_metadata'),
              controller: _metadata,
              minLines: 4,
              maxLines: 8,
              style: AppTextStyles.mono11(color: AppColors.textPrimary),
              decoration: const InputDecoration(
                labelText: 'Metadata JSON',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('admin_vendor_applicability_reason'),
              controller: _reason,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Reason for change',
                border: OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                key: const Key('admin_vendor_applicability_dialog_error'),
                style: AppTextStyles.body12(color: AppColors.negative),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReasonDialog extends StatefulWidget {
  const _ReasonDialog({required this.title, required this.helper});

  final String title;
  final String helper;

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final reason = _controller.text.trim();
    if (reason.isEmpty) {
      setState(() => _error = 'Reason is required for the audit log.');
      return;
    }
    Navigator.of(context).pop(reason);
  }

  @override
  Widget build(BuildContext context) {
    return OperatorWebDialog(
      key: const Key('admin_vendor_applicability_reason_dialog'),
      title: widget.title,
      maxWidth: 420,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: AdminButtonStyles.primary,
          onPressed: _submit,
          child: const Text('Continue'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.helper),
          const SizedBox(height: 10),
          TextField(
            key: const Key('admin_vendor_applicability_reason_note'),
            controller: _controller,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Reason',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: AppTextStyles.body12(color: AppColors.negative),
            ),
          ],
        ],
      ),
    );
  }
}

class _InlineBanner extends StatelessWidget {
  const _InlineBanner({
    super.key,
    required this.icon,
    required this.message,
    this.isError = false,
  });

  final IconData icon;
  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: OperatorWebBanner(
        icon: icon,
        message: message,
        tone: isError
            ? OperatorWebBannerTone.error
            : OperatorWebBannerTone.neutral,
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const Key('admin_vendor_applicability_empty'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Text(
          'No rows yet for this setting kind. Add a vendor to publish a current applicability row.',
          textAlign: TextAlign.center,
          style: AppTextStyles.body14(color: AppColors.textSecondary),
        ),
      ),
    );
  }
}

String _prettyJson(Map<String, Object?> value) {
  return const JsonEncoder.withIndent('  ').convert(value);
}

String _formatDate(DateTime? value) {
  if (value == null) return 'Current';
  final utc = value.toUtc();
  return '${utc.year.toString().padLeft(4, '0')}-'
      '${utc.month.toString().padLeft(2, '0')}-'
      '${utc.day.toString().padLeft(2, '0')}';
}
