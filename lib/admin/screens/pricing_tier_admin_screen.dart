// Phase 11A.2 — Pricing tier admin screen.
//
// Admin-side editor over `usage_caps` per (operator, location,
// usage_class, staff_id?, workflow_id?) plus subscription tier on
// `operators.subscription_tier`. Replaces the 11A.0 placeholder in
// `admin_routes.dart`.
//
// Coverage:
//
//   * Lists every operator with their current subscription tier and
//     cap rows.
//   * One-click apply of the locked tier templates (Pilot / Starter /
//     Premium / Elite / Pro / Enterprise) from
//     `phase_11a_decision_register.md`.
//   * Inline edit of per-class monthly + per-invocation USD caps.
//   * Surfaces created_by / updated_by audit metadata.
//
// Brand styling reuses `lib/theme/app_theme.dart` verbatim per the
// 11A non-negotiable. The screen takes a [PricingTierAdminGateway]
// from the outside; production passes the HTTP gateway, demo + widget
// tests pass the in-memory gateway. `editingEnabled` defaults to
// `true`; passing `false` renders a read-only view (used for the
// `ff_support` demo identity walkthrough).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import '../models/pricing_tier_admin_models.dart';
import '../services/pricing_tier_admin_gateway.dart';

class PricingTierAdminScreen extends StatefulWidget {
  const PricingTierAdminScreen({
    super.key,
    required this.gateway,
    this.editingEnabled = true,
  });

  final PricingTierAdminGateway gateway;

  /// When false, the screen hides every mutate affordance — used for
  /// the `ff_support` walkthrough path. The proxy enforces the same
  /// gate server-side; this flag keeps the UI honest about it.
  final bool editingEnabled;

  @override
  State<PricingTierAdminScreen> createState() =>
      _PricingTierAdminScreenState();
}

