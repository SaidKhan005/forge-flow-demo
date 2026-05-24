// Admin "Audit log" page — the full-page account audit surface reached
// from the My account "View audit log" button and from the "Your
// account" side-nav section.
//
// Parity intent: this mirrors the operator-web Audit Log screen's look
// and interaction (screen header + Export action, a time-window filter,
// a row list with a view-detail expand, and the loading / empty / error
// states), applied to the signed-in admin's OWN account events.
//
// Data scope (HP #11 carve-out, same as My account / Notifications): a
// personal account log is flat — there is no operator/location
// hierarchy to filter through and no other actor to pick — so the
// operator-web hierarchy + actor filters do not apply here and are
// intentionally absent. The events come from the self-scoped
// `GET /v1/auth/audit-log` route via
// [AdminSecurityGateway.listAccountAuditLog]; the proxy resolves the
// acting admin from the verified bearer token, so no new backend route,
// no schema, and no auth-logic change.
//
// CSV export copies the rendered rows to the clipboard (web-safe, same
// pattern the operator-web Audit Log screen uses) so the admin can
// paste into a spreadsheet.
//
// UX writing standard + CLAUDE.md no-em-dash law: every label, status,
// and message reads as training the user, in plain English, with no em
// dash anywhere in operator-facing copy.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import 'package:forge_and_flow/widgets/console/console_screen_body.dart';
import 'package:forge_and_flow/widgets/console/console_screen_header.dart';
import 'package:forge_and_flow/widgets/console/console_surface.dart';
import '../services/admin_security_gateway.dart';

/// Time window for the audit-log filter. Mirrors the operator-web Audit
/// Log screen's preset windows (the 90-day cap matches the server-side
/// projection in [AdminSecurityGateway.listAccountAuditLog]).
enum _AuditWindow { last24h, last7Days, last30Days, last90Days }

extension _AuditWindowMeta on _AuditWindow {
  Duration get duration {
    switch (this) {
      case _AuditWindow.last24h:
        return const Duration(hours: 24);
      case _AuditWindow.last7Days:
        return const Duration(days: 7);
      case _AuditWindow.last30Days:
        return const Duration(days: 30);
      case _AuditWindow.last90Days:
        return const Duration(days: 90);
    }
  }

  String get label {
    switch (this) {
      case _AuditWindow.last24h:
        return 'Last 24 hours';
      case _AuditWindow.last7Days:
        return 'Last 7 days';
      case _AuditWindow.last30Days:
        return 'Last 30 days';
      case _AuditWindow.last90Days:
        return 'Last 90 days';
    }
  }

  String get filterKey {
    switch (this) {
      case _AuditWindow.last24h:
        return 'last_24h';
      case _AuditWindow.last7Days:
        return 'last_7';
      case _AuditWindow.last30Days:
        return 'last_30';
      case _AuditWindow.last90Days:
        return 'last_90';
    }
  }
}

/// Full-page admin Audit log for the signed-in admin's own account.
class AccountAuditLogAdminScreen extends StatefulWidget {
  const AccountAuditLogAdminScreen({
    super.key,
    this.gateway,
    this.now,
    this.copyToClipboard,
  });

  /// Live gateway. Null renders the honest disconnected state (demo /
  /// share-preview without a backend, or a wiring gap).
  final AdminSecurityGateway? gateway;

  /// Test seam for the time-window cutoff clock.
  final DateTime Function()? now;

  /// Test seam for the CSV clipboard write. Production uses
  /// [Clipboard.setData].
  final Future<void> Function(String csv)? copyToClipboard;

  @override
  State<AccountAuditLogAdminScreen> createState() =>
      _AccountAuditLogAdminScreenState();
}

