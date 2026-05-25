// Advisor Knowledge Activation — Slice A4.6 operational read tools.
//
// Three READ-ONLY tools the agentic answer engine
// (`AdvisorAgenticAnswerEngine`, Slice A4.1) can call to pull the
// operator's live numbers:
//
//   * `get_active_targets`  → the active TargetCycle (target CPLH/SPLH/
//     PPA, FOH/BOH wage, optimal-zone floor/ceiling, per-daypart rows).
//   * `get_week_plan`       → the active WeeklyPlanSnapshot for a week
//     (forecast covers/sales, required FOH/BOH hours, theoretical labor
//     dollars, lock status).
//   * `get_shift_variance`  → per-shift ACTUAL-vs-TARGET + computed
//     variance + provenance/state for a business-date window.
//
// This is a Dart `part of advisor_proxy.dart`, so it shares the
// library's imports + private scope. It is INERT in A4.6: it defines the
// tool definitions, the handlers, and a factory that binds them to an
// `OperatorContext` + the three read repos. NOTHING here is wired into a
// live route, `routeRequest` dispatch, or bootstrap — the A4.2 answer
// route is what will construct an engine with these tools and deploy it.
// The monolith grows by ONLY the `part` directive + the repo imports;
// no `kAdvisorProxyMaxLines` raise.
//
// ── Hard Promise #4 (per-operator isolation is non-negotiable) ──
// Every handler builds its tenant context FROM THE INJECTED
// `OperatorContext` (operatorId / locationId / userId), which the proxy
// derived from the verified JWT. Scope is NEVER taken from tool input.
// The model may pass an optional `restaurant_id`, but it is honored ONLY
// as a SELECTOR among the caller's OWN restaurants (validated against
// `loadScopedRestaurantIds`, which is itself tenant-scoped). A
// hallucinated or foreign `operator_id` / `location_id` / `restaurant_id`
// in tool input is impossible to honor: there is no tool field that
// feeds operator/location scope, and an unknown restaurant_id is
// rejected. RLS (`SET LOCAL app.operator_id/location_id`) is the second
// gate inside every repo call.
//
// ── Hard Promise #6 (advisor recommends, never acts) ──
// All three tools are reads. No write / mutation tool is exposed here.
// Variance is computed in Dart from the single co-located shift row,
// never written back.
//
// ── Metric honesty (metric_card_honesty_contract.md) ──
// A metric that is genuinely NULL in the row is surfaced with an
// explicit `state: 'unavailable'` and `value: null` envelope — NEVER a
// phantom 0.0. Present values carry their provenance. `sources` is
// included only where the data is genuinely citable (the operator's own
// locked target cycle / week plan / shift facts), so the engine can
// trace a recommendation back to real operator data.

part of 'advisor_proxy.dart';

/// Tool name constants. Exported so the A4.2 answer route + tests can
/// reference the canonical strings without hardcoding them.
const String advisorToolGetActiveTargets = 'get_active_targets';
const String advisorToolGetWeekPlan = 'get_week_plan';
const String advisorToolGetShiftVariance = 'get_shift_variance';

/// Metric-honesty state strings surfaced in tool output envelopes.
/// Mirror `MetricState` (`lib/domain/models/metric_provenance.dart`):
/// a present measurement is `measured`; a genuinely-absent one is
/// `unavailable` with `value: null` (never 0.0).
const String _advisorMetricStateMeasured = 'measured';
const String _advisorMetricStateUnavailable = 'unavailable';

/// Bundle returned by [buildAdvisorOperationalTools]: the tool
/// definitions (for the Anthropic `tools` catalog) paired with the
/// matching handler map (keyed by tool name). The A4.2 answer route will
/// merge these into the engine alongside the retrieval tool.
typedef AdvisorOperationalTools = ({
  List<AnthropicToolDefinition> definitions,
  Map<String, ToolHandler> handlers,
});

