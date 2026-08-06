import 'dart:ui';

import '../widgets/barrio_destination_scaffold.dart';

/// A single entry on the El Podio scoreboard.
///
/// Phase-9-ready: [userId] will map to a real authenticated user once
/// restaurant-scoped login lands. Until then, demo entries are used.
///
/// Score logic: completed unit = +10 pts, correct first-try answer = +25 pts
/// bonus, wrong answer = −5 pts penalty.
class PodioEntry {
  /// Unique user identifier (Phase 9: real auth ID).
  final String userId;

  /// Display name shown on the scoreboard.
  final String displayName;

  /// 1–2 character initials for the avatar circle.
  final String initials;

  /// Background color of the avatar circle.
  final Color avatarColor;

  /// Cumulative score (can be negative).
  final int score;

  /// Score change over the current week (positive or negative).
  final int weeklyChange;

  const PodioEntry({
    required this.userId,
    required this.displayName,
    required this.initials,
    required this.avatarColor,
    required this.score,
    required this.weeklyChange,
  });
}

/// Demo seed data — replaced by live user data in Phase 9.
///
/// Sorted by score descending. Priya intentionally has a negative score
/// to demonstrate the muted (not shaming) negative-score treatment.
const List<PodioEntry> podioDemo = [
  PodioEntry(
    userId: 'demo_brian',
    displayName: 'Brian',
    initials: 'B',
    avatarColor: Color(0xFF3A6ED0), // royal blue
    score: 842,
    weeklyChange: 48,
  ),
  PodioEntry(
    userId: 'demo_emily',
    displayName: 'Emily',
    initials: 'E',
    // Identity colour, not a status: the module's named emerald, so this
    // is not a second unnamed copy of BarrioColors.success (same value).
    avatarColor: BarrioColors.accentPlaybook, // emerald green
    score: 715,
    weeklyChange: 32,
  ),
  PodioEntry(
    userId: 'demo_amy',
    displayName: 'Amy',
    initials: 'A',
    avatarColor: Color(0xFFCC8A3A), // warm amber
    score: 580,
    weeklyChange: 15,
  ),
  PodioEntry(
    userId: 'demo_priya',
    displayName: 'Priya',
    initials: 'P',
    avatarColor: Color(0xFF8B6FAF), // muted purple
    score: -42,
    weeklyChange: -8,
  ),
];
