// Phase 9.UX.6 — Settings → Account → Audit Log section.
//
// Self-service viewer over `AuthOperationsGateway.listAuthEventsForActor`.
// Operators inspect their own auth_events_audit history (sign-ins,
// password changes, MFA enrollment, role grants, sessions, invites)
// without exposing engineering shorthand. The proxy resolves user_id
// from the verified bearer token; the WHERE clause + per-tenant RLS
// policy form a defense-in-depth gate against cross-user reads.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/auth/auth_operations_gateway.dart';
import '../../state/auth_session_notifier.dart';
import '../../theme/app_theme.dart';
import 'settings_shared_widgets.dart';

/// Snapshot the section needs about the signed-in actor so it can
/// scope `listAuthEventsForActor` and the proxy gate.
class AuditLogActor {
  const AuditLogActor({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
}

/// Stable demo fixtures (kDemoMode) so the walkthrough can show
/// multiple events without staging.
class DemoAuditLogFixtures {
  const DemoAuditLogFixtures._();

  static List<AuthEventListEntry> seed() {
    final now = DateTime.utc(2026, 4, 30, 14, 22);
    return <AuthEventListEntry>[
      AuthEventListEntry(
        eventId: 'demo-audit-1',
        eventKind: AuthEventKind.signIn,
        eventType: 'auth.user.signed_in',
        friendlyLabel: AuthEventLabels.labelFor('auth.user.signed_in'),
        occurredAt: now.subtract(const Duration(minutes: 2)),
        ip: '203.0.113.42',
        userAgent: 'Forge&Flow/1.0 (iPhone; iOS 18.1)',
        geoCountry: 'CA',
      ),
      AuthEventListEntry(
        eventId: 'demo-audit-2',
        eventKind: AuthEventKind.password,
        eventType: 'auth.password_changed',
        friendlyLabel: AuthEventLabels.labelFor('auth.password_changed'),
        occurredAt: now.subtract(const Duration(hours: 3)),
        ip: '203.0.113.42',
        geoCountry: 'CA',
      ),
      AuthEventListEntry(
        eventId: 'demo-audit-3',
        eventKind: AuthEventKind.mfa,
        eventType: 'auth.mfa_totp_enrolled',
        friendlyLabel: AuthEventLabels.labelFor('auth.mfa_totp_enrolled'),
        occurredAt: now.subtract(const Duration(days: 1, hours: 4)),
      ),
      AuthEventListEntry(
        eventId: 'demo-audit-4',
        eventKind: AuthEventKind.role,
        eventType: 'auth.role_grant_created',
        friendlyLabel: AuthEventLabels.labelFor('auth.role_grant_created'),
        occurredAt: now.subtract(const Duration(days: 2, hours: 5)),
        scope: 'location',
      ),
      AuthEventListEntry(
        eventId: 'demo-audit-5',
        eventKind: AuthEventKind.session,
        eventType: 'auth.session_revoked',
        friendlyLabel: AuthEventLabels.labelFor('auth.session_revoked'),
        occurredAt: now.subtract(const Duration(days: 3, hours: 6)),
        ip: '198.51.100.18',
      ),
      AuthEventListEntry(
        eventId: 'demo-audit-6',
        eventKind: AuthEventKind.signIn,
        eventType: 'auth.user.signed_in',
        friendlyLabel: AuthEventLabels.labelFor('auth.user.signed_in'),
        occurredAt: now.subtract(const Duration(days: 4, hours: 7)),
        ip: '203.0.113.7',
        userAgent: 'Mozilla/5.0 (iPad; CPU OS 18_1) Safari/605.1.15',
        geoCountry: 'CA',
      ),
    ];
  }
}

/// In-memory `AuthOperationsGateway` for kDemoMode. Implements only
/// the audit-log read path so callers don't accidentally route
/// other Team / Org actions through it.
class DemoAuditLogGateway extends ScaffoldFailingAuthOperationsGateway {
  DemoAuditLogGateway({List<AuthEventListEntry>? seed})
    : _entries = List<AuthEventListEntry>.of(
        seed ?? DemoAuditLogFixtures.seed(),
      );

  final List<AuthEventListEntry> _entries;

  @override
  Future<AuthEventsListed> listAuthEventsForActor(
    AuthEventListCommand command,
  ) async {
    Iterable<AuthEventListEntry> filtered = _entries;
    if (command.eventKind != null) {
      filtered = filtered.where((e) => e.eventKind == command.eventKind);
    }
    final from = command.from;
    if (from != null) {
      filtered = filtered.where(
        (e) => !e.occurredAt.toUtc().isBefore(from.toUtc()),
      );
    }
    final to = command.to;
    if (to != null) {
      filtered = filtered.where(
        (e) => !e.occurredAt.toUtc().isAfter(to.toUtc()),
      );
    }
    final all = filtered.toList(growable: false);
    final start = command.offset.clamp(0, all.length);
    final end = (command.offset + command.limit).clamp(0, all.length);
    final page = all.sublist(start, end);
    return AuthEventsListed(
      entries: List<AuthEventListEntry>.unmodifiable(page),
      hasMore: end < all.length,
    );
  }
}

class SettingsAuditLogSection extends StatefulWidget {
  const SettingsAuditLogSection({
    super.key,
    this.gateway,
    this.actor,
    this.allowDemoGatewayFallback = false,
    this.refreshGeneration = 0,
    this.pageSize = 50,
  });

  final AuthOperationsGateway? gateway;
  final AuditLogActor? actor;

  /// In demo / preview shells where no proxy is wired, opting in to
  /// the demo fixture lets the walkthrough click path complete.
  final bool allowDemoGatewayFallback;
  final int refreshGeneration;
  final int pageSize;

  @override
  State<SettingsAuditLogSection> createState() =>
      _SettingsAuditLogSectionState();
}

class _SettingsAuditLogSectionState extends State<SettingsAuditLogSection> {
  AuthOperationsGateway? _gateway;
  AuditLogActor? _actor;

  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  String? _errorMessage;
  AuthEventKind? _activeFilter;
  DateTimeRange? _activeDateRange;
  List<AuthEventListEntry> _entries = const <AuthEventListEntry>[];
  final Set<String> _expandedEventIds = <String>{};

  @override
  void initState() {
    super.initState();
    _bindActorAndGateway();
    _refresh();
  }

  @override
  void didUpdateWidget(SettingsAuditLogSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gateway != widget.gateway ||
        oldWidget.actor != widget.actor) {
      _bindActorAndGateway();
      _refresh();
    } else if (oldWidget.refreshGeneration != widget.refreshGeneration) {
      _refresh();
    }
  }

  void _bindActorAndGateway() {
    AuthOperationsGateway? gateway = widget.gateway;
    if (gateway == null && widget.allowDemoGatewayFallback) {
      gateway = DemoAuditLogGateway();
    }
    _gateway = gateway;
    _actor = widget.actor ?? _actorFromContext();
  }

  AuditLogActor? _actorFromContext() {
    AuthSessionNotifier? notifier;
    try {
      notifier = context.read<AuthSessionNotifier>();
    } catch (_) {
      return null;
    }
    final session = notifier.session;
    if (session == null) return null;
    return AuditLogActor(
      actorUserId: session.userId,
      operatorId: session.operatorId,
      locationId: session.locationId,
    );
  }

  Future<void> _refresh() async {
    final gateway = _gateway;
    final actor = _actor;
    if (gateway == null || actor == null) {
      setState(() {
        _loading = false;
        _entries = const <AuthEventListEntry>[];
        _hasMore = false;
        _errorMessage = null;
        _expandedEventIds.clear();
      });
      return;
    }
    setState(() {
      _loading = true;
      _errorMessage = null;
    });
    try {
      final result = await gateway.listAuthEventsForActor(
        AuthEventListCommand(
          actorUserId: actor.actorUserId,
          operatorId: actor.operatorId,
          locationId: actor.locationId,
          limit: widget.pageSize,
          offset: 0,
          eventKind: _activeFilter,
          from: _startOfDayUtc(_activeDateRange?.start),
          to: _endOfDayUtc(_activeDateRange?.end),
        ),
      );
      if (!mounted) return;
      setState(() {
        _entries = result.entries;
        _hasMore = result.hasMore;
        _loading = false;
        _expandedEventIds.clear();
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMessage = _auditLogLoadMessage(error);
      });
    }
  }

  Future<void> _loadMore() async {
    final gateway = _gateway;
    final actor = _actor;
    if (gateway == null || actor == null) return;
    if (_loadingMore || !_hasMore) return;
    setState(() {
      _loadingMore = true;
      _errorMessage = null;
    });
    try {
      final result = await gateway.listAuthEventsForActor(
        AuthEventListCommand(
          actorUserId: actor.actorUserId,
          operatorId: actor.operatorId,
          locationId: actor.locationId,
          limit: widget.pageSize,
          offset: _entries.length,
          eventKind: _activeFilter,
          from: _startOfDayUtc(_activeDateRange?.start),
          to: _endOfDayUtc(_activeDateRange?.end),
        ),
      );
      if (!mounted) return;
      setState(() {
        // Append rather than replace so prior rows stay visible.
        _entries = List<AuthEventListEntry>.unmodifiable(<AuthEventListEntry>[
          ..._entries,
          ...result.entries,
        ]);
        _hasMore = result.hasMore;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _errorMessage = 'Could not load more audit events. Please try again.';
      });
    }
  }

  void _setFilter(AuthEventKind? kind) {
    if (_activeFilter == kind) return;
    setState(() => _activeFilter = kind);
    unawaited(_refresh());
  }

  /// Build a local-day start (00:00:00) from the picked date and
  /// then convert to UTC. Going local→UTC last is intentional: in
  /// timezones west of UTC, building a UTC midnight then comparing
  /// against `occurred_at` would chop off the early hours of the
  /// local day (e.g. America/St_Johns selecting Apr 30 with a UTC
  /// floor would miss anything between 00:00 and 03:30 local).
  static DateTime? _startOfDayUtc(DateTime? day) {
    if (day == null) return null;
    final local = day.toLocal();
    return DateTime(local.year, local.month, local.day).toUtc();
  }

  /// Treats the picked end day as inclusive: build the local end-of-
  /// day (23:59:59.999) from the picked date and then convert to UTC.
  /// In America/St_Johns selecting Apr 30, this yields ~03:29 May 1
  /// UTC instead of Apr 30 23:59 UTC, so events late on the local day
  /// are still inside the bound.
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

  Future<void> _pickDateRange() async {
    final initialRange =
        _activeDateRange ??
        DateTimeRange(
          start: DateTime.now().subtract(const Duration(days: 30)),
          end: DateTime.now(),
        );
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      initialDateRange: initialRange,
    );
    if (picked == null) return;
    if (!mounted) return;
    setState(() => _activeDateRange = picked);
    unawaited(_refresh());
  }

