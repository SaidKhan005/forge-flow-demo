// Phase 11A.5 / Support logs redesign P3 - Support logs admin surface
// (per-operator request log; the RIGHT content pane only — the left
// scope picker is owned elsewhere and intentionally untouched).
//
// Read-only support tool over the proxy `proxy_requests` projection,
// now backed by the real per-request telemetry P1b/P2 added (provider,
// model, tokens, cost, measured latency, real status, actor uid via
// the `proxy_request_stats` LEFT JOIN). The redesign (plan §3/§12)
// makes it plain English with the engineering detail tucked away:
//
//   * One compact filter row: Search + Type + When + Result. The Type
//     filter folds what used to be three tabs (All requests /
//     Relationship Help / Account Help) AND the old request-type key
//     box into a single dropdown (All activity, the four AI types, and
//     the two support-help groups). AI types reuse `listRequests`;
//     support groups reuse `listSupportHelpRequests` — no gateway change.
//   * Each row collapsed: a status dot + a plain title + a secondary
//     "<result> · <relative time>" line (body font, no monospace).
//   * Each row expanded: a plain "What happened" zone (What / Result /
//     When / Who / Took) and a collapsible "Technical reference (for
//     engineering)" zone that keeps the raw ids, model, tokens, and
//     cost out of the way (monospace + copy there only).
//
// Honesty (Metric Honesty Doctrine): rich telemetry exists ONLY for
// successful LLM requests. Support-help rows and failed / older /
// pre-P1b requests have null telemetry and render the honest "—"
// sentinel or "Not recorded" — never a fabricated value or phantom 0.
//
// Live refresh is OFF by default, surfaced as a small "Live" chip beside
// Refresh in the header. When on, the screen polls `tailRecent` every
// [kDebugConsoleTailPollInterval] seconds and merges new rows into the
// table; the toggle stops polling when off or when the screen disposes.
//
// Permission gating (unchanged):
//   * `super_admin` lands with `editingEnabled = true`. Full-message-
//     text reveal is gated by the operator's `feature_flags` opt-in row.
//   * `ff_support` lands with `editingEnabled = false` ("Support view
//     only"). Full message text stays hidden even when the opt-in is on.
//
// The screen is performance-disciplined per
// `docs/contracts/slice_runtime_acceptance_contract.md`:
//   * cheap initial render - a manual fetch button surfaces the first
//     request-log page rather than auto-polling on mount;
//   * the live chip is opt-in and does not stack in-flight requests;
//   * search / filter changes re-filter client-side first so a
//     narrowing change does not force a fresh round-trip.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:forge_and_flow/widgets/console/console_screen_body.dart';
import 'package:forge_and_flow/widgets/console/console_screen_header.dart';

import '../../theme/app_theme.dart';
import '../../theme/scope_icons.dart';

import '../admin_button_styles.dart';
import '../admin_human_labels.dart';
import '../admin_route_handoff.dart';
import '../models/debug_console_admin_models.dart';
import '../services/debug_console_admin_gateway.dart';
import '../services/roles_hierarchy_sessions_admin_gateway.dart';
import '../widgets/admin_business_accounts_back_button.dart';

const int _kMaxOrgUnitSupportLogLocationIds = 100;

/// One option in the folded "Type" filter. Replaces the old three tabs
/// (All requests / Relationship Help / Account Help) AND the separate
/// request-type key box: a single dropdown picks the activity to show.
///
///   * [allActivity] — the four AI request types, unfiltered.
///   * [advisorAnswers]/[coachingHelp]/[workflowPlanning]/
///     [workflowScheduling] — one AI use class each (sets
///     `RequestLogFilter.usageClass`, reusing `listRequests`).
///   * [relationshipHelp]/[accountHelp] — the grouped support-help
///     surfaces (reuse `listSupportHelpRequests`).
enum _RequestTypeView {
  allActivity,
  advisorAnswers,
  coachingHelp,
  workflowPlanning,
  workflowScheduling,
  relationshipHelp,
  accountHelp,
}

extension _RequestTypeViewCopy on _RequestTypeView {
  /// Plain-English label shown in the Type dropdown + its trigger.
  String get label {
    switch (this) {
      case _RequestTypeView.allActivity:
        return 'All activity';
      case _RequestTypeView.advisorAnswers:
        return 'Advisor answers';
      case _RequestTypeView.coachingHelp:
        return 'Coaching help';
      case _RequestTypeView.workflowPlanning:
        return 'Workflow planning';
      case _RequestTypeView.workflowScheduling:
        return 'Workflow scheduling';
      case _RequestTypeView.relationshipHelp:
        return 'Relationship help';
      case _RequestTypeView.accountHelp:
        return 'Account help';
    }
  }

  /// The AI `usage_class` this view filters `listRequests` to, or null
  /// for [allActivity] and the support-help groups (which are served by
  /// their own gateway calls, not a usage_class filter).
  String? get usageClass {
    switch (this) {
      case _RequestTypeView.advisorAnswers:
        return 'advisor_qa';
      case _RequestTypeView.coachingHelp:
        return 'coach_qa';
      case _RequestTypeView.workflowPlanning:
        return 'wf_pl';
      case _RequestTypeView.workflowScheduling:
        return 'wf_schedule';
      case _RequestTypeView.allActivity:
      case _RequestTypeView.relationshipHelp:
      case _RequestTypeView.accountHelp:
        return null;
    }
  }

}

class DebugConsoleAdminScreen extends StatefulWidget {
  const DebugConsoleAdminScreen({
    super.key,
    required this.gateway,
    this.hierarchyGateway,
    this.editingEnabled = true,
    this.hierarchyScope,
    this.initialFilter = const RequestLogFilter(),
    this.onBackToBusinessAccounts,
    this.tailPollInterval = kDebugConsoleTailPollInterval,
    @visibleForTesting this.now,
  });

  final DebugConsoleAdminGateway gateway;
  final RolesHierarchySessionsAdminGateway? hierarchyGateway;

  /// `true` when the signed-in actor is `super_admin`. Drives the
  /// expand-row full-content reveal - `false` (ff_support) hides the
  /// expand affordance entirely so the meta view is the only path.
  final bool editingEnabled;

  /// Optional hierarchy scope from Business accounts. Business and
  /// location scopes map directly onto the existing request-log route.
  /// Org-unit scopes are expanded through [hierarchyGateway] before
  /// the request-log filter is sent to the admin proxy.
  final AdminHierarchyScopeIntent? hierarchyScope;

