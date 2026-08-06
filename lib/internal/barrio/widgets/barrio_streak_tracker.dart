import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'barrio_destination_scaffold.dart';

/// Persistent learning streak tracker for Barrio screens.
///
/// Honest streak revival (operator-approved rec #10, 2026-07-23): the
/// streak counts DAYS YOU OPENED A MANUAL (a fact: the training reader
/// and the flashcard review screen record on open), with up to
/// [BarrioStreakService.kFreePassesPerWeek] automatic free passes per
/// week covering days off. A pass never fakes activity: a streak that
/// survived on a pass is visibly labeled 'day off covered' in the chip
/// (Metric Honesty; never silently faked).
///
/// Storage stays backward-compatible: the original
/// `barrio_streak_last_activity` / `barrio_streak_count` keys keep
/// their exact meaning; the free-pass bookkeeping lives in NEW keys,
/// so an old install upgrades in place with its streak intact.
class BarrioStreakService {
  /// Original keys (unchanged values and meaning).
  static const String keyLastActivity = 'barrio_streak_last_activity';
  static const String keyStreakCount = 'barrio_streak_count';

  /// New keys (additive, 2026-07-23): free-pass bookkeeping.
  /// [keyPassWeek] holds the Monday date key of the week the passes
  /// were consumed in; [keyPassesUsed] how many of that week's
  /// allowance are gone; [keyCoveredOn] the activity-day key whose
  /// streak extension consumed at least one pass (drives the honest
  /// 'day off covered' label).
  static const String keyPassWeek = 'barrio_streak_pass_week';
  static const String keyPassesUsed = 'barrio_streak_passes_used';
  static const String keyCoveredOn = 'barrio_streak_covered_on';

  /// Automatic day-off passes per calendar week (Monday start).
  static const int kFreePassesPerWeek = 2;

  /// Records that the user opened learning content today. Idempotent
  /// per day. [now] is injectable for tests; production callers omit
  /// it.
  static Future<int> recordActivity({DateTime? now}) async {
    final prefs = await SharedPreferences.getInstance();
    final today = _dateOf(now ?? DateTime.now());
    final todayKey = _keyOf(today);

    final lastKey = prefs.getString(keyLastActivity);
    if (lastKey == todayKey) {
      return prefs.getInt(keyStreakCount) ?? 1;
    }

    final outcome = _extend(
      lastDay: _parseKey(lastKey),
      today: today,
      count: prefs.getInt(keyStreakCount) ?? 0,
      passesUsed: _passesUsedThisWeek(prefs, today),
    );

    await prefs.setString(keyLastActivity, todayKey);
    await prefs.setInt(keyStreakCount, outcome.count);
    await prefs.setString(keyPassWeek, _keyOf(_mondayOf(today)));
    await prefs.setInt(keyPassesUsed, outcome.passesUsed);
    if (outcome.coveredGap) {
      await prefs.setString(keyCoveredOn, todayKey);
    } else {
      await prefs.remove(keyCoveredOn);
    }
    return outcome.count;
  }

  /// Pure streak-extension decision for one new activity day.
  static _ExtendOutcome _extend({
    required DateTime? lastDay,
    required DateTime today,
    required int count,
    required int passesUsed,
  }) {
    if (lastDay == null) {
      // First ever activity.
      return _ExtendOutcome(1, passesUsed, false);
    }
    final gap = today.difference(lastDay).inDays;
    if (gap <= 1) {
      // Consecutive day (gap 1). gap <= 0 means a clock moved
      // backwards; treat as consecutive rather than punishing.
      return _ExtendOutcome(count + 1, passesUsed, false);
    }
    final daysOff = gap - 1;
    final available = kFreePassesPerWeek - passesUsed;
    if (daysOff <= available) {
      // Days off covered by this week's automatic passes: the streak
      // survives (today extends it) and the cover is recorded so the
      // chip can label it honestly.
      return _ExtendOutcome(count + 1, passesUsed + daysOff, true);
    }
    // More days off than passes: honest restart.
    return _ExtendOutcome(1, passesUsed, false);
  }

