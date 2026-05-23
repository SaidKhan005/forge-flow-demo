// Phase 11A.2 - Pricing tier admin screen.
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
import '../../widgets/console/console_screen_header.dart';
import '../../widgets/console/console_surface.dart';

import '../admin_button_styles.dart';
import '../admin_human_labels.dart';
import '../admin_route_handoff.dart';
import '../models/pricing_tier_admin_models.dart';
import '../services/pricing_tier_admin_gateway.dart';
import '../widgets/admin_responsive_layout.dart';

class PricingTierAdminScreen extends StatefulWidget {
  const PricingTierAdminScreen({
    super.key,
    required this.gateway,
    this.editingEnabled = true,
    this.idempotencyKeyFactory,
    this.hierarchyScope,
    this.scopeLocationIds = const <String>{},
  });

  final PricingTierAdminGateway gateway;

  /// When false, the screen hides every mutate affordance - used for
  /// the `ff_support` walkthrough path. The proxy enforces the same
  /// gate server-side; this flag keeps the UI honest about it.
  final bool editingEnabled;

  /// Factory for the idempotency key the gateway attaches to each
  /// mutating call. Production binds this to a UUID-shaped generator;
  /// widget tests inject a deterministic counter so retries can be
  /// asserted.
  final String Function()? idempotencyKeyFactory;
  final AdminHierarchyScopeIntent? hierarchyScope;
  final Set<String> scopeLocationIds;

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
        final visible = _visibleBundles;
        final preferredOperatorId = widget.hierarchyScope?.operatorId;
        if (preferredOperatorId != null &&
            visible.any((b) => b.operatorId == preferredOperatorId)) {
          _selectedOperatorId = preferredOperatorId;
        }
        if (_selectedOperatorId != null &&
            visible.every((b) => b.operatorId != _selectedOperatorId)) {
          _selectedOperatorId = null;
        }
        _selectedOperatorId ??= visible.isEmpty
            ? null
            : visible.first.operatorId;
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
    for (final b in _visibleBundles) {
      if (b.operatorId == id) return b;
    }
    return null;
  }

  List<PricingOperatorBundle> get _visibleBundles {
    final scope = widget.hierarchyScope;
    if (scope == null) return _bundles;
    return <PricingOperatorBundle>[
      for (final bundle in _bundles)
        if (bundle.operatorId == scope.operatorId) _bundleForScope(bundle),
    ];
  }

  PricingOperatorBundle _bundleForScope(PricingOperatorBundle bundle) {
    final scope = widget.hierarchyScope;
    if (scope == null || scope.isBusinessScope) return bundle;
    final scopedLocationIds = _scopeLocationIds(scope);
    return PricingOperatorBundle(
      operatorId: bundle.operatorId,
      businessName: bundle.businessName,
      subscriptionTier: bundle.subscriptionTier,
      preferredCurrency: bundle.preferredCurrency,
      primaryLocationId: bundle.primaryLocationId,
      primaryLocationName: bundle.primaryLocationName,
      suspended: bundle.suspended,
      caps: bundle.caps
          .where((cap) => scopedLocationIds.contains(cap.locationId))
          .toList(growable: false),
    );
  }

  Set<String> _scopeLocationIds(AdminHierarchyScopeIntent scope) {
    final locationId = scope.locationId;
    if (locationId != null && locationId.isNotEmpty) {
      return <String>{locationId};
    }
    return widget.scopeLocationIds;
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
    // Centre + max-width cap matching the shared operator-web body kit, so
    // the content stays balanced with even margins on a wide window instead
    // of running edge-to-edge. The body keeps its fill layout (the
    // master/detail panes below need the bounded height an Expanded gives
    // them, and stack on compact widths), so the cap is applied with the
    // same Center + ConstrainedBox + edge padding OperatorWebScreenBody
    // uses, without forcing a scroll view around the master/detail. The
    // dark background stays full-bleed behind the cap.
    return Container(
      key: const Key('admin_pricing_screen'),
      color: AppColors.backgroundDeep,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1120),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const OperatorWebScreenHeader(
                  icon: Icons.payments_outlined,
                  title: 'Plans and limits',
                  collapseBelowWidth: 0,
                  subtitle:
                      'Review each operator\'s Forge & Flow AI plan and the limits that keep advisor spend predictable.',
                ),
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
    final visibleBundles = _visibleBundles;
    if (visibleBundles.isEmpty) {
      return Center(
        key: const Key('admin_pricing_empty'),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'No operators on file',
                  style: AppTextStyles.display20(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 8),
                Text(
                  'Create an operator first, then return here to review the AI plan and usage limits.',
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
        bundles: visibleBundles,
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
            'Sets the Forge & Flow AI plan to ${template.displayName} and '
            'replaces ${template.caps.length} usage limit'
            '${template.caps.length == 1 ? '' : 's'} '
            'on ${bundle.businessName}. Existing limits for the same '
            'use case are overwritten; other limits are preserved.',
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
    await _runAndRefresh(
      () async {
        await widget.gateway.updateOperatorTier(
          OperatorTierPatchCommand(
            operatorId: bundle.operatorId,
            subscriptionTier: newTier,
            idempotencyKey: key,
          ),
        );
      },
      successHint: 'Forge & Flow AI plan set to ${_tierDisplayName(newTier)}.',
    );
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
        primaryLocationId: _defaultLocationId(bundle),
        idempotencyKey: _nextIdempotencyKey(),
      ),
    );
    if (command == null) return;
    await _runAndRefresh(() async {
      await widget.gateway.upsertUsageCap(command);
    }, successHint: 'Cap row added.');
  }

  String? _defaultLocationId(PricingOperatorBundle bundle) {
    final scopeLocationId = widget.hierarchyScope?.locationId;
    if (scopeLocationId != null && scopeLocationId.isNotEmpty) {
      return scopeLocationId;
    }
    if (widget.scopeLocationIds.isNotEmpty) {
      return widget.scopeLocationIds.first;
    }
    return bundle.primaryLocationId;
  }
}

