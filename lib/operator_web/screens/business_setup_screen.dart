import 'package:flutter/material.dart';

import '../../auth/permission_keys.dart';
import '../../theme/app_theme.dart';
import '../auth/operator_web_auth_source.dart';
import '../services/business_timing_gateway.dart';
import '../widgets/hierarchy_tree_visualization.dart';

const Set<String> kOperatorWebBusinessTimingEditRoles = <String>{
  'operator_owner',
  'operator_admin',
};

const String kOperatorWebBusinessTimingEditPermission =
    PermissionKeys.businessTimingConfigure;

class BusinessSetupScreen extends StatefulWidget {
  const BusinessSetupScreen({
    super.key,
    required this.session,
    required this.locationId,
    this.locationName,
    this.gateway,
    this.onEditTiming,
  });

  final OperatorWebSession session;
  final String locationId;
  final String? locationName;
  final BusinessTimingGateway? gateway;

  /// When non-null, the read view exposes an "Edit timing" button
  /// that calls this callback. The router uses it to switch the
  /// Business setup nav slot to the editor screen. When null (live
  /// write gateway not provisioned), the read view shows the
  /// existing safe-dialog placeholder.
  final VoidCallback? onEditTiming;

  bool get _canEditTiming =>
      session.roles.any(kOperatorWebBusinessTimingEditRoles.contains) ||
      session.permissions.contains(kOperatorWebBusinessTimingEditPermission);

  @override
  State<BusinessSetupScreen> createState() => _BusinessSetupScreenState();
}

