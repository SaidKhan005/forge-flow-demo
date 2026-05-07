// Phase 11W.5 - Operator Web Audit Log screen.
//
// Web parity for the mobile Settings -> Audit Log section. Mounted at
// the `/audit-log` route in the operator-web shell. Renders the
// operator's audit_logs ledger with the locked filter set + cursor
// pagination + row rendering documented in the parity contract
// `§ Audit Log (11W.5 + 11A.14 Audit log tab)`:
//
//   * Filter set (locked):
//       actor       - multi-select user picker (the demo gateway
//                     applies this client-side; the live route will
//                     forward it once the proxy widens).
//       action      - multi-select catalog of canonical action
//                     strings (e.g. team.users.invite).
//       target_kind / target_id  - free-text contains filter.
//       time_window - 24h / 7d / 30d / 90d / custom date range.
//
//   * Pagination: cursor-based, 200 rows / page, sorted by
//                 created_at DESC.
//
//   * Row rendering: created_at in operator-local timezone, actor
//                    (display_name + email + actor_kind chip),
//                    action humanized via WebAuditLogActionLabels,
//                    target (target_kind + target_id with copy
//                    button), View payload toggle.
//
//   * CSV export: gated on `team.audit_log.export`. Pages through
//                 every matching row, hands the rendered CSV body to
//                 the clipboard (operator pastes into a CSV file or
//                 spreadsheet). Demo mode also writes its own
//                 audit.export.requested row so the export-is-
//                 audited rule renders in the walkthrough.
//
// Permission gating mirrors `§ Permission gate cheat sheet`. The
// screen prefers `OperatorWebSession.permissions` (live) when present;
// it falls back to a role-tier set so the demo flavor + bootstrap
// stage of live mode still render.
//
// Wiring honesty: the screen reads through [WebTeamAuditLogGateway]
// which the router binds to either the `package:http` live impl or
// the in-memory demo impl. No dart:io, no sqflite. CSV download is
// surfaced via clipboard (web-safe) + a screen-level callback so
// `11W.5.live` can swap in a Blob-anchor download path without
// touching the screen.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/operator_web_auth_source.dart';
import '../services/web_team_audit_log_gateway.dart';
import '../widgets/audit_log_row.dart';
import '../widgets/operator_web_summary_strip.dart';
import '../../theme/app_theme.dart';

/// Permission-key bound for the Audit Log read surface. Live source
/// hydrates from `/v1/auth/permissions/snapshot`.
const String kAuditLogViewPermissionKey = 'team.audit_log.view';

/// Permission-key bound for the CSV export action.
const String kAuditLogExportPermissionKey = 'team.audit_log.export';

/// Roles admitted to the Audit Log read surface when the proxy
/// permission snapshot is not yet hydrated. Authoritative gate is the
/// permission key.
const Set<String> kAuditLogViewAdmittedRoles = <String>{
  'operator_owner',
  'operator_admin',
  'operator_manager',
  'location_manager',
};

/// Roles admitted to the CSV export action when the snapshot is
/// empty. Authoritative gate is `team.audit_log.export`.
const Set<String> kAuditLogExportAdmittedRoles = <String>{
  'operator_owner',
  'operator_admin',
};

/// Per-page size pinned by the parity contract (Performance Framework).
const int kAuditLogPageSize = 200;

/// Operator Web Audit Log screen.
class AuditLogScreen extends StatefulWidget {
  const AuditLogScreen({
    super.key,
    required this.session,
    required this.gateway,
    this.idempotencyKeyFactory,
    this.onCsvReady,
    this.copyToClipboard,
  });

  final OperatorWebSession session;
  final WebTeamAuditLogGateway gateway;

  /// Optional override for tests so an assertion can pin the
  /// idempotency-key value the screen forwards into the gateway on
  /// CSV export.
  final String Function()? idempotencyKeyFactory;