/// Builds the three operational read tools bound to [operator] (the
/// verified caller scope) and the injected read repos.
///
/// HP #4: [operator] is the ONLY source of operator/location scope. The
/// returned handlers close over it; no tool input can change it.
///
/// The repos are injected (not constructed here) so the A4.2 route can
/// pass the same tenant-pool-backed instances the rest of the proxy uses
/// (`proxy_bootstrap.dart` builds them against `tenantWrapper`), and so
/// tests can pass fakes.
AdvisorOperationalTools buildAdvisorOperationalTools({
  required OperatorContext operator,
  required TargetCycleRepository targetCycleRepository,
  required WeeklyPlanSnapshotRepository weeklyPlanSnapshotRepository,
  required ShiftRecordsReadRepository shiftRecordsReadRepository,
}) {
  final resolver = _AdvisorRestaurantScopeResolver(
    operator: operator,
    shiftRecordsReadRepository: shiftRecordsReadRepository,
  );

  final handlers = <String, ToolHandler>{
    advisorToolGetActiveTargets: (input) => _handleGetActiveTargets(
          input: input,
          operator: operator,
          resolver: resolver,
          targetCycleRepository: targetCycleRepository,
        ),
    advisorToolGetWeekPlan: (input) => _handleGetWeekPlan(
          input: input,
          operator: operator,
          resolver: resolver,
          weeklyPlanSnapshotRepository: weeklyPlanSnapshotRepository,
        ),
    advisorToolGetShiftVariance: (input) => _handleGetShiftVariance(
          input: input,
          operator: operator,
          resolver: resolver,
          shiftRecordsReadRepository: shiftRecordsReadRepository,
        ),
  };

  return (
    definitions: _advisorOperationalToolDefinitions,
    handlers: handlers,
  );
}

/// The three tool definitions (Anthropic `tools` shape). `restaurant_id`
/// is documented as an OPTIONAL selector among the operator's OWN
/// restaurants — never a way to choose scope (HP #4).
final List<AnthropicToolDefinition> _advisorOperationalToolDefinitions =
    <AnthropicToolDefinition>[
  AnthropicToolDefinition(
    name: advisorToolGetActiveTargets,
    description:
        'Get the operator\'s current locked labor and sales targets for '
        'their restaurant: target CPLH (covers per labor hour), SPLH '
        '(sales per labor hour), PPA (per-person average), the FOH and '
        'BOH hourly wages used, the optimal-zone CPLH floor and ceiling, '
        'and any per-daypart target rows. Reads the active target cycle. '
        'Use this when the operator asks what their targets are or you '
        'need targets to explain a number. Read-only.',
    inputSchema: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'restaurant_id': <String, Object?>{
          'type': 'string',
          'description':
              'Optional. Only needed when the operator runs more than one '
              'restaurant; selects which of THEIR restaurants to read. '
              'Omit for a single-restaurant operator. It cannot change '
              'which operator the data belongs to.',
        },
      },
      'required': <String>[],
      'additionalProperties': false,
    },
  ),
  AnthropicToolDefinition(
    name: advisorToolGetWeekPlan,
    description:
        'Get the operator\'s locked weekly plan for a given week: '
        'forecast covers and sales, required FOH and BOH hours, the '
        'theoretical FOH and BOH labor dollars, and whether the plan is '
        'locked. Reads the active weekly plan snapshot for the week. Use '
        'this when the operator asks about their plan for a week or you '
        'need planned numbers to compare against actuals. Read-only.',
    inputSchema: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'week_start_date': <String, Object?>{
          'type': 'string',
          'description':
              'Required. The first day of the week to read, as an '
              'ISO date (YYYY-MM-DD).',
        },
        'restaurant_id': <String, Object?>{
          'type': 'string',
          'description':
              'Optional. Only needed when the operator runs more than one '
              'restaurant; selects which of THEIR restaurants to read. '
              'Omit for a single-restaurant operator. It cannot change '
              'which operator the data belongs to.',
        },
      },
      'required': <String>['week_start_date'],
      'additionalProperties': false,
    },
  ),
  AnthropicToolDefinition(
    name: advisorToolGetShiftVariance,
    description:
        'Get the operator\'s closed shifts for a date range with both the '
        'actual results and the locked targets side by side, plus the '
        'computed variance (actual minus target) for CPLH, SPLH, and PPA. '
        'Each shift also carries where its covers and labor dollars came '
        'from, so you never present an estimate as a measurement. Use '
        'this when the operator asks how a shift or a stretch of days '
        'performed against target. Read-only.',
    inputSchema: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'business_date_from': <String, Object?>{
          'type': 'string',
          'description':
              'Required. Start of the date range (inclusive), as an '
              'ISO date (YYYY-MM-DD).',
        },
        'business_date_to': <String, Object?>{
          'type': 'string',
          'description':
              'Required. End of the date range (inclusive), as an '
              'ISO date (YYYY-MM-DD).',
        },
        'restaurant_id': <String, Object?>{
          'type': 'string',
          'description':
              'Optional. Only needed when the operator runs more than one '
              'restaurant; selects which of THEIR restaurants to read. '
              'Omit for a single-restaurant operator. It cannot change '
              'which operator the data belongs to.',
        },
      },
      'required': <String>['business_date_from', 'business_date_to'],
      'additionalProperties': false,
    },
  ),
];

