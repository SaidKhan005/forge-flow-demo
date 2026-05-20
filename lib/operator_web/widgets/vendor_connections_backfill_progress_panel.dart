// Wave W2.D — Vendor Connections per-connection backfill progress panel.
//
// Operator-web-only chrome that sits inside the Vendor Connections
// screen, alongside the shared `VendorConnectionsWidget`. The shared
// widget renders the per-vendor cards; this panel surfaces the state
// of the bounded 60-day first-backfill job per connection so the
// operator sees something honest after they connect a vendor and the
// proxy enqueues the worker.
//
// Plain-English states (Doc 1):
//
//   * setting up        — `pending`, no claim yet.
//   * backfill running  — `running` and the worker has claimed.
//   * backfill complete — `succeeded`.
//   * backfill failed   — `failed` with retries remaining.
//   * dead-lettered     — `dead_lettered` (worker exhausted retries
//                         and surfaced for support).
//
// The panel renders rows imported / target days (the bounded 60-day
// window) plus the cursor watermark (most recent business date the
// worker advanced past). Retry button reads as disabled with a
// "Contact support" tooltip until a dedicated retry route ships.
//
// UX writing standard (per `memory/project_ux_writing_standard.md`):
// every row reads as if training the operator. Empty / loading /
// stale / permission-denied states never blank — the panel always
// renders honest copy explaining why nothing is showing.

import 'package:flutter/material.dart';

import '../services/operator_web_connector_backfill_jobs_gateway.dart';
import '../../theme/app_theme.dart';
import 'operator_web_section_heading.dart';

/// Panel state machine — drives the rendered surface based on the
/// gateway response (or absence of gateway).
enum _BackfillProgressPanelState {
  /// No gateway wired. Demo mode falls here; the panel renders an
  /// honest "progress not available" line so the operator sees the
  /// real state without a fixture lying about progress.
  notWired,
  loading,
  empty,
  hasJobs,
  failed,
}

/// Per-connection backfill progress panel. The operator-web Vendor
/// Connections screen mounts one of these alongside the shared
/// [`VendorConnectionsWidget`]; the panel reads the new
/// `connector_backfill_jobs` proxy route and renders one row per
/// connection.
class VendorConnectionsBackfillProgressPanel extends StatefulWidget {
  const VendorConnectionsBackfillProgressPanel({
    super.key,
    required this.gateway,
  });

  /// Live operator-web gateway. Null in demo mode and during early
  /// wiring; the panel renders honest "not wired" copy in that case.
  final OperatorWebConnectorBackfillJobsGateway? gateway;

  @override
  State<VendorConnectionsBackfillProgressPanel> createState() =>
      _VendorConnectionsBackfillProgressPanelState();
}