class _ReadOnlyBanner extends StatelessWidget {
  const _ReadOnlyBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(bottom: 12),
      child: OperatorWebBanner(
        icon: Icons.lock_outline,
        message: 'View only: pricing edits require ecosystem admin access.',
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
                      'Forge & Flow AI plan: ${_tierDisplayName(bundle.subscriptionTier)}',
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
          OperatorWebPanel(
            title: bundle.businessName,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AdminDetailRow(
                  label: 'Forge & Flow AI plan',
                  value: _tierDisplayName(bundle.subscriptionTier),
                ),
                AdminDetailRow(
                  label: 'Currency',
                  value: bundle.preferredCurrency,
                ),
                AdminDetailRow(
                  label: 'Primary location',
                  value: _primaryLocationLabel(bundle),
                ),
                _PricingAdvancedDetails(
                  keyName:
                      'admin_pricing_operator_details_${bundle.operatorId}',
                  title: 'Plan details',
                  rows: <_PricingDetail>[
                    _PricingDetail(
                      label: 'Operator ID',
                      value: bundle.operatorId,
                    ),
                    _PricingDetail(
                      label: 'Plan key',
                      value: bundle.subscriptionTier,
                    ),
                    if (bundle.primaryLocationId != null)
                      _PricingDetail(
                        label: 'Primary location ID',
                        value: bundle.primaryLocationId!,
                      ),
                  ],
                ),
                if (editingEnabled) ...[
                  const SizedBox(height: 14),
                  Text(
                    'Plan presets',
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
          OperatorWebPanel(
            title: 'Usage limits',
            trailing: editingEnabled
                ? OutlinedButton.icon(
                    key: const Key('admin_pricing_add_cap_button'),
                    onPressed: () => onAddCap(bundle),
                    icon: const Icon(Icons.add, size: 14),
                    label: const Text('Add usage limit'),
                  )
                : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (bundle.caps.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'No usage limits yet. Start with a plan preset or add one limit.',
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

String _primaryLocationLabel(PricingOperatorBundle bundle) {
  final name = bundle.primaryLocationName?.trim();
  if (name != null && name.isNotEmpty) return name;
  if (bundle.primaryLocationId != null) return 'Primary location selected';
  return 'No primary location';
}

String _tierDisplayName(String tier) {
  final normalized = tier.trim().toLowerCase();
  for (final template in kPricingTierTemplates) {
    if (template.subscriptionTier.toLowerCase() == normalized ||
        template.tierKey.toLowerCase() == normalized) {
      return template.displayName;
    }
  }
  if (normalized.isEmpty) return 'Unknown plan';
  return normalized
      .replaceAll(RegExp(r'[_\-]+'), ' ')
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .map(
        (part) => part.length == 1
            ? part.toUpperCase()
            : '${part.substring(0, 1).toUpperCase()}${part.substring(1)}',
      )
      .join(' ');
}

String _limitScopeLabel(UsageCapRow row) {
  final parts = <String>[];
  if (row.staffId != null) parts.add('specific staff member');
  if (row.workflowId != null) parts.add('specific workflow');
  if (parts.isEmpty) return 'Applies to all staff and workflows';
  return 'Applies to ${parts.join(' and ')}';
}

class _PricingDetail {
  const _PricingDetail({required this.label, required this.value});

  final String label;
  final String value;
}

class _PricingAdvancedDetails extends StatelessWidget {
  const _PricingAdvancedDetails({
    required this.keyName,
    required this.title,
    required this.rows,
  });

  final String keyName;
  final String title;
  final List<_PricingDetail> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: Material(
        type: MaterialType.transparency,
        child: ExpansionTile(
          key: Key(keyName),
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(top: 4, bottom: 4),
          title: Text(
            title,
            style: AppTextStyles.mono8(
              color: AppColors.textMuted,
            ).copyWith(fontWeight: FontWeight.w700),
          ),
          children: <Widget>[
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SizedBox(
                      width: 140,
                      child: Text(
                        row.label,
                        style: AppTextStyles.mono10(color: AppColors.textMuted),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        row.value,
                        style: AppTextStyles.mono10(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
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
                  adminRequestUseCaseLabel(row.usageClass),
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
                    _limitScopeLabel(row),
                    style: AppTextStyles.mono8(color: AppColors.textMuted),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 2),
                Text(
                  'Updated ${adminHumanDateTime(row.updatedAt)}',
                  style: AppTextStyles.mono8(color: AppColors.textMuted),
                  overflow: TextOverflow.ellipsis,
                ),
                _PricingAdvancedDetails(
                  keyName: 'admin_pricing_cap_details_$keySuffix',
                  title: 'Limit details',
                  rows: <_PricingDetail>[
                    if (row.capId != null)
                      _PricingDetail(label: 'Limit ID', value: row.capId!),
                    _PricingDetail(label: 'Use case ID', value: row.usageClass),
                    _PricingDetail(label: 'Location ID', value: row.locationId),
                    if (row.staffId != null)
                      _PricingDetail(
                        label: 'Staff member ID',
                        value: row.staffId!,
                      ),
                    if (row.workflowId != null)
                      _PricingDetail(
                        label: 'Workflow ID',
                        value: row.workflowId!,
                      ),
                    if (row.updatedBy != null)
                      _PricingDetail(
                        label: 'Updated by',
                        value: row.updatedBy!,
                      ),
                  ],
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
    return OperatorWebDialog(
      key: const Key('admin_pricing_cap_dialog'),
      title: editing ? 'Edit usage limit' : 'Add usage limit',
      icon: Icons.speed_outlined,
      actions: <Widget>[
        TextButton(
          key: const Key('admin_pricing_cap_cancel_button'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_pricing_cap_submit_button'),
          style: AdminButtonStyles.primary,
          onPressed: _onSubmit,
          child: Text(editing ? 'Save' : 'Add'),
        ),
      ],
      child: Flexible(
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
                      'This operator needs a primary location before you can edit usage limits.',
                      style: AppTextStyles.mono11(color: AppColors.negative),
                    ),
                  ),
                _LabelledField(
                  label: 'Use case',
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
                  label: 'Staff member (optional)',
                  controller: _staffId,
                  fieldKey: const Key('admin_pricing_cap_staff_id'),
                  hintText: 'Leave blank for all staff',
                  enabled: !editing,
                ),
                _LabelledField(
                  label: 'Workflow (optional)',
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
    );
  }

  void _onSubmit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final locationId = widget.existing?.locationId ?? widget.primaryLocationId;
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
        staffId: _staffId.text.trim().isEmpty ? null : _staffId.text.trim(),
        workflowId: _workflowId.text.trim().isEmpty
            ? null
            : _workflowId.text.trim(),
        idempotencyKey: widget.idempotencyKey,
      ),
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: OperatorWebBanner(
        tone: OperatorWebBannerTone.error,
        message: message,
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
    return OperatorWebDialog(
      key: const Key('admin_pricing_confirm_dialog'),
      title: title,
      icon: Icons.help_outline,
      actions: <Widget>[
        TextButton(
          key: const Key('admin_pricing_confirm_cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_pricing_confirm_ok'),
          style: AdminButtonStyles.primary,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
      child: Text(
        message,
        style: AppTextStyles.body13(color: AppColors.textSecondary),
      ),
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