class _BusinessSetupScreenState extends State<BusinessSetupScreen> {
  late BusinessTimingGateway _gateway;
  BusinessTimingBundle? _bundle;
  String? _loadError;
  bool _loading = true;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _gateway = widget.gateway ?? const DemoBusinessTimingGateway();
    _loadTiming();
  }

  @override
  void didUpdateWidget(covariant BusinessSetupScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gateway != widget.gateway ||
        oldWidget.locationId != widget.locationId ||
        oldWidget.session.operatorId != widget.session.operatorId) {
      _gateway = widget.gateway ?? const DemoBusinessTimingGateway();
      _loadTiming();
    }
  }

  Future<void> _loadTiming() async {
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final bundle = await _gateway.loadTiming(
        operatorId: widget.session.operatorId,
        locationId: widget.locationId,
        operatorName: widget.session.businessName,
        locationName: _locationName(),
      );
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _bundle = bundle;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loadError = 'Could not load business timing: $error';
        _loading = false;
      });
    }
  }

  String _locationName() {
    final provided = widget.locationName?.trim();
    if (provided != null && provided.isNotEmpty) return provided;
    if (widget.locationId == widget.session.primaryLocationId) {
      return widget.session.primaryLocationName;
    }
    return 'this location';
  }

  Future<void> _showSafeTimingDialog(String actionLabel) {
    return showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        key: const Key('operator_web_business_timing_safe_dialog'),
        backgroundColor: AppColors.backgroundSurface,
        title: Text(
          'Timing changes are not live yet',
          style: AppTextStyles.display20(color: AppColors.textPrimary),
        ),
        content: SizedBox(
          width: 420,
          child: Text(
            '$actionLabel is available for owner/admin review in this '
            'preview, but it is not connected to a timing write route yet. '
            'Nothing was changed.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
        ),
        actions: [
          TextButton(
            key: const Key('operator_web_business_timing_safe_close'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        key: Key('operator_web_business_setup_loading'),
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
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              key: const Key('operator_web_business_setup_error'),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _loadError!,
                  style: AppTextStyles.body13(color: AppColors.negative),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  key: const Key('operator_web_business_setup_retry'),
                  onPressed: _loadTiming,
                  icon: const Icon(Icons.refresh, size: 15),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final bundle = _bundle!;
    return SingleChildScrollView(
      key: const Key('operator_web_business_setup_screen'),
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.storefront_outlined,
                size: 22,
                color: AppColors.sunsetDark,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  // Wave 2 U-FU-hp11-account — HP #11 nav-title scope
                  // hint. Business setup is a location-scoped surface
                  // (the screen edits one location's timing at a
                  // time), so the title carries the location name in
                  // plain English so the operator always sees what
                  // they are editing.
                  'Business setup • ${_locationName()}',
                  key: const Key('operator_web_business_setup_nav_title'),
                  style: AppTextStyles.display20(color: AppColors.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          if (widget._canEditTiming)
            _TimingEditControls(
              bundle: bundle,
              onEdit:
                  widget.onEditTiming ??
                  () => _showSafeTimingDialog('Edit timing'),
              onSchedule: () => _showSafeTimingDialog('Schedule timing'),
              onReset: bundle.hasLocationOverride
                  ? () => _showSafeTimingDialog('Reset timing')
                  : null,
            )
          else
            const _ReadOnlyTimingBanner(),
          const SizedBox(height: 14),
          // Wave 2 H-2: visual hierarchy tree above the existing
          // text inheritance card. Companion to (not replacement
          // for) the textual card below, per HP #11.
          HierarchyTreeVisualization(
            keyName: 'operator_web_business_setup_hierarchy_tree',
            headline: 'Hierarchy for this location',
            nodes: _hierarchyTreeNodesFromBundle(bundle),
            dataGapExplainer: _treeDataGapForBundle(bundle),
          ),
          const SizedBox(height: 14),
          _InheritanceCard(bundle: bundle),
          const SizedBox(height: 14),
          _EffectiveTimingCard(bundle: bundle),
          const SizedBox(height: 14),
          _ServicePeriodsCard(bundle: bundle),
        ],
      ),
    );
  }
}

/// Wave 2 H-2 — adapter from `BusinessTimingBundle.inheritanceChain` to
/// the visual tree's node shape. The bundle exposes a flat list of
/// scope rungs (operator default, optional regional rollup, location);
/// each row's `active` flag tells us whether that scope contributes a
/// value, and the location is always the "currently editing" scope on
/// the Business setup surface.
///
/// Today the timing bundle does not expose intermediate brand rungs
/// or the full hierarchy ltree, so the tree shows what IS reachable
/// — Business → optional Region (when active) → Location — and the
/// host screen emits a [dataGapExplainer] note that the full chain
/// will light up once the hierarchy backbone is wired through to this
/// surface (TODO(wave-N): wire full tree once hierarchy reachable).
List<HierarchyTreeNodeView> _hierarchyTreeNodesFromBundle(
  BusinessTimingBundle bundle,
) {
  final nodes = <HierarchyTreeNodeView>[];

  // Locate the relevant rungs in the bundle's inheritance chain. The
  // bundle's chain is ordered top-down (business → org unit → location)
  // by `DemoBusinessTimingGateway` and the live gateway follows the
  // same convention.
  BusinessTimingScopeSummary? businessScope;
  BusinessTimingScopeSummary? regionScope;
  BusinessTimingScopeSummary? locationScope;
  for (final scope in bundle.inheritanceChain) {
    final kind = scope.scopeKind.toLowerCase();
    if (kind.contains('operator') || kind.contains('business')) {
      businessScope ??= scope;
    } else if (kind.contains('location')) {
      locationScope ??= scope;
    } else {
      regionScope ??= scope;
    }
  }

  // Business root — always render, even if the bundle skipped it,
  // because the operator-facing IA always has a business at the top.
  nodes.add(HierarchyTreeNodeView(
    level: HierarchyTreeLevel.business,
    name: businessScope?.label.isNotEmpty == true
        ? businessScope!.label
        : bundle.operatorName,
    subtitle: businessScope?.summary,
    // The business contributes the inherited value whenever any of
    // the bundle's effective fields are marked inherited.
    inheritsFromHere: bundle.effectiveFields.any((f) => f.inherited),
  ));

  // Region rung — only when the bundle carries an active regional
  // override. If the regional rung is present but inactive ("No
  // timing override set."), we skip it to avoid implying the operator
  // has a region layer when they do not.
  if (regionScope != null && regionScope.active) {
    nodes.add(HierarchyTreeNodeView(
      level: HierarchyTreeLevel.region,
      name: regionScope.label,
      subtitle: regionScope.summary,
    ));
  }

  // Location leaf — the scope the operator is currently editing on
  // the Business setup screen.
  nodes.add(HierarchyTreeNodeView(
    level: HierarchyTreeLevel.location,
    name: locationScope?.label.isNotEmpty == true
        ? locationScope!.label
        : bundle.locationName,
    isCurrentScope: true,
    subtitle: bundle.hasLocationOverride
        ? 'Local override is set here.'
        : 'No local override. Uses business defaults.',
  ));

  return nodes;
}

/// Wave 2 H-2 — plain-English note when the timing bundle does not
/// expose every rung of the org hierarchy. Returns `null` when the
/// bundle carries a regional override (we already render every rung
/// we have data for); otherwise points the operator at the data gap
/// without using engineering jargon.
String? _treeDataGapForBundle(BusinessTimingBundle bundle) {
  final hasRegion = bundle.inheritanceChain.any(
    (scope) =>
        scope.active &&
        !scope.scopeKind.toLowerCase().contains('operator') &&
        !scope.scopeKind.toLowerCase().contains('business') &&
        !scope.scopeKind.toLowerCase().contains('location'),
  );
  if (hasRegion) return null;
  // TODO(wave-N): wire full tree once hierarchy reachable — the timing
  // bundle does not expose brand / district rungs yet, so we show the
  // anchor levels we have and document the gap below the tree.
  return 'Regions and brands will appear here once your hierarchy is '
      'connected. Today the tree shows the business and the location '
      'you are editing.';
}

class _TimingEditControls extends StatelessWidget {
  const _TimingEditControls({
    required this.bundle,
    required this.onEdit,
    required this.onSchedule,
    required this.onReset,
  });

  final BusinessTimingBundle bundle;
  final VoidCallback onEdit;
  final VoidCallback onSchedule;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_business_timing_edit_controls'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _TimingStatusPill(
            label: bundle.writesAvailable ? 'Live editor' : 'Read-only preview',
            color: bundle.writesAvailable
                ? AppColors.peacockDark
                : AppColors.sunsetDark,
          ),
          OutlinedButton.icon(
            key: const Key('operator_web_business_timing_edit_button'),
            onPressed: onEdit,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            ),
            icon: const Icon(Icons.edit_outlined, size: 20),
            label: Text(
              'Edit Time Settings',
              style: AppTextStyles.display16(color: AppColors.textPrimary),
            ),
          ),
          OutlinedButton.icon(
            key: const Key('operator_web_business_timing_schedule_button'),
            onPressed: onSchedule,
            icon: const Icon(Icons.event_outlined, size: 15),
            label: const Text('Schedule timing'),
          ),
          OutlinedButton.icon(
            key: const Key('operator_web_business_timing_reset_button'),
            onPressed: onReset,
            icon: const Icon(Icons.undo_outlined, size: 15),
            label: const Text('Reset timing'),
          ),
        ],
      ),
    );
  }
}

