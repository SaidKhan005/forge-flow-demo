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
import '../widgets/admin_responsive_layout.dart';

class PricingTierAdminScreen extends StatefulWidget {
  const PricingTierAdminScreen({
    super.key,
    required this.gateway,
    this.editingEnabled = true,
    this.idempotencyKeyFactory,
  });

  final PricingTierAdminGateway gateway;

  /// When false, the screen hides every mutate affordance — used for
  /// the `ff_support` walkthrough path. The proxy enforces the same
  /// gate server-side; this flag keeps the UI honest about it.
  final bool editingEnabled;

  /// Factory for the idempotency key the gateway attaches to each
  /// mutating call. Production binds this to a UUID-shaped generator;
  /// widget tests inject a deterministic counter so retries can be
  /// asserted.
  final String Function()? idempotencyKeyFactory;

  @override
  State<PricingTierAdminScreen> createState() => _PricingTierAdminScreenState();
}

class _PricingTierAdminScreenState extends State<PricingTierAdminScreen> {
  bool _loading = true;
  String? _loadError;
  List<PricingOperatorBundle> _bundles = const <PricingOperatorBundle>[];
  String? _selectedOperatorId;
  String? _actionError;
  int _idempotencyCounter = 0;

  /// Mints a fresh idempotency key per user action so a retried PATCH,
  /// PUT, or POST at the proxy collapses to one ledger row + one audit
  /// row in `admin_request_idempotency`.
  String _nextIdempotencyKey() {
    final factory = widget.idempotencyKeyFactory;
    if (factory != null) return factory();
    _idempotencyCounter += 1;
    return 'pricing-${DateTime.now().toUtc().microsecondsSinceEpoch}-'
        '$_idempotencyCounter';
  }

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
        _selectedOperatorId ??= bundles.isEmpty
            ? null
            : bundles.first.operatorId;
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(successHint)));
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
            const AdminPageHeader(
              title: 'Plans and limits',
              subtitle:
                  'Set each customer plan and the spending limits that keep advisor usage predictable.',
            ),
            const SizedBox(height: 14),
            if (!widget.editingEnabled)
              const _ReadOnlyBanner(key: Key('admin_pricing_readonly_banner')),
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
                  'No customers on file',
                  style: AppTextStyles.display20(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 8),
                Text(
                  'Create a customer first, then return here to choose a plan and usage limits.',
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return AdminMasterDetailLayout(
      master: _OperatorList(
        bundles: _bundles,
        selectedOperatorId: _selectedOperatorId,
        onSelect: (id) => setState(() => _selectedOperatorId = id),
      ),
      detail: _selected == null
          ? const SizedBox.shrink()
          : _OperatorPricingDetail(
              bundle: _selected!,
              editingEnabled: widget.editingEnabled,
              onApplyTemplate: _onApplyTemplate,
              onChangeTier: _onChangeTier,
              onEditCap: _onEditCap,
              onAddCap: _onAddCap,
            ),
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
    final key = _nextIdempotencyKey();
    await _runAndRefresh(() async {
      await widget.gateway.applyTierTemplate(
        ApplyTierTemplateCommand(
          operatorId: bundle.operatorId,
          tierKey: template.tierKey,
          idempotencyKey: key,
        ),
      );
    }, successHint: '${template.displayName} template applied.');
  }

  Future<void> _onChangeTier(
    PricingOperatorBundle bundle,
    String newTier,
  ) async {
    if (newTier == bundle.subscriptionTier) return;
    final key = _nextIdempotencyKey();
    await _runAndRefresh(() async {
      await widget.gateway.updateOperatorTier(
        OperatorTierPatchCommand(
          operatorId: bundle.operatorId,
          subscriptionTier: newTier,
          idempotencyKey: key,
        ),
      );
    }, successHint: 'Subscription tier set to $newTier.');
  }

  Future<void> _onEditCap(PricingOperatorBundle bundle, UsageCapRow row) async {
    final command = await showDialog<UsageCapUpsertCommand>(
      context: context,
      builder: (_) => _UsageCapDialog(
        operatorId: bundle.operatorId,
        primaryLocationId: bundle.primaryLocationId,
        existing: row,
        idempotencyKey: _nextIdempotencyKey(),
      ),
    );
    if (command == null) return;
    await _runAndRefresh(() async {
      await widget.gateway.upsertUsageCap(command);
    }, successHint: 'Cap row updated.');
  }

  Future<void> _onAddCap(PricingOperatorBundle bundle) async {
    final command = await showDialog<UsageCapUpsertCommand>(
      context: context,
      builder: (_) => _UsageCapDialog(
        operatorId: bundle.operatorId,
        primaryLocationId: bundle.primaryLocationId,
        idempotencyKey: _nextIdempotencyKey(),
      ),
    );
    if (command == null) return;
    await _runAndRefresh(() async {
      await widget.gateway.upsertUsageCap(command);
    }, successHint: 'Cap row added.');
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
          const Icon(Icons.lock_outline, size: 16, color: AppColors.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'View only: pricing edits require platform admin access.',
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
                      'Plan: ${bundle.subscriptionTier}',
                      style: AppTextStyles.mono11(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${bundle.caps.length} usage limit'
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
          AdminCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  bundle.businessName,
                  style: AppTextStyles.display20(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 10),
                AdminDetailRow(label: 'Plan', value: bundle.subscriptionTier),
                AdminDetailRow(
                  label: 'Currency',
                  value: bundle.preferredCurrency,
                ),
                AdminDetailRow(
                  label: 'Main location',
                  value: bundle.primaryLocationId ?? 'No main location',
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
          AdminCard(
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
                      'Usage limits',
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
                        label: const Text('Add usage limit'),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                if (bundle.caps.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'No usage limits yet. Apply a plan template or add a limit individually.',
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
    final keySuffix =
        row.capId ??
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
                  '\$${row.monthlyCapUsd.toStringAsFixed(2)} monthly - '
                  '\$${row.perInvocationCapUsd.toStringAsFixed(2)} per call',
                  style: AppTextStyles.mono11(color: AppColors.textSecondary),
                  overflow: TextOverflow.ellipsis,
                ),
                if (row.staffId != null || row.workflowId != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (row.staffId != null) 'staff: ${row.staffId}',
                      if (row.workflowId != null) 'workflow: ${row.workflowId}',
                    ].join(' - '),
                    style: AppTextStyles.mono8(color: AppColors.textMuted),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 2),
                Text(
                  'Updated by ${row.updatedBy ?? 'Unknown'} - '
                  '${row.updatedAt.toUtc().toIso8601String()}',
                  style: AppTextStyles.mono8(color: AppColors.textMuted),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (editingEnabled)
            IconButton(
              key: Key('admin_pricing_cap_edit_$keySuffix'),
              icon: const Icon(Icons.edit_outlined, size: 16),
              tooltip: 'Edit usage limit',
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
    required this.idempotencyKey,
    this.existing,
  });

  final String operatorId;
  final String? primaryLocationId;
  final UsageCapRow? existing;

  /// Per-action idempotency key minted by the screen.
  final String idempotencyKey;

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
        editing ? 'Edit usage limit' : 'Add usage limit',
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
                      'This customer needs a main location before you can edit usage limits.',
                      style: AppTextStyles.mono11(color: AppColors.negative),
                    ),
                  ),
                _LabelledField(
                  label: 'Use case key',
                  controller: _usageClass,
                  fieldKey: const Key('admin_pricing_cap_usage_class'),
                  validator: _requiredValidator,
                  enabled: !editing,
                  hintText: 'Example: advisor_qa',
                ),
                _LabelledField(
                  label: 'Monthly limit (USD)',
                  controller: _monthly,
                  fieldKey: const Key('admin_pricing_cap_monthly'),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.allow(
                      RegExp(r'^[0-9]*\.?[0-9]*'),
                    ),
                  ],
                  validator: _decimalValidator,
                ),
                _LabelledField(
                  label: 'Per request limit (USD)',
                  controller: _perInvocation,
                  fieldKey: const Key('admin_pricing_cap_per_invocation'),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.allow(
                      RegExp(r'^[0-9]*\.?[0-9]*'),
                    ),
                  ],
                  validator: _decimalValidator,
                ),
                _LabelledField(
                  label: 'Staff member ID (optional)',
                  controller: _staffId,
                  fieldKey: const Key('admin_pricing_cap_staff_id'),
                  hintText: 'Leave blank for all staff',
                  enabled: !editing,
                ),
                _LabelledField(
                  label: 'Workflow ID (optional)',
                  controller: _workflowId,
                  fieldKey: const Key('admin_pricing_cap_workflow_id'),
                  hintText: 'Leave blank for all workflows',
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
            final locationId =
                widget.existing?.locationId ?? widget.primaryLocationId;
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
                idempotencyKey: widget.idempotencyKey,
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
            borderSide: const BorderSide(
              color: AppColors.borderSubtle,
              width: 1,
            ),
          ),
        ),
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