// ─── Handlers ────────────────────────────────────────────────────────────────

Future<Map<String, Object?>> _handleGetActiveTargets({
  required Map<String, Object?> input,
  required OperatorContext operator,
  required _AdvisorRestaurantScopeResolver resolver,
  required TargetCycleRepository targetCycleRepository,
}) async {
  final scope = await resolver.resolve(input);
  if (scope.needsSelection) return scope.toToolResult();
  final restaurantId = scope.restaurantId!;

  // HP #4: operatorId / locationId / userId come from the verified
  // OperatorContext ONLY. restaurantId is the caller's own (validated).
  final row = await targetCycleRepository.loadActiveCycle(
    operatorId: operator.operatorId,
    locationId: operator.locationId,
    restaurantId: restaurantId,
    userId: _userIdOrNull(operator),
  );

  if (row == null) {
    return <String, Object?>{
      'found': false,
      'restaurant_id': restaurantId,
      'message':
          'No active target cycle is set for this restaurant yet.',
    };
  }

  return <String, Object?>{
    'found': true,
    'restaurant_id': row.restaurantId,
    'effective_start': row.effectiveStart,
    'effective_end': row.effectiveEnd,
    'source': row.source,
    'targets': <String, Object?>{
      'cplh': _measured(row.targetCplh),
      'splh': _measured(row.targetSplh),
      'ppa': _measured(row.targetPpa),
      'foh_wage': _measured(row.fohWage),
      'boh_wage': _measured(row.bohWage),
      'opz_floor_cplh': _measured(row.opzFloorCplh),
      'opz_ceiling_cplh': _measured(row.opzCeilingCplh),
    },
    'dayparts': <Map<String, Object?>>[
      for (final dp in row.dayparts)
        <String, Object?>{
          'service_period_id': dp.servicePeriodId,
          'cplh': _measured(dp.targetCplh),
          'splh': _measured(dp.targetSplh),
          'ppa': _measured(dp.targetPpa),
          'opz_floor_cplh': _measured(dp.opzFloorCplh),
          'opz_ceiling_cplh': _measured(dp.opzCeilingCplh),
          if (dp.verdict != null) 'verdict': dp.verdict,
        },
    ],
    // Citable: the operator's own locked target cycle.
    'sources': <Map<String, Object?>>[
      <String, Object?>{
        'source_id': 'target_cycle:${row.cycleId}',
        'title': 'Active target cycle ($restaurantId)',
        'snippet':
            'Targets effective ${row.effectiveStart} to ${row.effectiveEnd}, '
            'source ${row.source}.',
      },
    ],
  };
}

Future<Map<String, Object?>> _handleGetWeekPlan({
  required Map<String, Object?> input,
  required OperatorContext operator,
  required _AdvisorRestaurantScopeResolver resolver,
  required WeeklyPlanSnapshotRepository weeklyPlanSnapshotRepository,
}) async {
  final weekStartDate = _requiredIsoDateInput(input, 'week_start_date');
  if (weekStartDate == null) {
    return _invalidInputResult(
      'week_start_date is required and must be an ISO date (YYYY-MM-DD).',
    );
  }

  final scope = await resolver.resolve(input);
  if (scope.needsSelection) return scope.toToolResult();
  final restaurantId = scope.restaurantId!;

  // HP #4: scope from the verified OperatorContext only.
  final row = await weeklyPlanSnapshotRepository.loadActiveSnapshot(
    operatorId: operator.operatorId,
    locationId: operator.locationId,
    restaurantId: restaurantId,
    weekStartDate: weekStartDate,
    userId: _userIdOrNull(operator),
  );

  if (row == null) {
    return <String, Object?>{
      'found': false,
      'restaurant_id': restaurantId,
      'week_start_date': weekStartDate,
      'message':
          'No active weekly plan is locked for that week yet.',
    };
  }

  return <String, Object?>{
    'found': true,
    'restaurant_id': row.restaurantId,
    'week_start_date': row.weekStartDate,
    'week_end_date': row.weekEndDate,
    'snapshot_status': row.snapshotStatus,
    'is_locked': row.snapshotStatus == 'active',
    'plan': <String, Object?>{
      'forecast_covers': _measured(row.forecastCovers),
      'forecast_sales': _measured(row.forecastSales),
      'required_foh_hours': _measured(row.requiredFohHours),
      'required_boh_hours': _measured(row.requiredBohHours),
      'theoretical_foh_labor_dollars':
          _measured(row.theoreticalFohLaborDollars),
      'theoretical_boh_labor_dollars':
          _measured(row.theoreticalBohLaborDollars),
    },
    'covers_source': row.coversSource,
    'sales_source': row.salesSource,
    // Citable: the operator's own locked weekly plan snapshot.
    'sources': <Map<String, Object?>>[
      <String, Object?>{
        'source_id': 'weekly_plan_snapshot:${row.snapshotId}',
        'title': 'Weekly plan for ${row.weekStartDate} ($restaurantId)',
        'snippet':
            'Forecast ${row.forecastCovers} covers, status '
            '${row.snapshotStatus}.',
      },
    ],
  };
}

