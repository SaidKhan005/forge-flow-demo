// Phase 11A.5 - Debug console admin surface (per-operator request log).
//
// Read-only operator-facing console for the proxy `proxy_requests`
// projection. Three tabs reflect the launch-slice scope and the two
// future plug-ins:
//
//   * Request log - live filterable / searchable view of recent
//                   proxy requests. Meta-only by default; expand-row
//                   reveals the full content payload only when the
//                   operator's `feature_flags` opt-in is on AND the
//                   actor holds `super_admin`.
//   * Graph debug - stub for 11A.3.x. Shows the 501-style banner.
//   * MFA diagnostics - stub for 9.UX.1a. Shows the 501-style banner.
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

import '../../theme/app_theme.dart';

import '../admin_button_styles.dart';
import '../admin_human_labels.dart';
import '../admin_route_handoff.dart';
import '../models/debug_console_admin_models.dart';
import '../services/debug_console_admin_gateway.dart';
import '../services/roles_hierarchy_sessions_admin_gateway.dart';
import '../widgets/admin_business_accounts_back_button.dart';
import '../widgets/admin_responsive_layout.dart';

const String _kRequestLogTab = 'request_log';
const String _kGraphDebugTab = 'graph_debug';
const String _kMfaDiagnosticsTab = 'mfa_diagnostics';

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
  List<FullContentOptIn> _optIns = const <FullContentOptIn>[];

  late RequestLogFilter _filter;
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
    super.dispose();
  }

  bool _optInOnFor(String operatorId) {
    for (final row in _optIns) {
      if (row.operatorId == operatorId) return row.enabled;
    }
    return false;
  }

  RequestLogFilter get _effectiveFilter {
    final scope = widget.hierarchyScope;
    if (scope == null) return _filter;
    switch (scope.scopeType) {
      case AdminHierarchyScopeType.business:
        return _filter.copyWith(operatorId: scope.operatorId);
      case AdminHierarchyScopeType.location:
        return _filter.copyWith(
          operatorId: scope.operatorId,
          locationId: scope.locationId,
          locationIds: null,
        );
      case AdminHierarchyScopeType.orgUnit:
        final locationIds = _scopeLocationIds ?? const <String>[];
        return _filter.copyWith(
          operatorId: scope.operatorId,
          locationIds: List<String>.unmodifiable(locationIds),
        );
    }
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
    final requestFilter = _effectiveFilter;
    setState(() {
      _refreshing = true;
      if (_entries.isEmpty) _initialLoading = true;
      _loadError = null;
    });
    try {
      final results = await Future.wait(<Future<Object>>[
        widget.gateway.listRequests(requestFilter),
        widget.gateway.listFullContentOptIns(),
      ]);
      if (!mounted) return;
      setState(() {
        _entries = results[0] as List<RequestLogEntry>;
        _optIns = results[1] as List<FullContentOptIn>;
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
    return Material(
      key: const Key('admin_debug_console_screen'),
      color: AppColors.backgroundDeep,
      type: MaterialType.canvas,
      child: Padding(
        padding: const EdgeInsets.all(20),
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
                  text: 'Requests',
                ),
                Tab(
                  key: Key('admin_debug_console_tab_$_kGraphDebugTab'),
                  text: 'Relationship help',
                ),
                Tab(
                  key: Key('admin_debug_console_tab_$_kMfaDiagnosticsTab'),
                  text: 'Account help',
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
                  const _StubTab(
                    key: Key('admin_debug_console_stub_$_kGraphDebugTab'),
                    title: 'Relationship help',
                    badge: 'Coming soon',
                    body:
                        'Relationship diagnostics are not wired here yet. Use Corpus > Relationship review for the current review workflow.',
                  ),
                  const _StubTab(
                    key: Key('admin_debug_console_stub_$_kMfaDiagnosticsTab'),
                    title: 'Account help',
                    badge: 'Coming soon',
                    body:
                        'Account diagnostics are not wired here yet. This tab will cover authenticator apps, pending removal requests, notifications, and account mismatch checks.',
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
    return AdminPageHeader(
      title: 'Support logs',
      subtitle:
          'Translate recent backend requests into support-safe details. Filter with exact IDs when you need a precise lookup.',
      leading: onBackToBusinessAccounts == null
          ? null
          : AdminBusinessAccountsBackButton(
              onPressed: onBackToBusinessAccounts,
            ),
      compactBreakpoint: 640,
      trailing: ConstrainedBox(
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
                ? Icons.account_tree_outlined
                : scope.isLocationScope
                ? Icons.storefront_outlined
                : Icons.business_outlined,
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
    required this.scopeLocationIds,
    required this.searchController,
    required this.onFilterChanged,
    required this.onSearchChanged,
  });

  final RequestLogFilter filter;
  final List<String>? scopeLocationIds;
  final TextEditingController searchController;
  final ValueChanged<RequestLogFilter> onFilterChanged;
  final ValueChanged<String> onSearchChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_debug_console_filter_bar'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
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
              hintText: 'Search by request or retry ID',
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
                label: 'Operator',
                value: filter.operatorId,
                hint: 'Type an operator ID, or open this view from Operators',
                onChanged: (next) =>
                    onFilterChanged(filter.copyWith(operatorId: next)),
              ),
              _StringFilterChip(
                keyName: const Key('admin_debug_console_filter_location'),
                label: 'Location',
                value: filter.locationId,
                hint: 'Type a location ID, or open this view from a location',
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
                label: 'Request use case ID',
                value: filter.usageClass,
                hint: 'advisor_qa, coach_qa, wf_pl',
                onChanged: (next) =>
                    onFilterChanged(filter.copyWith(usageClass: next)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Tip: choose View logs from a business, org unit, or location to fill the exact filters automatically.',
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
}

class _StatusFilterChip extends StatelessWidget {
  const _StatusFilterChip({required this.value, required this.onChanged});

  final RequestLogStatus? value;
  final ValueChanged<RequestLogStatus?> onChanged;

  @override
  Widget build(BuildContext context) {
    final label = value == null
        ? 'Status: any'
        : 'Status: ${_statusLabel(value!)}';
    return PopupMenuButton<RequestLogStatus?>(
      key: const Key('admin_debug_console_filter_status'),
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
  const _TimeWindowFilterChip({required this.value, required this.onChanged});

  final RequestLogTimeWindow? value;
  final ValueChanged<RequestLogTimeWindow?> onChanged;

  @override
  Widget build(BuildContext context) {
    final label = value == null
        ? 'Window: any'
        : 'Window: ${requestLogTimeWindowLabel(value!)}';
    return PopupMenuButton<RequestLogTimeWindow?>(
      key: const Key('admin_debug_console_filter_window'),
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
    required this.hint,
    required this.onChanged,
  });

  final Key keyName;
  final String label;
  final String? value;
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
        : '${widget.label}: $v';
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
    return AlertDialog(
      title: Text('Filter by ${widget.label.toLowerCase()}'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(hintText: widget.hint),
      ),
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
            'Request use case ID key',
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
        child: Text.rich(
          TextSpan(
            text: label,
            children: <InlineSpan>[
              TextSpan(
                text: '  $id',
                style: AppTextStyles.mono10(
                  color: active ? AppColors.sunsetDark : AppColors.textMuted,
                ),
              ),
            ],
          ),
        ),
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
                      entry.requestId,
                      style: AppTextStyles.mono11(
                        color: AppColors.textPrimary,
                      ).copyWith(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      entry.idempotencyKey,
                      style: AppTextStyles.mono10(
                        color: AppColors.textSecondary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          adminRequestUseCaseLabel(entry.usageClass),
                          style: AppTextStyles.body12(
                            color: AppColors.textPrimary,
                          ).copyWith(fontWeight: FontWeight.w700),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          entry.usageClass,
                          style: AppTextStyles.mono8(
                            color: AppColors.textMuted,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
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
                  _MetaRow(label: 'Operator ID', value: entry.operatorId),
                  _MetaRow(
                    label: 'Location ID',
                    value: entry.locationId ?? 'Unknown',
                  ),
                  _MetaRow(
                    label: 'Request use case',
                    value: adminRequestUseCaseLabelWithId(entry.usageClass),
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

class _StubTab extends StatelessWidget {
  const _StubTab({
    super.key,
    required this.title,
    required this.badge,
    required this.body,
  });

  final String title;
  final String badge;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
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
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  const Icon(
                    Icons.hourglass_empty,
                    size: 16,
                    color: AppColors.textMuted,
                  ),
                  Text(
                    title,
                    style: AppTextStyles.display20(
                      color: AppColors.textPrimary,
                    ),
                  ),
                  Container(
                    key: Key(
                      'admin_debug_console_stub_badge_'
                      '${title.toLowerCase().replaceAll(' ', '_')}',
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.warning.withValues(alpha: 0.14),
                      border: Border.all(color: AppColors.warning, width: 1),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      badge,
                      style: AppTextStyles.chipLabel(color: AppColors.warning),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                body,
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
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