  /// Optional route seed used by contextual actions elsewhere in the
  /// admin console. Empty keeps the manual Refresh-first behavior.
  final RequestLogFilter initialFilter;
  final VoidCallback? onBackToBusinessAccounts;

  /// Cadence for live-tail polling. Production uses
  /// [kDebugConsoleTailPollInterval]; tests pin a synthetic value.
  final Duration tailPollInterval;

  /// Test-only clock injection so live-tail and time-window filters
  /// are deterministic. Production uses [DateTime.now].
  final DateTime Function()? now;

  @override
  State<DebugConsoleAdminScreen> createState() =>
      _DebugConsoleAdminScreenState();
}

class _DebugConsoleAdminScreenState extends State<DebugConsoleAdminScreen> {
  bool _initialLoading = false;
  bool _refreshing = false;
  String? _loadError;
  DateTime? _lastRefreshed;

  List<RequestLogEntry> _entries = const <RequestLogEntry>[];
  List<RequestLogEntry> _relationshipHelpEntries = const <RequestLogEntry>[];
  List<RequestLogEntry> _accountHelpEntries = const <RequestLogEntry>[];
  List<FullContentOptIn> _optIns = const <FullContentOptIn>[];

  late RequestLogFilter _filter;

  /// The folded Type filter selection. Drives which list renders and,
  /// for AI types, the `usage_class` axis on [_filter]. Support-help
  /// views read the dedicated support entries instead.
  _RequestTypeView _typeView = _RequestTypeView.allActivity;
  RequestLogFilter? _serverFilter;
  bool _refreshQueued = false;
  List<String>? _scopeLocationIds;
  bool _scopeResolving = false;
  String? _scopeResolutionError;
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _expanded = <String>{};

  bool _liveTailOn = false;
  Timer? _tailTimer;
  bool _tailing = false;

  DateTime _clockNow() => (widget.now ?? () => DateTime.now().toUtc())();

  @override
  void initState() {
    super.initState();
    _filter = widget.initialFilter;
    _startScopeResolution();
    if (!widget.initialFilter.isEmpty) {
      unawaited(_refresh());
    }
  }