Future<Map<String, Object?>> _handleGetShiftVariance({
  required Map<String, Object?> input,
  required OperatorContext operator,
  required _AdvisorRestaurantScopeResolver resolver,
  required ShiftRecordsReadRepository shiftRecordsReadRepository,
}) async {
  final from = _requiredIsoDateInput(input, 'business_date_from');
  final to = _requiredIsoDateInput(input, 'business_date_to');
  if (from == null || to == null) {
    return _invalidInputResult(
      'business_date_from and business_date_to are required and must be '
      'ISO dates (YYYY-MM-DD).',
    );
  }
  if (from.compareTo(to) > 0) {
    return _invalidInputResult(
      'business_date_from must be on or before business_date_to.',
    );
  }

  final scope = await resolver.resolve(input);
  if (scope.needsSelection) return scope.toToolResult();
  final restaurantId = scope.restaurantId!;

  // HP #4: operator/location scope from the verified OperatorContext.
  final rows = await shiftRecordsReadRepository.loadShiftVarianceForWindow(
    operatorId: operator.operatorId,
    locationId: operator.locationId,
    restaurantId: restaurantId,
    businessDateFrom: from,
    businessDateTo: to,
    userId: _userIdOrNull(operator),
  );

  return <String, Object?>{
    'restaurant_id': restaurantId,
    'business_date_from': from,
    'business_date_to': to,
    'shift_count': rows.length,
    'shifts': <Map<String, Object?>>[
      for (final row in rows)
        <String, Object?>{
          'business_date': row.businessDate,
          'daypart': row.daypart,
          'status': row.status,
          'cplh': <String, Object?>{
            'actual': _measured(row.actualCplh),
            'target': _measured(row.targetCplh),
            'variance': _measured(row.cplhVariance),
          },
          'splh': <String, Object?>{
            'actual': _measured(row.actualSplh),
            'target': _measured(row.targetSplh),
            'variance': _measured(row.splhVariance),
          },
          'ppa': <String, Object?>{
            'actual': _measured(row.actualPpa),
            'target': _measured(row.targetPpa),
            'variance': _measured(row.ppaVariance),
          },
          'actual_sales': _measured(row.actualSales),
          'covers': _measured(row.covers),
          'forecast_covers': _measured(row.forecastCovers),
          'opz_floor_cplh': _measured(row.opzFloorCplh),
          'opz_ceiling_cplh': _measured(row.opzCeilingCplh),
          'primary_lever': row.primaryLever,
          // Provenance so the advisor never presents an estimate as a
          // measurement (metric honesty).
          'covers_provenance': row.coversProvenance,
          'labor_dollars_provenance': row.laborDollarsProvenance,
          'source_system': row.sourceSystem,
        },
    ],
    // Each closed shift is a citable operator fact.
    'sources': <Map<String, Object?>>[
      for (final row in rows)
        <String, Object?>{
          'source_id':
              'shift_record:$restaurantId:${row.businessDate}:${row.daypart}',
          'title': '${row.businessDate} ${row.daypart}',
          'snippet':
              'Closed shift actual vs target for ${row.businessDate} '
              '${row.daypart}.',
        },
    ],
  };
}

// ─── Restaurant-scope resolver (HP #4) ─────────────────────────────────────────

/// Resolves the TEXT `restaurant_id` for a tool call from the verified
/// [OperatorContext] ONLY. Tool input can supply an optional
/// `restaurant_id`, but it is honored solely as a SELECTOR among the
/// operator's OWN restaurants. The candidate set comes from
/// [ShiftRecordsReadRepository.loadScopedRestaurantIds], which runs in
/// the caller's tenant scope (RLS-folded), so a hallucinated / foreign
/// id can never match.
///
/// Resolution outcomes:
///   * exactly one own restaurant, no/blank selector → that restaurant.
///   * a selector that matches one of the own restaurants → that one.
///   * a selector that matches none → `needsSelection` (rejected; the
///     operator's own ids are listed so the model can re-ask).
///   * multiple own restaurants, no selector → `needsSelection`.
///   * zero own restaurants → `needsSelection` with an empty list (the
///     advisor reports it has no restaurant data for this operator).
class _AdvisorRestaurantScopeResolver {
  _AdvisorRestaurantScopeResolver({
    required this.operator,
    required this.shiftRecordsReadRepository,
  });

