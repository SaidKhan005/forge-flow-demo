// Phase 11A.7 - Feature flags admin screen.
//
// Replaces the 11A.0 placeholder. F&F internal-only surface that
// lists every row in the `public.feature_flags` catalog and lets a
// `super_admin` toggle them. `ff_support` lands on the read-only
// branch - toggle buttons are disabled and the proxy enforces the
// same gate server-side.
//
// Destructive flag UX:
//
//   * Each row marked `kind = 'destructive'` (audit-logs cutover, KMS
//     rollout lanes, etc.) renders a DANGER chip.
//   * Toggling a destructive flag forces a confirm-by-typing dialog -
//     the operator must enter the exact `flag_name` before the
//     gateway POST fires. Standard flags toggle on a single click +
//     SnackBar.
//
// Toggle audit:
//
//   * Each successful POST emits an `admin.feature_flags.toggle`
//     event via `AuthEventsAuditRepository.insertSystemEvent`. The
//     row fans out to the hash-chained `audit_logs` table when the
//     `audit_logs_cutover_enabled` flag is on (B.2).
//
// Brand styling reuses `lib/theme/app_theme.dart` verbatim per the
// 11A non-negotiable. The screen takes a [FeatureFlagsAdminGateway]
// from the outside; production passes the HTTP gateway, demo +
// widget tests pass the in-memory gateway.

import 'package:flutter/material.dart';
import 'package:forge_and_flow/widgets/console/console_screen_body.dart';
import 'package:forge_and_flow/widgets/console/console_screen_header.dart';
import 'package:forge_and_flow/widgets/console/console_surface.dart';

import '../../theme/app_theme.dart';

import '../admin_button_styles.dart';
import '../admin_human_labels.dart';
import '../admin_route_handoff.dart';
import '../models/feature_flags_admin_models.dart';
import '../services/feature_flags_admin_gateway.dart';

class FeatureFlagsAdminScreen extends StatefulWidget {
  const FeatureFlagsAdminScreen({
    super.key,
    required this.gateway,
    this.editingEnabled = true,
    this.hierarchyScope,
    this.scopeLocationIds = const <String>{},
    this.idempotencyKeyFactory,
  });

  final FeatureFlagsAdminGateway gateway;
  final AdminHierarchyScopeIntent? hierarchyScope;
  final Set<String> scopeLocationIds;

  /// When false, the screen hides every toggle affordance - used for
  /// the `ff_support` walkthrough path. The proxy enforces the same
  /// gate server-side; this flag keeps the UI honest about it.
  final bool editingEnabled;

  /// Factory for the idempotency key the gateway attaches to each
  /// toggle POST. Production binds this to a UUID generator; widget
  /// tests inject a deterministic counter so retries can be asserted.
  final String Function()? idempotencyKeyFactory;

  @override
  State<FeatureFlagsAdminScreen> createState() =>
      _FeatureFlagsAdminScreenState();
}

