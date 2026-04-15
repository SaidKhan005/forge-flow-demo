// Phase 7.55n.3 — ServicePeriodDefinitionResolver.
//
// Pure deterministic resolver for service-period definitions.
// Replaces hardcoded daypart availability, labels, and ordering with
// restaurant-scoped definitions.
//
// This slice is about definition resolution, not live service tracking.
// Service-period close, current open-period logic, and live Shift
// behavior are separate concerns owned by later slices.
library;

import '../canonical_day_order.dart';
import '../models/service_period_definition.dart';

class ServicePeriodDefinitionResolver {
  const ServicePeriodDefinitionResolver._();

  // ── Demo definitions ─────────────────────────────────────────────────────
  // Compatibility bridge matching the fixture-era WeekDayOrder shape.
  // Used by sync callers that do not yet have access to persisted timing
  // config. Later slices will wire callers to the persisted config.

  static const List<ServicePeriodDefinition> demoDefinitions = [
    ServicePeriodDefinition(
      id: 'lunch',
      label: 'Lunch',
      shortLabel: 'L',
      sortOrder: 1,
      startLocalTime: '11:00',
      endLocalTime: '15:00',
      rollsPastMidnight: false,
      applicableDays: [1, 2, 3, 4, 5],
    ),
    ServicePeriodDefinition(
      id: 'dinner',
      label: 'Dinner',
      shortLabel: 'D',
      sortOrder: 2,
      startLocalTime: '17:00',
      endLocalTime: '23:00',
      rollsPastMidnight: false,
      applicableDays: [1, 2, 3, 4, 5, 6, 7],
    ),
    ServicePeriodDefinition(
      id: 'late_night',
      label: 'Late Night',
      shortLabel: 'LN',
      sortOrder: 3,
      startLocalTime: '23:00',
      endLocalTime: '02:00',
      rollsPastMidnight: true,
      applicableDays: [5, 6],
    ),
  ];

  // ── Canonical ordering ───────────────────────────────────────────────────

  /// Returns definitions sorted by [ServicePeriodDefinition.sortOrder],
  /// then [ServicePeriodDefinition.id].
  static List<ServicePeriodDefinition> ordered(
    List<ServicePeriodDefinition> defs,
  ) {
    final sorted = [...defs];
    sorted.sort((a, b) {
      final cmp = a.sortOrder.compareTo(b.sortOrder);
      return cmp != 0 ? cmp : a.id.compareTo(b.id);
    });
    return sorted;
  }

  // ── Weekday filtering ────────────────────────────────────────────────────

  /// Returns ordered definitions applicable to the given ISO weekday
  /// (1 = Monday, 7 = Sunday).
  static List<ServicePeriodDefinition> applicableForWeekday(
    List<ServicePeriodDefinition> defs,
    int isoWeekday,
  ) {
    return ordered(defs)
        .where((d) => d.applicableDays.contains(isoWeekday))
        .toList();
  }

  /// Returns ordered definition IDs applicable to a day label
  /// ('Mon', 'Tue', etc.).
  ///
  /// Uses [CanonicalDayOrder.dayNumber] to map labels to ISO weekdays.
  /// Returns an empty list for unrecognized labels.
  static List<String> idsForDayLabel(
    List<ServicePeriodDefinition> defs,
    String dayLabel,
  ) {
    final weekday = CanonicalDayOrder.dayNumber(dayLabel);
    if (weekday == null) return [];
    return applicableForWeekday(defs, weekday).map((d) => d.id).toList();
  }

  // ── Label lookup ─────────────────────────────────────────────────────────

  /// Returns the label for a service-period [id], or the raw [id] if
  /// not found in [defs].
  static String labelForId(
    List<ServicePeriodDefinition> defs,
    String id,
  ) {
    for (final d in defs) {
      if (d.id == id) return d.label;
    }
    return id;
  }

  /// Returns the short label for a service-period [id], or the raw [id]
  /// if not found in [defs].
  static String shortLabelForId(
    List<ServicePeriodDefinition> defs,
    String id,
  ) {
    for (final d in defs) {
      if (d.id == id) return d.shortLabel;
    }
    return id;
  }

  // ── Ordering ─────────────────────────────────────────────────────────────

  /// Returns a sort key for [id] that orders known definitions by
  /// [ServicePeriodDefinition.sortOrder] then [ServicePeriodDefinition.id],
  /// with unknown IDs sorted alphabetically after all known definitions.
  ///
  /// The sort order is zero-padded to 4 digits so multi-digit values
  /// compare correctly via lexicographic string ordering.
  static String sortKey(
    List<ServicePeriodDefinition> defs,
    String id,
  ) {
    for (final d in defs) {
      if (d.id == id) {
        return '0_${d.sortOrder.toString().padLeft(4, '0')}_${d.id}';
      }
    }
    return '1_$id';
  }

  /// Sorts [ids] by definition sort order, then alphabetically for
  /// unknown IDs.
  static List<String> sortIds(
    List<ServicePeriodDefinition> defs,
    List<String> ids,
  ) {
    final sorted = [...ids];
    sorted.sort((a, b) => sortKey(defs, a).compareTo(sortKey(defs, b)));
    return sorted;
  }

  /// Returns the sort index for a service-period [id] within [defs].
  /// Known definitions return their [ServicePeriodDefinition.sortOrder];
  /// unknown IDs return 99.
  static int sortIndex(
    List<ServicePeriodDefinition> defs,
    String id,
  ) {
    for (final d in defs) {
      if (d.id == id) return d.sortOrder;
    }
    return 99;
  }
}
