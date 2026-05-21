// Slice C-4 - Settings master Demo -> Live switch.
//
// kDemoMode carve-out #4: master Demo->Live switch UI; uses runtime
// demo_mode_state, not compile-time kDemoMode (no reader fork).
//
// HP #2: this reads runtime demo_mode_state through DemoModeStateNotifier and
// calls the proxy. It does not branch on kDemoMode and does not create a
// separate demo read path.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/auth_session_notifier.dart';
import '../../state/demo_mode_state_notifier.dart';
import '../../services/sync/sync_proxy_client.dart';
import '../../theme/app_theme.dart';
import 'settings_shared_widgets.dart';

class SettingsDemoLiveSwitch extends StatefulWidget {
  const SettingsDemoLiveSwitch({super.key, this.idempotencyKeyFactory});

  final String Function()? idempotencyKeyFactory;

  @override
  State<SettingsDemoLiveSwitch> createState() => _SettingsDemoLiveSwitchState();
}

class _SettingsDemoLiveSwitchState extends State<SettingsDemoLiveSwitch> {
  bool _submitting = false;
  static final Random _rng = Random();

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<DemoModeStateNotifier?>();
    final snapshot = notifier?.snapshot ?? DemoModeStateSnapshot.empty;
    final session = context.watch<AuthSessionNotifier?>()?.session;
    final client = context.read<SyncProxyClient?>();
    final DemoModeMasterSwitchClient? switchClient =
        client is DemoModeMasterSwitchClient
        ? client as DemoModeMasterSwitchClient
        : null;
    final hasScope =
        (snapshot.operatorId.isNotEmpty && snapshot.locationId.isNotEmpty) ||
        (session != null &&
            session.operatorId.isNotEmpty &&
            session.locationId.isNotEmpty);
    final enabled = hasScope && switchClient != null && !_submitting;
    final hasDemo = snapshot.hasDemoCategories;

    return SettingsCard(
      key: const Key('settings_demo_live_switch_card'),
      accentColor: hasDemo ? AppColors.sunset : AppColors.positive,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: (hasDemo ? AppColors.sunset : AppColors.positive)
                      .withValues(alpha: 0.12),
                  border: Border.all(
                    color: (hasDemo ? AppColors.sunset : AppColors.positive)
                        .withValues(alpha: 0.5),
                  ),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Icon(
                  hasDemo ? Icons.science_outlined : Icons.verified_outlined,
                  size: 18,
                  color: hasDemo ? AppColors.sunset : AppColors.positive,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Demo mode',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.mono12(
                        color: AppColors.textPrimary,
                        weight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _description(snapshot, switchClient),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.body13(color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (_submitting)
                const SizedBox(
                  key: Key('settings_demo_live_switch_progress'),
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Switch(
                  key: const Key('settings_demo_live_switch'),
                  value: hasDemo,
                  onChanged: enabled
                      ? (value) => _handleToggle(
                          context,
                          value: value,
                          snapshot: snapshot,
                          switchClient: switchClient,
                          sessionOperatorId: session?.operatorId,
                          sessionLocationId: session?.locationId,
                          notifier: notifier,
                        )
                      : null,
                ),
            ],
          ),
        ),
      ],
    );
  }

  static String _description(
    DemoModeStateSnapshot snapshot,
    DemoModeMasterSwitchClient? switchClient,
  ) {
    if (switchClient == null) {
      return 'Live switch unavailable in this build.';
    }
    if (!snapshot.hasDemoCategories) {
      return 'Live data has arrived. Demo mode cannot be restored.';
    }
    final labels = snapshot.demoCategories.map((c) => c.name).join(', ');
    return 'Switch $labels data to live for this location.';
  }

  Future<void> _handleToggle(
    BuildContext context, {
    required bool value,
    required DemoModeStateSnapshot snapshot,
    required DemoModeMasterSwitchClient switchClient,
    required String? sessionOperatorId,
    required String? sessionLocationId,
    required DemoModeStateNotifier? notifier,
  }) async {
    if (value) {
      _showSnackBar('Live data has arrived. Demo mode cannot be restored.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.backgroundMid,
        title: Text(
          'Switch demo data to live?',
          style: AppTextStyles.mono14(color: AppColors.textPrimary),
        ),
        content: Text(
          'This changes every demo category at this location to live. '
          'It cannot switch live data back to demo.',
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
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Switch to live'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final operatorId = snapshot.operatorId.isNotEmpty
        ? snapshot.operatorId
        : (sessionOperatorId ?? '');
    final locationId = snapshot.locationId.isNotEmpty
        ? snapshot.locationId
        : (sessionLocationId ?? '');
    if (operatorId.isEmpty || locationId.isEmpty) {
      _showSnackBar('Select a location before switching demo mode.');
      return;
    }

    setState(() => _submitting = true);
    try {
      await switchClient.switchDemoModeToLive(
        operatorId: operatorId,
        locationId: locationId,
        idempotencyKey: _nextIdempotencyKey(),
      );
      await notifier?.refresh();
      if (!mounted) return;
      _showSnackBar('Demo data switched to live.');
    } catch (_) {
      if (!mounted) return;
      _showSnackBar('Demo mode could not be switched. Please try again.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _nextIdempotencyKey() {
    final factory = widget.idempotencyKeyFactory;
    if (factory != null) return factory();
    return 'demo-live-${DateTime.now().toUtc().microsecondsSinceEpoch}-'
        '${_rng.nextInt(1 << 32)}';
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: AppTextStyles.mono11(color: AppColors.textPrimary),
        ),
        backgroundColor: AppColors.backgroundMid,
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