  @override
  void didUpdateWidget(covariant DebugConsoleAdminScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hierarchyScope?.cacheKey != widget.hierarchyScope?.cacheKey ||
        oldWidget.hierarchyGateway != widget.hierarchyGateway) {
      _startScopeResolution();
    }
  }

  @override
  void dispose() {
    _tailTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  bool _optInOnFor(String operatorId) {
    for (final row in _optIns) {
      if (row.operatorId == operatorId) return row.enabled;
    }
    return false;
  }

  RequestLogFilter get _effectiveFilter => _scopeFilter(_filter);

  RequestLogFilter _effectiveSupportFilter(SupportHelpSurface surface) {
    // Support-help views reuse the single compact filter row (search /
    // when / result), so the same `_filter` axes apply. The relationship
    // vs account grouping is the surface itself, not a usage_class.
    return _scopeFilter(_filter.copyWith(usageClass: null));
  }

  RequestLogFilter _scopeFilter(RequestLogFilter base) {
    final scope = widget.hierarchyScope;
    if (scope == null) return base;
    switch (scope.scopeType) {
      case AdminHierarchyScopeType.business:
        return base.copyWith(operatorId: scope.operatorId);
      case AdminHierarchyScopeType.location:
        return base.copyWith(
          operatorId: scope.operatorId,
          locationId: scope.locationId,
          locationIds: null,
        );
      case AdminHierarchyScopeType.orgUnit:
        final locationIds = _scopeLocationIds ?? const <String>[];
        return base.copyWith(
          operatorId: scope.operatorId,
          locationIds: List<String>.unmodifiable(locationIds),
        );
    }
  }

  bool get _orgUnitScopeBlocked {
    final scope = widget.hierarchyScope;
    if (scope == null || !scope.isOrgUnitScope) return false;
    if (_scopeResolving) return true;
    if (_scopeResolutionError != null) return true;
    return _scopeLocationIds == null;
  }

  void _startScopeResolution() {
    final scope = widget.hierarchyScope;
    if (scope == null || !scope.isOrgUnitScope) {
      _scopeLocationIds = null;
      _scopeResolving = false;
      _scopeResolutionError = null;
      return;
    }
    final gateway = widget.hierarchyGateway;
    if (gateway == null) {
      _scopeLocationIds = null;
      _scopeResolving = false;
      _scopeResolutionError =
          'Org-unit support logs need the hierarchy location list. This route does not expose that data here, so choose a business or location scope.';
      return;
    }
    _scopeLocationIds = null;
    _scopeResolving = true;
    _scopeResolutionError = null;
    unawaited(_resolveOrgUnitLocations(scope, gateway));
  }

  Future<void> _resolveOrgUnitLocations(
    AdminHierarchyScopeIntent scope,
    RolesHierarchySessionsAdminGateway gateway,
  ) async {
    try {
      final results = await Future.wait(<Future<Object>>[
        gateway.listOrgUnits(operatorId: scope.operatorId),
        gateway.listHierarchyLocations(operatorId: scope.operatorId),
      ]);
      if (!mounted || widget.hierarchyScope?.cacheKey != scope.cacheKey) {
        return;
      }
      final orgUnits = results[0] as List<OrgUnitAdminNode>;
      final locations = results[1] as List<HierarchyLocationLeaf>;
      final coveredUnitIds = _coveredOrgUnitIds(orgUnits, scope.orgUnitId!);
      final locationIds = <String>[
        for (final location in locations)
          if (coveredUnitIds.contains(location.orgUnitId)) location.locationId,
      ]..sort();
      if (locationIds.length > _kMaxOrgUnitSupportLogLocationIds) {
        setState(() {
          _scopeLocationIds = const <String>[];
          _scopeResolving = false;
          _scopeResolutionError =
              'This org unit covers ${locationIds.length} locations. Support logs cap explicit location filters at $_kMaxOrgUnitSupportLogLocationIds, so choose a smaller org unit or the business scope.';
        });
        return;
      }
      setState(() {
        _scopeLocationIds = List<String>.unmodifiable(locationIds);
        _scopeResolving = false;
        _scopeResolutionError = null;
      });
      unawaited(_refresh());
    } catch (error) {
      if (!mounted || widget.hierarchyScope?.cacheKey != scope.cacheKey) {
        return;
      }
      setState(() {
        _scopeLocationIds = null;
        _scopeResolving = false;
        _scopeResolutionError =
            'Could not expand this org unit to locations: $error';
      });
    }
  }

  Set<String> _coveredOrgUnitIds(
    List<OrgUnitAdminNode> orgUnits,
    String rootOrgUnitId,
  ) {
    final byParent = <String?, List<OrgUnitAdminNode>>{};
    for (final unit in orgUnits) {
      byParent
          .putIfAbsent(unit.parentOrgUnitId, () => <OrgUnitAdminNode>[])
          .add(unit);
    }
    final covered = <String>{};
    void visit(String orgUnitId) {
      if (!covered.add(orgUnitId)) return;
      for (final child in byParent[orgUnitId] ?? const <OrgUnitAdminNode>[]) {
        visit(child.orgUnitId);
      }
    }

    visit(rootOrgUnitId);
    return covered;
  }

  Future<void> _refresh() async {
    if (_refreshing) {
      _refreshQueued = true;
      return;
    }
    if (_orgUnitScopeBlocked) {
      setState(() {
        _entries = const <RequestLogEntry>[];
        _relationshipHelpEntries = const <RequestLogEntry>[];
        _accountHelpEntries = const <RequestLogEntry>[];
        _initialLoading = false;
        _refreshing = false;
        _loadError = null;
      });
      return;
    }
    final requestFilter = _effectiveFilter;
    final relationshipFilter = _effectiveSupportFilter(
      SupportHelpSurface.relationship,
    );
    final accountFilter = _effectiveSupportFilter(SupportHelpSurface.account);
    setState(() {
      _refreshing = true;
      if (_entries.isEmpty) _initialLoading = true;
      _loadError = null;
    });
    try {
      final results = await Future.wait(<Future<Object>>[
        widget.gateway.listRequests(requestFilter),
        widget.gateway.listFullContentOptIns(),
        widget.gateway.listSupportHelpRequests(
          SupportHelpSurface.relationship,
          relationshipFilter,
        ),
        widget.gateway.listSupportHelpRequests(
          SupportHelpSurface.account,
          accountFilter,
        ),
      ]);
      if (!mounted) return;
      setState(() {
        _entries = results[0] as List<RequestLogEntry>;
        _optIns = results[1] as List<FullContentOptIn>;
        _relationshipHelpEntries = results[2] as List<RequestLogEntry>;
        _accountHelpEntries = results[3] as List<RequestLogEntry>;
        _serverFilter = requestFilter;
        _initialLoading = false;
        _loadError = null;
        _lastRefreshed = _clockNow();
      });
    } on DebugConsoleAdminGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error.message;
        _initialLoading = false;
        _lastRefreshed = _clockNow();
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Could not load debug console: $error';
        _initialLoading = false;
        _lastRefreshed = _clockNow();
      });
    } finally {
      if (mounted) {
        setState(() => _refreshing = false);
        final loadedFilter = _serverFilter;
        final needsCurrentFilter =
            loadedFilter == null ||
            !_filterCovers(loadedFilter, _effectiveFilter);
        if (_refreshQueued || needsCurrentFilter) {
          _refreshQueued = false;
          unawaited(_refresh());
        }
      } else {
        _refreshing = false;
      }
    }
  }

  void _onFilterChanged(RequestLogFilter next) {
    setState(() {
      _filter = next;
    });
    final requestedFilter = _effectiveFilter;
    final loadedFilter = _serverFilter;
    if (_entries.isNotEmpty &&
        loadedFilter != null &&
        _filterCovers(loadedFilter, requestedFilter)) {
      // Re-narrowing client-side first; refresh on demand if the
      // operator wants a fresh window.
      return;
    }
    unawaited(_refresh());
  }

  void _onSearchChanged(String value) {
    final next = value.trim();
    _onFilterChanged(_filter.copyWith(searchText: next.isEmpty ? null : next));
  }

  /// Pick a folded Type filter option. AI types set the `usage_class`
  /// axis (reusing `listRequests`); support-help groups clear it and
  /// switch the rendered list to the dedicated support entries. All
  /// four lists are already fetched on refresh, so switching the view
  /// is local; we only re-fetch if the new `usage_class` is not covered
  /// by the last server load.
  void _onTypeViewChanged(_RequestTypeView next) {
    setState(() {
      _typeView = next;
    });
    _onFilterChanged(_filter.copyWith(usageClass: next.usageClass));
  }

  /// The coarse Result filter (Any / Worked / Not recorded). Maps to the
  /// real `status` axis without offering error/timeout as standing
  /// options (production only emits success or unknown today).
  void _onResultChanged(RequestLogStatus? status) {
    _onFilterChanged(_filter.copyWith(status: status));
  }

  bool _filterCovers(RequestLogFilter loaded, RequestLogFilter requested) {
    return _stringAxisCovers(loaded.operatorId, requested.operatorId) &&
        _stringAxisCovers(loaded.locationId, requested.locationId) &&
        _stringListAxisCovers(loaded.locationIds, requested.locationIds) &&
        _stringAxisCovers(loaded.usageClass, requested.usageClass) &&
        _valueAxisCovers(loaded.status, requested.status) &&
        _valueAxisCovers(loaded.timeWindow, requested.timeWindow) &&
        _stringAxisCovers(loaded.searchText, requested.searchText);
  }

  bool _stringAxisCovers(String? loaded, String? requested) {
    final loadedValue = loaded?.trim();
    if (loadedValue == null || loadedValue.isEmpty) return true;
    return loadedValue == requested?.trim();
  }

  bool _stringListAxisCovers(List<String>? loaded, List<String>? requested) {
    if (loaded == null) return true;
    if (requested == null) return false;
    final loadedSet = loaded.toSet();
    return requested.every(loadedSet.contains);
  }

  bool _valueAxisCovers<T>(T? loaded, T? requested) {
    return loaded == null || loaded == requested;
  }

  void _toggleLiveTail(bool enabled) {
    setState(() {
      _liveTailOn = enabled;
    });
    if (!enabled) {
      _tailTimer?.cancel();
      _tailTimer = null;
      return;
    }
    _tailTimer?.cancel();
    _tailTimer = Timer.periodic(widget.tailPollInterval, (_) {
      unawaited(_pollTail());
    });
  }

  Future<void> _pollTail() async {
    if (!mounted) return;
    // Skip the tick if a refresh is in flight or the previous tail
    // poll has not returned yet. The runtime acceptance contract
    // bans stacked in-flight requests; a slow `tailRecent()` cannot
    // accumulate concurrent calls behind it.
    if (_refreshing || _tailing) return;
    _tailing = true;
    try {
      final fresh = await widget.gateway.tailRecent();
      if (!mounted) return;
      // Merge by request_id, preserving ordering by started_at desc,
      // then clamp back to `kDebugConsoleListLimit` so a long live-
      // tail session cannot grow the table without bound.
      final byId = <String, RequestLogEntry>{};
      for (final entry in _entries) {
        byId[entry.requestId] = entry;
      }
      for (final entry in fresh) {
        byId[entry.requestId] = entry;
      }
      final merged = byId.values.toList()
        ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
      final clamped = merged.length > kDebugConsoleListLimit
          ? merged.sublist(0, kDebugConsoleListLimit)
          : merged;
      setState(() {
        _entries = List<RequestLogEntry>.unmodifiable(clamped);
        _lastRefreshed = _clockNow();
      });
    } catch (_) {
      // Live-tail polls are best-effort; transient errors do not
      // block the screen. The "Last checked" timestamp simply does
      // not advance until the next successful tick.
    } finally {
      _tailing = false;
    }
  }

  /// The rows the current Type filter shows. AI views (All activity and
  /// the four AI types) read [_entries]; the two support-help groups
  /// read their dedicated lists. Every view is re-filtered client-side
  /// by the shared compact filter (search / when / result) so a
  /// narrowing change feels instant without a round-trip.
  List<RequestLogEntry> get _visibleEntries {
    final reference = _clockNow();
    final effectiveFilter = _effectiveFilter;
    final List<RequestLogEntry> source;
    switch (_typeView) {
      case _RequestTypeView.relationshipHelp:
        source = _relationshipHelpEntries;
        break;
      case _RequestTypeView.accountHelp:
        source = _accountHelpEntries;
        break;
      case _RequestTypeView.allActivity:
      case _RequestTypeView.advisorAnswers:
      case _RequestTypeView.coachingHelp:
      case _RequestTypeView.workflowPlanning:
      case _RequestTypeView.workflowScheduling:
        source = _entries;
        break;
    }
    return <RequestLogEntry>[
      for (final entry in source)
        if (effectiveFilter.matches(entry, now: reference)) entry,
    ];
  }

  @override
  Widget build(BuildContext context) {
    // Single scrolling body (no tabs): the folded Type filter picks the
    // activity, so one CustomScrollView carries the compact filter row +
    // the rows. OperatorWebScreenFrame keeps the header pinned while the
    // body scrolls.
    return Material(
      key: const Key('admin_debug_console_screen'),
      color: AppColors.backgroundDeep,
      type: MaterialType.canvas,
      child: OperatorWebScreenFrame(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Header(
              lastRefreshed: _lastRefreshed,
              onRunRefresh: _refresh,
              loading: _initialLoading || _refreshing,
              editingEnabled: widget.editingEnabled,
              liveTailOn: _liveTailOn,
              onToggleLiveTail: _toggleLiveTail,
              onBackToBusinessAccounts: widget.onBackToBusinessAccounts,
              now: _clockNow,
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _RequestLogTab(
                entries: _visibleEntries,
                expanded: _expanded,
                filter: _filter,
                typeView: _typeView,
                hierarchyScope: widget.hierarchyScope,
                scopeLocationIds: _scopeLocationIds,
                scopeResolving: _scopeResolving,
                scopeResolutionError: _scopeResolutionError,
                searchController: _searchController,
                optInLookup: _optInOnFor,
                editingEnabled: widget.editingEnabled,
                initialLoading: _initialLoading,
                refreshing: _refreshing,
                loadError: _loadError,
                now: _clockNow(),
                onSearchChanged: _onSearchChanged,
                onTypeViewChanged: _onTypeViewChanged,
                onTimeWindowChanged: (next) =>
                    _onFilterChanged(_filter.copyWith(timeWindow: next)),
                onResultChanged: _onResultChanged,
                onToggleExpanded: (id) => setState(() {
                  if (_expanded.contains(id)) {
                    _expanded.remove(id);
                  } else {
                    _expanded.add(id);
                  }
                }),
                onRunRefresh: _refresh,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.lastRefreshed,
    required this.onRunRefresh,
    required this.loading,
    required this.editingEnabled,
    required this.liveTailOn,
    required this.onToggleLiveTail,
    required this.onBackToBusinessAccounts,
    required this.now,
  });

  final DateTime? lastRefreshed;
  final Future<void> Function() onRunRefresh;
  final bool loading;
  final bool editingEnabled;
  final bool liveTailOn;
  final ValueChanged<bool> onToggleLiveTail;
  final VoidCallback? onBackToBusinessAccounts;
  final DateTime Function() now;

  @override
  Widget build(BuildContext context) {
    return OperatorWebScreenHeader(
      icon: Icons.bug_report_outlined,
      title: 'Support logs',
      subtitle:
          'Recent activity for the business you picked. Open a row for the '
          'details support needs.',
      subtitleKey: const Key('admin_debug_console_subtitle'),
      collapseBelowWidth: 640,
      actions: <Widget>[
        if (onBackToBusinessAccounts != null)
          AdminBusinessAccountsBackButton(onPressed: onBackToBusinessAccounts),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!editingEnabled)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Container(
                    key: const Key('admin_debug_console_view_only_indicator'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.warning.withValues(alpha: 0.12),
                      border: Border.all(color: AppColors.warning, width: 1),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'Support view only',
                      style: AppTextStyles.body12(
                        color: AppColors.warning,
                      ).copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                alignment: WrapAlignment.end,
                children: <Widget>[
                  _LiveChip(
                    liveTailOn: liveTailOn,
                    onToggleLiveTail: onToggleLiveTail,
                  ),
                  OutlinedButton.icon(
                    key: const Key('admin_debug_console_refresh_button'),
                    onPressed: loading ? null : () => onRunRefresh(),
                    icon: loading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh, size: 16),
                    label: Text(loading ? 'Loading...' : 'Refresh'),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                lastRefreshed == null
                    ? 'Not checked yet'
                    : 'Updated ${_relativeUpdated(lastRefreshed!, now())}',
                key: const Key('admin_debug_console_last_refreshed'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.body12(color: AppColors.textMuted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Small "Live" chip + toggle replacing the old full-width live bar. The
/// 5s opt-in polling and no-stacked-calls discipline are unchanged; this
/// is a display swap only (the toggle still drives `_toggleLiveTail`).
class _LiveChip extends StatelessWidget {
  const _LiveChip({required this.liveTailOn, required this.onToggleLiveTail});

  final bool liveTailOn;
  final ValueChanged<bool> onToggleLiveTail;

  @override
  Widget build(BuildContext context) {
    final accent = liveTailOn ? AppColors.positive : AppColors.textMuted;
    return Tooltip(
      message: liveTailOn
          ? 'Live refresh on. Checking for new requests every 5 seconds. Tap to turn off.'
          : 'Turn on live refresh to check for new requests every 5 seconds.',
      child: InkWell(
        key: const Key('admin_debug_console_live_tail_toggle'),
        borderRadius: BorderRadius.circular(20),
        onTap: () => onToggleLiveTail(!liveTailOn),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            color: liveTailOn
                ? AppColors.positive.withValues(alpha: 0.10)
                : AppColors.backgroundSurface,
            border: Border.all(color: accent, width: 1),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                liveTailOn
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 13,
                color: accent,
              ),
              const SizedBox(width: 6),
              Text(
                'Live',
                style: AppTextStyles.body12(
                  color: accent,
                ).copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Human `Updated <relative>` wording for the header. Plain English, no
/// monospace timestamp.
String _relativeUpdated(DateTime updatedAt, DateTime now) {
  final elapsed = now.toUtc().difference(updatedAt.toUtc());
  if (elapsed.isNegative || elapsed.inSeconds < 45) return 'just now';
  if (elapsed.inMinutes < 60) {
    final m = elapsed.inMinutes;
    return '$m minute${m == 1 ? '' : 's'} ago';
  }
  if (elapsed.inHours < 24) {
    final h = elapsed.inHours;
    return '$h hour${h == 1 ? '' : 's'} ago';
  }
  final d = elapsed.inDays;
  return '$d day${d == 1 ? '' : 's'} ago';
}

class _RequestLogTab extends StatelessWidget {
  const _RequestLogTab({
    required this.entries,
    required this.expanded,
    required this.filter,
    required this.typeView,
    required this.hierarchyScope,
    required this.scopeLocationIds,
    required this.scopeResolving,
    required this.scopeResolutionError,
    required this.searchController,
    required this.optInLookup,
    required this.editingEnabled,
    required this.initialLoading,
    required this.refreshing,
    required this.loadError,
    required this.now,
    required this.onSearchChanged,
    required this.onTypeViewChanged,
    required this.onTimeWindowChanged,
    required this.onResultChanged,
    required this.onToggleExpanded,
    required this.onRunRefresh,
  });

  final List<RequestLogEntry> entries;
  final Set<String> expanded;
  final RequestLogFilter filter;
  final _RequestTypeView typeView;
  final AdminHierarchyScopeIntent? hierarchyScope;
  final List<String>? scopeLocationIds;
  final bool scopeResolving;
  final String? scopeResolutionError;
  final TextEditingController searchController;
  final bool Function(String operatorId) optInLookup;
  final bool editingEnabled;
  final bool initialLoading;
  final bool refreshing;
  final String? loadError;
  final DateTime now;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<_RequestTypeView> onTypeViewChanged;
  final ValueChanged<RequestLogTimeWindow?> onTimeWindowChanged;
  final ValueChanged<RequestLogStatus?> onResultChanged;
  final ValueChanged<String> onToggleExpanded;
  final Future<void> Function() onRunRefresh;

  @override
  Widget build(BuildContext context) {
    // Single scroll axis so the body never overflows when the shell
    // embeds the screen at narrow viewports (the admin shell's detail
    // pane gives the screen ~540x158 on the default 800x600 test
    // viewport, which is too tight for a Column-based layout).
    final showLoading = initialLoading;
    final showEmpty = !initialLoading && entries.isEmpty && loadError == null;
    return CustomScrollView(
      key: const Key('admin_debug_console_request_log_body'),
      slivers: <Widget>[
        if (hierarchyScope != null)
          SliverToBoxAdapter(
            child: _ScopeBanner(
              scope: hierarchyScope!,
              locationIds: scopeLocationIds,
              resolving: scopeResolving,
              error: scopeResolutionError,
            ),
          ),
        if (hierarchyScope != null)
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
        SliverToBoxAdapter(
          child: _FilterRow(
            filter: filter,
            typeView: typeView,
            searchController: searchController,
            onSearchChanged: onSearchChanged,
            onTypeViewChanged: onTypeViewChanged,
            onTimeWindowChanged: onTimeWindowChanged,
            onResultChanged: onResultChanged,
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
        if (loadError != null)
          SliverToBoxAdapter(
            child: _ErrorBanner(
              key: const Key('admin_debug_console_load_error'),
              message: loadError!,
            ),
          ),
        if (showLoading)
          const SliverToBoxAdapter(
            child: Padding(
              key: Key('admin_debug_console_loading'),
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Center(
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.sunsetDark,
                  ),
                ),
              ),
            ),
          )
        else if (showEmpty)
          SliverToBoxAdapter(
            child: _EmptyState(
              filterIsEmpty: filter.isEmpty,
              onRunRefresh: onRunRefresh,
              refreshing: refreshing,
            ),
          )
        else
          SliverList.builder(
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              return _RequestRow(
                key: Key('admin_debug_console_row_${entry.requestId}'),
                entry: entry,
                expanded: expanded.contains(entry.requestId),
                optInOn: optInLookup(entry.operatorId),
                editingEnabled: editingEnabled,
                now: now,
                onToggle: () => onToggleExpanded(entry.requestId),
              );
            },
          ),
      ],
    );
  }
}

class _ScopeBanner extends StatelessWidget {
  const _ScopeBanner({
    required this.scope,
    required this.locationIds,
    required this.resolving,
    required this.error,
  });

  final AdminHierarchyScopeIntent scope;
  final List<String>? locationIds;
  final bool resolving;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final isWarning = error != null;
    final accent = isWarning ? AppColors.warning : AppColors.peacock;
    return Container(
      key: const Key('admin_debug_console_scope_banner'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: accent.withValues(alpha: 0.75), width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            scope.isOrgUnitScope
                ? scopeIcon(kind: ScopeEntityKind.orgUnit)
                : scope.isLocationScope
                ? scopeIcon(kind: ScopeEntityKind.location)
                : scopeIcon(kind: ScopeEntityKind.business),
            size: 16,
            color: accent,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    Text(
                      '${scope.scopeType.label}: ${scope.displayLabel}',
                      key: const Key('admin_debug_console_scope_label'),
                      style: AppTextStyles.body13(
                        color: AppColors.textPrimary,
                      ).copyWith(fontWeight: FontWeight.w700),
                    ),
                    _ScopePill(label: scope.inheritanceLabel),
                  ],
                ),
                if (error != null) ...[
                  const SizedBox(height: 5),
                  Text(
                    error!,
                    key: const Key('admin_debug_console_scope_body'),
                    style: AppTextStyles.body12(color: AppColors.textSecondary),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

}

class _ScopePill extends StatelessWidget {
  const _ScopePill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_debug_console_scope_state'),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.peacock.withValues(alpha: 0.10),
        border: Border.all(
          color: AppColors.peacock.withValues(alpha: 0.35),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: AppTextStyles.chipLabel(color: AppColors.peacockDark),
      ),
    );
  }
}

/// The single compact filter row: Search + Type + When + Result. Folds
/// the old Filters panel, the three tabs, and the "Request type key" box
/// into one row. Business/Location come from the left scope picker
/// (mirrored by the scope banner above), so no standalone ID chips here.
class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.filter,
    required this.typeView,
    required this.searchController,
    required this.onSearchChanged,
    required this.onTypeViewChanged,
    required this.onTimeWindowChanged,
    required this.onResultChanged,
  });

  final RequestLogFilter filter;
  final _RequestTypeView typeView;
  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<_RequestTypeView> onTypeViewChanged;
  final ValueChanged<RequestLogTimeWindow?> onTimeWindowChanged;
  final ValueChanged<RequestLogStatus?> onResultChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      key: const Key('admin_debug_console_filter_bar'),
      spacing: 9,
      runSpacing: 9,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 200, maxWidth: 320),
          child: TextField(
            key: const Key('admin_debug_console_search_field'),
            controller: searchController,
            onChanged: onSearchChanged,
            style: AppTextStyles.body13(color: AppColors.textPrimary),
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 18),
              hintText: 'Search by reference',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        _PickerControl<_RequestTypeView>(
          keyName: const Key('admin_debug_console_filter_type'),
          label: 'Type',
          valueLabel: typeView.label,
          active: typeView != _RequestTypeView.allActivity,
          onSelected: onTypeViewChanged,
          items: <PopupMenuEntry<_RequestTypeView>>[
            for (final view in _RequestTypeView.values)
              PopupMenuItem<_RequestTypeView>(
                value: view,
                child: Text(view.label),
              ),
          ],
        ),
        _PickerControl<RequestLogTimeWindow?>(
          keyName: const Key('admin_debug_console_filter_window'),
          label: 'When',
          valueLabel: filter.timeWindow == null
              ? 'Any time'
              : requestLogTimeWindowLabel(filter.timeWindow!),
          active: filter.timeWindow != null,
          onSelected: onTimeWindowChanged,
          items: <PopupMenuEntry<RequestLogTimeWindow?>>[
            const PopupMenuItem<RequestLogTimeWindow?>(
              value: null,
              child: Text('Any time'),
            ),
            for (final w in RequestLogTimeWindow.values)
              PopupMenuItem<RequestLogTimeWindow?>(
                value: w,
                child: Text(requestLogTimeWindowLabel(w)),
              ),
          ],
        ),
        _PickerControl<RequestLogStatus?>(
          keyName: const Key('admin_debug_console_filter_status'),
          label: 'Result',
          // Result reads the real status axis but only offers Any /
          // Worked / Not recorded. Production never emits error/timeout
          // here today (failures read as "unknown" -> Not recorded), so
          // offering those would be a filter that always returns nothing.
          valueLabel: _resultFilterLabel(filter.status),
          active: filter.status != null,
          onSelected: onResultChanged,
          items: const <PopupMenuEntry<RequestLogStatus?>>[
            PopupMenuItem<RequestLogStatus?>(value: null, child: Text('Any')),
            PopupMenuItem<RequestLogStatus?>(
              value: RequestLogStatus.success,
              child: Text('Worked'),
            ),
            PopupMenuItem<RequestLogStatus?>(
              value: RequestLogStatus.unknown,
              child: Text('Not recorded'),
            ),
          ],
        ),
      ],
    );
  }

  static String _resultFilterLabel(RequestLogStatus? status) {
    if (status == null) return 'Any';
    return adminRequestResultWording(status);
  }
}

/// A compact `<label> <value> v` dropdown trigger used by the Type /
/// When / Result filters. Plain body font, a `PopupMenuButton` under
/// the hood so existing `find.byKey(...).tap` then `find.text(option)`
/// test flows keep working.
class _PickerControl<T> extends StatelessWidget {
  const _PickerControl({
    required this.keyName,
    required this.label,
    required this.valueLabel,
    required this.active,
    required this.items,
    required this.onSelected,
  });

  final Key keyName;
  final String label;
  final String valueLabel;
  final bool active;
  final List<PopupMenuEntry<T>> items;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final accent = active ? AppColors.sunset : AppColors.borderSubtle;
    return PopupMenuButton<T>(
      key: keyName,
      tooltip: 'Filter by ${label.toLowerCase()}',
      onSelected: onSelected,
      itemBuilder: (_) => items,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: active
              ? AppColors.sunset.withValues(alpha: 0.10)
              : AppColors.backgroundSurface,
          border: Border.all(color: accent, width: 1),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '$label  ',
              style: AppTextStyles.body12(color: AppColors.textMuted),
            ),
            Text(
              valueLabel,
              style: AppTextStyles.body13(
                color: active ? AppColors.sunsetDark : AppColors.textPrimary,
              ).copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 6),
            Icon(
              Icons.keyboard_arrow_down,
              size: 16,
              color: AppColors.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}

/// One activity row. Collapsed = status dot + plain title + a secondary
/// `<result> · <relative time>` line (body font, no monospace, no raw
/// summary, no "123 ms"). Expanded = a plain "What happened" zone and a
/// collapsible "Technical reference (for engineering)" zone that keeps
/// the raw identifiers (monospace + copy) tucked away.
class _RequestRow extends StatefulWidget {
  const _RequestRow({
    super.key,
    required this.entry,
    required this.expanded,
    required this.optInOn,
    required this.editingEnabled,
    required this.now,
    required this.onToggle,
  });

  final RequestLogEntry entry;
  final bool expanded;
  final bool optInOn;
  final bool editingEnabled;
  final DateTime now;
  final VoidCallback onToggle;

  @override
  State<_RequestRow> createState() => _RequestRowState();
}

class _RequestRowState extends State<_RequestRow> {
  bool _techOpen = false;

  RequestLogEntry get entry => widget.entry;

  @override
  Widget build(BuildContext context) {
    final canRevealFullContent =
        widget.editingEnabled &&
        widget.optInOn &&
        entry.fullContentPayload != null;
    final statusColor = _statusColor(entry.status);
    final requestType = adminRequestUseCaseLabel(entry.usageClass);
    final result = adminRequestResultWording(entry.status);

    return Container(
      margin: const EdgeInsets.only(bottom: 9),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          InkWell(
            onTap: widget.onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 11,
                    height: 11,
                    margin: const EdgeInsets.only(top: 2),
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          requestType,
                          style: AppTextStyles.body14(
                            color: AppColors.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text.rich(
                          TextSpan(
                            children: <InlineSpan>[
                              TextSpan(
                                text: result,
                                style: AppTextStyles.body12(color: statusColor)
                                    .copyWith(fontWeight: FontWeight.w600),
                              ),
                              TextSpan(
                                text:
                                    '  ·  ${_relativeUpdated(entry.startedAt, widget.now)}',
                                style: AppTextStyles.body12(
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    widget.expanded
                        ? Icons.expand_less
                        : Icons.chevron_right,
                    size: 20,
                    color: AppColors.textMuted,
                  ),
                ],
              ),
            ),
          ),
          if (widget.expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Divider(height: 1, color: AppColors.borderSubtle),
                  const SizedBox(height: 12),
                  _ZoneHeading(label: 'What happened'),
                  const SizedBox(height: 6),
                  _FactRow(label: 'What', value: requestType),
                  _FactRow(
                    label: 'Result',
                    value: result,
                    valueColor: statusColor,
                    emphasizeValue: true,
                  ),
                  _FactRow(
                    label: 'When',
                    value: adminHumanDateTime(entry.startedAt),
                  ),
                  _FactRow(label: 'Who', value: _whoLabel(entry)),
                  _FactRow(label: 'Took', value: _tookLabel(entry)),
                  _TechnicalReference(
                    entry: entry,
                    open: _techOpen,
                    onToggle: () => setState(() => _techOpen = !_techOpen),
                  ),
                  const SizedBox(height: 12),
                  if (canRevealFullContent)
                    _FullContentBlock(
                      key: Key(
                        'admin_debug_console_full_content_${entry.requestId}',
                      ),
                      payload: entry.fullContentPayload!,
                    )
                  else
                    _FullContentLockedBlock(
                      editingEnabled: widget.editingEnabled,
                      optInOn: widget.optInOn,
                      payloadPresent: entry.fullContentPayload != null,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// "Who" wording. Telemetry carries only the actor's UUID (PII is
  /// resolved at render, never stored). Full name + role resolution via
  /// the members lookup is a P3 follow-up (it needs the scoped members
  /// gateway + an async per-operator lookup, beyond this front-end
  /// slice); until then we render a short reference, or the honest "—"
  /// sentinel when no actor is recorded (system / scheduled turn).
  static String _whoLabel(RequestLogEntry entry) {
    final uid = entry.actorUserId?.trim();
    if (uid == null || uid.isEmpty) return '—';
    final shortId = uid.length > 8 ? uid.substring(0, 8) : uid;
    return 'User $shortId';
  }

  /// "Took" wording from the real measured latency (P1b). Rendered in
  /// seconds. Honest "—" when latency was not recorded (no stats row:
  /// failed / pre-P1b / non-LLM support request) — NEVER a phantom 0.
  static String _tookLabel(RequestLogEntry entry) {
    // latency_ms is the coalesced real-or-derived value. The derived
    // fallback is `updated_at - created_at` which is 0 for rows never
    // updated; a 0 here is not a real measurement, so sentinel it.
    if (entry.latencyMs <= 0) return '—';
    final seconds = entry.latencyMs / 1000;
    if (seconds < 0.1) return 'under 0.1 seconds';
    return '${seconds.toStringAsFixed(1)} seconds';
  }
}

/// Uppercase zone heading inside the expanded row ("What happened",
/// "Technical reference"). Body font, muted, tracked.
class _ZoneHeading extends StatelessWidget {
  const _ZoneHeading({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: AppTextStyles.uiLabel(color: AppColors.textMuted),
    );
  }
}

/// One plain `Label    value` fact in the "What happened" zone. Body
/// font (never monospace); "—" values render in the muted color so an
/// honest empty reads as empty, not as data.
class _FactRow extends StatelessWidget {
  const _FactRow({
    required this.label,
    required this.value,
    this.valueColor,
    this.emphasizeValue = false,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final bool emphasizeValue;

  @override
  Widget build(BuildContext context) {
    final isEmpty = value == '—';
    final color = isEmpty
        ? AppColors.textMuted
        : (valueColor ?? AppColors.textPrimary);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: AppTextStyles.body12(color: AppColors.textMuted),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              style: AppTextStyles.body13(color: color).copyWith(
                fontWeight: (emphasizeValue && !isEmpty)
                    ? FontWeight.w700
                    : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The collapsible "Technical reference (for engineering)" zone. Holds
/// the raw identifiers support occasionally needs: request/retry
/// references, request type + id, operator/location ids, model, tokens,
/// cost. Monospace is acceptable HERE (copy accuracy); each value shows
/// "—" when not recorded (Metric Honesty Doctrine — never a phantom 0).
class _TechnicalReference extends StatelessWidget {
  const _TechnicalReference({
    required this.entry,
    required this.open,
    required this.onToggle,
  });

  final RequestLogEntry entry;
  final bool open;
  final VoidCallback onToggle;

  static const String _dash = '—';

  @override
  Widget build(BuildContext context) {
    final tokens = _tokensLabel(entry);
    return Container(
      key: Key('admin_debug_console_technical_${entry.requestId}'),
      margin: const EdgeInsets.only(top: 12),
      decoration: BoxDecoration(
        color: AppColors.backgroundDeep,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          InkWell(
            key: Key(
              'admin_debug_console_technical_toggle_${entry.requestId}',
            ),
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.build_outlined,
                    size: 16,
                    color: AppColors.textMuted,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      'Technical reference (for engineering)',
                      style: AppTextStyles.body12(
                        color: AppColors.textSecondary,
                      ).copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Icon(
                    open ? Icons.expand_less : Icons.chevron_right,
                    size: 18,
                    color: AppColors.textMuted,
                  ),
                ],
              ),
            ),
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.fromLTRB(13, 0, 10, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _TechRow(
                    label: 'Request reference',
                    value: entry.requestId.isEmpty ? _dash : entry.requestId,
                    copyable: entry.requestId.isNotEmpty,
                  ),
                  _TechRow(
                    label: 'Retry reference',
                    value: entry.idempotencyKey.isEmpty
                        ? _dash
                        : entry.idempotencyKey,
                    copyable: entry.idempotencyKey.isNotEmpty,
                  ),
                  _TechRow(
                    label: 'Request type',
                    value: adminRequestUseCaseLabelWithId(entry.usageClass),
                  ),
                  _TechRow(
                    label: 'Operator id',
                    value: entry.operatorId.isEmpty ? _dash : entry.operatorId,
                    copyable: entry.operatorId.isNotEmpty,
                  ),
                  _TechRow(
                    label: 'Location id',
                    value: entry.locationId ?? _dash,
                    copyable: entry.locationId != null,
                  ),
                  _TechRow(label: 'Model', value: entry.modelId ?? _dash),
                  _TechRow(label: 'Tokens', value: tokens),
                  _TechRow(
                    label: 'Cost',
                    value: entry.costUsd == null
                        ? _dash
                        : '\$${entry.costUsd!.toStringAsFixed(4)}',
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _tokensLabel(RequestLogEntry entry) {
    final inTok = entry.promptTokenCount;
    final outTok = entry.completionTokenCount;
    if (inTok == null && outTok == null) return _dash;
    final inStr = inTok?.toString() ?? _dash;
    final outStr = outTok?.toString() ?? _dash;
    return '$inStr in / $outStr out';
  }
}

/// One `label : value` reference inside the Technical reference block.
/// Monospace value (copy accuracy) with an optional Copy affordance.
class _TechRow extends StatelessWidget {
  const _TechRow({
    required this.label,
    required this.value,
    this.copyable = false,
  });

  final String label;
  final String value;
  final bool copyable;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 118,
            child: Text(
              label,
              style: AppTextStyles.body12(color: AppColors.textMuted),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              value,
              style: AppTextStyles.mono11(color: AppColors.textPrimary),
            ),
          ),
          if (copyable) ...<Widget>[
            const SizedBox(width: 8),
            _CopyButton(value: value),
          ],
        ],
      ),
    );
  }
}

/// Small "Copy" affordance for a Technical-reference value. Writes to
/// the clipboard and confirms with a brief snackbar.
class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: () async {
        await Clipboard.setData(ClipboardData(text: value));
        if (!context.mounted) return;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text('Copied to clipboard'),
            duration: Duration(seconds: 2),
          ),
        );
      },
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: AppColors.sunsetDark,
      ),
      icon: const Icon(Icons.copy_outlined, size: 13),
      label: Text(
        'Copy',
        style: AppTextStyles.body12(color: AppColors.sunsetDark),
      ),
    );
  }
}

/// The unlocked full-message-text reveal. Gating is unchanged
/// (super_admin + the operator's opt-in flag); only the wording and
/// layout are reworded plainly. The payload itself is the raw saved
/// prompt/response, so it stays in the monospace technical treatment.
class _FullContentBlock extends StatelessWidget {
  const _FullContentBlock({super.key, required this.payload});

  final Map<String, Object?> payload;

  @override
  Widget build(BuildContext context) {
    final entries = payload.entries.toList();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.sunset, width: 1),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.lock_open, size: 15, color: AppColors.sunsetDark),
              const SizedBox(width: 7),
              Text(
                'Full message text',
                style: AppTextStyles.body13(
                  color: AppColors.sunsetDark,
                ).copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (entries.isEmpty)
            Text(
              'No saved message text for this request.',
              style: AppTextStyles.body12(color: AppColors.textMuted),
            )
          else
            for (final e in entries) ...<Widget>[
              Text(
                _humanizeKey(e.key),
                style: AppTextStyles.body12(
                  color: AppColors.textMuted,
                ).copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 2),
              SelectableText(
                e.value?.toString() ?? '—',
                style: AppTextStyles.mono11(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 8),
            ],
        ],
      ),
    );
  }

  static String _humanizeKey(String key) {
    final words = key
        .trim()
        .replaceAll(RegExp(r'[_\-]+'), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty);
    if (words.isEmpty) return key;
    final joined = words.join(' ');
    return joined.substring(0, 1).toUpperCase() + joined.substring(1);
  }
}

/// The locked full-message-text state. Same gating as before, reworded
/// to plain English. Body font, never monospace.
class _FullContentLockedBlock extends StatelessWidget {
  const _FullContentLockedBlock({
    required this.editingEnabled,
    required this.optInOn,
    required this.payloadPresent,
  });

  final bool editingEnabled;
  final bool optInOn;
  final bool payloadPresent;

  @override
  Widget build(BuildContext context) {
    final reason = !editingEnabled
        ? 'Full message text is hidden. Your support role cannot open it; ecosystem admin access is needed.'
        : !optInOn
        ? "Full message text is hidden. This business hasn't turned on full-content sharing."
        : 'Full message text was not saved for this request.';
    return Container(
      key: const Key('admin_debug_console_full_content_locked'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.backgroundDeep,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(Icons.lock_outline, size: 15, color: AppColors.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              reason,
              style: AppTextStyles.body13(color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.filterIsEmpty,
    required this.onRunRefresh,
    required this.refreshing,
  });

  final bool filterIsEmpty;
  final Future<void> Function() onRunRefresh;
  final bool refreshing;

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const Key('admin_debug_console_empty_state'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.backgroundSurface,
            border: Border.all(color: AppColors.borderSubtle, width: 1),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                filterIsEmpty
                    ? 'No requests loaded yet'
                    : 'No requests match the current filter',
                style: AppTextStyles.display20(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 8),
              Text(
                filterIsEmpty
                    ? 'Press Refresh to load the latest requests.'
                    : 'Adjust or clear the filters above, then refresh.',
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                key: const Key('admin_debug_console_empty_refresh_button'),
                onPressed: refreshing ? null : () => onRunRefresh(),
                style: AdminButtonStyles.primary,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Refresh'),
              ),
            ],
          ),
        ),
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

Color _statusColor(RequestLogStatus status) {
  switch (status) {
    case RequestLogStatus.success:
      return AppColors.positive;
    case RequestLogStatus.error:
      return AppColors.negative;
    case RequestLogStatus.timeout:
      return AppColors.warning;
    case RequestLogStatus.unknown:
      return AppColors.neutral;
  }
}