  /// Optional sink the router can wire to a Blob-anchor download in
  /// `11W.5.live`. The screen always copies the CSV body to the
  /// clipboard so the operator has a reliable fallback even when the
  /// router does not provide a downloader.
  final Future<void> Function(WebAuditLogCsvExport export)? onCsvReady;

  /// Override for the clipboard call so tests can pin the CSV body
  /// without reaching into the platform plugin.
  final Future<void> Function(String value)? copyToClipboard;

  bool get _canView {
    if (session.permissions.isNotEmpty) {
      return session.permissions.contains(kAuditLogViewPermissionKey);
    }
    return session.roles.any(kAuditLogViewAdmittedRoles.contains);
  }

  bool get _canExport {
    if (session.permissions.isNotEmpty) {
      return session.permissions.contains(kAuditLogExportPermissionKey);
    }
    return session.roles.any(kAuditLogExportAdmittedRoles.contains);
  }

  @override
  State<AuditLogScreen> createState() => _AuditLogScreenState();
}

class _AuditLogScreenState extends State<AuditLogScreen> {
  WebAuditLogQuery _query = const WebAuditLogQuery(
    timeWindow: WebAuditLogTimeWindow.last30d,
    limit: kAuditLogPageSize,
  );

  bool _loading = true;
  bool _loadingMore = false;
  bool _exporting = false;
  String? _loadError;
  String? _exportMessage;
  List<WebAuditLogEntry> _entries = const <WebAuditLogEntry>[];
  String? _nextCursor;
  final Set<String> _expandedEntryIds = <String>{};
  int _refreshGeneration = 0;
  int _idempotencySeq = 0;

  /// Optional client-side action filter the demo gateway applies on
  /// top of the gateway query. Multi-select drives both the `actions`
  /// query field and the `event_kind` query the live route uses for
  /// the coarse server-side bucket.
  Set<String> _selectedActions = <String>{};

  /// Optional actor filter the demo gateway applies client-side. Live
  /// route ignores it for now (proxy clamps to caller).
  Set<String> _selectedActors = <String>{};

  /// Source of unique actors for the picker, derived from the latest
  /// page of results. Refreshes on each load so newly-surfaced actors
  /// show up after a filter change.
  final Map<String, String> _actorPickerCatalog = <String, String>{};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  String _nextIdempotencyKey() {
    final factory = widget.idempotencyKeyFactory;
    if (factory != null) return factory();
    _idempotencySeq += 1;
    final ts = DateTime.now().toUtc().microsecondsSinceEpoch;
    return 'op-web-audit-${widget.session.uid}-$ts-$_idempotencySeq';
  }

