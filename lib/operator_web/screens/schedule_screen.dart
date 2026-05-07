// Phase 8 W5.B - Operator Web Schedule screen.
//
// Op-web parity for the locked weekly plan + forecast explainer that the
// mobile Schedule view shows. Reads the latest active
// `weekly_plan_snapshot` for the operator/location and the matching
// `forecast_context` so the operator can see:
//
//   * the locked week-in-force (header date range),
//   * planned hours / labor dollars / sales for each business day,
//   * the "Why these numbers?" explainer that names every input that
//     shaped the plan (60-day baseline, 21-day trend, target PPA,
//     forecast sales, required FOH/BOH hours, theoretical labor dollars),
//   * an honest fallback when the 60-day baseline can't be built yet
//     (per Doc 1: "explain unavailable, need 60-day history" instead of
//     zeroes).
//
// UX writing standard (`memory/project_ux_writing_standard.md`): every
// label, status, and copy line trains the operator. Plain English. No
// engineering jargon.

import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/operator_web_auth_source.dart';
import '../services/operator_web_schedule_gateway.dart';
import '../widgets/schedule_forecast_explainer_panel.dart';
import '../../theme/app_theme.dart';

/// Roles admitted to read the locked weekly plan from op-web. Mirrors the
/// existing operator-web read role gate (`kOperatorWebAdmittedRoles`)
/// rather than introducing a new permission key.
const Set<String> _kScheduleReadRoles = <String>{
  'operator_owner',
  'operator_admin',
  'operator_manager',
  'location_manager',
};

class ScheduleScreen extends StatefulWidget {
  const ScheduleScreen({
    super.key,
    required this.session,
    required this.locationId,
    required this.locationName,
    this.gateway,
  });

  final OperatorWebSession session;
  final String locationId;
  final String locationName;

