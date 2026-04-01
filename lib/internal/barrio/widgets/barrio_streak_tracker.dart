import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'barrio_destination_scaffold.dart';

/// Persistent learning streak tracker for Barrio screens.
///
/// Tracks consecutive days the user has engaged with any learning content.
/// Uses SharedPreferences for lightweight persistence.
///
/// Behavioral psychology: Loss Aversion + Commitment/Consistency.
/// Streaks increase return visits by ~60% (Duolingo data).
class BarrioStreakService {
  static const _keyLastActivity = 'barrio_streak_last_activity';
  static const _keyStreakCount = 'barrio_streak_count';

  /// Records that the user completed a learning interaction today.
  static Future<int> recordActivity() async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final todayKey = '${now.year}-${now.month}-${now.day}';

    final lastActivity = prefs.getString(_keyLastActivity);
    if (lastActivity == todayKey) {
      // Already recorded today
      return prefs.getInt(_keyStreakCount) ?? 1;
    }

    final yesterday = now.subtract(const Duration(days: 1));
    final yesterdayKey =
        '${yesterday.year}-${yesterday.month}-${yesterday.day}';

    int streak;
    if (lastActivity == yesterdayKey) {
      // Consecutive day — extend streak
      streak = (prefs.getInt(_keyStreakCount) ?? 0) + 1;
    } else if (lastActivity == null) {
      // First ever activity
      streak = 1;
    } else {
      // Streak broken — restart
      streak = 1;
    }

    await prefs.setString(_keyLastActivity, todayKey);
    await prefs.setInt(_keyStreakCount, streak);
    return streak;
  }

  /// Gets current streak info without recording activity.
  static Future<StreakInfo> getStreak() async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final todayKey = '${now.year}-${now.month}-${now.day}';
    final yesterday = now.subtract(const Duration(days: 1));
    final yesterdayKey =
        '${yesterday.year}-${yesterday.month}-${yesterday.day}';

    final lastActivity = prefs.getString(_keyLastActivity);
    final count = prefs.getInt(_keyStreakCount) ?? 0;

    if (lastActivity == todayKey) {
      return StreakInfo(count: count, status: StreakStatus.active);
    } else if (lastActivity == yesterdayKey) {
      return StreakInfo(count: count, status: StreakStatus.atRisk);
    } else {
      return StreakInfo(count: 0, status: StreakStatus.broken);
    }
  }
}

enum StreakStatus { active, atRisk, broken }

class StreakInfo {
  final int count;
  final StreakStatus status;
  const StreakInfo({required this.count, required this.status});
}

/// Compact streak display widget for the AppBar area.
///
/// Shows flame icon + streak count. Color-coded:
/// - Active: accent color with warm glow
/// - At risk: amber warning
/// - Broken/zero: grey, muted
class BarrioStreakChip extends StatefulWidget {
  final Color accentColor;

  const BarrioStreakChip({
    super.key,
    this.accentColor = BarrioColors.tealWarm,
  });

  @override
  State<BarrioStreakChip> createState() => _BarrioStreakChipState();
}

class _BarrioStreakChipState extends State<BarrioStreakChip> {
  StreakInfo? _info;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final info = await BarrioStreakService.getStreak();
    if (mounted) setState(() => _info = info);
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    if (info == null || info.count == 0) return const SizedBox.shrink();

    final Color chipColor;
    final IconData icon;
    switch (info.status) {
      case StreakStatus.active:
        chipColor = widget.accentColor;
        icon = Icons.local_fire_department_rounded;
      case StreakStatus.atRisk:
        chipColor = const Color(0xFFF39C12);
        icon = Icons.local_fire_department_outlined;
      case StreakStatus.broken:
        chipColor = BarrioColors.textMuted;
        icon = Icons.local_fire_department_outlined;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: chipColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: chipColor.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: chipColor),
          const SizedBox(width: 4),
          Text(
            '${info.count}',
            style: GoogleFonts.ibmPlexMono(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: chipColor,
            ),
          ),
        ],
      ),
    );
  }
}