class _VendorConnectionsBackfillProgressPanelState
    extends State<VendorConnectionsBackfillProgressPanel> {
  _BackfillProgressPanelState _state = _BackfillProgressPanelState.loading;
  String? _errorMessage;
  List<OperatorWebConnectorBackfillJob> _jobs =
      const <OperatorWebConnectorBackfillJob>[];
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(
    covariant VendorConnectionsBackfillProgressPanel oldWidget,
  ) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gateway != widget.gateway) {
      _refresh();
    }
  }

  Future<void> _refresh() async {
    final gateway = widget.gateway;
    if (gateway == null) {
      setState(() {
        _state = _BackfillProgressPanelState.notWired;
        _jobs = const <OperatorWebConnectorBackfillJob>[];
        _errorMessage = null;
      });
      return;
    }
    final generation = ++_loadGeneration;
    setState(() {
      _state = _BackfillProgressPanelState.loading;
      _errorMessage = null;
    });
    try {
      final bundle = await gateway.loadJobs();
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _jobs = bundle.jobs;
        _state = bundle.jobs.isEmpty
            ? _BackfillProgressPanelState.empty
            : _BackfillProgressPanelState.hasJobs;
      });
    } on OperatorWebConnectorBackfillJobsError catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _state = _BackfillProgressPanelState.failed;
        _errorMessage = error.message;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _state = _BackfillProgressPanelState.failed;
        _errorMessage = 'Could not load backfill progress ($error).';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('vendor_connections_backfill_progress_panel'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const OperatorWebSectionHeading(title: '60 day benchmark data'),
          const SizedBox(height: 10),
          Text(
            'Forge & Flow imports the last 60 days of history from each '
            'connection so dashboards have real numbers to show.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 10),
          _buildBody(),
        ],
      ),
    );
  }

  Widget _buildBody() {
    switch (_state) {
      case _BackfillProgressPanelState.notWired:
        return Padding(
          key: const Key(
            'vendor_connections_backfill_progress_panel_not_wired',
          ),
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            'Backfill progress is not available in this view yet. Once '
            'a vendor is connected here, this panel will show the import '
            'state per connection.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
        );
      case _BackfillProgressPanelState.loading:
        return const Padding(
          key: Key('vendor_connections_backfill_progress_panel_loading'),
          padding: EdgeInsets.symmetric(vertical: 8),
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      case _BackfillProgressPanelState.empty:
        return Padding(
          key: const Key('vendor_connections_backfill_progress_panel_empty'),
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            'No backfill jobs yet. Connect a vendor and Forge & Flow '
            'will begin importing the last 60 days.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
        );
      case _BackfillProgressPanelState.failed:
        return Padding(
          key: const Key('vendor_connections_backfill_progress_panel_failed'),
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            _errorMessage ??
                'Backfill progress is temporarily unavailable; please retry.',
            style: AppTextStyles.body13(color: AppColors.negative),
          ),
        );
      case _BackfillProgressPanelState.hasJobs:
        return Column(
          key: const Key('vendor_connections_backfill_progress_panel_has_jobs'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final job in _jobs)
              Padding(
                key: ValueKey<String>(
                  'vendor_connections_backfill_progress_row_${job.connectionId}',
                ),
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: _BackfillProgressRow(job: job),
              ),
          ],
        );
    }
  }
}

/// Status the panel surfaces. Wire status maps to one of these values
/// via [_resolveStatusKind] so a future server-side `dead_lettered`
/// status renders honestly without a wire bump on the panel.
enum _BackfillStatusKind {
  settingUp,
  running,
  complete,
  failed,
  deadLettered,
  unknown,
}

class _BackfillProgressRow extends StatelessWidget {
  const _BackfillProgressRow({required this.job});

  final OperatorWebConnectorBackfillJob job;

