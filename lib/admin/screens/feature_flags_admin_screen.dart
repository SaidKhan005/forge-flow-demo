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

import '../../theme/app_theme.dart';

import '../admin_button_styles.dart';
import '../admin_human_labels.dart';
import '../models/feature_flags_admin_models.dart';
import '../services/feature_flags_admin_gateway.dart';

class FeatureFlagsAdminScreen extends StatefulWidget {
  const FeatureFlagsAdminScreen({
    super.key,
    required this.gateway,
    this.editingEnabled = true,
    this.idempotencyKeyFactory,
  });

  final FeatureFlagsAdminGateway gateway;

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
      final list = await widget.gateway.listFlags();
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
    return Container(
      key: const Key('admin_feature_flags_screen'),
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
                key: Key('admin_feature_flags_readonly_banner'),
              ),
            if (_actionError != null)
              _ErrorBanner(
                key: const Key('admin_feature_flags_action_error'),
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
        key: Key('admin_feature_flags_loading'),
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
        key: const Key('admin_feature_flags_load_error'),
        message: _loadError!,
      );
    }
    if (_flags.isEmpty) {
      return Center(
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
      );
    }
    return ListView.separated(
      key: const Key('admin_feature_flags_list'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _flags.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final row = _flags[index];
        return _FeatureFlagTile(
          row: row,
          editingEnabled: widget.editingEnabled,
          toggling: _togglingFlagId == row.flagId,
          onToggle: () => _onTogglePressed(row),
        );
      },
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
          'Launch controls',
          style: AppTextStyles.display28(color: AppColors.textPrimary),
        ),
        const SizedBox(height: 4),
        Text(
          'Turn staged features on or off. High-impact changes need typed confirmation and are logged.',
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
          const Icon(Icons.lock_outline, size: 16, color: AppColors.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'View only: ecosystem admin access is required to change launch controls.',
              style: AppTextStyles.mono11(color: AppColors.textSecondary),
            ),
          ),
        ],
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
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        displayName,
                        style: AppTextStyles.body14(
                          color: AppColors.textPrimary,
                        ).copyWith(fontWeight: FontWeight.w700),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
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
                    const SizedBox(width: 6),
                    _Chip(
                      key: Key('admin_feature_flag_scope_${row.flagId}'),
                      label: _friendlyScope(row.scopeLabel),
                      background: AppColors.backgroundDeep,
                      foreground: AppColors.textMuted,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Control ID: ${row.flagName}',
                  style: AppTextStyles.mono10(color: AppColors.textMuted),
                ),
                const SizedBox(height: 4),
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
                    color: row.enabled
                        ? AppColors.positive
                        : AppColors.textSecondary,
                    weight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Last changed by ${row.updatedBy ?? 'unknown'} on '
                  '${adminHumanDateTime(row.updatedAt)}',
                  style: AppTextStyles.mono8(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (editingEnabled)
            FilledButton.tonal(
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
          else
            FilledButton.tonal(
              key: Key('admin_feature_flag_toggle_disabled_${row.flagId}'),
              onPressed: null,
              child: Text(row.enabled ? 'Disable' : 'Enable'),
            ),
        ],
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
    return AlertDialog(
      key: const Key('admin_feature_flag_danger_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        'Change high-impact control?',
        style: AppTextStyles.display20(color: AppColors.negative),
      ),
      content: SizedBox(
        width: 460,
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
      ),
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
