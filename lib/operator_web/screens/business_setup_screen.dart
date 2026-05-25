import 'package:flutter/material.dart';

import '../../auth/permission_keys.dart';
import '../../theme/app_theme.dart';
import '../auth/operator_web_auth_source.dart';
import '../services/business_timing_gateway.dart';
import 'package:forge_and_flow/widgets/console/console_info_button.dart';
import 'package:forge_and_flow/widgets/console/console_screen_body.dart';
import 'package:forge_and_flow/widgets/console/console_screen_header.dart';
import 'package:forge_and_flow/widgets/console/console_surface.dart';

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
    return showOperatorWebDialog<void>(
      context: context,
      title: 'Timing changes are unavailable here',
      icon: Icons.lock_outline,
      maxWidth: 460,
      child: SizedBox(
        key: const Key('operator_web_business_timing_safe_dialog'),
        child: Text(
          '$actionLabel is disabled in this demo preview. You can review '
          'the timezone, business day start, and service periods here, '
          'but this demo run does not save Business timing changes. '
          'Use a connected preview or staging run to test real saves. '
          'Nothing was changed.',
          style: AppTextStyles.body13(color: AppColors.textSecondary),
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('operator_web_business_timing_safe_close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
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
    return OperatorWebScreenBody(
      scrollKey: const Key('operator_web_business_setup_screen'),
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const OperatorWebScreenHeader(
            icon: Icons.storefront_outlined,
            title: 'Service periods',
            titleKey: Key('operator_web_business_setup_nav_title'),
          ),
          const SizedBox(height: 18),
          if (widget._canEditTiming)
            _TimingEditControls(
              onEdit:
                  widget.onEditTiming ??
                  () => _showSafeTimingDialog('Edit timing'),
            )
          else
            const _ReadOnlyTimingBanner(),
          const SizedBox(height: 14),
          _EffectiveTimingCard(bundle: bundle),
          const SizedBox(height: 14),
          _ServicePeriodsCard(bundle: bundle),
        ],
      ),
    );
  }
}

class _TimingEditControls extends StatelessWidget {
  const _TimingEditControls({required this.onEdit});

  final VoidCallback onEdit;

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
          SizedBox(
            height: 46,
            child: FilledButton.icon(
              key: const Key('operator_web_business_timing_edit_button'),
              onPressed: onEdit,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.sunset,
                foregroundColor: AppColors.backgroundSurface,
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
                textStyle: AppTextStyles.mono12(weight: FontWeight.w600),
              ),
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Edit service periods'),
            ),
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
    return OperatorWebBanner(
      key: const Key('operator_web_business_timing_readonly_banner'),
      icon: Icons.lock_outline,
      message:
          'You can view this location\'s timing. Operator owners and '
          'admins manage timing changes.',
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
      title: 'Timing defaults',
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
    return OperatorWebPanel(
      key: Key(keyName),
      title: title,
      trailing: trailing,
      child: child,
    );
  }
}

class _EffectiveFieldRow extends StatelessWidget {
  const _EffectiveFieldRow({required this.field});

  final BusinessTimingInheritedValue field;

  @override
  Widget build(BuildContext context) {
    final source = _TimingStatusPill(
      label: field.inherited ? 'Inherited' : field.sourceLabel,
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
                      label: period.inherited
                          ? 'Inherited'
                          : period.sourceLabel,
                      color: period.inherited
                          ? AppColors.textMuted
                          : AppColors.peacockDark,
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
