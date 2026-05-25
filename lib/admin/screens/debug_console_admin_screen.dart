// Phase 11A.5 - Debug console admin surface (per-operator request log).
//
// Read-only operator-facing console for the proxy `proxy_requests`
// projection. Three tabs reflect the support workflow:
//
//   * Request log - live filterable / searchable view of recent
//                   proxy requests. Meta-only by default; expand-row
//                   reveals the full content payload only when the
//                   operator's `feature_flags` opt-in is on AND the
//                   actor holds `super_admin`.
//   * Relationship Help - typed relationship-review / knowledge-link
//                   support requests, filterable by exact use-case ID.
//   * Account Help - typed account / auth / MFA / session support
//                   requests, filterable by exact use-case ID.
//
// Live-tail is OFF by default. When toggled on, the screen polls
// `tailRecent` every [kDebugConsoleTailPollInterval] seconds and
// merges new rows into the table; the toggle stops polling when off
// or when the screen disposes.
//
// Permission gating:
//   * `super_admin` lands with `editingEnabled = true`. Full-content
//     reveal is gated by the operator's `feature_flags` opt-in row.
//   * `ff_support` lands with `editingEnabled = false`. The diff
//     renders read-only meta - full content stays hidden even when
//     the opt-in is on. The graphify walkthrough establishes this
//     as the cross-surface convention; the proxy `/health` contract
//     bans raw payloads from public health, and the same posture
//     extends here so a less-privileged role cannot reveal
//     operator-visible content.
//
// The screen is performance-disciplined per
// `docs/contracts/slice_runtime_acceptance_contract.md`:
//   * cheap initial render - a manual fetch button surfaces the first
//     request-log page rather than auto-polling on mount;
//   * the live-tail toggle is opt-in and does not stack in-flight
//     requests;
//   * search and filter chips re-filter client-side first so a
//     narrowing change does not force a fresh round-trip.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:forge_and_flow/widgets/console/console_screen_body.dart';
import 'package:forge_and_flow/widgets/console/console_screen_header.dart';
import 'package:forge_and_flow/widgets/console/console_surface.dart';

import '../../theme/app_theme.dart';
import '../../theme/scope_icons.dart';

import '../admin_button_styles.dart';
import '../admin_console_style.dart';
import '../admin_human_labels.dart';
import '../admin_route_handoff.dart';
import '../models/debug_console_admin_models.dart';
import '../services/debug_console_admin_gateway.dart';
import '../services/roles_hierarchy_sessions_admin_gateway.dart';
import '../widgets/admin_business_accounts_back_button.dart';

const String _kRequestLogTab = 'request_log';
const String _kRelationshipHelpTab = 'relationship_help';
const String _kAccountHelpTab = 'account_help';
const int _kMaxOrgUnitSupportLogLocationIds = 100;

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