class _FeatureFlagsAdminScreenState extends State<FeatureFlagsAdminScreen> {
  bool _loading = true;
  String? _loadError;
  List<FeatureFlagAdminRow> _flags = const <FeatureFlagAdminRow>[];
  String? _actionError;
  String? _togglingFlagId;
  int _idempotencyCounter = 0;

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
      final list = await widget.gateway.listFlags(scope: _scopeFilter);
      if (!mounted) return;
      setState(() {
        _flags = list;
        _loading = false;
      });
    } on FeatureFlagsAdminGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error.message;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Could not load feature flags: $error';
        _loading = false;
      });
    }
  }

  String _nextIdempotencyKey() {
    final factory = widget.idempotencyKeyFactory;
    if (factory != null) return factory();
    _idempotencyCounter += 1;
    return 'ff-toggle-${DateTime.now().toUtc().microsecondsSinceEpoch}-'
        '$_idempotencyCounter';
  }

  Future<void> _onTogglePressed(FeatureFlagAdminRow row) async {
    if (!widget.editingEnabled) return;
    if (row.isDestructive) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => _DangerConfirmDialog(flagName: row.flagName),
      );
      if (confirmed != true) return;
    }
    setState(() {
      _togglingFlagId = row.flagId;
      _actionError = null;
    });
    try {
      await widget.gateway.toggleFlag(
        FeatureFlagToggleCommand(
          flagId: row.flagId,
          enabled: !row.enabled,
          idempotencyKey: _nextIdempotencyKey(),
        ),
      );
      if (!mounted) return;
      setState(() => _togglingFlagId = null);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Launch control updated')));
      await _refresh();
    } on FeatureFlagsAdminGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _actionError = error.message;
        _togglingFlagId = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _actionError = error.toString();
        _togglingFlagId = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // The screen renders inside a workspace pane whose vertical
    // budget shrinks at compact viewports (the 800x600 widget-test
    // viewport in particular, where the admin shell side nav leaves
    // the function pane just ~282 dp tall). When the static header
    // block (page header + hierarchy notice + banners) wrapped to
    // multiple lines at that width the inner Column previously
    // overflowed by ~15px at the bottom because the trailing
    // `Expanded(child: list/loader)` could not absorb a negative
    // slack. Pin only the page `_Header` to the top; everything else
    // — hierarchy notice, banners, the body — lives inside a single
    // scrollable region so the static content always has somewhere
    // to overflow into. When there are flags, the list is the
    // scrollable region; when there are not, a `SingleChildScrollView`
    // takes over so the placeholder body shares the same scroll
    // budget as the notice.
    final hasListBody = !_loading && _loadError == null && _flags.isNotEmpty;
    final secondaryChildren = <Widget>[
      if (!widget.editingEnabled)
        const _ReadOnlyBanner(key: Key('admin_feature_flags_readonly_banner')),
      if (_actionError != null)
        _ErrorBanner(
          key: const Key('admin_feature_flags_action_error'),
          message: _actionError!,
        ),
    ];
    return ColoredBox(
      key: const Key('admin_feature_flags_screen'),
      color: AppColors.backgroundDeep,
      child: OperatorWebScreenFrame(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _Header(),
            const SizedBox(height: 14),
            Expanded(
              child: hasListBody
                  ? _buildListBody(secondaryChildren)
                  : SingleChildScrollView(
                      key: const Key('admin_feature_flags_scroll'),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          ...secondaryChildren,
                          _buildPlaceholderBody(),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaceholderBody() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          key: Key('admin_feature_flags_loading'),
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.sunsetDark,
            ),
          ),
        ),
      );
    }
    if (_loadError != null) {
      return _ErrorBanner(
        key: const Key('admin_feature_flags_load_error'),
        message: _loadError!,
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        key: const Key('admin_feature_flags_empty'),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'No launch controls',
                  style: AppTextStyles.display20(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 8),
                Text(
                  'Add staged feature controls during release setup before using this page.',
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildListBody(List<Widget> secondaryChildren) {
    // Render the hierarchy notice + banners as a non-sticky list
    // header so they share the ListView's scroll region with the
    // flag tiles. This keeps the screen honest at narrow viewports
    // (the static block alone overflows the column at 540x282) while
    // matching the production UX: the page title stays pinned, the
    // notice scrolls with the list.
    final headerCount = secondaryChildren.length;
    return ListView.separated(
      key: const Key('admin_feature_flags_list'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _flags.length + headerCount,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (index < headerCount) {
          return secondaryChildren[index];
        }
        final row = _flags[index - headerCount];
        return _FeatureFlagTile(
          row: row,
          editingEnabled: widget.editingEnabled,
          toggling: _togglingFlagId == row.flagId,
          onToggle: () => _onTogglePressed(row),
        );
      },
    );
  }

  FeatureFlagScopeFilter? get _scopeFilter {
    final scope = widget.hierarchyScope;
    if (scope == null) return null;
    return FeatureFlagScopeFilter(
      operatorId: scope.operatorId,
      locationId: scope.locationId,
      locationIds: widget.scopeLocationIds,
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return const OperatorWebScreenHeader(
      icon: Icons.toggle_on_outlined,
      title: 'Launch controls',
      collapseBelowWidth: 0,
      subtitle:
          'Turn staged features on or off. High-impact changes need typed confirmation and are logged.',
    );
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
        message:
            'View only: ecosystem admin access is required to change launch controls.',
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

class _FeatureFlagTile extends StatelessWidget {
  const _FeatureFlagTile({
    required this.row,
    required this.editingEnabled,
    required this.toggling,
    required this.onToggle,
  });

  final FeatureFlagAdminRow row;
  final bool editingEnabled;
  final bool toggling;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final displayName = _friendlyFlagName(row.flagName);
    final toggleButton = editingEnabled
        ? FilledButton.tonal(
            key: Key('admin_feature_flag_toggle_${row.flagId}'),
            onPressed: toggling ? null : onToggle,
            style: AdminButtonStyles.tonal(destructive: row.isDestructive),
            child: toggling
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(row.enabled ? 'Disable' : 'Enable'),
          )
        : FilledButton.tonal(
            key: Key('admin_feature_flag_toggle_disabled_${row.flagId}'),
            onPressed: null,
            child: Text(row.enabled ? 'Disable' : 'Enable'),
          );
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              displayName,
              style: AppTextStyles.body14(
                color: AppColors.textPrimary,
              ).copyWith(fontWeight: FontWeight.w700),
            ),
            if (row.isDestructive)
              _Chip(
                key: Key('admin_feature_flag_danger_${row.flagId}'),
                label: 'High impact',
                background: AppColors.negative.withValues(alpha: 0.15),
                foreground: AppColors.negative,
              )
            else
              _Chip(
                key: Key('admin_feature_flag_kind_${row.flagId}'),
                label: _friendlyFlagKind(row.kind),
                background: AppColors.backgroundDeep,
                foreground: AppColors.textSecondary,
              ),
            _Chip(
              key: Key('admin_feature_flag_scope_${row.flagId}'),
              label: _friendlyScope(row.scopeLabel),
              background: AppColors.backgroundDeep,
              foreground: AppColors.textMuted,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            _friendlyFlagDescription(row.flagName, row.description),
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
        ),
        Text(
          'Status: ${row.enabled ? 'On' : 'Off'}',
          key: Key('admin_feature_flag_value_${row.flagId}'),
          style: AppTextStyles.mono12(
            color: row.enabled ? AppColors.positive : AppColors.textSecondary,
            weight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Last changed by ${row.updatedBy ?? 'unknown'} on '
          '${adminHumanDateTime(row.updatedAt)}',
          style: AppTextStyles.mono8(color: AppColors.textMuted),
        ),
        _FeatureFlagDetails(row: row),
      ],
    );

    return Container(
      key: Key('admin_feature_flag_row_${row.flagId}'),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(
          color: row.isDestructive
              ? AppColors.negative.withValues(alpha: 0.6)
              : AppColors.borderSubtle,
          width: 1,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 520) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                content,
                const SizedBox(height: 10),
                Align(alignment: Alignment.centerRight, child: toggleButton),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: content),
              const SizedBox(width: 12),
              toggleButton,
            ],
          );
        },
      ),
    );
  }
}