class _AccountAuditLogAdminScreenState
    extends State<AccountAuditLogAdminScreen> {
  bool _loading = false;
  String? _error;
  List<AdminSecurityAuditEntry> _entries = const <AdminSecurityAuditEntry>[];
  int _generation = 0;
  _AuditWindow _window = _AuditWindow.last90Days;
  final Set<String> _expanded = <String>{};

  String? _exportToast;
  Timer? _exportToastTimer;
  static const Duration _kToastVisibleDuration = Duration(seconds: 4);

  @override
  void initState() {
    super.initState();
    if (widget.gateway != null) {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _exportToastTimer?.cancel();
    super.dispose();
  }

  DateTime _now() => (widget.now?.call() ?? DateTime.now()).toUtc();

  Future<void> _load() async {
    final gateway = widget.gateway;
    if (gateway == null) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final listed = await gateway.listAccountAuditLog();
      if (!mounted || generation != _generation) return;
      setState(() {
        _entries = listed.entries;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error =
            'Could not load your audit log. Refresh this page, or try again '
            'in a moment.';
      });
    }
  }

  List<AdminSecurityAuditEntry> _filtered() {
    final cutoff = _now().subtract(_window.duration);
    return _entries
        .where((e) => !e.occurredAt.toUtc().isBefore(cutoff))
        .toList(growable: false);
  }

  void _toggle(String eventId) {
    setState(() {
      if (!_expanded.remove(eventId)) _expanded.add(eventId);
    });
  }

  Future<void> _exportCsv() async {
    final rows = _filtered();
    if (rows.isEmpty) return;
    final csv = _buildCsv(rows);
    final copy = widget.copyToClipboard ??
        (String value) => Clipboard.setData(ClipboardData(text: value));
    await copy(csv);
    if (!mounted) return;
    _exportToastTimer?.cancel();
    setState(
      () => _exportToast =
          'Audit log copied. Paste it into a spreadsheet to save or share.',
    );
    _exportToastTimer = Timer(_kToastVisibleDuration, () {
      if (!mounted) return;
      setState(() => _exportToast = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final hasGateway = widget.gateway != null;
    final rows = _filtered();
    final canExport = hasGateway && !_loading && _error == null && rows.isNotEmpty;
    return OperatorWebScreenBody(
      scrollKey: const Key('admin_account_audit_log_screen'),
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OperatorWebScreenHeader(
            icon: Icons.history,
            title: 'Audit log',
            subtitle:
                'Sign-ins, password changes, two-factor, and profile edits '
                'on your Forge & Flow admin account.',
            actions: <Widget>[
              SizedBox(
                height: 38,
                child: OutlinedButton.icon(
                  key: const Key('admin_account_audit_log_export'),
                  onPressed: canExport ? _exportCsv : null,
                  icon: const Icon(Icons.file_download_outlined, size: 16),
                  label: const Text('Export'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.sunsetDark,
                    disabledForegroundColor: AppColors.textMuted,
                    side: BorderSide(
                      color: canExport
                          ? AppColors.sunsetDark
                          : AppColors.borderSubtle,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          OperatorWebPanel(
            key: const Key('admin_account_audit_log_panel'),
            title: 'Account activity',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final w in _AuditWindow.values)
                      _AuditWindowChip(
                        keyName: 'admin_account_audit_log_filter_${w.filterKey}',
                        label: w.label,
                        selected: w == _window,
                        onTap: () => setState(() => _window = w),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                _buildBody(hasGateway, rows),
                if (_exportToast != null) ...[
                  const SizedBox(height: 12),
                  _AuditConfirmToast(
                    toastKey: const Key('admin_account_audit_log_export_toast'),
                    message: _exportToast!,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(bool hasGateway, List<AdminSecurityAuditEntry> rows) {
    if (!hasGateway) {
      return const _AuditInlineState(
        stateKey: Key('admin_account_audit_log_disconnected'),
        icon: Icons.history,
        message:
            'Your audit log will appear here once your admin account is '
            'connected.',
      );
    }
    if (_loading) {
      return const _AuditInlineState(
        stateKey: Key('admin_account_audit_log_loading'),
        icon: Icons.sync,
        message: 'Loading your audit log...',
      );
    }
    if (_error != null) {
      return Container(
        key: const Key('admin_account_audit_log_error'),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.negative.withValues(alpha: 0.08),
          border: Border.all(
            color: AppColors.negative.withValues(alpha: 0.35),
            width: 1,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.error_outline, size: 16, color: AppColors.negative),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _error!,
                style: AppTextStyles.body13(color: AppColors.negative),
              ),
            ),
            TextButton(
              key: const Key('admin_account_audit_log_retry'),
              onPressed: _loading ? null : _load,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    if (rows.isEmpty) {
      return const _AuditInlineState(
        stateKey: Key('admin_account_audit_log_empty'),
        icon: Icons.history,
        message: 'No account activity in this window.',
      );
    }
    return Column(
      key: const Key('admin_account_audit_log_list'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          _AuditRow(
            entry: rows[i],
            expanded: _expanded.contains(rows[i].eventId),
            onToggle: () => _toggle(rows[i].eventId),
          ),
          if (i != rows.length - 1) const SizedBox(height: 10),
        ],
      ],
    );
  }

  static String _buildCsv(List<AdminSecurityAuditEntry> rows) {
    final buffer = StringBuffer()
      ..writeln('When (UTC),Event,Type,Device,Location');
    for (final r in rows) {
      final location = <String>[
        if (r.geoCity != null && r.geoCity!.isNotEmpty) r.geoCity!,
        if (r.geoCountry != null && r.geoCountry!.isNotEmpty) r.geoCountry!,
      ].join(', ');
      buffer.writeln(
        <String>[
          _formatAuditStamp(r.occurredAt),
          r.friendlyLabel,
          r.eventType,
          r.deviceLabel ?? '',
          location,
        ].map(_csvCell).join(','),
      );
    }
    return buffer.toString();
  }

  static String _csvCell(String value) {
    final needsQuote =
        value.contains(',') || value.contains('"') || value.contains('\n');
    final escaped = value.replaceAll('"', '""');
    return needsQuote ? '"$escaped"' : escaped;
  }
}

class _AuditRow extends StatelessWidget {
  const _AuditRow({
    required this.entry,
    required this.expanded,
    required this.onToggle,
  });

  final AdminSecurityAuditEntry entry;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final location = <String>[
      if (entry.geoCity != null && entry.geoCity!.isNotEmpty) entry.geoCity!,
      if (entry.geoCountry != null && entry.geoCountry!.isNotEmpty)
        entry.geoCountry!,
    ].join(', ');
    final metaParts = <String>[
      _formatAuditStamp(entry.occurredAt),
      if (entry.deviceLabel != null && entry.deviceLabel!.isNotEmpty)
        entry.deviceLabel!,
      if (location.isNotEmpty) location,
    ];
    return Container(
      key: Key('admin_account_audit_log_row_${entry.eventId}'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.history, size: 18, color: AppColors.sunsetDark),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.friendlyLabel,
                      style: AppTextStyles.body13(color: AppColors.textPrimary),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      metaParts.join(' / '),
                      style: AppTextStyles.body12(color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                key: Key('admin_account_audit_log_detail_toggle_${entry.eventId}'),
                onPressed: onToggle,
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.sunsetDark,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: AppTextStyles.mono11(color: AppColors.sunsetDark),
                ),
                child: Text(expanded ? 'Hide detail' : 'View detail'),
              ),
            ],
          ),
          if (expanded) ...[
            const SizedBox(height: 10),
            Container(
              key: Key('admin_account_audit_log_detail_${entry.eventId}'),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.backgroundDeep,
                border: Border.all(color: AppColors.borderSubtle, width: 1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _AuditDetailLine(label: 'Event type', value: entry.eventType),
                  if (entry.deviceLabel != null &&
                      entry.deviceLabel!.isNotEmpty)
                    _AuditDetailLine(
                      label: 'Device',
                      value: entry.deviceLabel!,
                    ),
                  if (entry.userAgent != null && entry.userAgent!.isNotEmpty)
                    _AuditDetailLine(label: 'Browser', value: entry.userAgent!),
                  if (location.isNotEmpty)
                    _AuditDetailLine(label: 'Location', value: location),
                  _AuditDetailLine(
                    label: 'When (UTC)',
                    value: _formatAuditStamp(entry.occurredAt),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AuditDetailLine extends StatelessWidget {
  const _AuditDetailLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTextStyles.mono11(color: AppColors.textMuted)),
          const SizedBox(height: 2),
          SelectableText(
            value,
            style: AppTextStyles.body13(color: AppColors.textPrimary),
          ),
        ],
      ),
    );
  }
}

class _AuditWindowChip extends StatelessWidget {
  const _AuditWindowChip({
    required this.keyName,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String keyName;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      key: Key(keyName),
      label: Text(label),
      selected: selected,
      labelStyle: AppTextStyles.mono11(
        color: selected ? AppColors.sunsetDark : AppColors.textSecondary,
      ),
      selectedColor: AppColors.sunset.withValues(alpha: 0.15),
      backgroundColor: AppColors.backgroundSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
        side: BorderSide(
          color: selected ? AppColors.sunsetDark : AppColors.borderSubtle,
          width: 1,
        ),
      ),
      onSelected: (_) => onTap(),
    );
  }
}

class _AuditInlineState extends StatelessWidget {
  const _AuditInlineState({
    required this.stateKey,
    required this.icon,
    required this.message,
  });

  final Key stateKey;
  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: stateKey,
      children: [
        Icon(icon, size: 16, color: AppColors.textMuted),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
        ),
      ],
    );
  }
}

class _AuditConfirmToast extends StatelessWidget {
  const _AuditConfirmToast({required this.toastKey, required this.message});

  final Key toastKey;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: toastKey,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.positive.withValues(alpha: 0.10),
        border: Border.all(
          color: AppColors.positive.withValues(alpha: 0.45),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.check_circle_outline,
            size: 16,
            color: AppColors.positive,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body13(color: AppColors.positive),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatAuditStamp(DateTime value) {
  final utc = value.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${utc.year}-${two(utc.month)}-${two(utc.day)} '
      '${two(utc.hour)}:${two(utc.minute)} UTC';
}