  /// Gets current streak info without recording activity. [now] is
  /// injectable for tests.
  static Future<StreakInfo> getStreak({DateTime? now}) async {
    final prefs = await SharedPreferences.getInstance();
    final today = _dateOf(now ?? DateTime.now());

    final lastDay = _parseKey(prefs.getString(keyLastActivity));
    final count = prefs.getInt(keyStreakCount) ?? 0;
    if (lastDay == null || count == 0) {
      return const StreakInfo(count: 0, status: StreakStatus.broken);
    }

    final covered =
        prefs.getString(keyCoveredOn) == prefs.getString(keyLastActivity);
    final gap = today.difference(lastDay).inDays;
    if (gap <= 0) {
      return StreakInfo(
        count: count,
        status: StreakStatus.active,
        dayOffCovered: covered,
      );
    }
    // Not opened today: the streak survives if opening now would keep
    // it (yesterday, or a gap this week's remaining passes can cover).
    final daysOff = gap - 1;
    final available = kFreePassesPerWeek - _passesUsedThisWeek(prefs, today);
    if (gap == 1 || daysOff <= available) {
      return StreakInfo(
        count: count,
        status: StreakStatus.atRisk,
        dayOffCovered: covered,
      );
    }
    return const StreakInfo(count: 0, status: StreakStatus.broken);
  }

  /// Passes already consumed in [today]'s Monday-start week. A stored
  /// week other than the current one reads as a fresh allowance.
  static int _passesUsedThisWeek(SharedPreferences prefs, DateTime today) {
    if (prefs.getString(keyPassWeek) != _keyOf(_mondayOf(today))) return 0;
    return prefs.getInt(keyPassesUsed) ?? 0;
  }

  /// UTC date-only value (safe day arithmetic, no DST edges).
  static DateTime _dateOf(DateTime now) =>
      DateTime.utc(now.year, now.month, now.day);

  static DateTime _mondayOf(DateTime day) =>
      day.subtract(Duration(days: day.weekday - DateTime.monday));

  /// The original unpadded 'y-m-d' key format (backward-compatible).
  static String _keyOf(DateTime day) => '${day.year}-${day.month}-${day.day}';

  static DateTime? _parseKey(String? key) {
    if (key == null) return null;
    final parts = key.split('-');
    if (parts.length != 3) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return null;
    return DateTime.utc(y, m, d);
  }
}

class _ExtendOutcome {
  final int count;
  final int passesUsed;
  final bool coveredGap;
  const _ExtendOutcome(this.count, this.passesUsed, this.coveredGap);
}

enum StreakStatus { active, atRisk, broken }

class StreakInfo {
  final int count;
  final StreakStatus status;

  /// True when the streak's latest extension consumed a free pass:
  /// the chip must say so ('day off covered'), never fake a fully
  /// active run (Metric Honesty).
  final bool dayOffCovered;

  const StreakInfo({
    required this.count,
    required this.status,
    this.dayOffCovered = false,
  });
}

/// Compact streak chip for the home shelf header area.
///
/// Shows flame icon + streak count, plus the honest 'day off covered'
/// detail when the latest extension used a free pass. Color-coded:
/// - Active: accent color with warm glow
/// - At risk: amber warning
/// - Broken/zero: renders nothing (no phantom zero chip)
class BarrioStreakChip extends StatefulWidget {
  final Color accentColor;

  /// Preloaded streak info. When provided the chip renders it
  /// directly (the home screen reloads it on every return to the
  /// shelf); when null the chip loads its own snapshot once.
  final StreakInfo? info;

  const BarrioStreakChip({
    super.key,
    this.accentColor = BarrioColors.tealWarm,
    this.info,
  });

  @override
  State<BarrioStreakChip> createState() => _BarrioStreakChipState();
}

class _BarrioStreakChipState extends State<BarrioStreakChip> {
  StreakInfo? _loaded;

  @override
  void initState() {
    super.initState();
    if (widget.info == null) _load();
  }

  Future<void> _load() async {
    final info = await BarrioStreakService.getStreak();
    if (mounted) setState(() => _loaded = info);
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info ?? _loaded;
    if (info == null || info.count == 0) return const SizedBox.shrink();

    final Color chipColor;
    final IconData icon;
    switch (info.status) {
      case StreakStatus.active:
        chipColor = widget.accentColor;
        icon = Icons.local_fire_department_rounded;
      case StreakStatus.atRisk:
        chipColor = BarrioColors.warning;
        icon = Icons.local_fire_department_outlined;
      case StreakStatus.broken:
        chipColor = BarrioColors.textMuted;
        icon = Icons.local_fire_department_outlined;
    }

    return Semantics(
      label: 'Learning streak: ${info.count} '
          '${info.count == 1 ? 'day' : 'days'}'
          '${info.dayOffCovered ? ', day off covered' : ''}',
      // The label above says everything; the visible count + note are
      // excluded so screen readers never hear the facts twice (rec #12).
      child: ExcludeSemantics(
        child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: chipColor.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(BarrioRadii.chip),
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
            if (info.dayOffCovered) ...[
              const SizedBox(width: 6),
              Text(
                'day off covered',
                style: GoogleFonts.ibmPlexSans(
                  fontSize: 10,
                  color: chipColor.withValues(alpha: 0.85),
                ),
              ),
            ],
          ],
        ),
        ),
      ),
    );
  }
}