class _PricingTierAdminScreenState extends State<PricingTierAdminScreen> {
  bool _loading = true;
  String? _loadError;
  List<PricingOperatorBundle> _bundles = const <PricingOperatorBundle>[];
  String? _selectedOperatorId;
  String? _actionError;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final bundles = await widget.gateway.listOperators();
      if (!mounted) return;
      setState(() {
        _bundles = bundles;
        _loading = false;
        if (_selectedOperatorId != null &&
            bundles.every((b) => b.operatorId != _selectedOperatorId)) {
          _selectedOperatorId = null;
        }
        _selectedOperatorId ??=
            bundles.isEmpty ? null : bundles.first.operatorId;
      });
    } on PricingTierAdminGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error.message;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Could not load pricing data: $error';
        _loading = false;
      });
    }
  }

  PricingOperatorBundle? get _selected {
    final id = _selectedOperatorId;
    if (id == null) return null;
    for (final b in _bundles) {
      if (b.operatorId == id) return b;
    }
    return null;
  }

  Future<void> _runAndRefresh(
    Future<void> Function() action, {
    String? successHint,
  }) async {
    setState(() => _actionError = null);
    try {
      await action();
      await _refresh();
      if (successHint != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(successHint)),
        );
      }
    } on PricingTierAdminGatewayError catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_pricing_screen'),
      color: AppColors.backgroundDeep,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _Header(),
            const SizedBox(height: 14),
            if (!widget.editingEnabled)
              const _ReadOnlyBanner(
                key: Key('admin_pricing_readonly_banner'),
              ),
            if (_actionError != null)
              _ErrorBanner(
                key: const Key('admin_pricing_action_error'),
                message: _actionError!,
              ),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        key: Key('admin_pricing_loading'),
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.sunsetDark,
          ),
        ),
      );
    }
    if (_loadError != null) {
      return _ErrorBanner(
        key: const Key('admin_pricing_load_error'),
        message: _loadError!,
      );
    }
    if (_bundles.isEmpty) {
      return Center(
        key: const Key('admin_pricing_empty'),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'No operators on file',
                  style: AppTextStyles.display20(
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Onboard an operator from the Operators tab before '
                  'configuring pricing tiers.',
                  style: AppTextStyles.body13(
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 280,
          child: _OperatorList(
            bundles: _bundles,
            selectedOperatorId: _selectedOperatorId,
            onSelect: (id) => setState(() => _selectedOperatorId = id),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _selected == null
              ? const SizedBox.shrink()
              : _OperatorPricingDetail(
                  bundle: _selected!,
                  editingEnabled: widget.editingEnabled,
                  onApplyTemplate: _onApplyTemplate,
                  onChangeTier: _onChangeTier,
                  onEditCap: _onEditCap,
                  onAddCap: _onAddCap,
                ),
        ),
      ],
    );
  }

  Future<void> _onApplyTemplate(
    PricingOperatorBundle bundle,
    PricingTierTemplate template,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _ConfirmDialog(
        title: 'Apply ${template.displayName} template?',
        message:
            'Sets subscription tier to ${template.subscriptionTier} and '
            'replaces ${template.caps.length} cap row'
            '${template.caps.length == 1 ? '' : 's'} '
            'on ${bundle.businessName}. Existing rows for the same '
            'usage class will be overwritten; other rows are preserved.',
        confirmLabel: 'Apply',
      ),
    );
    if (confirmed != true) return;
    await _runAndRefresh(
      () async {
        await widget.gateway.applyTierTemplate(
          ApplyTierTemplateCommand(
            operatorId: bundle.operatorId,
            tierKey: template.tierKey,
          ),
        );
      },
      successHint: '${template.displayName} template applied.',
    );
  }

  Future<void> _onChangeTier(
    PricingOperatorBundle bundle,
    String newTier,
  ) async {
    if (newTier == bundle.subscriptionTier) return;
    await _runAndRefresh(
      () async {
        await widget.gateway.updateOperatorTier(
          OperatorTierPatchCommand(
            operatorId: bundle.operatorId,
            subscriptionTier: newTier,
          ),
        );
      },
      successHint: 'Subscription tier set to $newTier.',
    );
  }

  Future<void> _onEditCap(
    PricingOperatorBundle bundle,
    UsageCapRow row,
  ) async {
    final command = await showDialog<UsageCapUpsertCommand>(
      context: context,
      builder: (_) => _UsageCapDialog(
        operatorId: bundle.operatorId,
        primaryLocationId: bundle.primaryLocationId,
        existing: row,
      ),
    );
    if (command == null) return;
    await _runAndRefresh(
      () async {
        await widget.gateway.upsertUsageCap(command);
      },
      successHint: 'Cap row updated.',
    );
  }

  Future<void> _onAddCap(PricingOperatorBundle bundle) async {
    final command = await showDialog<UsageCapUpsertCommand>(
      context: context,
      builder: (_) => _UsageCapDialog(
        operatorId: bundle.operatorId,
        primaryLocationId: bundle.primaryLocationId,
      ),
    );
    if (command == null) return;
    await _runAndRefresh(
      () async {
        await widget.gateway.upsertUsageCap(command);
      },
      successHint: 'Cap row added.',
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Pricing',
          style: AppTextStyles.display28(color: AppColors.textPrimary),
        ),
        const SizedBox(height: 4),
        Text(
          'Subscription tier + per-(operator, location, usage_class) '
          'usage caps. Apply a tier template to seed defaults, or edit '
          'individual cap rows inline.',
          style: AppTextStyles.body13(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

class _ReadOnlyBanner extends StatelessWidget {
  const _ReadOnlyBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.lock_outline,
            size: 16,
            color: AppColors.textMuted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'View-only: pricing edits require the super_admin role.',
              style: AppTextStyles.mono11(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _OperatorList extends StatelessWidget {
  const _OperatorList({
    required this.bundles,
    required this.selectedOperatorId,
    required this.onSelect,
  });

  final List<PricingOperatorBundle> bundles;
  final String? selectedOperatorId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_pricing_operator_list'),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: bundles.length,
        separatorBuilder: (_, __) => Container(
          height: 1,
          color: AppColors.borderSubtle.withValues(alpha: 0.4),
        ),
        itemBuilder: (context, index) {
          final bundle = bundles[index];
          final selected = bundle.operatorId == selectedOperatorId;
          return Material(
            color: selected
                ? AppColors.sunset.withValues(alpha: 0.10)
                : Colors.transparent,
            child: InkWell(
              key: Key('admin_pricing_row_${bundle.operatorId}'),
              onTap: () => onSelect(bundle.operatorId),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      bundle.businessName,
                      style: AppTextStyles.mono14(
                        color: AppColors.textPrimary,
                        weight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'tier: ${bundle.subscriptionTier}',
                      style: AppTextStyles.mono11(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${bundle.caps.length} cap row'
                      '${bundle.caps.length == 1 ? '' : 's'}',
                      style: AppTextStyles.mono8(color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _OperatorPricingDetail extends StatelessWidget {
  const _OperatorPricingDetail({
    required this.bundle,
    required this.editingEnabled,
    required this.onApplyTemplate,
    required this.onChangeTier,
    required this.onEditCap,
    required this.onAddCap,
  });

  final PricingOperatorBundle bundle;
  final bool editingEnabled;
  final void Function(PricingOperatorBundle, PricingTierTemplate)
      onApplyTemplate;
  final void Function(PricingOperatorBundle, String) onChangeTier;
  final void Function(PricingOperatorBundle, UsageCapRow) onEditCap;
  final void Function(PricingOperatorBundle) onAddCap;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      key: Key('admin_pricing_detail_${bundle.operatorId}'),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  bundle.businessName,
                  style:
                      AppTextStyles.display20(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 10),
                _DetailRow(
                  label: 'Subscription tier',
                  value: bundle.subscriptionTier,
                ),
                _DetailRow(
                  label: 'Preferred currency',
                  value: bundle.preferredCurrency,
                ),
                _DetailRow(
                  label: 'Primary location',
                  value: bundle.primaryLocationId ?? '—',
                ),
                if (editingEnabled) ...[
                  const SizedBox(height: 14),
                  Text(
                    'Tier templates',
                    style: AppTextStyles.mono14(
                      color: AppColors.textPrimary,
                      weight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (final template in kPricingTierTemplates)
                        OutlinedButton(
                          key: Key(
                            'admin_pricing_template_${template.tierKey}_button',
                          ),
                          onPressed: () => onApplyTemplate(bundle, template),
                          child: Text(template.displayName),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    Text(
                      'Usage caps',
                      style: AppTextStyles.mono15(
                        color: AppColors.textPrimary,
                        weight: FontWeight.w700,
                      ),
                    ),
                    if (editingEnabled)
                      OutlinedButton.icon(
                        key: const Key('admin_pricing_add_cap_button'),
                        onPressed: () => onAddCap(bundle),
                        icon: const Icon(Icons.add, size: 14),
                        label: const Text('Add cap row'),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                if (bundle.caps.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'No cap rows yet. Apply a tier template to seed '
                      'defaults, or add cap rows individually.',
                      style: AppTextStyles.body13(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  )
                else
                  ...bundle.caps.map(
                    (row) => _UsageCapRowTile(
                      bundle: bundle,
                      row: row,
                      editingEnabled: editingEnabled,
                      onEdit: onEditCap,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _UsageCapRowTile extends StatelessWidget {
  const _UsageCapRowTile({
    required this.bundle,
    required this.row,
    required this.editingEnabled,
    required this.onEdit,
  });

  final PricingOperatorBundle bundle;
  final UsageCapRow row;
  final bool editingEnabled;
  final void Function(PricingOperatorBundle, UsageCapRow) onEdit;

  @override
  Widget build(BuildContext context) {
    final keySuffix = row.capId ??
        '${row.locationId}:${row.usageClass}:${row.staffId ?? ''}:${row.workflowId ?? ''}';
    return Container(
      key: Key('admin_pricing_cap_$keySuffix'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(
          color: AppColors.borderSubtle.withValues(alpha: 0.6),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  row.usageClass,
                  style: AppTextStyles.mono14(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '\$${row.monthlyCapUsd.toStringAsFixed(2)} monthly · '
                  '\$${row.perInvocationCapUsd.toStringAsFixed(2)} per call',
                  style:
                      AppTextStyles.mono11(color: AppColors.textSecondary),
                ),
                if (row.staffId != null || row.workflowId != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (row.staffId != null) 'staff: ${row.staffId}',
                      if (row.workflowId != null)
                        'workflow: ${row.workflowId}',
                    ].join(' · '),
                    style: AppTextStyles.mono8(color: AppColors.textMuted),
                  ),
                ],
                const SizedBox(height: 2),
                Text(
                  'updated by ${row.updatedBy ?? '—'} · '
                  '${row.updatedAt.toUtc().toIso8601String()}',
                  style: AppTextStyles.mono8(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          if (editingEnabled)
            IconButton(
              key: Key('admin_pricing_cap_edit_$keySuffix'),
              icon: const Icon(Icons.edit_outlined, size: 16),
              tooltip: 'Edit cap row',
              onPressed: () => onEdit(bundle, row),
            ),
        ],
      ),
    );
  }
}

class _UsageCapDialog extends StatefulWidget {
  const _UsageCapDialog({
    required this.operatorId,
    required this.primaryLocationId,
    this.existing,
  });

  final String operatorId;
  final String? primaryLocationId;
  final UsageCapRow? existing;

  @override
  State<_UsageCapDialog> createState() => _UsageCapDialogState();
}

class _UsageCapDialogState extends State<_UsageCapDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _usageClass;
  late final TextEditingController _monthly;
  late final TextEditingController _perInvocation;
  late final TextEditingController _staffId;
  late final TextEditingController _workflowId;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _usageClass = TextEditingController(text: existing?.usageClass ?? '');
    _monthly = TextEditingController(
      text: existing == null ? '' : existing.monthlyCapUsd.toStringAsFixed(2),
    );
    _perInvocation = TextEditingController(
      text: existing == null
          ? ''
          : existing.perInvocationCapUsd.toStringAsFixed(2),
    );
    _staffId = TextEditingController(text: existing?.staffId ?? '');
    _workflowId = TextEditingController(text: existing?.workflowId ?? '');
  }

  @override
  void dispose() {
    _usageClass.dispose();
    _monthly.dispose();
    _perInvocation.dispose();
    _staffId.dispose();
    _workflowId.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    return AlertDialog(
      key: const Key('admin_pricing_cap_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        editing ? 'Edit cap row' : 'Add cap row',
        style: AppTextStyles.display20(color: AppColors.textPrimary),
      ),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.primaryLocationId == null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      'This operator has no primary_location_id; '
                      'set one on the Operators tab before editing caps.',
                      style: AppTextStyles.mono11(color: AppColors.negative),
                    ),
                  ),
                _LabelledField(
                  label: 'Usage class',
                  controller: _usageClass,
                  fieldKey: const Key('admin_pricing_cap_usage_class'),
                  validator: _requiredValidator,
                  enabled: !editing,
                  hintText: 'advisor_qa, coach_qa, workflow_pl, …',
                ),
                _LabelledField(
                  label: 'Monthly cap (USD)',
                  controller: _monthly,
                  fieldKey: const Key('admin_pricing_cap_monthly'),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.allow(
                      RegExp(r'^[0-9]*\.?[0-9]*'),
                    ),
                  ],
                  validator: _decimalValidator,
                ),
                _LabelledField(
                  label: 'Per-invocation cap (USD)',
                  controller: _perInvocation,
                  fieldKey: const Key('admin_pricing_cap_per_invocation'),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.allow(
                      RegExp(r'^[0-9]*\.?[0-9]*'),
                    ),
                  ],
                  validator: _decimalValidator,
                ),
                _LabelledField(
                  label: 'Staff ID (optional)',
                  controller: _staffId,
                  fieldKey: const Key('admin_pricing_cap_staff_id'),
                  hintText: 'leave blank for all staff',
                  enabled: !editing,
                ),
                _LabelledField(
                  label: 'Workflow ID (optional)',
                  controller: _workflowId,
                  fieldKey: const Key('admin_pricing_cap_workflow_id'),
                  hintText: 'leave blank for all workflows',
                  enabled: !editing,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('admin_pricing_cap_cancel_button'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_pricing_cap_submit_button'),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.sunset,
            foregroundColor: AppColors.backgroundSurface,
          ),
          onPressed: () {
            if (!(_formKey.currentState?.validate() ?? false)) return;
            final locationId = widget.existing?.locationId ??
                widget.primaryLocationId;
            if (locationId == null) return;
            final monthly = double.tryParse(_monthly.text.trim()) ?? 0;
            final perInv = double.tryParse(_perInvocation.text.trim()) ?? 0;
            Navigator.of(context).pop(
              UsageCapUpsertCommand(
                operatorId: widget.operatorId,
                locationId: locationId,
                usageClass: _usageClass.text.trim(),
                monthlyCapUsd: monthly,
                perInvocationCapUsd: perInv,
                staffId: _staffId.text.trim().isEmpty
                    ? null
                    : _staffId.text.trim(),
                workflowId: _workflowId.text.trim().isEmpty
                    ? null
                    : _workflowId.text.trim(),
              ),
            );
          },
          child: Text(editing ? 'Save' : 'Add'),
        ),
      ],
    );
  }
}

class _LabelledField extends StatelessWidget {
  const _LabelledField({
    required this.label,
    required this.controller,
    required this.fieldKey,
    this.validator,
    this.keyboardType,
    this.inputFormatters,
    this.hintText,
    this.enabled = true,
  });

  final String label;
  final TextEditingController controller;
  final Key fieldKey;
  final String? Function(String?)? validator;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final String? hintText;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextFormField(
        key: fieldKey,
        controller: controller,
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        enabled: enabled,
        validator: validator,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: AppTextStyles.mono11(color: AppColors.textMuted),
          hintText: hintText,
          hintStyle: AppTextStyles.mono11(color: AppColors.textMuted),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide:
                const BorderSide(color: AppColors.borderSubtle, width: 1),
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 160,
            child: Text(
              label,
              style: AppTextStyles.mono11(color: AppColors.textMuted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: AppTextStyles.mono14(color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(16),
      child: child,
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.negative, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        message,
        style: AppTextStyles.mono11(color: AppColors.negative),
      ),
    );
  }
}

class _ConfirmDialog extends StatelessWidget {
  const _ConfirmDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
  });

  final String title;
  final String message;
  final String confirmLabel;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('admin_pricing_confirm_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        title,
        style: AppTextStyles.display20(color: AppColors.textPrimary),
      ),
      content: Text(
        message,
        style: AppTextStyles.body13(color: AppColors.textSecondary),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('admin_pricing_confirm_cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_pricing_confirm_ok'),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.sunset,
            foregroundColor: AppColors.backgroundSurface,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}

String? _requiredValidator(String? value) {
  if (value == null || value.trim().isEmpty) return 'Required';
  return null;
}

String? _decimalValidator(String? value) {
  if (value == null || value.trim().isEmpty) return 'Required';
  final parsed = double.tryParse(value.trim());
  if (parsed == null) return 'Enter a number';
  if (parsed < 0) return 'Must be ≥ 0';
  return null;
}