class _FeatureFlagDetails extends StatelessWidget {
  const _FeatureFlagDetails({required this.row});

  final FeatureFlagAdminRow row;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: Material(
        type: MaterialType.transparency,
        child: ExpansionTile(
          key: Key('admin_feature_flag_details_${row.flagId}'),
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          title: Text(
            'Advanced details',
            style: AppTextStyles.mono8(
              color: AppColors.textMuted,
            ).copyWith(fontWeight: FontWeight.w700),
          ),
          children: <Widget>[
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Control ID: ${row.flagName}',
                style: AppTextStyles.mono10(color: AppColors.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    super.key,
    required this.label,
    required this.background,
    required this.foreground,
  });

  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: AppTextStyles.mono10(
          color: foreground,
        ).copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _DangerConfirmDialog extends StatefulWidget {
  const _DangerConfirmDialog({required this.flagName});

  final String flagName;

  @override
  State<_DangerConfirmDialog> createState() => _DangerConfirmDialogState();
}

class _DangerConfirmDialogState extends State<_DangerConfirmDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _matches = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_recompute);
  }

  void _recompute() {
    final next = _controller.text.trim() == widget.flagName;
    if (next != _matches) {
      setState(() => _matches = next);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return OperatorWebDialog(
      key: const Key('admin_feature_flag_danger_dialog'),
      title: 'Change high-impact control?',
      icon: Icons.warning_amber_outlined,
      maxWidth: 460,
      showCloseButton: false,
      actions: <Widget>[
        TextButton(
          key: const Key('admin_feature_flag_danger_cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_feature_flag_danger_confirm'),
          style: AdminButtonStyles.danger,
          onPressed: _matches ? () => Navigator.of(context).pop(true) : null,
          child: const Text('Update'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This can affect live behavior, service keys, or emergency shutoff. Type the control ID to continue:',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 8),
          Text(
            widget.flagName,
            style: AppTextStyles.mono14(
              color: AppColors.textPrimary,
              weight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('admin_feature_flag_danger_input'),
            controller: _controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: widget.flagName,
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
        ],
      ),
    );
  }
}

String _friendlyFlagName(String flagName) {
  return switch (flagName) {
    'audit_logs_cutover_enabled' => 'Audit log routing',
    'kms_real_provider_anthropic_enabled' => 'Anthropic key storage',
    'kms_real_provider_voyage_enabled' => 'Voyage key storage',
    'advisor_enabled' => 'Advisor access',
    _ =>
      flagName
          .replaceAll('_enabled', '')
          .replaceAll('_', ' ')
          .trim()
          .split(' ')
          .where((part) => part.isNotEmpty)
          .map((part) => part[0].toUpperCase() + part.substring(1))
          .join(' '),
  };
}

String _friendlyFlagDescription(String flagName, String? fallback) {
  return switch (flagName) {
    'audit_logs_cutover_enabled' =>
      'Routes sign-in and admin changes into the permanent audit log. Turn off only for a rollback.',
    'kms_real_provider_anthropic_enabled' =>
      'Uses secure cloud storage for Anthropic service keys instead of demo storage.',
    'kms_real_provider_voyage_enabled' =>
      'Uses secure cloud storage for Voyage service keys instead of demo storage.',
    'advisor_enabled' =>
      'Controls whether the advisor experience is available in the app.',
    _ =>
      (fallback == null || fallback.trim().isEmpty)
          ? 'Controls a staged release setting.'
          : fallback.trim(),
  };
}

String _friendlyFlagKind(String kind) {
  return switch (kind) {
    kFeatureFlagKindDestructive => 'Sensitive',
    kFeatureFlagKindStandard => 'Standard',
    _ => kind.replaceAll('_', ' '),
  };
}

String _friendlyScope(String scope) {
  return switch (scope.toLowerCase()) {
    'global' => 'All operators',
    'operator' => 'Operator',
    'location' => 'Location',
    _ => scope.replaceAll('_', ' '),
  };
}
