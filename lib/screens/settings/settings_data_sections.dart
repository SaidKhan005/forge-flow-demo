// Phase 7.55o.4 — Settings data-facing sections.
//
// Houses the data status, mock replay, data management, and audit-panel
// wrapper sections. Callbacks and state are supplied by SettingsScreen.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../auth/password_policy.dart';
import 'package:forge_and_flow/services/baseline_manager_service.dart';
import '../../data/mock_integration_replay_seed.dart';
import '../../models/app_data_status.dart';
import '../../services/auth/password_change_gateway.dart';
import '../../services/shift_service.dart';
import '../../state/auth_session_notifier.dart';
import '../../theme/app_theme.dart';
import '../../widgets/data_alignment_audit_panel.dart';
import 'settings_shared_widgets.dart';

// ─── Section wrappers ────────────────────────────────────────────

/// Data status card — wraps [_DataStatusTile] for dispatch from the
/// SettingsScreen shell.
class SettingsDataStatusSection extends StatelessWidget {
  final AppDataStatus? status;
  const SettingsDataStatusSection({super.key, required this.status});

  @override
  Widget build(BuildContext context) => _DataStatusTile(status: status);
}

/// Mock replay section — mock-date card plus Reset / Advance action
/// rows. Takes a [ValueGetter] for the mock date so the Advance
/// snackbar reads the value AFTER [onAfterWrite] has refreshed it,
/// preserving the pre-split behaviour.
class SettingsMockReplaySection extends StatelessWidget {
  final ValueGetter<String?> mockReplayDate;
  final Future<void> Function() onAfterWrite;
  const SettingsMockReplaySection({
    super.key,
    required this.mockReplayDate,
    required this.onAfterWrite,
  });

  @override
  Widget build(BuildContext context) {
    final date = mockReplayDate();
    return Column(
      children: [
        _SettingsMockReplayCard(mockReplayDate: date, formatDate: _formatDate),
        const SizedBox(height: 10),
        SettingsCard(
          children: [
            SettingsActionRow(
              icon: Icons.replay_rounded,
              label: 'Reset Mock Scenario',
              description:
                  'Reset to default scenario date (${_formatDate(MockIntegrationReplaySeed.defaultBusinessDate)})',
              onTap: () async {
                await ShiftService.instance.reseedDemo();
                await onAfterWrite();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Mock scenario reset to ${_formatDate(MockIntegrationReplaySeed.defaultBusinessDate)}.',
                        style: AppTextStyles.mono11(
                          color: AppColors.textPrimary,
                        ),
                      ),
                      backgroundColor: AppColors.backgroundMid,
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
              },
            ),
            const SettingsRowDivider(),
            SettingsActionRow(
              icon: Icons.skip_next_rounded,
              label: 'Advance Mock Day',
              description: 'Move mock business date forward one day',
              onTap: () async {
                await ShiftService.instance.advanceMockReplayDay();
                await onAfterWrite();
                if (context.mounted) {
                  final current = mockReplayDate();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Mock scenario advanced to ${current != null ? _formatDate(current) : "next day"}.',
                        style: AppTextStyles.mono11(
                          color: AppColors.textPrimary,
                        ),
                      ),
                      backgroundColor: AppColors.backgroundMid,
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
              },
            ),
          ],
        ),
      ],
    );
  }
}

/// Data management section — Clear All Data + Reset Target Cycle.
/// Both actions confirm via dialog, then call [onAfterWrite] and
/// surface a snackbar. Behaviour is identical to the pre-split
/// shell's inline implementation.
class SettingsDataManagementSection extends StatelessWidget {
  final Future<void> Function() onAfterWrite;
  const SettingsDataManagementSection({super.key, required this.onAfterWrite});