  /// Live gateway. When null the screen renders an honest setup-state
  /// banner explaining that the schedule is unavailable in the active
  /// session.
  final OperatorWebScheduleGateway? gateway;

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> {
  bool _loading = true;
  String? _loadError;
  ScheduleSnapshot? _snapshot;

  bool get _hasReadRole {
    if (widget.session.roles.any(_kScheduleReadRoles.contains)) return true;
    // Fall back to the same permission keys the auth source admits. If the
    // user holds any of these they can read locked plans for the location
    // they were resolved into.
    return widget.session.permissions.any(
      const <String>{
        'forgeflow.settings.view',
        'team.users.view',
        'admin.users.view',
        'integrations.configure',
      }.contains,
    );
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final gateway = widget.gateway;
    if (gateway == null) {
      setState(() {
        _loading = false;
        _snapshot = null;
        _loadError = null;
      });
      return;
    }
    if (!_hasReadRole) {
      setState(() {
        _loading = false;
        _snapshot = null;
        _loadError = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final snapshot = await gateway.fetchCurrent(
        operatorId: widget.session.operatorId,
        locationId: widget.locationId,
      );
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _loading = false;
        _loadError = null;
      });
    } on OperatorWebScheduleGatewayException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = error.statusCode == 403
            ? "You don't have permission to see ${widget.locationName}'s "
                "schedule. Ask your operator owner to grant access."
            : "We couldn't load this week's schedule. Refresh the page or "
                "try again in a minute.";
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError =
            "We couldn't load this week's schedule. Refresh the page or "
            "try again in a minute.";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        key: Key('schedule_screen_loading'),
        child: CircularProgressIndicator(),
      );
    }
    return SingleChildScrollView(
      key: const Key('schedule_screen'),
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _Header(
            locationName: widget.locationName,
            snapshot: _snapshot,
          ),
          if (!_hasReadRole) ...<Widget>[
            const SizedBox(height: 14),
            const _Banner(
              keyName: 'schedule_screen_permission_denied',
              icon: Icons.lock_outline,
              title: "You can't see this week's plan",
              body:
                  "The locked weekly plan is for operator owners, admins, "
                  "and location managers. Ask one of them to walk through "
                  "the plan with you.",
            ),
          ] else if (widget.gateway == null) ...<Widget>[
            const SizedBox(height: 14),
            const _Banner(
              keyName: 'schedule_screen_unavailable',
              icon: Icons.signal_wifi_off_outlined,
              title: 'Setting up first connection',
              body:
                  "Connect a POS or labor vendor so Forge & Flow can build "
                  "your locked weekly plan. The schedule lights up as soon "
                  "as the first close lands.",
            ),
          ] else if (_loadError != null) ...<Widget>[
            const SizedBox(height: 14),
            _Banner(
              keyName: 'schedule_screen_error',
              icon: Icons.error_outline,
              title: 'Schedule unavailable right now',
              body: _loadError!,
              isError: true,
            ),
          ] else if (_snapshot == null) ...<Widget>[
            const SizedBox(height: 14),
            const _Banner(
              keyName: 'schedule_screen_empty',
              icon: Icons.event_available_outlined,
              title: 'No locked plan yet',
              body:
                  "Forge & Flow locks each week's plan once the prior "
                  "week closes. Check back after the next forecast runs.",
            ),
          ] else ...<Widget>[
            const SizedBox(height: 18),
            _DailyPlanTable(snapshot: _snapshot!),
            const SizedBox(height: 18),
            ScheduleForecastExplainerPanel(
              context: _snapshot!.forecastContext,
            ),
          ],
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.locationName,
    required this.snapshot,
  });

  final String locationName;
  final ScheduleSnapshot? snapshot;

  @override
  Widget build(BuildContext context) {
    final range = snapshot == null
        ? null
        : _formatWeekRange(snapshot!.weekStartDate, snapshot!.weekEndDate);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Icon(
              Icons.calendar_today_outlined,
              size: 22,
              color: AppColors.sunsetDark,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Schedule',
                style: AppTextStyles.display20(color: AppColors.textPrimary),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          range == null
              ? 'Forge & Flow locks one weekly plan at a time per location. '
                  "Once your forecasts run you'll see $locationName's locked "
                  "plan here, plus a plain-English explainer for every "
                  "number that shaped it."
              : "Week of $range — $locationName's locked plan and the "
                  "forecast inputs that built it.",
          style: AppTextStyles.body13(color: AppColors.textSecondary),
        ),
      ],
    );
  }

  static String _formatWeekRange(String startIso, String endIso) {
    final start = _parse(startIso);
    final end = _parse(endIso);
    if (start == null || end == null) return '$startIso — $endIso';
    final startLabel = _shortMonthDay(start);
    final endLabel = start.year == end.year && start.month == end.month
        ? end.day.toString()
        : _shortMonthDay(end);
    return '$startLabel — $endLabel';
  }

  static DateTime? _parse(String iso) {
    if (iso.length != 10) return null;
    return DateTime.tryParse(iso);
  }

  static String _shortMonthDay(DateTime d) {
    const months = <String>[
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
    return '${months[d.month - 1]} ${d.day}';
  }
}

class _DailyPlanTable extends StatelessWidget {
  const _DailyPlanTable({required this.snapshot});

  final ScheduleSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('schedule_screen_daily_table'),
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'Daily plan',
                  style: AppTextStyles.mono15(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                'Locked ${_formatLockedAt(snapshot.lockedAt)}',
                key: const Key('schedule_screen_locked_at'),
                style: AppTextStyles.body12(color: AppColors.textMuted),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            "Each row is the plan you committed to before the week opened. "
            "Compare these numbers to your actuals on Shift to see where the "
            "week is winning or slipping.",
            style: AppTextStyles.body12(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),
          const _ColumnHeader(),
          const Divider(height: 1, color: AppColors.borderSubtle),
          for (final row in snapshot.dayRows) ...<Widget>[
            _DailyRow(row: row),
            const Divider(height: 1, color: AppColors.borderSubtle),
          ],
          const SizedBox(height: 12),
          _TotalsRow(snapshot: snapshot),
        ],
      ),
    );
  }

  static String _formatLockedAt(DateTime when) {
    if (when.millisecondsSinceEpoch == 0) return 'just now';
    final local = when.toLocal();
    final yyyy = local.year.toString().padLeft(4, '0');
    final mm = local.month.toString().padLeft(2, '0');
    final dd = local.day.toString().padLeft(2, '0');
    return '$yyyy-$mm-$dd';
  }
}

