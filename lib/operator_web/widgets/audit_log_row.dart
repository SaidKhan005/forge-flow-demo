// Phase 11W.5 - Operator Web audit log row widget.
//
// One audit_logs row, rendered per the parity contract `§ Audit Log`
// row shape:
//
//   * created_at    in operator-local timezone (per
//                   phase_7_55_time_boundary_contract.md)
//   * actor         display_name + email + actor_kind chip
//   * action        humanized via WebAuditLogActionLabels.labelFor
//                   (e.g. team.users.invite -> "Invited team member")
//   * target        target_kind + target_id with a copy-to-clipboard
//                   button so support tickets can paste the id into
//                   a search box without retyping it
//   * View payload  collapsed JSONB pretty-printed; expands inline
//
// admin_reason renders inline only when actor_kind = forge_admin
// (the F&F admin path populates it; self-service rows leave it null).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/web_team_audit_log_gateway.dart';
import '../../theme/app_theme.dart';

/// A single audit_logs row. The screen passes [expanded] +
/// [onTogglePayload] so multiple rows can stay collapsed/expanded
/// independently while the screen owns the expansion state.
class AuditLogRow extends StatelessWidget {
  const AuditLogRow({
    super.key,
    required this.entry,
    required this.expanded,
    required this.onTogglePayload,
    this.onCopyTargetId,
  });

  final WebAuditLogEntry entry;
  final bool expanded;
  final VoidCallback onTogglePayload;

  /// Optional override so tests can pin clipboard writes without
  /// reaching into the platform plugin. Defaults to
  /// `Clipboard.setData(ClipboardData(text: entry.targetId))`.
  final Future<void> Function(String value)? onCopyTargetId;

  @override
  Widget build(BuildContext context) {
    final action = WebAuditLogActionLabels.labelFor(entry.action);
    final timestamp = _formatLocal(entry.createdAt);
    return Container(
      key: Key('operator_web_audit_log_row_${entry.entryId}'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: 160,
                child: Text(
                  timestamp,
                  style: AppTextStyles.mono11(color: AppColors.textMuted),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            action,
                            style: AppTextStyles.mono12(
                              color: AppColors.textPrimary,
                              weight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _ActorKindChip(kind: entry.actorKind),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _actorLine(entry),
                      style: AppTextStyles.body12(color: AppColors.textMuted),
                    ),
                    if (entry.targetId != null) ...[
                      const SizedBox(height: 4),
                      _TargetRow(
                        targetKind: entry.targetKind,
                        targetId: entry.targetId!,
                        rowKey: entry.entryId,
                        onCopy: onCopyTargetId ?? _defaultCopy,
                      ),
                    ],
                    if (entry.adminReason != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Admin reason: ${entry.adminReason}',
                        style: AppTextStyles.body12(
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                key: Key(
                  'operator_web_audit_log_row_${entry.entryId}_payload_toggle',
                ),
                onPressed: onTogglePayload,
                style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: const Size(0, 0),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
                child: Text(
                  expanded ? 'Hide payload' : 'View payload',
                  style: AppTextStyles.mono11(color: AppColors.sunsetDark),
                ),
              ),
            ],
          ),
          if (expanded) ...[
            const SizedBox(height: 8),
            Container(
              key: Key(
                'operator_web_audit_log_row_${entry.entryId}_payload',
              ),
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.backgroundMid,
                border: Border.all(color: AppColors.borderSubtle),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _formatPayload(entry.payload),
                style: AppTextStyles.mono10(color: AppColors.textPrimary),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _formatLocal(DateTime utc) {
    final local = utc.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm';
  }

  static String _actorLine(WebAuditLogEntry entry) {
    final name = entry.actorDisplayName ?? entry.actorEmail ?? 'Unknown actor';
    final email = entry.actorEmail;
    if (email == null || email == name) return name;
    return '$name • $email';
  }

  static String _formatPayload(Map<String, Object?> payload) {
    if (payload.isEmpty) return '(no payload)';
    try {
      const encoder = JsonEncoder.withIndent('  ');
      return encoder.convert(payload);
    } catch (_) {
      return payload.toString();
    }
  }

  static Future<void> _defaultCopy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
  }
}

class _ActorKindChip extends StatelessWidget {
  const _ActorKindChip({required this.kind});

  final WebAuditLogActorKind kind;

  @override
  Widget build(BuildContext context) {
    final (label, fg, bg) = _styleFor(kind);
    return Container(
      key: Key('operator_web_audit_log_actor_kind_${webAuditLogActorKindWire(kind)}'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: fg.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Text(
        label,
        style: AppTextStyles.mono7(color: fg),
      ),
    );
  }

  static (String, Color, Color) _styleFor(WebAuditLogActorKind kind) {
    switch (kind) {
      case WebAuditLogActorKind.teamMember:
        return (
          'team',
          AppColors.sunsetDark,
          AppColors.sunset.withValues(alpha: 0.15),
        );
      case WebAuditLogActorKind.forgeAdmin:
        return (
          'F&F admin',
          AppColors.negative,
          AppColors.negative.withValues(alpha: 0.15),
        );
      case WebAuditLogActorKind.servicePrincipal:
        return (
          'service',
          AppColors.textSecondary,
          AppColors.borderSubtle.withValues(alpha: 0.5),
        );
    }
  }
}

class _TargetRow extends StatelessWidget {
  const _TargetRow({
    required this.targetKind,
    required this.targetId,
    required this.rowKey,
    required this.onCopy,
  });

  final String? targetKind;
  final String targetId;
  final String rowKey;
  final Future<void> Function(String value) onCopy;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        if (targetKind != null) ...[
          Text(
            '$targetKind:',
            style: AppTextStyles.body12(color: AppColors.textMuted),
          ),
          const SizedBox(width: 6),
        ],
        Flexible(
          child: Text(
            targetId,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.mono11(color: AppColors.textPrimary),
          ),
        ),
        const SizedBox(width: 6),
        InkWell(
          key: Key('operator_web_audit_log_row_${rowKey}_copy_target'),
          onTap: () async {
            await onCopy(targetId);
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Copied $targetId to clipboard.'),
                duration: const Duration(seconds: 2),
              ),
            );
          },
          borderRadius: BorderRadius.circular(2),
          child: const Padding(
            padding: EdgeInsets.all(2),
            child: Icon(
              Icons.copy_rounded,
              size: 14,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}