  @override
  Widget build(BuildContext context) {
    return SettingsCard(
      children: [
        SettingsActionRow(
          icon: Icons.delete_outline_rounded,
          label: 'Clear All Data',
          description:
              'Remove all operational data while keeping restaurant scope and connector settings.',
          tone: SettingsRowTone.danger,
          onTap: () async {
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: AppColors.backgroundMid,
                title: Text(
                  'Clear all data?',
                  style: AppTextStyles.mono14(color: AppColors.textPrimary),
                ),
                content: Text(
                  'This removes all operational data while keeping restaurant scope and connector settings. Cannot be undone.',
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: Text(
                      'Cancel',
                      style: AppTextStyles.mono11(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: Text(
                      'Clear',
                      style: AppTextStyles.mono11(color: AppColors.negative),
                    ),
                  ),
                ],
              ),
            );
            if (confirmed == true) {
              await ShiftService.instance.clearAllData();
              await onAfterWrite();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'All operational data cleared.',
                      style: AppTextStyles.mono11(color: AppColors.textPrimary),
                    ),
                    backgroundColor: AppColors.backgroundMid,
                    duration: const Duration(seconds: 2),
                  ),
                );
              }
            }
          },
        ),
        const SettingsRowDivider(),
        // 7.55q.9: admin/dev affordance — clears the manager override
        // + rebuilds the active 60-day cycle from the current
        // recommendation so the once-per-cycle rule can be tested
        // repeatedly without a real 60-day rollover.
        SettingsActionRow(
          icon: Icons.refresh_rounded,
          label: 'Reset Target Cycle (Admin)',
          description:
              'Clears manager override + rebuilds the active 60-day '
              'cycle from the current recommendation. For testing — '
              'skips the once-per-cycle rule.',
          tone: SettingsRowTone.admin,
          trailingBadge: 'ADMIN',
          onTap: () async {
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: AppColors.backgroundMid,
                title: Text(
                  'Reset target cycle?',
                  style: AppTextStyles.mono14(color: AppColors.textPrimary),
                ),
                content: Text(
                  'Clears the persisted manager override and the '
                  'active 60-day TargetCycle, then creates a fresh '
                  'recommended cycle. Use this to test the '
                  'once-per-cycle override rule repeatedly. '
                  'Closed shifts and week history are NOT affected.',
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: Text(
                      'Cancel',
                      style: AppTextStyles.mono11(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: Text(
                      'Reset',
                      style: AppTextStyles.mono11(color: AppColors.sunset),
                    ),
                  ),
                ],
              ),
            );
            if (confirmed == true) {
              await BaselineManagerService.instance.resetForAdminTest();
              await onAfterWrite();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Target cycle reset. Manager override is '
                      'available again.',
                      style: AppTextStyles.mono11(color: AppColors.textPrimary),
                    ),
                    backgroundColor: AppColors.backgroundMid,
                    duration: const Duration(seconds: 2),
                  ),
                );
              }
            }
          },
        ),
      ],
    );
  }
}

class SettingsAccountSection extends StatefulWidget {
  const SettingsAccountSection({super.key, this.passwordChangeGateway});

  final PasswordChangeGateway? passwordChangeGateway;

  @override
  State<SettingsAccountSection> createState() => _SettingsAccountSectionState();
}

class _SettingsAccountSectionState extends State<SettingsAccountSection> {
  bool _changingPassword = false;
  bool _signingOut = false;
  bool _signingOutEverywhere = false;

  Future<void> _changePassword() async {
    final gateway = widget.passwordChangeGateway;
    final notifier = context.read<AuthSessionNotifier>();
    final session = notifier.session;
    if (gateway == null || session == null) {
      _showSnackBar('Password changes are unavailable in this build.');
      return;
    }
    setState(() => _changingPassword = true);
    try {
      final result = await _showPasswordChangeDialog(
        context,
        onSubmit: (input) {
          return gateway.changePassword(
            PasswordChangeCommand(
              actorUserId: session.userId,
              operatorId: session.operatorId,
              locationId: session.locationId,
              currentPassword: input.currentPassword,
              newPassword: input.newPassword,
            ),
          );
        },
      );
      if (result == null || !mounted) return;
      final suffix = result.hibpUnavailable
          ? ' Breach check was unavailable.'
          : '';
      _showSnackBar('Password updated.$suffix');
    } finally {
      if (mounted) setState(() => _changingPassword = false);
    }
  }