  Future<void> _refresh() async {
    final generation = ++_refreshGeneration;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _loadError = null;
    });
    try {
      final query = _query.copyWith(
        cursor: null,
        actions: _selectedActions.toList(),
        actorUserIds: _selectedActors.toList(),
      );
      final page = await widget.gateway.listEntries(query);
      if (!mounted || generation != _refreshGeneration) return;
      setState(() {
        _entries = page.entries;
        _nextCursor = page.nextCursor;
        _loading = false;
        _expandedEntryIds.clear();
        _refreshActorCatalog(page.entries);
      });
    } catch (error) {
      if (!mounted || generation != _refreshGeneration) return;
      setState(() {
        _loading = false;
        _loadError = _friendlyLoadError(error);
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _nextCursor == null) return;
    final generation = _refreshGeneration;
    setState(() {
      _loadingMore = true;
    });
    try {
      final query = _query.copyWith(
        cursor: _nextCursor,
        actions: _selectedActions.toList(),
        actorUserIds: _selectedActors.toList(),
      );
      final page = await widget.gateway.listEntries(query);
      if (!mounted || generation != _refreshGeneration) return;
      setState(() {
        _entries = List<WebAuditLogEntry>.unmodifiable(<WebAuditLogEntry>[
          ..._entries,
          ...page.entries,
        ]);
        _nextCursor = page.nextCursor;
        _loadingMore = false;
        _refreshActorCatalog(page.entries);
      });
    } catch (error) {
      if (!mounted || generation != _refreshGeneration) return;
      setState(() {
        _loadingMore = false;
        _loadError = _friendlyLoadError(error);
      });
    }
  }

  Future<void> _exportCsv() async {
    if (_exporting || !widget._canExport) return;
    setState(() {
      _exporting = true;
      _exportMessage = null;
    });
    try {
      final export = await widget.gateway.exportCsv(
        _query.copyWith(
          cursor: null,
          actions: _selectedActions.toList(),
          actorUserIds: _selectedActors.toList(),
        ),
        idempotencyKey: _nextIdempotencyKey(),
      );
      final clipboard = widget.copyToClipboard ?? _defaultCopy;
      await clipboard(export.csv);
      final downloader = widget.onCsvReady;
      if (downloader != null) {
        await downloader(export);
      }
      if (!mounted) return;
      setState(() {
        _exporting = false;
        _exportMessage =
            'Copied audit log CSV to your clipboard. Paste it into a '
            'spreadsheet to save the export.';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Audit log CSV ready (${export.filename}).')),
      );
      // The export wrote its own audit.export.requested row server-side,
      // so refresh the page so it surfaces at the top of the ledger.
      await _refresh();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _exporting = false;
        _exportMessage = _friendlyExportError(error);
      });
    }
  }

  void _refreshActorCatalog(List<WebAuditLogEntry> entries) {
    for (final row in entries) {
      final id = row.actorUserId;
      if (id == null) continue;
      _actorPickerCatalog[id] = row.actorDisplayName ?? row.actorEmail ?? id;
    }
  }

  void _toggleExpanded(String entryId) {
    setState(() {
      if (_expandedEntryIds.contains(entryId)) {
        _expandedEntryIds.remove(entryId);
      } else {
        _expandedEntryIds.add(entryId);
      }
    });
  }

  int _activeFilterCount() {
    var count = 1; // Time window is always active.
    if (_selectedActions.isNotEmpty) count += 1;
    if (_selectedActors.isNotEmpty) count += 1;
    if ((_query.targetKind ?? '').trim().isNotEmpty) count += 1;
    if ((_query.targetId ?? '').trim().isNotEmpty) count += 1;
    return count;
  }

  String _friendlyLoadError(Object error) {
    if (error is WebTeamAuditLogError) {
      if (error.isForbidden) {
        return 'You do not have permission to view the audit log for this '
            'operator.';
      }
      return 'Could not load the audit log (${error.code}). Refresh the '
          'page or try again in a moment.';
    }
    return 'Could not load the audit log. Refresh the page or try again '
        'in a moment.';
  }

  String _friendlyExportError(Object error) {
    if (error is WebTeamAuditLogError) {
      return 'Could not export the audit log (${error.code}). Try a '
          'narrower filter and try again.';
    }
    return 'Could not export the audit log. Try a narrower filter and '
        'try again.';
  }

  Future<void> _defaultCopy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
  }

  /// Build a local-day start (00:00:00) from the picked date and then
  /// convert to UTC. Going local->UTC last is intentional: in
  /// timezones west of UTC, building a UTC midnight then comparing
  /// against `created_at` would chop off the early hours of the local
  /// day. Mirrors the mobile audit-log section.
  static DateTime? _startOfDayUtc(DateTime? day) {
    if (day == null) return null;
    final local = day.toLocal();
    return DateTime(local.year, local.month, local.day).toUtc();
  }

  /// Treats the picked end day as inclusive: builds the local
  /// 23:59:59.999 of the picked date and converts to UTC.
  static DateTime? _endOfDayUtc(DateTime? day) {
    if (day == null) return null;
    final local = day.toLocal();
    return DateTime(
      local.year,
      local.month,
      local.day,
      23,
      59,
      59,
      999,
    ).toUtc();
  }

  Future<void> _pickCustomRange() async {
    final initialRange = (_query.customFrom != null && _query.customTo != null)
        ? DateTimeRange(
            start: _query.customFrom!.toLocal(),
            end: _query.customTo!.toLocal(),
          )
        : DateTimeRange(
            start: DateTime.now().subtract(const Duration(days: 30)),
            end: DateTime.now(),
          );
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      initialDateRange: initialRange,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _query = _query.copyWith(
        timeWindow: WebAuditLogTimeWindow.custom,
        customFrom: _startOfDayUtc(picked.start),
        customTo: _endOfDayUtc(picked.end),
      );
    });
    unawaited(_refresh());
  }

  @override
  Widget build(BuildContext context) {
    if (!widget._canView) {
      return const _AuditLogForbiddenSurface(
        key: Key('operator_web_audit_log_forbidden'),
      );
    }
    return SingleChildScrollView(
      key: const Key('operator_web_audit_log_screen'),
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _AuditLogHeader(
            canExport: widget._canExport,
            exporting: _exporting,
            onExport: _exportCsv,
          ),
          const SizedBox(height: 18),
          _AuditLogFilters(
            query: _query,
            selectedActions: _selectedActions,
            selectedActors: _selectedActors,
            actorCatalog: _actorPickerCatalog,
            onTimeWindowChanged: (window) {
              if (window == WebAuditLogTimeWindow.custom) {
                unawaited(_pickCustomRange());
                return;
              }
              setState(() {
                _query = _query.copyWith(
                  timeWindow: window,
                  customFrom: null,
                  customTo: null,
                );
              });
              unawaited(_refresh());
            },
            onCustomRangePick: _pickCustomRange,
            onActionsChanged: (next) {
              setState(() => _selectedActions = next);
              unawaited(_refresh());
            },
            onActorsChanged: (next) {
              setState(() => _selectedActors = next);
              unawaited(_refresh());
            },
            onTargetKindChanged: (value) {
              setState(() {
                _query = _query.copyWith(targetKind: value);
              });
              unawaited(_refresh());
            },
            onTargetIdChanged: (value) {
              setState(() {
                _query = _query.copyWith(targetId: value);
              });
              unawaited(_refresh());
            },
          ),
          const SizedBox(height: 16),
          OperatorWebSummaryStrip(
            key: const Key('operator_web_audit_log_summary'),
            items: [
              OperatorWebSummaryItem(
                icon: Icons.receipt_long_outlined,
                label: 'Rows loaded',
                value: _entries.length.toString(),
                helper: _loading ? 'loading latest page' : 'current filter',
              ),
              OperatorWebSummaryItem(
                icon: Icons.filter_alt_outlined,
                label: 'Active filters',
                value: _activeFilterCount().toString(),
                helper: 'time window included',
              ),
              OperatorWebSummaryItem(
                icon: Icons.more_horiz_outlined,
                label: 'More results',
                value: _nextCursor == null ? 'No' : 'Yes',
                helper: 'load more when present',
              ),
              OperatorWebSummaryItem(
                icon: Icons.file_download_outlined,
                label: 'Export',
                value: widget._canExport ? 'Available' : 'View only',
                helper: widget._canExport ? 'CSV uses filters' : 'role gated',
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_exportMessage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _exportMessage!,
                key: const Key('operator_web_audit_log_export_message'),
                style: AppTextStyles.body12(color: AppColors.textPrimary),
              ),
            ),
          if (_loading)
            const _AuditLogLoading()
          else if (_loadError != null)
            _AuditLogError(message: _loadError!, onRetry: _refresh)
          else if (_entries.isEmpty)
            const _AuditLogEmpty()
          else
            _AuditLogList(
              entries: _entries,
              expandedEntryIds: _expandedEntryIds,
              onToggleEntry: _toggleExpanded,
              hasMore: _nextCursor != null,
              loadingMore: _loadingMore,
              onLoadMore: _loadMore,
            ),
        ],
      ),
    );
  }
}