  void _clearDateRange() {
    if (_activeDateRange == null) return;
    setState(() => _activeDateRange = null);
    unawaited(_refresh());
  }

  void _toggleExpanded(String eventId) {
    setState(() {
      if (_expandedEventIds.contains(eventId)) {
        _expandedEventIds.remove(eventId);
      } else {
        _expandedEventIds.add(eventId);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final actor = _actor;
    if (actor == null) {
      return _emptyCard(
        message:
            "Audit Log becomes available once you're signed in to your account.",
      );
    }
    // Hide the filter chips and date control until we have something
    // worth filtering. An unauthenticated demo / unwired shell with
    // no events should not show controls that do nothing — and a
    // taller empty surface can also push neighbouring sliver
    // section actions into the pinned-header overlap zone.
    final hasActiveFilter = _activeFilter != null || _activeDateRange != null;
    final showFilters =
        _loading || _entries.isNotEmpty || _errorMessage != null || hasActiveFilter;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showFilters) ...[
          _AuditLogFilterChips(
            activeFilter: _activeFilter,
            onSelected: _setFilter,
          ),
          const SizedBox(height: 6),
          _AuditLogDateRangeControl(
            range: _activeDateRange,
            onPick: _pickDateRange,
            onClear: _clearDateRange,
          ),
          const SizedBox(height: 8),
        ],
        if (_loading) const _AuditLogLoadingCard(),
        if (!_loading &&
            _errorMessage != null &&
            _entries.isEmpty)
          _AuditLogErrorCard(
            message: _errorMessage!,
            onRetry: _refresh,
          ),
        if (!_loading && _entries.isEmpty && _errorMessage == null)
          _emptyCard(message: 'No audit events yet.'),
        if (!_loading && _entries.isNotEmpty)
          SettingsCard(
            children: [
              const _AuditLogHeader(),
              const SettingsRowDivider(),
              for (var i = 0; i < _entries.length; i++) ...[
                _AuditLogRow(
                  entry: _entries[i],
                  expanded: _expandedEventIds.contains(_entries[i].eventId),
                  onToggle: () => _toggleExpanded(_entries[i].eventId),
                ),
                if (i != _entries.length - 1) const SettingsRowDivider(),
              ],
              if (_errorMessage != null) ...[
                const SettingsRowDivider(),
                _AuditLogInlineError(message: _errorMessage!),
              ],
              if (_hasMore) ...[
                const SettingsRowDivider(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                  child: Center(
                    child: TextButton.icon(
                      key: const Key('audit_log_load_more'),
                      onPressed: _loadingMore ? null : _loadMore,
                      icon: _loadingMore
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.expand_more_rounded, size: 16),
                      label: Text(
                        _loadingMore ? 'Loading more' : 'Load more',
                        style: AppTextStyles.mono11(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
      ],
    );
  }

  Widget _emptyCard({required String message}) {
    return SettingsCard(
      children: [
        Padding(
          key: const Key('audit_log_empty'),
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.fact_check_outlined,
                size: 20,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: AppTextStyles.body13(color: AppColors.textMuted),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AuditLogFilterChips extends StatelessWidget {
  const _AuditLogFilterChips({
    required this.activeFilter,
    required this.onSelected,
  });

  final AuthEventKind? activeFilter;
  final ValueChanged<AuthEventKind?> onSelected;

  @override
  Widget build(BuildContext context) {
    final chips = <_FilterChipSpec>[
      const _FilterChipSpec(label: 'All', kind: null, keyId: 'all'),
      const _FilterChipSpec(
        label: 'Sign-ins',
        kind: AuthEventKind.signIn,
        keyId: 'sign_in',
      ),
      const _FilterChipSpec(
        label: 'Passwords',
        kind: AuthEventKind.password,
        keyId: 'password',
      ),
      const _FilterChipSpec(
        label: 'MFA',
        kind: AuthEventKind.mfa,
        keyId: 'mfa',
      ),
      const _FilterChipSpec(
        label: 'Roles',
        kind: AuthEventKind.role,
        keyId: 'role',
      ),
      const _FilterChipSpec(
        label: 'Sessions',
        kind: AuthEventKind.session,
        keyId: 'session',
      ),
    ];
    return SingleChildScrollView(
      key: const Key('audit_log_filter_chips'),
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final spec in chips) ...[
            _FilterChip(
              spec: spec,
              isActive: activeFilter == spec.kind,
              onTap: () => onSelected(spec.kind),
            ),
            const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }
}

class _AuditLogDateRangeControl extends StatelessWidget {
  const _AuditLogDateRangeControl({
    required this.range,
    required this.onPick,
    required this.onClear,
  });

  final DateTimeRange? range;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final r = range;
    final label = r == null
        ? 'All dates'
        : '${_formatDate(r.start)} – ${_formatDate(r.end)}';
    return Row(
      children: [
        InkWell(
          key: const Key('audit_log_date_range_picker'),
          onTap: onPick,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: r == null
                  ? AppColors.backgroundMid
                  : AppColors.sunset.withValues(alpha: 0.18),
              border: Border.all(
                color: r == null
                    ? AppColors.borderSubtle
                    : AppColors.sunset.withValues(alpha: 0.5),
              ),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.calendar_today_outlined,
                  size: 13,
                  color: r == null
                      ? AppColors.textSecondary
                      : AppColors.sunsetDark,
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: AppTextStyles.mono11(
                    color: r == null
                        ? AppColors.textSecondary
                        : AppColors.sunsetDark,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (r != null) ...[
          const SizedBox(width: 6),
          IconButton(
            key: const Key('audit_log_date_range_clear'),
            onPressed: onClear,
            icon: const Icon(Icons.close_rounded, size: 14),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 24, height: 24),
            visualDensity: VisualDensity.compact,
            color: AppColors.textMuted,
            tooltip: 'Clear date range',
          ),
        ],
      ],
    );
  }

  static String _formatDate(DateTime d) {
    final local = d.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }
}

class _FilterChipSpec {
  const _FilterChipSpec({
    required this.label,
    required this.kind,
    required this.keyId,
  });

  final String label;
  final AuthEventKind? kind;
  final String keyId;
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.spec,
    required this.isActive,
    required this.onTap,
  });

  final _FilterChipSpec spec;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: Key('audit_log_filter_${spec.keyId}'),
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
          spec.label,
          style: AppTextStyles.mono11(
            color: isActive ? AppColors.sunsetDark : AppColors.textSecondary,
          ).copyWith(
            fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _AuditLogHeader extends StatelessWidget {
  const _AuditLogHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.sunset.withValues(alpha: 0.12),
              border: Border.all(
                color: AppColors.sunset.withValues(alpha: 0.4),
              ),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Icon(
              Icons.fact_check_rounded,
              size: 19,
              color: AppColors.sunsetDark,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Audit log',
                  style: AppTextStyles.mono12(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Recent security activity on your account.',
                  style: AppTextStyles.body12(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AuditLogRow extends StatelessWidget {
  const _AuditLogRow({
    required this.entry,
    required this.expanded,
    required this.onToggle,
  });

  final AuthEventListEntry entry;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: Key('audit_log_row_${entry.eventId}'),
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.borderSubtle.withValues(alpha: 0.4),
                    border: Border.all(color: AppColors.borderSubtle),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Icon(
                    _iconFor(entry.eventKind),
                    size: 16,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.friendlyLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.mono12(
                          color: AppColors.textPrimary,
                          weight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _relative(entry.occurredAt),
                        style: AppTextStyles.body12(
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: AppColors.textMuted,
                ),
              ],
            ),
            if (expanded) ...[
              const SizedBox(height: 10),
              Padding(
                key: Key('audit_log_row_${entry.eventId}_details'),
                padding: const EdgeInsets.only(left: 44),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _DetailRow(
                      label: 'When',
                      value: entry.occurredAt.toLocal().toString(),
                    ),
                    _DetailRow(label: 'Event', value: entry.eventType),
                    if (entry.scope != null)
                      _DetailRow(label: 'Scope', value: entry.scope!),
                    if (entry.subType != null)
                      _DetailRow(label: 'Reason', value: entry.subType!),
                    if (entry.ip != null)
                      _DetailRow(label: 'IP', value: entry.ip!),
                    if (entry.geoCountry != null)
                      _DetailRow(label: 'Country', value: entry.geoCountry!),
                    if (entry.userAgent != null)
                      _DetailRow(label: 'Device', value: entry.userAgent!),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static IconData _iconFor(AuthEventKind kind) {
    switch (kind) {
      case AuthEventKind.signIn:
        return Icons.login_rounded;
      case AuthEventKind.password:
        return Icons.password_rounded;
      case AuthEventKind.mfa:
        return Icons.shield_outlined;
      case AuthEventKind.role:
        return Icons.assignment_ind_outlined;
      case AuthEventKind.session:
        return Icons.devices_other_rounded;
      case AuthEventKind.invite:
        return Icons.mail_outline_rounded;
      case AuthEventKind.user:
        return Icons.person_outline_rounded;
      case AuthEventKind.other:
        return Icons.info_outline_rounded;
    }
  }

  static String _relative(DateTime when) {
    final now = DateTime.now().toUtc();
    final diff = now.difference(when.toUtc());
    if (diff.isNegative) return 'just now';
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) {
      final m = diff.inMinutes;
      return m == 1 ? '1 minute ago' : '$m minutes ago';
    }
    if (diff.inHours < 24) {
      final h = diff.inHours;
      return h == 1 ? '1 hour ago' : '$h hours ago';
    }
    if (diff.inDays < 7) {
      final d = diff.inDays;
      return d == 1 ? '1 day ago' : '$d days ago';
    }
    final weeks = (diff.inDays / 7).floor();
    if (weeks < 5) return weeks == 1 ? '1 week ago' : '$weeks weeks ago';
    final months = (diff.inDays / 30).floor();
    return months == 1 ? '1 month ago' : '$months months ago';
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: Text(
              label,
              style: AppTextStyles.mono10(color: AppColors.textMuted),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: AppTextStyles.body12(color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

String _auditLogLoadMessage(Object error) {
  final text = error.toString().toLowerCase();
  if (text.contains('status: 401') || text.contains('status: 403')) {
    return 'You do not have access to view the audit log.';
  }
  if (text.contains('status: 404') || text.contains('not found')) {
    return 'Audit log route not found. Rebuild with the staging proxy.';
  }
  if (text.contains('transport_error') || text.contains('status: null')) {
    return 'Could not reach the proxy. Check connection and retry.';
  }
  return "We couldn't load your audit log. Please try again.";
}

class _AuditLogLoadingCard extends StatelessWidget {
  const _AuditLogLoadingCard();

  @override
  Widget build(BuildContext context) {
    return SettingsCard(
      children: [
        Padding(
          key: const Key('audit_log_loading'),
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
          child: Row(
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Text(
                'Loading audit log',
                style: AppTextStyles.mono11(color: AppColors.textMuted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AuditLogErrorCard extends StatelessWidget {
  const _AuditLogErrorCard({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return SettingsCard(
      children: [
        Padding(
          key: const Key('audit_log_error'),
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.info_outline_rounded,
                size: 20,
                color: AppColors.sunsetDark,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Audit log',
                      style: AppTextStyles.mono12(
                        color: AppColors.textPrimary,
                        weight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      message,
                      style: AppTextStyles.body13(color: AppColors.textMuted),
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      key: const Key('audit_log_retry'),
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh_rounded, size: 16),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AuditLogInlineError extends StatelessWidget {
  const _AuditLogInlineError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('audit_log_inline_error'),
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.info_outline_rounded,
            size: 16,
            color: AppColors.negative,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body12(color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