  @override
  Widget build(BuildContext context) {
    final kind = _resolveStatusKind(job.status);
    final label = _statusLabel(kind);
    final color = _statusColor(kind);
    final isFailure =
        kind == _BackfillStatusKind.failed ||
        kind == _BackfillStatusKind.deadLettered;
    final progressBar = _resolveProgressFraction(job, kind);
    final cursorLabel = _resolveCursorLabel(job);
    final attemptLabel = job.attemptCount > 0
        ? 'Attempts: ${job.attemptCount}'
        : null;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${_humanizeVendor(job.vendorId)} '
                  '· ${_humanizeCategory(job.category)}',
                  style: AppTextStyles.body13(color: AppColors.textPrimary),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  border: Border.all(color: color.withValues(alpha: 0.4)),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  label,
                  key: ValueKey<String>(
                    'vendor_connections_backfill_progress_status_'
                    '${job.connectionId}',
                  ),
                  style: AppTextStyles.mono11(color: color),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              key: ValueKey<String>(
                'vendor_connections_backfill_progress_bar_'
                '${job.connectionId}',
              ),
              value: progressBar,
              minHeight: 6,
              backgroundColor: AppColors.shimmer,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Window: ${_dateOnly(job.windowStart)} → '
            '${_dateOnly(job.windowEnd)} (${_targetDayCount(job)} days)',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          if (cursorLabel != null) ...[
            const SizedBox(height: 2),
            Text(
              'Latest business date imported: $cursorLabel',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          ],
          if (attemptLabel != null) ...[
            const SizedBox(height: 2),
            Text(
              attemptLabel,
              style: AppTextStyles.mono11(color: AppColors.textMuted),
            ),
          ],
          if (isFailure && job.lastError != null) ...[
            const SizedBox(height: 4),
            Text(
              job.lastError!,
              key: ValueKey<String>(
                'vendor_connections_backfill_progress_error_'
                '${job.connectionId}',
              ),
              style: AppTextStyles.body13(color: AppColors.negative),
            ),
          ],
          if (isFailure) ...[
            const SizedBox(height: 6),
            // Retry route is a planned follow-up; surface a disabled
            // button with an honest tooltip rather than building the
            // route in this lane.
            Tooltip(
              message:
                  'Retry is not wired yet. Contact Forge & Flow support to '
                  'requeue this connection.',
              child: ElevatedButton(
                key: ValueKey<String>(
                  'vendor_connections_backfill_progress_retry_'
                  '${job.connectionId}',
                ),
                onPressed: null,
                child: const Text('Retry backfill'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

_BackfillStatusKind _resolveStatusKind(String wireStatus) {
  switch (wireStatus) {
    case 'pending':
      return _BackfillStatusKind.settingUp;
    case 'running':
      return _BackfillStatusKind.running;
    case 'succeeded':
      return _BackfillStatusKind.complete;
    case 'failed':
      return _BackfillStatusKind.failed;
    case 'dead_lettered':
    case 'dead-lettered':
      return _BackfillStatusKind.deadLettered;
  }
  return _BackfillStatusKind.unknown;
}

String _statusLabel(_BackfillStatusKind kind) {
  switch (kind) {
    case _BackfillStatusKind.settingUp:
      return 'Setting up';
    case _BackfillStatusKind.running:
      return 'Backfill running';
    case _BackfillStatusKind.complete:
      return 'Backfill complete';
    case _BackfillStatusKind.failed:
      return 'Backfill failed';
    case _BackfillStatusKind.deadLettered:
      return 'Dead-lettered';
    case _BackfillStatusKind.unknown:
      return 'Status unknown';
  }
}

Color _statusColor(_BackfillStatusKind kind) {
  switch (kind) {
    case _BackfillStatusKind.settingUp:
      return AppColors.textSecondary;
    case _BackfillStatusKind.running:
      return AppColors.sunsetDark;
    case _BackfillStatusKind.complete:
      return AppColors.positive;
    case _BackfillStatusKind.failed:
    case _BackfillStatusKind.deadLettered:
      return AppColors.negative;
    case _BackfillStatusKind.unknown:
      return AppColors.warning;
  }
}

double? _resolveProgressFraction(
  OperatorWebConnectorBackfillJob job,
  _BackfillStatusKind kind,
) {
  if (kind == _BackfillStatusKind.complete) return 1.0;
  if (kind == _BackfillStatusKind.failed ||
      kind == _BackfillStatusKind.deadLettered) {
    return 1.0;
  }
  if (kind == _BackfillStatusKind.settingUp) return 0.0;
  // Running with no cursor yet — render indeterminate (null).
  final cursor = job.lastModifiedSeen;
  if (cursor == null) return null;
  final totalMs = job.windowEnd
      .difference(job.windowStart)
      .inMilliseconds
      .toDouble();
  if (totalMs <= 0) return null;
  final processedMs = cursor
      .difference(job.windowStart)
      .inMilliseconds
      .toDouble();
  if (processedMs.isNaN) return null;
  final fraction = processedMs / totalMs;
  if (fraction.isNaN || fraction.isInfinite) return null;
  if (fraction <= 0) return 0.0;
  if (fraction >= 1) return 1.0;
  return fraction;
}

String? _resolveCursorLabel(OperatorWebConnectorBackfillJob job) {
  final cursor = job.lastModifiedSeen;
  if (cursor == null) return null;
  return _dateOnly(cursor);
}

String _dateOnly(DateTime value) {
  final utc = value.toUtc();
  final y = utc.year.toString().padLeft(4, '0');
  final m = utc.month.toString().padLeft(2, '0');
  final d = utc.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

int _targetDayCount(OperatorWebConnectorBackfillJob job) {
  final delta = job.windowEnd.difference(job.windowStart).inHours;
  if (delta <= 0) return 0;
  return (delta / 24).ceil();
}

String _humanizeVendor(String vendorId) {
  if (vendorId.isEmpty) return 'Vendor';
  return vendorId
      .split('_')
      .map((part) {
        if (part.isEmpty) return part;
        return part.substring(0, 1).toUpperCase() + part.substring(1);
      })
      .join(' ');
}

String _humanizeCategory(String category) {
  switch (category) {
    case 'pos':
      return 'Point-of-sale';
    case 'labor':
      return 'Labor';
    case 'reservation':
      return 'Reservations';
  }
  return category;
}