class _AuditLogHeader extends StatelessWidget {
  const _AuditLogHeader({
    required this.canExport,
    required this.exporting,
    required this.onExport,
  });

  final bool canExport;
  final bool exporting;
  final Future<void> Function() onExport;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Icon(
          Icons.fact_check_outlined,
          size: 22,
          color: AppColors.sunsetDark,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Audit log',
                style: AppTextStyles.display20(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 6),
              Text(
                'Every change someone made to your team, your roles, your '
                'org tree, and your sign-in security shows up here. Use the '
                'filters to narrow down to a specific action or actor, then '
                'export the result to a CSV when you need a paper trail.',
                key: const Key('operator_web_audit_log_subtitle'),
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
        if (canExport) ...[
          const SizedBox(width: 16),
          OutlinedButton.icon(
            key: const Key('operator_web_audit_log_export_button'),
            onPressed: exporting ? null : () => onExport(),
            icon: exporting
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.sunsetDark,
                    ),
                  )
                : const Icon(Icons.file_download_outlined, size: 16),
            label: Text(exporting ? 'Exporting' : 'Export CSV'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.sunsetDark,
              side: const BorderSide(color: AppColors.sunsetDark, width: 1),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            ),
          ),
        ],
      ],
    );
  }
}

class _AuditLogFilters extends StatelessWidget {
  const _AuditLogFilters({
    required this.query,
    required this.selectedActions,
    required this.selectedActors,
    required this.actorCatalog,
    required this.onTimeWindowChanged,
    required this.onCustomRangePick,
    required this.onActionsChanged,
    required this.onActorsChanged,
    required this.onTargetKindChanged,
    required this.onTargetIdChanged,
  });