class _ReadOnlyTimingBanner extends StatelessWidget {
  const _ReadOnlyTimingBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_business_timing_readonly_banner'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.lock_outline, size: 18, color: AppColors.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'You can view effective timing. Operator owners and admins '
              'manage timing changes.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _InheritanceCard extends StatelessWidget {
  const _InheritanceCard({required this.bundle});

  final BusinessTimingBundle bundle;

  @override
  Widget build(BuildContext context) {
    return _TimingPanel(
      keyName: 'operator_web_business_timing_inheritance_card',
      title: 'Inheritance',
      icon: Icons.account_tree_outlined,
      child: Column(
        children: [
          for (final scope in bundle.inheritanceChain) ...[
            _ScopeRow(scope: scope),
            if (scope != bundle.inheritanceChain.last)
              Divider(
                height: 18,
                color: AppColors.borderSubtle.withValues(alpha: 0.45),
              ),
          ],
        ],
      ),
    );
  }
}

class _EffectiveTimingCard extends StatelessWidget {
  const _EffectiveTimingCard({required this.bundle});

  final BusinessTimingBundle bundle;

  @override
  Widget build(BuildContext context) {
    return _TimingPanel(
      keyName: 'operator_web_business_timing_effective_card',
      title: 'Effective timing',
      icon: Icons.schedule_outlined,
      child: Column(
        children: [
          for (final field in bundle.effectiveFields)
            _EffectiveFieldRow(field: field),
        ],
      ),
    );
  }
}