  final OperatorContext operator;
  final ShiftRecordsReadRepository shiftRecordsReadRepository;

  Future<_AdvisorRestaurantScope> resolve(Map<String, Object?> input) async {
    final own = await shiftRecordsReadRepository.loadScopedRestaurantIds(
      operatorId: operator.operatorId,
      locationId: operator.locationId,
      userId: _userIdOrNull(operator),
    );

    final raw = input['restaurant_id'];
    final selector = raw is String && raw.trim().isNotEmpty ? raw.trim() : null;

    if (selector != null) {
      // HP #4: only honor a selector that is one of the caller's OWN
      // restaurants. Never honor a foreign / hallucinated id.
      if (own.contains(selector)) {
        return _AdvisorRestaurantScope.resolved(selector);
      }
      return _AdvisorRestaurantScope.needsSelection(
        own,
        message:
            'That restaurant is not one of yours. Pick one of your '
            'restaurants below.',
      );
    }

    if (own.length == 1) {
      return _AdvisorRestaurantScope.resolved(own.single);
    }
    if (own.isEmpty) {
      return _AdvisorRestaurantScope.needsSelection(
        own,
        message:
            'I do not have any restaurant set up for you yet, so I cannot '
            'pull these numbers.',
      );
    }
    return _AdvisorRestaurantScope.needsSelection(
      own,
      message:
          'You have more than one restaurant. Tell me which one and I will '
          'pull the numbers.',
    );
  }
}

/// Outcome of restaurant-scope resolution. Either a concrete
/// [restaurantId] or a `needsSelection` signal carrying the operator's
/// OWN restaurant ids (never any other operator's) for the model to
/// re-ask against.
class _AdvisorRestaurantScope {
  const _AdvisorRestaurantScope.resolved(this.restaurantId)
      : needsSelection = false,
        ownRestaurantIds = const <String>[],
        message = null;

  const _AdvisorRestaurantScope.needsSelection(
    this.ownRestaurantIds, {
    required this.message,
  })  : needsSelection = true,
        restaurantId = null;

  final String? restaurantId;
  final bool needsSelection;
  final List<String> ownRestaurantIds;
  final String? message;

  /// The `needs_restaurant_selection` tool-result envelope. NOT an error
  /// (the engine still cites/answers gracefully); lists ONLY the
  /// operator's own restaurant ids.
  Map<String, Object?> toToolResult() => <String, Object?>{
        'needs_restaurant_selection': true,
        'your_restaurant_ids': ownRestaurantIds,
        'message': message,
      };
}

// ─── Envelope + input helpers ──────────────────────────────────────────────────

/// Wraps a present numeric/value in a `measured` envelope, or emits the
/// `unavailable` envelope (value: null) when [value] is null. Metric
/// honesty: a genuinely-absent measurement is NEVER coerced to 0.0.
Map<String, Object?> _measured(Object? value) {
  if (value == null) {
    return const <String, Object?>{
      'value': null,
      'state': _advisorMetricStateUnavailable,
    };
  }
  return <String, Object?>{
    'value': value,
    'state': _advisorMetricStateMeasured,
  };
}

/// Reads an ISO `YYYY-MM-DD` date input. Returns null when missing,
/// non-string, blank, or not a strict 10-char ISO date that parses.
String? _requiredIsoDateInput(Map<String, Object?> input, String key) {
  final raw = input[key];
  if (raw is! String) return null;
  final trimmed = raw.trim();
  if (trimmed.length != 10) return null;
  final parsed = DateTime.tryParse(trimmed);
  if (parsed == null) return null;
  return trimmed;
}

/// The caller's `user_id` for actor attribution, or null when blank
/// (global-admin sentinel scope). Repos accept a null userId.
String? _userIdOrNull(OperatorContext operator) {
  final id = operator.userId;
  return id.isEmpty ? null : id;
}

/// A non-fabricated `invalid_input` tool result. Not flagged is_error at
/// this layer (the engine decides); the model can correct its arguments.
Map<String, Object?> _invalidInputResult(String message) => <String, Object?>{
      'error': 'invalid_input',
      'message': message,
    };