  final WebAuditLogQuery query;
  final Set<String> selectedActions;
  final Set<String> selectedActors;
  final Map<String, String> actorCatalog;
  final ValueChanged<WebAuditLogTimeWindow> onTimeWindowChanged;
  final Future<void> Function() onCustomRangePick;
  final ValueChanged<Set<String>> onActionsChanged;
  final ValueChanged<Set<String>> onActorsChanged;
  final ValueChanged<String?> onTargetKindChanged;
  final ValueChanged<String?> onTargetIdChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_audit_log_filters'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Filters',
            style: AppTextStyles.mono14(
              color: AppColors.textPrimary,
              weight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          _TimeWindowChips(
            selected: query.timeWindow,
            customFrom: query.customFrom,
            customTo: query.customTo,
            onChanged: onTimeWindowChanged,
            onPickCustom: onCustomRangePick,
          ),
          const SizedBox(height: 12),
          _ActionPicker(selected: selectedActions, onChanged: onActionsChanged),
          const SizedBox(height: 12),
          if (actorCatalog.isNotEmpty) ...[
            _ActorPicker(
              catalog: actorCatalog,
              selected: selectedActors,
              onChanged: onActorsChanged,
            ),
            const SizedBox(height: 12),
          ],
          Row(
            children: <Widget>[
              Expanded(
                child: _TextFilterField(
                  fieldKey: const Key(
                    'operator_web_audit_log_filter_target_kind',
                  ),
                  label: 'Target kind',
                  hint: 'team_user, role, session, org_unit',
                  value: query.targetKind,
                  onChanged: onTargetKindChanged,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _TextFilterField(
                  fieldKey: const Key(
                    'operator_web_audit_log_filter_target_id',
                  ),
                  label: 'Target id',
                  hint: 'paste a uuid or stable id',
                  value: query.targetId,
                  onChanged: onTargetIdChanged,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TimeWindowChips extends StatelessWidget {
  const _TimeWindowChips({
    required this.selected,
    required this.customFrom,
    required this.customTo,
    required this.onChanged,
    required this.onPickCustom,
  });

  final WebAuditLogTimeWindow selected;
  final DateTime? customFrom;
  final DateTime? customTo;
  final ValueChanged<WebAuditLogTimeWindow> onChanged;
  final Future<void> Function() onPickCustom;

  static const List<(WebAuditLogTimeWindow, String, String)> _options =
      <(WebAuditLogTimeWindow, String, String)>[
        (WebAuditLogTimeWindow.last24h, 'Last 24 hours', '24h'),
        (WebAuditLogTimeWindow.last7d, 'Last 7 days', '7d'),
        (WebAuditLogTimeWindow.last30d, 'Last 30 days', '30d'),
        (WebAuditLogTimeWindow.last90d, 'Last 90 days', '90d'),
      ];

  @override
  Widget build(BuildContext context) {
    final customLabel =
        (selected == WebAuditLogTimeWindow.custom &&
            customFrom != null &&
            customTo != null)
        ? '${_fmt(customFrom!)} to ${_fmt(customTo!)}'
        : 'Custom range';
    return Wrap(
      key: const Key('operator_web_audit_log_filter_time_window'),
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        for (final option in _options)
          _ChoiceChip(
            chipKey: Key('operator_web_audit_log_time_window_${option.$3}'),
            label: option.$2,
            isActive: selected == option.$1,
            onTap: () => onChanged(option.$1),
          ),
        _ChoiceChip(
          chipKey: const Key('operator_web_audit_log_time_window_custom'),
          label: customLabel,
          isActive: selected == WebAuditLogTimeWindow.custom,
          onTap: () => onPickCustom(),
        ),
      ],
    );
  }

  static String _fmt(DateTime utc) {
    final local = utc.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}

class _ActionPicker extends StatelessWidget {
  const _ActionPicker({required this.selected, required this.onChanged});

  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Action',
          style: AppTextStyles.mono11(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 6),
        Wrap(
          key: const Key('operator_web_audit_log_filter_action'),
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final action in WebAuditLogActions.catalog)
              _ChoiceChip(
                chipKey: Key(
                  'operator_web_audit_log_action_${action.replaceAll('.', '_')}',
                ),
                label: WebAuditLogActionLabels.labelFor(action),
                isActive: selected.contains(action),
                onTap: () {
                  final next = Set<String>.from(selected);
                  if (next.contains(action)) {
                    next.remove(action);
                  } else {
                    next.add(action);
                  }
                  onChanged(next);
                },
              ),
          ],
        ),
      ],
    );
  }
}

class _ActorPicker extends StatelessWidget {
  const _ActorPicker({
    required this.catalog,
    required this.selected,
    required this.onChanged,
  });

  final Map<String, String> catalog;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    final actors = catalog.entries.toList()
      ..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Actor',
          style: AppTextStyles.mono11(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 6),
        Wrap(
          key: const Key('operator_web_audit_log_filter_actor'),
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final entry in actors)
              _ChoiceChip(
                chipKey: Key('operator_web_audit_log_actor_${entry.key}'),
                label: entry.value,
                isActive: selected.contains(entry.key),
                onTap: () {
                  final next = Set<String>.from(selected);
                  if (next.contains(entry.key)) {
                    next.remove(entry.key);
                  } else {
                    next.add(entry.key);
                  }
                  onChanged(next);
                },
              ),
          ],
        ),
      ],
    );
  }
}

