import 'package:flutter/material.dart';

import '../../auth/permission_keys.dart';
import '../../theme/app_theme.dart';
import '../auth/operator_web_auth_source.dart';
import '../services/business_timing_gateway.dart';
import '../widgets/hierarchy_tree_visualization.dart';
import '../widgets/operator_web_info_button.dart';
import '../widgets/operator_web_section_heading.dart';

// G7d (spec §2.B/§3): v2 catalog constants. Phantom
// `'operator_admin'` dropped (folded into `operator_owner`).
// Live-path neutral — authoritative gate is
// `kOperatorWebBusinessTimingEditPermission`.
const Set<String> kOperatorWebBusinessTimingEditRoles = <String>{
  PermissionKeys.roleOperatorOwner,
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
    this.onScheduleTiming,
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

  /// Opens the effective-dated timing editor in schedule mode. When
  /// null, the read view keeps the same non-mutating placeholder used
  /// by builds without a timing write gateway.
  final VoidCallback? onScheduleTiming;

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
          'Timing changes are unavailable here',
          style: AppTextStyles.display20(color: AppColors.textPrimary),
        ),
        content: SizedBox(
          width: 420,
          child: Text(
            '$actionLabel is disabled in this demo preview. You can review '
            'the timezone, business day start, and service periods here, '
            'but this demo run does not save Business setup timing changes. '
            'Use a connected preview or staging run to test real saves. '
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
              onEdit:
                  widget.onEditTiming ??
                  () => _showSafeTimingDialog('Edit timing'),
              onSchedule:
                  widget.onScheduleTiming ??
                  () => _showSafeTimingDialog('Schedule future timing'),
              onReset: null,
            )
          else
            const _ReadOnlyTimingBanner(),
          const SizedBox(height: 14),
          // Wave 2 H-2: visual hierarchy tree above the existing
          // text inheritance card. Companion to (not replacement
          // for) the textual card below, per HP #11.
          HierarchyTreeVisualization(
            keyName: 'operator_web_business_setup_hierarchy_tree',
            headline: 'Where this location sits',
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

/// Fix #4 / S3 (G13) — adapter from `BusinessTimingBundle
/// .inheritanceChain` to the visual tree's node shape.
///
/// REWRITTEN 2026-05-16: the chain now carries one rung per REAL
/// resolved candidate scope (operator default -> each org-unit
/// ancestor -> location) from the canonical resolver via the S1
/// route, in top-down precedence order. Previously the bundle only
/// exposed a 2-3 rung approximation and every intermediate org-unit
/// rung was discarded; the old "wire full tree once hierarchy
/// reachable" TODO is now closed because the resolver chain IS the
/// real hierarchy chain for timing.
///
/// Each `scopeKind` ("Operator default" / "Org unit" / "Location")
/// maps to a tree level; the last rung is always the location the
/// operator is editing on this surface. The business root is always
/// rendered even if the operator default rung is absent, because the
/// operator-facing IA always has a business at the top.
List<HierarchyTreeNodeView> _hierarchyTreeNodesFromBundle(
  BusinessTimingBundle bundle,
) {
  final chain = bundle.inheritanceChain;
  final nodes = <HierarchyTreeNodeView>[];

  HierarchyTreeLevel levelFor(String scopeKind) {
    final kind = scopeKind.toLowerCase();
    if (kind.contains('operator') || kind.contains('business')) {
      return HierarchyTreeLevel.business;
    }
    if (kind.contains('location')) {
      return HierarchyTreeLevel.location;
    }
    // Org-unit ancestors render as the intermediate "region" rung —
    // the visual tree's middle tier. Brand is reserved for a future
    // typed org-unit kind; until the resolver carries org-unit
    // sub-kinds, every org-unit ancestor is a region-tier rung.
    return HierarchyTreeLevel.region;
  }

  // The business root: the first operator-scope rung when present,
  // else a synthetic root so the IA always shows a business at top.
  final hasOperatorRung = chain.any(
    (s) =>
        s.scopeKind.toLowerCase().contains('operator') ||
        s.scopeKind.toLowerCase().contains('business'),
  );
  if (!hasOperatorRung) {
    nodes.add(
      HierarchyTreeNodeView(
        level: HierarchyTreeLevel.business,
        name: bundle.operatorName,
        subtitle: 'No operator default saved yet.',
        inheritsFromHere: bundle.effectiveFields.any((f) => f.inherited),
      ),
    );
  }

  // Render every REAL rung. The S1-backed live path returns only
  // rungs the canonical CTE actually found (each is real and
  // `active`). The demo gateway emits an inactive placeholder
  // org-unit rung ("No timing override set."); skip inactive
  // non-anchor rungs so the tree does not imply a region layer the
  // operator never configured. Operator + location anchor rungs
  // always render even if marked inactive (empty-profile state).
  final renderable = <BusinessTimingScopeSummary>[
    for (final scope in chain)
      if (scope.active ||
          levelFor(scope.scopeKind) == HierarchyTreeLevel.business ||
          levelFor(scope.scopeKind) == HierarchyTreeLevel.location)
        scope,
  ];

  for (var i = 0; i < renderable.length; i++) {
    final scope = renderable[i];
    final isLast = i == renderable.length - 1;
    final level = levelFor(scope.scopeKind);
    nodes.add(
      HierarchyTreeNodeView(
        level: level,
        name: scope.label.isNotEmpty
            ? scope.label
            : (level == HierarchyTreeLevel.location
                  ? bundle.locationName
                  : bundle.operatorName),
        subtitle: scope.summary,
        // The location rung is the scope the operator is editing here.
        isCurrentScope: isLast && level == HierarchyTreeLevel.location,
        // A rung "inherits from here" when a deeper rung in the chain
        // does NOT override the effective value — i.e. at least one
        // effective field is inherited from an ancestor and this is
        // not the deepest rung.
        inheritsFromHere:
            !isLast && bundle.effectiveFields.any((f) => f.inherited),
      ),
    );
  }

  return nodes;
}

/// Fix #4 / S3 (G13) — the timing inheritance chain now comes from
/// the canonical resolver via the S1 route, so every rung the
/// resolver saw (operator default + each org-unit ancestor +
/// location) is rendered. There is no longer a hidden data gap to
/// explain: return `null` so the tree stands on its own. (Retained
/// as a hook in case a future surface needs a gap note again.)
String? _treeDataGapForBundle(BusinessTimingBundle bundle) {
  return null;
}

class _TimingEditControls extends StatelessWidget {
  const _TimingEditControls({
    required this.onEdit,
    required this.onSchedule,
    required this.onReset,
  });

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
        spacing: 10,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          OutlinedButton.icon(
            key: const Key('operator_web_business_timing_edit_button'),
            onPressed: onEdit,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            ),
            icon: const Icon(Icons.edit_outlined, size: 20),
            label: Text(
              'Edit time settings',
              style: AppTextStyles.display16(color: AppColors.textPrimary),
            ),
          ),
          OutlinedButton.icon(
            key: const Key('operator_web_business_timing_schedule_button'),
            onPressed: onSchedule,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            ),
            icon: const Icon(Icons.event_outlined, size: 20),
            label: Text(
              'Schedule future timing',
              style: AppTextStyles.display16(color: AppColors.textPrimary),
            ),
          ),
          if (onReset != null)
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
              'You can view this location\'s timing. Operator owners and admins '
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
      title: 'Where timing comes from',
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
      title: 'Timing in use',
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
      trailing: hasMidnightRollover
          ? OperatorWebInfoButton(
              title: 'Service periods',
              tooltip: 'Service periods',
              body: Text(
                'One period runs past midnight, so its sales count toward the '
                'business day it started in.',
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final period in bundle.servicePeriods)
            _ServicePeriodRow(period: period),
        ],
      ),
    );
  }
}

class _TimingPanel extends StatelessWidget {
  const _TimingPanel({
    required this.keyName,
    required this.title,
    required this.child,
    this.trailing,
  });

  final String keyName;
  final String title;
  final Widget child;
  final Widget? trailing;

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
          OperatorWebSectionHeading(title: title, trailing: trailing),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  period.name,
                  style: AppTextStyles.body14(color: AppColors.textPrimary),
                ),
                if (period.daysLabel != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      // G45 / Gap 28 — day-restricted period is shown
                      // explicitly so the operator sees it does not
                      // run every day.
                      period.daysLabel!,
                      style: AppTextStyles.body13(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                if (period.sourceLabel.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: _TimingStatusPill(
                      label: 'Source: ${period.sourceLabel}',
                      color: AppColors.textMuted,
                    ),
                  ),
              ],
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