class _ColumnHeader extends StatelessWidget {
  const _ColumnHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: <Widget>[
          Expanded(
            flex: 3,
            child: Text(
              'Day',
              style: AppTextStyles.mono12(
                color: AppColors.textMuted,
                weight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              'Forecast covers',
              style: AppTextStyles.mono12(
                color: AppColors.textMuted,
                weight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              'FOH hrs',
              style: AppTextStyles.mono12(
                color: AppColors.textMuted,
                weight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              'BOH hrs',
              style: AppTextStyles.mono12(
                color: AppColors.textMuted,
                weight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
                'Forecast sales',
                style: AppTextStyles.mono12(
                  color: AppColors.textMuted,
                  weight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DailyRow extends StatelessWidget {
  const _DailyRow({required this.row});

  final ScheduleSnapshotDay row;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: Key('schedule_screen_day_row_${row.businessDate}'),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: <Widget>[
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  row.day,
                  style: AppTextStyles.mono14(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  row.businessDate,
                  style: AppTextStyles.body11(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              '${row.forecastCovers}',
              style: AppTextStyles.mono14(
                color: AppColors.textPrimary,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              '${row.requiredFohHours}',
              style: AppTextStyles.mono14(
                color: AppColors.textPrimary,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              '${row.requiredBohHours}',
              style: AppTextStyles.mono14(
                color: AppColors.textPrimary,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
                _money(row.forecastSales),
                style: AppTextStyles.mono14(
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _money(num value) {
    final whole = value.round();
    final formatted = whole.toString().replaceAllMapped(
          RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
          (match) => '${match.group(1)},',
        );
    return '\$$formatted';
  }
}

class _TotalsRow extends StatelessWidget {
  const _TotalsRow({required this.snapshot});

  final ScheduleSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('schedule_screen_totals'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            flex: 3,
            child: Text(
              'Week total',
              style: AppTextStyles.mono14(
                color: AppColors.textPrimary,
                weight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              '${snapshot.forecastCovers}',
              style: AppTextStyles.mono14(
                color: AppColors.textPrimary,
                weight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              '${snapshot.requiredFohHours}',
              style: AppTextStyles.mono14(
                color: AppColors.textPrimary,
                weight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              '${snapshot.requiredBohHours}',
              style: AppTextStyles.mono14(
                color: AppColors.textPrimary,
                weight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
                _money(snapshot.forecastSales),
                style: AppTextStyles.mono14(
                  color: AppColors.textPrimary,
                  weight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _money(num value) {
    final whole = value.round();
    final formatted = whole.toString().replaceAllMapped(
          RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
          (match) => '${match.group(1)},',
        );
    return '\$$formatted';
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.keyName,
    required this.icon,
    required this.title,
    required this.body,
    this.isError = false,
  });

  final String keyName;
  final IconData icon;
  final String title;
  final String body;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final accent = isError ? AppColors.negative : AppColors.textSecondary;
    return Container(
      key: Key(keyName),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isError
            ? AppColors.negative.withValues(alpha: 0.10)
            : AppColors.cardGlow,
        border: Border.all(
          color: isError
              ? AppColors.negative.withValues(alpha: 0.45)
              : AppColors.borderSubtle,
          width: 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 18, color: accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: AppTextStyles.mono14(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: AppTextStyles.body12(color: accent),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