class _TextFilterField extends StatefulWidget {
  const _TextFilterField({
    required this.fieldKey,
    required this.label,
    required this.hint,
    required this.value,
    required this.onChanged,
  });

  final Key fieldKey;
  final String label;
  final String hint;
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  State<_TextFilterField> createState() => _TextFilterFieldState();
}

class _TextFilterFieldState extends State<_TextFilterField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value ?? '');
  }

  @override
  void didUpdateWidget(covariant _TextFilterField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((widget.value ?? '') != _controller.text) {
      _controller.text = widget.value ?? '';
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          widget.label,
          style: AppTextStyles.mono11(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 4),
        TextField(
          key: widget.fieldKey,
          controller: _controller,
          onSubmitted: (raw) {
            final trimmed = raw.trim();
            widget.onChanged(trimmed.isEmpty ? null : trimmed);
          },
          decoration: InputDecoration(
            hintText: widget.hint,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        ),
      ],
    );
  }
}

class _ChoiceChip extends StatelessWidget {
  const _ChoiceChip({
    required this.chipKey,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  final Key chipKey;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: chipKey,
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isActive
              ? AppColors.sunset.withValues(alpha: 0.18)
              : AppColors.backgroundMid,
          border: Border.all(
            color: isActive
                ? AppColors.sunset.withValues(alpha: 0.5)
                : AppColors.borderSubtle,
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: AppTextStyles.mono11(
            color: isActive ? AppColors.sunsetDark : AppColors.textSecondary,
          ).copyWith(fontWeight: isActive ? FontWeight.w700 : FontWeight.w500),
        ),
      ),
    );
  }
}

