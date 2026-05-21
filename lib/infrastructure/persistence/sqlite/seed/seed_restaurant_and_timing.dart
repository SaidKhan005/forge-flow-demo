// Part of sqlite_database.dart. Demo restaurant rows, timing config, and open-period resolvers.
//
// Mechanically split out of sqlite_database_seed.dart (code_hardening_plan
// 2026-05-21 §4.4 god-object #3). Moved verbatim — no change to what is
// seeded, table names, values, or ordering (HP #2 demo-writer parity).

part of '../sqlite_database.dart';

Future<void> _seedDemoRestaurant(Database db) async {
  final now = nowIsoUtc();

  // §2c hierarchy: seed all four demo locations (Downtown / North Loop
  // / Riverside / Harbour) so the scope drawer is a real switcher and
  // both consoles tell the same story. The org tree (corp → regions →
  // district) lives in the operator-web fixture; the mobile side has
  // no SQLite `org_units` table, so multi-location scope is expressed
  // purely as multiple `restaurant_locations` rows. HP #2: same table,
  // no `demo_*` table, no `kDemoMode` reader branch. `ignore` keeps
  // the seed idempotent/deterministic (reseed yields the same rows).
  // Slice A seeds the location rows only — per-location operational
  // data (shifts/weeks/cycle/plan) is Slice C.
  for (final location in DemoScope.locations) {
    await db.insert('restaurant_locations', {
      'restaurant_id': location.restaurantId,
      'display_name': location.displayName,
      'business_timezone': location.businessTimezone,
      'created_at': now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  // Seed demo timing config (7.55n.1) for Downtown only —
  // `_seedDemoTimingConfig` is keyed to `DemoScope.restaurantId`, and
  // per-location timing is operational config owned by Slice C / the
  // HP #11 scope-override slice (F), not this foundation slice.
  // Defaults preserve the current fixture-era shape from WeekDayOrder.
  // Guard: table may not exist yet during older upgrade paths.
  if (await _tableExists(db, 'restaurant_timing_configs')) {
    await _seedDemoTimingConfig(db, now);
  }
}

/// The demo restaurant's business-day start (restaurant-local). Shared
/// by [_seedDemoTimingConfig] and [resolveDemoOpenPeriod] so the seeded
/// timing config and the clock-derived open-period selection use ONE
/// business-date basis (Time Guardrails — business date is the anchor).
const String _kDemoBusinessDayStartLocalTime = '04:00';

/// The demo restaurant's three service periods (business default,
/// applied to Downtown + every inheriting location).
///
/// QA fix (Change B): `lunch.applicable_days` now includes Sat (6) and
/// Sun (7) — weekends serve a lunch/brunch like a real restaurant, so
/// the per-daypart phase resolver treats weekend Lunch as a real,
/// applicable period (no longer "not applicable → always Opens at").
/// Kept byte-equal to [_kDemoBusinessDefaultServicePeriods] (the
/// East-Region override input) so the HP #11 diff stays a single axis
/// (week-start only). SINGLE source of truth for both the seeded
/// `service_period_definitions_json` and [resolveDemoOpenPeriod].
const List<Map<String, Object?>> _kDemoDowntownServicePeriods =
    <Map<String, Object?>>[
      {
        'id': 'lunch',
        'label': 'Lunch',
        'short_label': 'L',
        'sort_order': 1,
        'start_local_time': '11:00',
        'end_local_time': '15:00',
        'rolls_past_midnight': false,
        'applicable_days': [1, 2, 3, 4, 5, 6, 7],
      },
      {
        'id': 'dinner',
        'label': 'Dinner',
        'short_label': 'D',
        'sort_order': 2,
        'start_local_time': '17:00',
        'end_local_time': '23:00',
        'rolls_past_midnight': false,
        'applicable_days': [1, 2, 3, 4, 5, 6, 7],
      },
      {
        'id': 'late_night',
        'label': 'Late Night',
        'short_label': 'LN',
        'sort_order': 3,
        'start_local_time': '23:00',
        'end_local_time': '02:00',
        'rolls_past_midnight': true,
        'applicable_days': [5, 6],
      },
    ];

Future<void> _seedDemoTimingConfig(Database db, String now) async {
  // Per-Daypart V1 Slice 1.5: `shift_close_authority` +
  // `local_close_fallback` dropped (operator decision 2026-05-15).
  await db.insert('restaurant_timing_configs', {
    'restaurant_id': DemoScope.restaurantId,
    'business_day_start_local_time': _kDemoBusinessDayStartLocalTime,
    'week_start_day': DateTime.monday,
    'service_period_definitions_json': jsonEncode(_kDemoDowntownServicePeriods),
    'created_at': now,
    'updated_at': now,
  }, conflictAlgorithm: ConflictAlgorithm.ignore);
}

/// Parses an `HH:mm` clock string to minutes-since-midnight.
///
/// MUST mirror `_parseHm` in
/// `lib/state/shift_service_period_notifier.dart` (the canonical
/// per-daypart phase resolver). Replicated here (not imported) so
/// `lib/infrastructure` does not depend on `lib/state`; the parity
/// guard is this comment + the shared [_kDemoDowntownServicePeriods].
int? _demoParseHm(String hm) {
  final parts = hm.split(':');
  if (parts.length != 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return null;
  return h * 60 + m;
}

/// Derives the demo restaurant's open service period from a
/// restaurant-local [localNow] at seed time — the QA fix for the
/// device-reproduced defect (Sat ~09:25 showed Dinner "live" because
/// the seed hardcoded `openShiftDaypart='dinner'`).
///
/// This MUST mirror `resolveActiveServicePeriodId` /
/// `resolveServicePeriodPhase` in
/// `lib/state/shift_service_period_notifier.dart:733-890` (the canonical
/// phase resolver cited by the per-daypart contract): business-date
/// weekday via [BusinessDateResolver] for applicability, inclusive-end
/// time-of-day comparison, and the `rollsPastMidnight` rule that a
/// non-active rolling period is always *future* (not closed). It is
/// replicated rather than imported to keep `lib/infrastructure` off
/// `lib/state`; both consume the SAME period defs
/// ([_kDemoDowntownServicePeriods]) so they cannot drift. Do not
/// diverge from the resolver without updating both.
///
/// Returns:
///  * the single period IN PROGRESS at [localNow] as `openDaypart`
///    with a real progress fraction + wall-clock / elapsed labels;
///  * `openDaypart == null` when NO period is in progress (honest — no
///    open shift; upcoming periods are projected, e.g. 09:25 < Lunch);
///  * `currentDayClosedPeriods` = periods applicable on the business
///    day that already ended (→ seeded `closed` with actuals — closed
///    truth is not rewritten).
OpenPeriodResolution resolveDemoOpenPeriod({required DateTime localNow}) {
  final defs =
      _kDemoDowntownServicePeriods.map(ServicePeriodDefinition.fromMap).toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  final businessDateIso = BusinessDateResolver.resolve(
    localTimestamp: localNow,
    businessDayStartLocalTime: _kDemoBusinessDayStartLocalTime,
  );
  final businessWeekday = DateTime.parse(businessDateIso).weekday;
  final tod = Duration(
    hours: localNow.hour,
    minutes: localNow.minute,
    seconds: localNow.second,
    milliseconds: localNow.millisecond,
    microseconds: localNow.microsecond,
  );

  ServicePeriodDefinition? active;
  for (final d in defs) {
    if (!d.applicableDays.contains(businessWeekday)) continue;
    final s = _demoParseHm(d.startLocalTime);
    final e = _demoParseHm(d.endLocalTime);
    if (s == null || e == null) continue;
    final start = Duration(minutes: s);
    final end = Duration(minutes: e);
    if (d.rollsPastMidnight) {
      if (tod >= start || tod <= end) {
        active = d;
        break;
      }
    } else {
      if (tod >= start && tod <= end) {
        active = d;
        break;
      }
    }
  }

  // Periods applicable today, not active, already ended → closed.
  // Mirrors `resolveServicePeriodPhase`: a non-active `rollsPastMidnight`
  // period is always *future* (its only non-active window is "not
  // re-opened yet"), never closed.
  final closed = <String>[];
  for (final d in defs) {
    if (active != null && d.id == active.id) continue;
    if (!d.applicableDays.contains(businessWeekday)) continue;
    if (d.rollsPastMidnight) continue;
    final e = _demoParseHm(d.endLocalTime);
    if (e == null) continue;
    if (tod > Duration(minutes: e)) closed.add(d.id);
  }

  if (active == null) {
    return OpenPeriodResolution(
      openDaypart: null,
      openProgressFraction: null,
      openTimeLabel: null,
      openServiceElapsedLabel: null,
      currentDayClosedPeriods: closed,
    );
  }

  final startMin = _demoParseHm(active.startLocalTime)!;
  final endMin = _demoParseHm(active.endLocalTime)!;
  // Minutes-of-day, full sub-minute precision (deterministic given the
  // injected anchor — no DateTime.now() in any seeded VALUE).
  final nowMin =
      localNow.hour * 60 +
      localNow.minute +
      localNow.second / 60.0 +
      localNow.millisecond / 60000.0;
  final double elapsedMin;
  final double windowMin;
  if (active.rollsPastMidnight) {
    windowMin = ((1440 - startMin) + endMin).toDouble();
    elapsedMin = nowMin >= startMin
        ? nowMin - startMin
        : (1440 - startMin) + nowMin;
  } else {
    windowMin = (endMin - startMin).toDouble();
    elapsedMin = nowMin - startMin;
  }
  final fraction = windowMin <= 0
      ? 0.0
      : (elapsedMin / windowMin).clamp(0.0, 1.0);

  final h = localNow.hour;
  final hour12 = (h % 12) == 0 ? 12 : h % 12;
  final ampm = h < 12 ? 'AM' : 'PM';
  final timeLabel =
      '$hour12:${localNow.minute.toString().padLeft(2, '0')} $ampm';

  final elapsedWhole = elapsedMin.floor().clamp(0, 24 * 60);
  final eh = elapsedWhole ~/ 60;
  final em = elapsedWhole % 60;
  final elapsedLabel = '${eh}h ${em}m into service';

  return OpenPeriodResolution(
    openDaypart: active.id,
    openProgressFraction: double.parse(fraction.toStringAsFixed(4)),
    openTimeLabel: timeLabel,
    openServiceElapsedLabel: elapsedLabel,
    currentDayClosedPeriods: closed,
  );
}

/// SEED-TIME wrapper that guarantees the demo's Shift home is NEVER
/// blank for a CONNECTED demo location (operator decision 2026-05-16,
/// Fix B). [resolveDemoOpenPeriod] stays the honest clock truth (it
/// still returns `openDaypart == null` between services and all its
/// mirror-the-canonical-resolver tests stay green); this wrapper only
/// adjusts what the SEEDER persists.
///
/// Behaviour:
///  * When a period is genuinely IN PROGRESS at [localNow], this returns
///    the honest [resolveDemoOpenPeriod] result UNCHANGED (real clock,
///    real progress).
///  * When NO period is in progress (e.g. Sat 16:00, between Lunch and
///    Dinner), it picks the MOST-RELEVANT applicable period for the
///    business day and presents it as the live/open shift so the Shift
///    home always shows a real whole-day card:
///      - the UPCOMING period (earliest applicable period whose start is
///        still ahead of [localNow]) — generated `projected`, cleanly
///        upgradeable to `open`; else
///      - the MOST-RECENTLY-ENDED applicable non-rolling period (after
///        the day's last service). It is removed from
///        `currentDayClosedPeriods` so the generator emits it
///        `projected` (not `closed`) and the snapshot builder upgrades
///        exactly one slot to `open` — no open/closed UNIQUE collision.
///
/// Determinism (Hard Constraint): the SELECTION is clock-relative (the
/// existing injectable-anchor pattern), but every seeded VALUE is
/// derived from the chosen period's fixed window — fraction is the fixed
/// window MIDPOINT (0.5), labels are computed from the period's own
/// start/end literals, NEVER from [localNow] or `DateTime.now()`. Two
/// reseeds with the same anchor are byte-identical.
///
/// HP #2: seed/writer-side only. No `demo_*` table, no `kDemoMode`
/// reader branch — every reader is byte-unchanged.
OpenPeriodResolution seedTimeOpenPeriodResolution({
  required DateTime localNow,
}) {
  final honest = resolveDemoOpenPeriod(localNow: localNow);
  if (honest.openDaypart != null) {
    // A real service is live — keep the honest clock-derived answer.
    return honest;
  }

  final defs =
      _kDemoDowntownServicePeriods.map(ServicePeriodDefinition.fromMap).toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  final businessDateIso = BusinessDateResolver.resolve(
    localTimestamp: localNow,
    businessDayStartLocalTime: _kDemoBusinessDayStartLocalTime,
  );
  final businessWeekday = DateTime.parse(businessDateIso).weekday;
  final todMin = localNow.hour * 60 + localNow.minute;

  // Applicable periods for this business day, in start-time order.
  final applicable = <ServicePeriodDefinition>[];
  for (final d in defs) {
    if (!d.applicableDays.contains(businessWeekday)) continue;
    if (_demoParseHm(d.startLocalTime) == null) continue;
    if (_demoParseHm(d.endLocalTime) == null) continue;
    applicable.add(d);
  }
  applicable.sort(
    (a, b) => _demoParseHm(
      a.startLocalTime,
    )!.compareTo(_demoParseHm(b.startLocalTime)!),
  );

  if (applicable.isEmpty) {
    // No applicable period at all (should never happen — Lunch/Dinner
    // apply every day). Fall back to the deterministic legacy
    // resolution so the demo still shows a card.
    return MockIntegrationReplaySeed.legacyDefaultResolution;
  }

  // Prefer the UPCOMING period (earliest start still ahead of now).
  ServicePeriodDefinition? chosen;
  for (final d in applicable) {
    if (_demoParseHm(d.startLocalTime)! > todMin) {
      chosen = d;
      break;
    }
  }
  // Else (the day's last service already ended) → most-recently-ended
  // applicable non-rolling period (latest end time).
  chosen ??= applicable
      .where((d) => !d.rollsPastMidnight)
      .fold<ServicePeriodDefinition?>(null, (best, d) {
        if (best == null) return d;
        return _demoParseHm(d.endLocalTime)! > _demoParseHm(best.endLocalTime)!
            ? d
            : best;
      });
  // Absolute last resort: the first applicable period.
  chosen ??= applicable.first;

  // The chosen period must NOT also be seeded `closed` (else the
  // generator emits it `closed` and the snapshot builder would create
  // both an `open` and a `closed` row for the same slot → UNIQUE
  // replace collision). Drop it from the honest closed set; the
  // remaining genuinely-ended periods stay `closed` (closed truth).
  final closed = honest.currentDayClosedPeriods
      .where((id) => id != chosen!.id)
      .toList();

  // Deterministic presentation derived from the chosen period's FIXED
  // window — never from `localNow` (Hard Constraint: determinism).
  final startMin = _demoParseHm(chosen.startLocalTime)!;
  final endMin = _demoParseHm(chosen.endLocalTime)!;
  final windowMin = chosen.rollsPastMidnight
      ? ((1440 - startMin) + endMin)
      : (endMin - startMin);
  // Present the demo "live" shift at the window MIDPOINT (fully
  // deterministic) so the whole-day card shows a believable in-service
  // figure regardless of wall-clock.
  final midMin = startMin + (windowMin ~/ 2);
  final mh = (midMin ~/ 60) % 24;
  final mm = midMin % 60;
  final hour12 = (mh % 12) == 0 ? 12 : mh % 12;
  final ampm = mh < 12 ? 'AM' : 'PM';
  final timeLabel = '$hour12:${mm.toString().padLeft(2, '0')} $ampm';
  final elapsedWhole = (windowMin ~/ 2).clamp(0, 24 * 60);
  final elapsedLabel =
      '${elapsedWhole ~/ 60}h ${elapsedWhole % 60}m into service';

  return OpenPeriodResolution(
    openDaypart: chosen.id,
    openProgressFraction: 0.5,
    openTimeLabel: timeLabel,
    openServiceElapsedLabel: elapsedLabel,
    currentDayClosedPeriods: closed,
  );
}