class _ServicePeriodsCard extends StatelessWidget {
  const _ServicePeriodsCard({required this.bundle});

  final BusinessTimingBundle bundle;

  @override
  Widget build(BuildContext context) {
    final hasMidnightRollover = bundle.servicePeriods.any(
      (period) => period.rollsPastMidnight,
    );
    return _TimingPanel(
      keyName: 'operator_web_business_timing_periods_card',
      title: 'Service periods',
      icon: Icons.segment_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final period in bundle.servicePeriods)
            _ServicePeriodRow(period: period),
          if (hasMidnightRollover) ...[
            const SizedBox(height: 8),
            Text(
              key: const Key('operator_web_business_timing_midnight_note'),
              'One period runs past midnight, so its sales count toward the '
              'business day it started in.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}

class _TimingPanel extends StatelessWidget {
  const _TimingPanel({
    required this.keyName,
    required this.title,
    required this.icon,
    required this.child,
  });

  final String keyName;
  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key(keyName),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: AppColors.sunsetDark),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: AppTextStyles.sectionTitle(
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _ScopeRow extends StatelessWidget {
  const _ScopeRow({required this.scope});

  final BusinessTimingScopeSummary scope;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          scope.active
              ? Icons.check_circle_outline
              : Icons.radio_button_unchecked,
          size: 17,
          color: scope.active ? AppColors.peacockDark : AppColors.textMuted,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    scope.label,
                    style: AppTextStyles.body14(color: AppColors.textPrimary),
                  ),
                  _TimingStatusPill(
                    label: scope.scopeKind,
                    color: scope.active
                        ? AppColors.sunsetDark
                        : AppColors.textMuted,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                scope.summary,
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EffectiveFieldRow extends StatelessWidget {
  const _EffectiveFieldRow({required this.field});

  final BusinessTimingInheritedValue field;

  @override
  Widget build(BuildContext context) {
    final source = _TimingStatusPill(
      label: field.inherited
          ? 'Inherited from ${field.sourceLabel}'
          : field.sourceLabel,
      color: field.inherited ? AppColors.textMuted : AppColors.peacockDark,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 520) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  field.label,
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 4),
                Text(
                  field.value,
                  style: AppTextStyles.body14(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 6),
                source,
              ],
            );
          }
          return Row(
            children: [
              Expanded(
                flex: 2,
                child: Text(
                  field.label,
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  field.value,
                  style: AppTextStyles.body14(color: AppColors.textPrimary),
                ),
              ),
              Expanded(
                flex: 2,
                child: Align(alignment: Alignment.centerLeft, child: source),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ServicePeriodRow extends StatelessWidget {
  const _ServicePeriodRow({required this.period});

  final BusinessTimingServicePeriod period;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Expanded(
            child: Text(
              period.name,
              style: AppTextStyles.body14(color: AppColors.textPrimary),
            ),
          ),
          Text(
            '${period.startsAt} - ${period.endsAt}',
            style: AppTextStyles.mono11(color: AppColors.textPrimary),
          ),
        ],
      ),
    );
  }
}

class _TimingStatusPill extends StatelessWidget {
  const _TimingStatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.42), width: 1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: AppTextStyles.mono8(color: color)),
    );
  }
}