class _AuditLogList extends StatelessWidget {
  const _AuditLogList({
    required this.entries,
    required this.expandedEntryIds,
    required this.onToggleEntry,
    required this.hasMore,
    required this.loadingMore,
    required this.onLoadMore,
  });

  final List<WebAuditLogEntry> entries;
  final Set<String> expandedEntryIds;
  final ValueChanged<String> onToggleEntry;
  final bool hasMore;
  final bool loadingMore;
  final Future<void> Function() onLoadMore;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_audit_log_list'),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final entry in entries)
            AuditLogRow(
              key: ValueKey('operator_web_audit_log_entry_${entry.entryId}'),
              entry: entry,
              expanded: expandedEntryIds.contains(entry.entryId),
              onTogglePayload: () => onToggleEntry(entry.entryId),
            ),
          if (hasMore)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Center(
                child: TextButton.icon(
                  key: const Key('operator_web_audit_log_load_more'),
                  onPressed: loadingMore ? null : () => onLoadMore(),
                  icon: loadingMore
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.sunsetDark,
                          ),
                        )
                      : const Icon(Icons.expand_more_rounded, size: 16),
                  label: Text(
                    loadingMore ? 'Loading next page' : 'Load next page',
                    style: AppTextStyles.mono11(color: AppColors.sunsetDark),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AuditLogLoading extends StatelessWidget {
  const _AuditLogLoading();

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const Key('operator_web_audit_log_loading'),
      child: const Padding(
        padding: EdgeInsets.all(28),
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.sunsetDark,
          ),
        ),
      ),
    );
  }
}

class _AuditLogError extends StatelessWidget {
  const _AuditLogError({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_audit_log_error'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Audit log could not load',
            style: AppTextStyles.mono14(
              color: AppColors.textPrimary,
              weight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            style: AppTextStyles.body13(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            key: const Key('operator_web_audit_log_retry'),
            onPressed: () => onRetry(),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.sunsetDark,
              side: const BorderSide(color: AppColors.sunsetDark, width: 1),
            ),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

class _AuditLogEmpty extends StatelessWidget {
  const _AuditLogEmpty();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_audit_log_empty'),
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        'No audit log entries match the current filters.',
        style: AppTextStyles.body13(color: AppColors.textMuted),
      ),
    );
  }
}

class _AuditLogForbiddenSurface extends StatelessWidget {
  const _AuditLogForbiddenSurface({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(
                    Icons.lock_outline,
                    size: 20,
                    color: AppColors.sunsetDark,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Audit log is not available for this account',
                      style: AppTextStyles.display20(
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'The Audit Log shows every change someone made to your '
                'team, your roles, and your sign-in security. Operator '
                'owners and managers see it from the web console; line '
                'staff stay on the mobile app.',
                style: AppTextStyles.body13(color: AppColors.textPrimary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