class _DebugConsoleAdminScreenState extends State<DebugConsoleAdminScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  bool _initialLoading = false;
  bool _refreshing = false;
  String? _loadError;
  DateTime? _lastRefreshed;

  List<RequestLogEntry> _entries = const <RequestLogEntry>[];
  List<RequestLogEntry> _relationshipHelpEntries = const <RequestLogEntry>[];
  List<RequestLogEntry> _accountHelpEntries = const <RequestLogEntry>[];
  List<FullContentOptIn> _optIns = const <FullContentOptIn>[];

  late RequestLogFilter _filter;
  RequestLogFilter _relationshipHelpFilter = const RequestLogFilter();
  RequestLogFilter _accountHelpFilter = const RequestLogFilter();
  String? _relationshipHelpUseCase;
  String? _accountHelpUseCase;
  RequestLogFilter? _serverFilter;
  bool _refreshQueued = false;
  List<String>? _scopeLocationIds;
  bool _scopeResolving = false;
  String? _scopeResolutionError;
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _relationshipHelpSearchController =
      TextEditingController();
  final TextEditingController _accountHelpSearchController =
      TextEditingController();
  final Set<String> _expanded = <String>{};

  bool _liveTailOn = false;
  Timer? _tailTimer;
  bool _tailing = false;

  DateTime _clockNow() => (widget.now ?? () => DateTime.now().toUtc())();

  @override
  void initState() {
    super.initState();
    _filter = widget.initialFilter;
    _tabs = TabController(length: 3, vsync: this);
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
    _tabs.dispose();
    _tailTimer?.cancel();
    _searchController.dispose();
    _relationshipHelpSearchController.dispose();
    _accountHelpSearchController.dispose();
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
    return _scopeFilter(
      surface == SupportHelpSurface.relationship
          ? _relationshipHelpFilter
          : _accountHelpFilter,
    );
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
          supportUseCaseId: _relationshipHelpUseCase,
        ),
        widget.gateway.listSupportHelpRequests(
          SupportHelpSurface.account,
          accountFilter,
          supportUseCaseId: _accountHelpUseCase,
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

  void _onSupportFilterChanged(
    SupportHelpSurface surface,
    RequestLogFilter next,
  ) {
    setState(() {
      switch (surface) {
        case SupportHelpSurface.relationship:
          _relationshipHelpFilter = next;
          break;
        case SupportHelpSurface.account:
          _accountHelpFilter = next;
          break;
      }
    });
    unawaited(_refresh());
  }

  void _onSupportSearchChanged(SupportHelpSurface surface, String value) {
    final next = value.trim();
    final filter = surface == SupportHelpSurface.relationship
        ? _relationshipHelpFilter
        : _accountHelpFilter;
    _onSupportFilterChanged(
      surface,
      filter.copyWith(searchText: next.isEmpty ? null : next),
    );
  }

  void _onSupportUseCaseChanged(SupportHelpSurface surface, String? useCaseId) {
    setState(() {
      switch (surface) {
        case SupportHelpSurface.relationship:
          _relationshipHelpUseCase = useCaseId;
          break;
        case SupportHelpSurface.account:
          _accountHelpUseCase = useCaseId;
          break;
      }
    });
    unawaited(_refresh());
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

  List<RequestLogEntry> get _visibleEntries {
    final reference = _clockNow();
    final effectiveFilter = _effectiveFilter;
    return <RequestLogEntry>[
      for (final entry in _entries)
        if (effectiveFilter.matches(entry, now: reference)) entry,
    ];
  }

  @override
  Widget build(BuildContext context) {
    // Fixed-height tabbed view (TabBar + Expanded TabBarView, the
    // request-log tab being its own CustomScrollView): uses
    // OperatorWebScreenFrame, not OperatorWebScreenBody. The sub-view
    // (_SupportHelpTab) is single-axis and uses OperatorWebScreenBody.
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
              onBackToBusinessAccounts: widget.onBackToBusinessAccounts,
            ),
            const SizedBox(height: 12),
            TabBar(
              key: const Key('admin_debug_console_tabs'),
              controller: _tabs,
              isScrollable: true,
              labelColor: AppColors.textPrimary,
              unselectedLabelColor: AppColors.textSecondary,
              indicatorColor: AppColors.sunset,
              tabs: const <Widget>[
                Tab(
                  key: Key('admin_debug_console_tab_$_kRequestLogTab'),
                  text: 'All requests',
                ),
                Tab(
                  key: Key('admin_debug_console_tab_$_kRelationshipHelpTab'),
                  text: 'Relationship Help',
                ),
                Tab(
                  key: Key('admin_debug_console_tab_$_kAccountHelpTab'),
                  text: 'Account Help',
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: <Widget>[
                  _RequestLogTab(
                    entries: _visibleEntries,
                    expanded: _expanded,
                    filter: _filter,
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
                    liveTailOn: _liveTailOn,
                    onFilterChanged: _onFilterChanged,
                    onSearchChanged: _onSearchChanged,
                    onToggleExpanded: (id) => setState(() {
                      if (_expanded.contains(id)) {
                        _expanded.remove(id);
                      } else {
                        _expanded.add(id);
                      }
                    }),
                    onToggleLiveTail: _toggleLiveTail,
                    onRunRefresh: _refresh,
                  ),
                  _SupportHelpTab(
                    key: const Key('admin_debug_console_relationship_help_tab'),
                    surface: SupportHelpSurface.relationship,
                    title: 'Relationship help',
                    entries: _relationshipHelpEntries,
                    filter: _relationshipHelpFilter,
                    selectedUseCaseId: _relationshipHelpUseCase,
                    searchController: _relationshipHelpSearchController,
                    loading: _initialLoading || _refreshing,
                    loadError: _loadError,
                    onFilterChanged: (next) => _onSupportFilterChanged(
                      SupportHelpSurface.relationship,
                      next,
                    ),
                    onSearchChanged: (value) => _onSupportSearchChanged(
                      SupportHelpSurface.relationship,
                      value,
                    ),
                    onUseCaseChanged: (value) => _onSupportUseCaseChanged(
                      SupportHelpSurface.relationship,
                      value,
                    ),
                    onRunRefresh: _refresh,
                    emptyBody:
                        'No relationship review requests match the current filters.',
                    body:
                        'Typed view of relationship review, knowledge-link, and corpus relationship support requests for the selected scope.',
                  ),
                  _SupportHelpTab(
                    key: const Key('admin_debug_console_account_help_tab'),
                    surface: SupportHelpSurface.account,
                    title: 'Account help',
                    entries: _accountHelpEntries,
                    filter: _accountHelpFilter,
                    selectedUseCaseId: _accountHelpUseCase,
                    searchController: _accountHelpSearchController,
                    loading: _initialLoading || _refreshing,
                    loadError: _loadError,
                    onFilterChanged: (next) => _onSupportFilterChanged(
                      SupportHelpSurface.account,
                      next,
                    ),
                    onSearchChanged: (value) => _onSupportSearchChanged(
                      SupportHelpSurface.account,
                      value,
                    ),
                    onUseCaseChanged: (value) => _onSupportUseCaseChanged(
                      SupportHelpSurface.account,
                      value,
                    ),
                    onRunRefresh: _refresh,
                    emptyBody:
                        'No account support requests match the current filters.',
                    body:
                        'Typed view of account, sign-in, MFA, session, notification, and removal support requests for the selected scope.',
                  ),
                ],
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
    required this.onBackToBusinessAccounts,
  });

  final DateTime? lastRefreshed;
  final Future<void> Function() onRunRefresh;
  final bool loading;
  final bool editingEnabled;
  final VoidCallback? onBackToBusinessAccounts;

  @override
  Widget build(BuildContext context) {
    return OperatorWebScreenHeader(
      icon: Icons.bug_report_outlined,
      title: 'Support logs',
      subtitle:
          'Translate recent backend requests into support-safe details. Use precise references only when support needs a targeted lookup.',
      collapseBelowWidth: 640,
      actions: <Widget>[
        if (onBackToBusinessAccounts != null)
          AdminBusinessAccountsBackButton(onPressed: onBackToBusinessAccounts),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
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
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.warning.withValues(alpha: 0.12),
                      border: Border.all(color: AppColors.warning, width: 1),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'Support view only',
                      style: AppTextStyles.mono10(
                        color: AppColors.warning,
                      ).copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
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
              const SizedBox(height: 6),
              Text(
                lastRefreshed == null
                    ? 'Last checked: -'
                    : 'Last checked: ${adminHumanDateTime(lastRefreshed!)}',
                key: const Key('admin_debug_console_last_refreshed'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.mono10(color: AppColors.textMuted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RequestLogTab extends StatelessWidget {
  const _RequestLogTab({
    required this.entries,
    required this.expanded,
    required this.filter,
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
    required this.liveTailOn,
    required this.onFilterChanged,
    required this.onSearchChanged,
    required this.onToggleExpanded,
    required this.onToggleLiveTail,
    required this.onRunRefresh,
  });

  final List<RequestLogEntry> entries;
  final Set<String> expanded;
  final RequestLogFilter filter;
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
  final bool liveTailOn;
  final ValueChanged<RequestLogFilter> onFilterChanged;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<String> onToggleExpanded;
  final ValueChanged<bool> onToggleLiveTail;
  final Future<void> Function() onRunRefresh;

  @override
  Widget build(BuildContext context) {
    // Single scroll axis so the tab body never overflows when the
    // shell embeds the screen at narrow viewports (the admin shell's
    // detail pane gives the screen ~540x158 on the default 800x600
    // test viewport, which is too tight for a Column-based layout).
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
          child: _FilterBar(
            filter: filter,
            hierarchyScope: hierarchyScope,
            scopeLocationIds: scopeLocationIds,
            searchController: searchController,
            onFilterChanged: onFilterChanged,
            onSearchChanged: onSearchChanged,
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
        SliverToBoxAdapter(
          child: _LiveTailRow(
            liveTailOn: liveTailOn,
            onToggleLiveTail: onToggleLiveTail,
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
    final body = switch (scope.scopeType) {
      AdminHierarchyScopeType.business =>
        'Business scope includes all recent support-log rows for this operator unless you add a location filter.',
      AdminHierarchyScopeType.location =>
        'Location only. Support logs are filtered to this location using the existing operator/location route contract.',
      AdminHierarchyScopeType.orgUnit => _orgUnitBody(),
    };
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
                const SizedBox(height: 5),
                Text(
                  body,
                  key: const Key('admin_debug_console_scope_body'),
                  style: AppTextStyles.body12(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _orgUnitBody() {
    final scopedError = error;
    if (scopedError != null) return scopedError;
    if (resolving) {
      return 'Resolving covered locations before filtering support logs.';
    }
    final count = locationIds?.length;
    if (count == null) {
      return 'Org-unit support logs need the hierarchy location list. This route does not expose that data here, so choose a business or location scope.';
    }
    if (count == 0) {
      return 'This org unit has no covered locations, so no support-log rows can match it.';
    }
    return 'Org unit expands to $count covered location${count == 1 ? '' : 's'}. The admin proxy receives the covered-location filter and the screen narrows visible rows to the same scope.';
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

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.filter,
    required this.hierarchyScope,
    required this.scopeLocationIds,
    required this.searchController,
    required this.onFilterChanged,
    required this.onSearchChanged,
  });

  final RequestLogFilter filter;
  final AdminHierarchyScopeIntent? hierarchyScope;
  final List<String>? scopeLocationIds;
  final TextEditingController searchController;
  final ValueChanged<RequestLogFilter> onFilterChanged;
  final ValueChanged<String> onSearchChanged;

  @override
  Widget build(BuildContext context) {
    return OperatorWebPanel(
      key: const Key('admin_debug_console_filter_bar'),
      title: 'Filters',
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            key: const Key('admin_debug_console_search_field'),
            controller: searchController,
            onChanged: onSearchChanged,
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 18),
              hintText: 'Search by request or retry reference',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              _StatusFilterChip(
                value: filter.status,
                onChanged: (next) =>
                    onFilterChanged(filter.copyWith(status: next)),
              ),
              _TimeWindowFilterChip(
                value: filter.timeWindow,
                onChanged: (next) =>
                    onFilterChanged(filter.copyWith(timeWindow: next)),
              ),
              _StringFilterChip(
                keyName: const Key('admin_debug_console_filter_operator'),
                label: 'Business',
                value: filter.operatorId,
                displayValue: _businessFilterLabel(filter.operatorId),
                hint: 'Type an exact business ID for support lookup',
                onChanged: (next) =>
                    onFilterChanged(filter.copyWith(operatorId: next)),
              ),
              _StringFilterChip(
                keyName: const Key('admin_debug_console_filter_location'),
                label: 'Location',
                value: filter.locationId,
                displayValue: _locationFilterLabel(filter.locationId),
                hint: 'Type an exact location ID for support lookup',
                onChanged: (next) =>
                    onFilterChanged(filter.copyWith(locationId: next)),
              ),
              if (scopeLocationIds != null)
                _ChipShell(
                  label: 'Covered locations: ${scopeLocationIds!.length}',
                  active: true,
                ),
              _StringFilterChip(
                keyName: const Key('admin_debug_console_filter_usage_class'),
                label: 'Request type',
                value: filter.usageClass,
                displayValue: _requestTypeFilterLabel(filter.usageClass),
                hint: 'advisor_qa, coach_qa, wf_pl',
                onChanged: (next) =>
                    onFilterChanged(filter.copyWith(usageClass: next)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Tip: choose View logs from a business, org unit, or location to fill the scope filters automatically.',
            style: AppTextStyles.body12(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 10),
          _RequestUseCaseKey(
            selectedUsageClass: filter.usageClass,
            onSelected: (usageClass) {
              final next = filter.usageClass == usageClass ? null : usageClass;
              onFilterChanged(filter.copyWith(usageClass: next));
            },
          ),
        ],
      ),
    );
  }

  String? _businessFilterLabel(String? value) {
    if (value == null || value.isEmpty) return null;
    final scope = hierarchyScope;
    if (scope != null && value == scope.operatorId) {
      return scope.operatorName ?? scope.displayLabel;
    }
    return 'Exact business filter';
  }

  String? _locationFilterLabel(String? value) {
    if (value == null || value.isEmpty) return null;
    final scope = hierarchyScope;
    if (scope != null && value == scope.locationId) {
      return scope.locationName ?? scope.displayLabel;
    }
    return 'Exact location filter';
  }

  String? _requestTypeFilterLabel(String? value) {
    if (value == null || value.isEmpty) return null;
    return adminRequestUseCaseLabel(value);
  }
}

class _StatusFilterChip extends StatelessWidget {
  const _StatusFilterChip({
    this.keyName = const Key('admin_debug_console_filter_status'),
    required this.value,
    required this.onChanged,
  });

  final Key keyName;
  final RequestLogStatus? value;
  final ValueChanged<RequestLogStatus?> onChanged;

  @override
  Widget build(BuildContext context) {
    final label = value == null
        ? 'Status: any'
        : 'Status: ${_statusLabel(value!)}';
    return PopupMenuButton<RequestLogStatus?>(
      key: keyName,
      tooltip: 'Filter by status',
      onSelected: onChanged,
      itemBuilder: (_) => <PopupMenuEntry<RequestLogStatus?>>[
        const PopupMenuItem<RequestLogStatus?>(value: null, child: Text('Any')),
        const PopupMenuItem<RequestLogStatus?>(
          value: RequestLogStatus.success,
          child: Text('Success'),
        ),
        const PopupMenuItem<RequestLogStatus?>(
          value: RequestLogStatus.error,
          child: Text('Error'),
        ),
        const PopupMenuItem<RequestLogStatus?>(
          value: RequestLogStatus.timeout,
          child: Text('Timeout'),
        ),
      ],
      child: _ChipShell(label: label, active: value != null),
    );
  }
}

class _TimeWindowFilterChip extends StatelessWidget {
  const _TimeWindowFilterChip({
    this.keyName = const Key('admin_debug_console_filter_window'),
    required this.value,
    required this.onChanged,
  });

  final Key keyName;
  final RequestLogTimeWindow? value;
  final ValueChanged<RequestLogTimeWindow?> onChanged;

  @override
  Widget build(BuildContext context) {
    final label = value == null
        ? 'Window: any'
        : 'Window: ${requestLogTimeWindowLabel(value!)}';
    return PopupMenuButton<RequestLogTimeWindow?>(
      key: keyName,
      tooltip: 'Filter by time window',
      onSelected: onChanged,
      itemBuilder: (_) => <PopupMenuEntry<RequestLogTimeWindow?>>[
        const PopupMenuItem<RequestLogTimeWindow?>(
          value: null,
          child: Text('Any'),
        ),
        for (final w in RequestLogTimeWindow.values)
          PopupMenuItem<RequestLogTimeWindow?>(
            value: w,
            child: Text(requestLogTimeWindowLabel(w)),
          ),
      ],
      child: _ChipShell(label: label, active: value != null),
    );
  }
}

class _StringFilterChip extends StatefulWidget {
  const _StringFilterChip({
    required this.keyName,
    required this.label,
    required this.value,
    this.displayValue,
    required this.hint,
    required this.onChanged,
  });

  final Key keyName;
  final String label;
  final String? value;
  final String? displayValue;
  final String hint;
  final ValueChanged<String?> onChanged;

  @override
  State<_StringFilterChip> createState() => _StringFilterChipState();
}

class _StringFilterChipState extends State<_StringFilterChip> {
  @override
  Widget build(BuildContext context) {
    final v = widget.value;
    final label = (v == null || v.isEmpty)
        ? '${widget.label}: any'
        : '${widget.label}: ${widget.displayValue ?? v}';
    return InkWell(
      key: widget.keyName,
      onTap: () async {
        final next = await showDialog<String?>(
          context: context,
          builder: (ctx) => _StringFilterDialog(
            label: widget.label,
            hint: widget.hint,
            initial: v ?? '',
          ),
        );
        if (next == null) return;
        widget.onChanged(next.isEmpty ? null : next);
      },
      child: _ChipShell(label: label, active: v != null && v.isNotEmpty),
    );
  }
}

class _StringFilterDialog extends StatefulWidget {
  const _StringFilterDialog({
    required this.label,
    required this.hint,
    required this.initial,
  });

  final String label;
  final String hint;
  final String initial;

  @override
  State<_StringFilterDialog> createState() => _StringFilterDialogState();
}

class _StringFilterDialogState extends State<_StringFilterDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return OperatorWebDialog(
      title: 'Filter by ${widget.label.toLowerCase()}',
      icon: Icons.filter_alt_outlined,
      actions: <Widget>[
        TextButton(
          key: const Key('admin_debug_console_filter_clear'),
          onPressed: () => Navigator.of(context).pop(''),
          child: const Text('Clear'),
        ),
        FilledButton(
          key: const Key('admin_debug_console_filter_apply'),
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Apply'),
        ),
      ],
      child: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(hintText: widget.hint),
      ),
    );
  }
}

class _ChipShell extends StatelessWidget {
  const _ChipShell({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.sunset : AppColors.borderSubtle;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: active
            ? AppColors.sunset.withValues(alpha: 0.12)
            : AppColors.backgroundSurface,
        border: Border.all(color: color, width: 1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: AppTextStyles.mono11(
          color: active ? AppColors.sunsetDark : AppColors.textPrimary,
        ).copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _RequestUseCaseKey extends StatelessWidget {
  const _RequestUseCaseKey({
    required this.selectedUsageClass,
    required this.onSelected,
  });

  final String? selectedUsageClass;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_debug_console_use_case_key'),
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.backgroundDeep,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Request type key',
            style: AppTextStyles.body13(
              color: AppColors.textPrimary,
            ).copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: <Widget>[
              for (final useCase in adminRequestUseCases)
                _KeyChip(
                  label: useCase.label,
                  id: useCase.id,
                  description: useCase.description,
                  active: selectedUsageClass == useCase.id,
                  onPressed: () => onSelected(useCase.id),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _KeyChip extends StatelessWidget {
  const _KeyChip({
    required this.label,
    required this.id,
    required this.description,
    required this.active,
    required this.onPressed,
  });

  final String label;
  final String id;
  final String description;
  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: active
          ? 'Clear $label filter'
          : 'Filter support logs to $description',
      child: OutlinedButton(
        key: Key('admin_debug_console_use_case_filter_$id'),
        onPressed: onPressed,
        style: AdminButtonStyles.filter(active: active),
        child: Text(label),
      ),
    );
  }
}

class _LiveTailRow extends StatelessWidget {
  const _LiveTailRow({
    required this.liveTailOn,
    required this.onToggleLiveTail,
  });

  final bool liveTailOn;
  final ValueChanged<bool> onToggleLiveTail;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_debug_console_live_tail_row'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            liveTailOn
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
            size: 14,
            color: liveTailOn ? AppColors.positive : AppColors.textMuted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              liveTailOn
                  ? 'Live refresh on. Checking for new requests every 5 seconds.'
                  : 'Live refresh off. Turn it on to check for new requests every 5 seconds.',
              style: AppTextStyles.body13(color: AppColors.textPrimary),
            ),
          ),
          const SizedBox(width: 8),
          Switch(
            key: const Key('admin_debug_console_live_tail_toggle'),
            value: liveTailOn,
            onChanged: onToggleLiveTail,
          ),
        ],
      ),
    );
  }
}

class _RequestRow extends StatelessWidget {
  const _RequestRow({
    super.key,
    required this.entry,
    required this.expanded,
    required this.optInOn,
    required this.editingEnabled,
    required this.onToggle,
  });

  final RequestLogEntry entry;
  final bool expanded;
  final bool optInOn;
  final bool editingEnabled;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final canRevealFullContent =
        editingEnabled && optInOn && entry.fullContentPayload != null;
    final statusColor = _statusColor(entry.status);
    final requestType = adminRequestUseCaseLabel(entry.usageClass);
    final summary = _requestSummary(entry);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: <Widget>[
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: AppColors.textMuted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 3,
                    child: Text(
                      requestType,
                      style: AppTextStyles.body12(
                        color: AppColors.textPrimary,
                      ).copyWith(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      summary,
                      style: AppTextStyles.body12(
                        color: AppColors.textSecondary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      _requestAge(entry.startedAt),
                      style: AppTextStyles.body12(color: AppColors.textMuted),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.15),
                      border: Border.all(color: statusColor, width: 1),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      _statusLabel(entry.status),
                      style: AppTextStyles.mono10(
                        color: statusColor,
                      ).copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 88,
                    child: Text(
                      '${entry.latencyMs} ms',
                      style: AppTextStyles.mono10(color: AppColors.textMuted),
                      textAlign: TextAlign.end,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(40, 0, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _MetaRow(label: 'Request reference', value: entry.requestId),
                  _MetaRow(
                    label: 'Retry reference',
                    value: entry.idempotencyKey,
                  ),
                  _MetaRow(label: 'Operator ID', value: entry.operatorId),
                  _MetaRow(
                    label: 'Location ID',
                    value: entry.locationId ?? 'Unknown',
                  ),
                  _MetaRow(
                    label: 'Request use case',
                    value: adminRequestUseCaseLabelWithId(entry.usageClass),
                  ),
                  if (_supportLogActorIdentity(entry).isNotEmpty)
                    _MetaRow(
                      label: 'Actor',
                      value: _supportLogActorIdentity(entry),
                    ),
                  _MetaRow(
                    label: 'Started',
                    value: adminHumanDateTime(entry.startedAt),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Request details',
                    style: AppTextStyles.mono10(
                      color: AppColors.textMuted,
                    ).copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.backgroundDeep,
                      border: Border.all(
                        color: AppColors.borderSubtle,
                        width: 1,
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      _formatMap(entry.requestMeta),
                      style: AppTextStyles.mono10(color: AppColors.textPrimary),
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (canRevealFullContent)
                    _FullContentBlock(
                      key: Key(
                        'admin_debug_console_full_content_${entry.requestId}',
                      ),
                      payload: entry.fullContentPayload!,
                    )
                  else
                    _FullContentLockedBlock(
                      editingEnabled: editingEnabled,
                      optInOn: optInOn,
                      payloadPresent: entry.fullContentPayload != null,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _requestSummary(RequestLogEntry entry) {
    final meta = entry.requestMeta;
    final value =
        meta['summary'] ??
        meta['route'] ??
        meta['path'] ??
        meta['method'] ??
        entry.idempotencyKey;
    final text = value.toString().trim();
    if (text.isEmpty) return 'Recent support request';
    return text;
  }

  static String _requestAge(DateTime startedAt) {
    final elapsed = DateTime.now().toUtc().difference(startedAt.toUtc());
    if (elapsed.inMinutes < 1) return 'just now';
    if (elapsed.inHours < 1) return '${elapsed.inMinutes} min ago';
    if (elapsed.inDays < 1) return '${elapsed.inHours} hr ago';
    return '${elapsed.inDays} d ago';
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: AppTextStyles.mono10(
                color: AppColors.textMuted,
              ).copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: AppTextStyles.mono10(color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

class _FullContentBlock extends StatelessWidget {
  const _FullContentBlock({super.key, required this.payload});

  final Map<String, Object?> payload;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.sunset, width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(
                Icons.lock_open,
                size: 14,
                color: AppColors.sunsetDark,
              ),
              const SizedBox(width: 6),
              Text(
                'Full content (operator opt-in is on)',
                style: AppTextStyles.mono10(
                  color: AppColors.sunsetDark,
                ).copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _formatMap(payload),
            style: AppTextStyles.mono10(color: AppColors.textPrimary),
          ),
        ],
      ),
    );
  }
}

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
        ? 'This support role cannot reveal full request content. Use ecosystem admin access to view it.'
        : !optInOn
        ? 'This operator has not allowed full request content. Enable the full-content opt-in in Launch controls to view it.'
        : 'Full request content was not saved for this request.';
    return Container(
      key: const Key('admin_debug_console_full_content_locked'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.backgroundDeep,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(Icons.lock_outline, size: 14, color: AppColors.textMuted),
          const SizedBox(width: 6),
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

class _SupportHelpTab extends StatelessWidget {
  const _SupportHelpTab({
    super.key,
    required this.surface,
    required this.title,
    required this.entries,
    required this.filter,
    required this.selectedUseCaseId,
    required this.searchController,
    required this.loading,
    required this.loadError,
    required this.onFilterChanged,
    required this.onSearchChanged,
    required this.onUseCaseChanged,
    required this.onRunRefresh,
    required this.emptyBody,
    required this.body,
  });

  final SupportHelpSurface surface;
  final String title;
  final List<RequestLogEntry> entries;
  final RequestLogFilter filter;
  final String? selectedUseCaseId;
  final TextEditingController searchController;
  final bool loading;
  final String? loadError;
  final ValueChanged<RequestLogFilter> onFilterChanged;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<String?> onUseCaseChanged;
  final Future<void> Function() onRunRefresh;
  final String emptyBody;
  final String body;

  @override
  Widget build(BuildContext context) {
    final rows = entries;
    return OperatorWebScreenBody(
      maxContentWidth: AdminConsoleLayout.narrowContentWidth,
      padding: AdminConsoleLayout.screenPadding,
      child: OperatorWebPanel(
        title: title,
        subtitle: body,
        trailing: _SupportHelpCountPill(count: rows.length),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _SupportHelpFilterBar(
              surface: surface,
              filter: filter,
              selectedUseCaseId: selectedUseCaseId,
              searchController: searchController,
              onFilterChanged: onFilterChanged,
              onSearchChanged: onSearchChanged,
              onUseCaseChanged: onUseCaseChanged,
            ),
            const SizedBox(height: 14),
            if (loadError != null)
              _ErrorBanner(message: loadError!)
            else if (loading && rows.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.sunsetDark,
                    ),
                  ),
                ),
              )
            else if (rows.isEmpty)
              Text(
                emptyBody,
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              )
            else
              for (final entry in rows.take(8))
                _SupportHelpRequestRow(surface: surface, entry: entry),
            if (rows.isEmpty && !loading && loadError == null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: Key('admin_debug_console_${surface.name}_help_refresh'),
                onPressed: onRunRefresh,
                style: AdminButtonStyles.secondary(),
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Refresh'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SupportHelpFilterBar extends StatelessWidget {
  const _SupportHelpFilterBar({
    required this.surface,
    required this.filter,
    required this.selectedUseCaseId,
    required this.searchController,
    required this.onFilterChanged,
    required this.onSearchChanged,
    required this.onUseCaseChanged,
  });

  final SupportHelpSurface surface;
  final RequestLogFilter filter;
  final String? selectedUseCaseId;
  final TextEditingController searchController;
  final ValueChanged<RequestLogFilter> onFilterChanged;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<String?> onUseCaseChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('admin_debug_console_${surface.name}_help_filter_bar'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.backgroundDeep,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            key: Key('admin_debug_console_${surface.name}_help_search'),
            controller: searchController,
            onChanged: onSearchChanged,
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 18),
              hintText: 'Search by request or retry reference',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              _StatusFilterChip(
                keyName: Key(
                  'admin_debug_console_${surface.name}_help_filter_status',
                ),
                value: filter.status,
                onChanged: (next) =>
                    onFilterChanged(filter.copyWith(status: next)),
              ),
              _TimeWindowFilterChip(
                keyName: Key(
                  'admin_debug_console_${surface.name}_help_filter_window',
                ),
                value: filter.timeWindow,
                onChanged: (next) =>
                    onFilterChanged(filter.copyWith(timeWindow: next)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: <Widget>[
              _KeyChip(
                label: 'All ${surface.label}',
                id: 'all',
                description: 'all typed ${surface.label.toLowerCase()} rows',
                active: selectedUseCaseId == null,
                onPressed: () => onUseCaseChanged(null),
              ),
              for (final useCase in supportHelpUseCasesFor(surface))
                _KeyChip(
                  label: useCase.label,
                  id: useCase.id,
                  description: useCase.description,
                  active: selectedUseCaseId == useCase.id,
                  onPressed: () => onUseCaseChanged(
                    selectedUseCaseId == useCase.id ? null : useCase.id,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SupportHelpCountPill extends StatelessWidget {
  const _SupportHelpCountPill({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.peacock.withValues(alpha: 0.12),
        border: Border.all(color: AppColors.peacockDark, width: 1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$count request${count == 1 ? '' : 's'}',
        style: AppTextStyles.chipLabel(color: AppColors.peacockDark),
      ),
    );
  }
}

class _SupportHelpRequestRow extends StatelessWidget {
  const _SupportHelpRequestRow({required this.surface, required this.entry});

  final SupportHelpSurface surface;
  final RequestLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final route = _friendlyRoute(entry);
    return Container(
      key: Key(
        'admin_debug_console_${surface.name}_help_row_${entry.requestId}',
      ),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            _statusIcon(entry.status),
            size: 17,
            color: _statusColor(entry.status),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  route,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.body14(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 3),
                Text(
                  '${requestLogStatusLabel(entry.status)} - ${entry.latencyMs} ms - ${_timeAgo(entry.startedAt)}',
                  style: AppTextStyles.body12(color: AppColors.textSecondary),
                ),
                if (_supportLogActorIdentity(entry).isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    _supportLogActorIdentity(entry),
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

  static String _friendlyRoute(RequestLogEntry entry) {
    final meta = entry.requestMeta;
    final value =
        meta['summary'] ??
        meta['route'] ??
        meta['path'] ??
        meta['method'] ??
        entry.usageClass;
    final text = value.toString().trim();
    if (text.isEmpty) return 'Support request';
    return text;
  }

  static IconData _statusIcon(RequestLogStatus status) {
    switch (status) {
      case RequestLogStatus.success:
        return Icons.check_circle_outline;
      case RequestLogStatus.error:
        return Icons.error_outline;
      case RequestLogStatus.timeout:
        return Icons.timer_off_outlined;
      case RequestLogStatus.unknown:
        return Icons.help_outline;
    }
  }

  static Color _statusColor(RequestLogStatus status) {
    switch (status) {
      case RequestLogStatus.success:
        return AppColors.positive;
      case RequestLogStatus.error:
        return AppColors.negative;
      case RequestLogStatus.timeout:
        return AppColors.warning;
      case RequestLogStatus.unknown:
        return AppColors.textMuted;
    }
  }

  static String _timeAgo(DateTime startedAt) {
    final elapsed = DateTime.now().toUtc().difference(startedAt.toUtc());
    if (elapsed.inMinutes < 1) return 'just now';
    if (elapsed.inHours < 1) return '${elapsed.inMinutes} min ago';
    if (elapsed.inDays < 1) return '${elapsed.inHours} hr ago';
    return '${elapsed.inDays} d ago';
  }
}

String _supportLogActorIdentity(RequestLogEntry entry) {
  final meta = entry.requestMeta;
  final name = _metaString(meta, const <String>[
    'actor_display_name',
    'actor_name',
    'display_name',
  ]);
  final role = _metaString(meta, const <String>[
    'actor_role',
    'actor_role_label',
    'role_label',
    'role',
  ]);
  final email = _metaString(meta, const <String>['actor_email', 'email']);
  if (name == null && role == null && email == null) return '';
  return <String>[
    name ?? 'Actor unavailable',
    role ?? 'role unavailable',
    email ?? 'email unavailable',
  ].join(' - ');
}

String? _metaString(Map<String, Object?> meta, List<String> keys) {
  for (final key in keys) {
    final raw = meta[key];
    if (raw is String && raw.trim().isNotEmpty) return raw.trim();
  }
  return null;
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

String _statusLabel(RequestLogStatus status) {
  final label = requestLogStatusLabel(status);
  return label.substring(0, 1).toUpperCase() + label.substring(1);
}

String _formatMap(Map<String, Object?> map) {
  if (map.isEmpty) return '{}';
  final buf = StringBuffer('{\n');
  for (final entry in map.entries) {
    buf
      ..write('  ')
      ..write(entry.key)
      ..write(': ')
      ..write(entry.value)
      ..write('\n');
  }
  buf.write('}');
  return buf.toString();
}