  Future<void> _signOutThisSession() async {
    if (_signingOut) return;
    final notifier = context.read<AuthSessionNotifier>();
    final navigator = Navigator.of(context);
    setState(() => _signingOut = true);
    try {
      await notifier.signOutThisSession();
      if (mounted) navigator.pop();
    } finally {
      if (mounted) setState(() => _signingOut = false);
    }
  }

  Future<void> _signOutAllSessions() async {
    if (_signingOut) return;
    final notifier = context.read<AuthSessionNotifier>();
    final navigator = Navigator.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.backgroundMid,
        title: Text(
          'Sign out everywhere?',
          style: AppTextStyles.mono14(color: AppColors.textPrimary),
        ),
        content: Text(
          'This signs you out on this device and asks Forge & Flow to '
          'revoke other sessions for your account.',
          style: AppTextStyles.body13(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'Cancel',
              style: AppTextStyles.mono11(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              'Sign out',
              style: AppTextStyles.mono11(color: AppColors.negative),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _signingOut = true;
      _signingOutEverywhere = true;
    });
    try {
      await notifier.signOutAllSessions();
      if (mounted) navigator.pop();
    } finally {
      if (mounted) {
        setState(() {
          _signingOut = false;
          _signingOutEverywhere = false;
        });
      }
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: AppTextStyles.mono11(color: AppColors.textPrimary),
        ),
        backgroundColor: AppColors.backgroundMid,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsCard(
      children: [
        SettingsActionRow(
          icon: Icons.lock_reset_rounded,
          label: _changingPassword ? 'Updating Password' : 'Change Password',
          description: 'Update your signed-in account password.',
          onTap: _changingPassword ? () {} : _changePassword,
        ),
        const SettingsRowDivider(),
        SettingsActionRow(
          icon: Icons.logout_rounded,
          label: _signingOut ? 'Signing Out' : 'Sign Out',
          description: 'Sign out on this device.',
          onTap: _signingOut ? () {} : _signOutThisSession,
        ),
        const SettingsRowDivider(),
        SettingsActionRow(
          icon: Icons.phonelink_lock_rounded,
          label: _signingOutEverywhere
              ? 'Signing out of all devices'
              : 'Sign out of all devices',
          description: 'Revoke other active sessions for this account.',
          tone: SettingsRowTone.danger,
          onTap: _signingOut ? () {} : _signOutAllSessions,
        ),
        if (_signingOutEverywhere)
          const _AccountProgressNotice(
            message: 'Chit times rising, Signing you off Captain',
          ),
        const SettingsRowDivider(),
        _AccountInfoRow(
          icon: Icons.policy_outlined,
          label: 'Terms & Conditions',
          value:
              'Legal copy is in review for Phase 9.8. Existing operator agreements remain in effect until the official version is published.',
        ),
      ],
    );
  }
}

class _AccountProgressNotice extends StatelessWidget {
  const _AccountProgressNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('account_sign_out_everywhere_progress'),
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.backgroundMid,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body12(color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountInfoRow extends StatelessWidget {
  const _AccountInfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.borderSubtle.withValues(alpha: 0.4),
              border: Border.all(color: AppColors.borderSubtle, width: 1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(icon, size: 18, color: AppColors.textSecondary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: AppTextStyles.mono12(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  style: AppTextStyles.body13(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PasswordChangeInput {
  const _PasswordChangeInput({
    required this.currentPassword,
    required this.newPassword,
  });

  final String currentPassword;
  final String newPassword;
}

Future<PasswordChangeCompleted?> _showPasswordChangeDialog(
  BuildContext context, {
  required Future<PasswordChangeCompleted> Function(_PasswordChangeInput input)
  onSubmit,
}) async {
  return showDialog<PasswordChangeCompleted>(
    context: context,
    builder: (_) => _PasswordChangeDialog(onSubmit: onSubmit),
  );
}

class _PasswordChangeDialog extends StatefulWidget {
  const _PasswordChangeDialog({required this.onSubmit});

  final Future<PasswordChangeCompleted> Function(_PasswordChangeInput input)
  onSubmit;

  @override
  State<_PasswordChangeDialog> createState() => _PasswordChangeDialogState();
}

class _PasswordChangeDialogState extends State<_PasswordChangeDialog> {
  final _currentController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();
  String? _errorText;
  bool _submitting = false;

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final current = _currentController.text;
    final next = _newController.text;
    final confirm = _confirmController.text;
    if (current.isEmpty || next.isEmpty || confirm.isEmpty) {
      setState(() => _errorText = 'All fields are required');
      return;
    }
    if (next != confirm) {
      setState(() => _errorText = 'Passwords do not match');
      return;
    }
    final policy = PasswordPolicy.validate(next);
    if (!policy.isValid) {
      setState(() => _errorText = _passwordPolicyText(policy));
      return;
    }

    setState(() {
      _submitting = true;
      _errorText = null;
    });
    var completed = false;
    try {
      final result = await widget.onSubmit(
        _PasswordChangeInput(currentPassword: current, newPassword: next),
      );
      if (!mounted) return;
      completed = true;
      Navigator.of(context).pop(result);
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorText = _passwordChangeErrorText(error));
    } finally {
      if (mounted && !completed) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final contentWidth = (MediaQuery.sizeOf(context).width - 88).clamp(
      240.0,
      360.0,
    );
    return AlertDialog(
      backgroundColor: AppColors.backgroundMid,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      actionsOverflowButtonSpacing: 8,
      title: Text(
        'Change password',
        style: AppTextStyles.mono14(color: AppColors.textPrimary),
      ),
      content: SizedBox(
        width: contentWidth,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const Key('settings_current_password_field'),
                controller: _currentController,
                enabled: !_submitting,
                obscureText: true,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Current password',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('settings_new_password_field'),
                controller: _newController,
                enabled: !_submitting,
                obscureText: true,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'New password',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('settings_confirm_password_field'),
                controller: _confirmController,
                enabled: !_submitting,
                obscureText: true,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: 'Confirm new password',
                  border: const OutlineInputBorder(),
                  errorText: _errorText == null
                      ? null
                      : 'Review password requirements',
                  errorMaxLines: 2,
                ),
              ),
              if (_errorText != null) ...[
                const SizedBox(height: 10),
                _PasswordDialogMessage(message: _errorText!),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: Text(
            'Cancel',
            style: AppTextStyles.mono11(color: AppColors.textSecondary),
          ),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Update'),
        ),
      ],
    );
  }
}

class _PasswordDialogMessage extends StatelessWidget {
  const _PasswordDialogMessage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('settings_password_dialog_message'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.negative.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 18, color: AppColors.negative),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              softWrap: true,
              style: AppTextStyles.body12(color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

String _passwordPolicyText(PasswordPolicyResult policy) {
  final messages = <String>[
    if (policy.violations.contains(PasswordViolation.tooShort))
      'Use at least 8 characters.',
    if (policy.violations.contains(PasswordViolation.tooLong))
      'Use 256 characters or fewer.',
    if (policy.violations.contains(PasswordViolation.containsControlChars))
      'Remove tabs, line breaks, or control characters.',
    if (policy.violations.contains(
      PasswordViolation.containsLeadingOrTrailingSpace,
    ))
      'Remove spaces at the beginning or end.',
  ];
  return messages.join(' ');
}

String _passwordChangeErrorText(Object error) {
  if (error is PasswordChangeRejected) {
    return switch (error.code) {
      'current_password_invalid' => 'The current password is incorrect.',
      'password_policy_failed' =>
        error.rejections.isEmpty
            ? 'Choose a password that meets the password policy.'
            : 'Choose a different password. ${error.rejections.map(_passwordRejectionText).join(' ')}',
      'password_pwned' =>
        'Choose a password that has not appeared in a known breach.',
      'password_reused' => 'Choose a password you have not used recently.',
      'hibp_unavailable' || 'password_history_unavailable' =>
        'Password screening is unavailable. Please try again.',
      'no_id_token' => 'Your session expired. Sign in again to continue.',
      _ => 'Password could not be changed. Please try again.',
    };
  }
  return 'Password could not be changed. Please try again.';
}

String _passwordRejectionText(String code) {
  return switch (code) {
    'too_short' || 'violates_policy' => 'Use at least 8 characters.',
    'too_long' => 'Use 256 characters or fewer.',
    'control_chars' => 'Remove tabs, line breaks, or control characters.',
    'edge_whitespace' => 'Remove spaces at the beginning or end.',
    'pwned_in_breach' => 'Choose one that has not appeared in a known breach.',
    'reused_from_history' => 'Choose one you have not used recently.',
    _ => 'Review the password requirements and try again.',
  };
}

/// Audit panel wrapper. The shell previously rendered
/// [DataAlignmentAuditPanel] directly; keeping the wrapper makes the
/// Settings section surface symmetric with the other responsibilities.
class SettingsAuditSection extends StatelessWidget {
  const SettingsAuditSection({super.key});

  @override
  Widget build(BuildContext context) => const DataAlignmentAuditPanel();
}

// ─── Private helpers ─────────────────────────────────────────────

/// Formats an ISO date string as a human-readable label. Moved from
/// [_SettingsScreenState._formatDate] — used by the mock replay card
/// and its Reset / Advance snackbars.
String _formatDate(String isoDate) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  final parts = isoDate.split('-');
  if (parts.length != 3) return isoDate;
  final y = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  final d = int.tryParse(parts[2]);
  if (y == null || m == null || d == null) return isoDate;
  final dt = DateTime(y, m, d);
  return '${weekdays[dt.weekday - 1]}, ${months[m - 1]} $d, $y';
}

// ─── Private building blocks ─────────────────────────────────────

class _DataStatusTile extends StatelessWidget {
  final AppDataStatus? status;
  const _DataStatusTile({this.status});

  @override
  Widget build(BuildContext context) {
    final s = status;
    if (s == null) {
      return SettingsCard(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
            child: Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.sunset,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  'Loading…',
                  style: AppTextStyles.mono11(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
        ],
      );
    }

    final statusColor = switch (s.type) {
      AppDataStatusType.current => AppColors.positive,
      AppDataStatusType.historicalOnly => AppColors.sunsetDark,
      AppDataStatusType.stale => AppColors.warning,
      AppDataStatusType.failedImport => AppColors.negative,
      AppDataStatusType.noData => AppColors.textMuted,
    };

    return SettingsCard(
      accentColor: statusColor,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // Status pill — icon-style dot inside a tinted chip
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.14),
                      border: Border.all(
                        color: statusColor.withValues(alpha: 0.55),
                        width: 1,
                      ),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: statusColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          s.label,
                          style: AppTextStyles.mono10(color: statusColor),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                s.description,
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
              if (s.latestImportTimestamp != null) ...[
                const SizedBox(height: 8),
                Container(height: 1, color: AppColors.borderSubtle),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      Icons.history_rounded,
                      size: 12,
                      color: AppColors.textMuted,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Last import: ${s.latestImportTimestamp}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.mono8(color: AppColors.textMuted),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _SettingsMockReplayCard extends StatelessWidget {
  final String? mockReplayDate;
  final String Function(String) formatDate;
  const _SettingsMockReplayCard({
    required this.mockReplayDate,
    required this.formatDate,
  });

  @override
  Widget build(BuildContext context) {
    final formatted = mockReplayDate != null
        ? formatDate(mockReplayDate!)
        : '...';
    // Split formatted date "Fri, Mar 27, 2026" into emphasis + meta parts
    // for hero display, while still rendering the full string verbatim
    // somewhere in the tree so existing widget tests stay green.
    return SettingsCard(
      accentColor: AppColors.sunsetDark,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.sunsetDark.withValues(alpha: 0.14),
                  border: Border.all(
                    color: AppColors.sunsetDark.withValues(alpha: 0.5),
                  ),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Icon(
                  Icons.calendar_today_rounded,
                  size: 20,
                  color: AppColors.sunsetDark,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Mock Business Date',
                      style: AppTextStyles.mono12(color: AppColors.textPrimary),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      formatted,
                      style: AppTextStyles.mono14(
                        color: AppColors.sunsetDark,
                        weight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
