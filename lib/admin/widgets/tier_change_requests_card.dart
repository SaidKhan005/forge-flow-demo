import 'package:flutter/material.dart';

import '../../domain/models/forge_flow_polling_tier_assignment.dart';
import '../../theme/app_theme.dart';
import '../admin_button_styles.dart';
import '../admin_human_labels.dart';
import '../services/data_accuracy_admin_gateway.dart';
import 'admin_responsive_layout.dart';

class TierChangeRequestsCard extends StatelessWidget {
  const TierChangeRequestsCard({
    super.key,
    required this.requests,
    required this.editingEnabled,
    required this.onResolve,
  });

  final List<TierChangeRequest> requests;
  final bool editingEnabled;
  final void Function(
    TierChangeRequest request,
    TierChangeRequestStatus newStatus,
  )
  onResolve;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_tier_change_requests_card'),
      child: AdminCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Tier change requests',
              style: AppTextStyles.sectionTitle(color: AppColors.textPrimary),
            ),
            const SizedBox(height: 12),
            if (requests.isEmpty)
              Text(
                'No requests.',
                style: AppTextStyles.body13(color: AppColors.textMuted),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: requests.length,
                separatorBuilder: (_, __) =>
                    const Divider(color: AppColors.borderSubtle, height: 16),
                itemBuilder: (context, index) => _RequestRow(
                  request: requests[index],
                  editingEnabled: editingEnabled,
                  onResolve: onResolve,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RequestRow extends StatelessWidget {
  const _RequestRow({
    required this.request,
    required this.editingEnabled,
    required this.onResolve,
  });

  final TierChangeRequest request;
  final bool editingEnabled;
  final void Function(
    TierChangeRequest request,
    TierChangeRequestStatus newStatus,
  )
  onResolve;

  @override
  Widget build(BuildContext context) {
    final isPending = request.status == TierChangeRequestStatus.pending;
    return Container(
      key: Key('admin_tier_change_request_${request.requestId}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  '${request.operatorRef.businessName} • '
                  '${request.operatorRef.locationName}',
                  style: AppTextStyles.mono14(color: AppColors.textPrimary),
                ),
              ),
              _StatusBadge(status: request.status),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Tier change: ${request.currentTier.wire} → ${request.requestedTier.wire}',
            style: AppTextStyles.body13(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 4),
          Text(
            'Reason: ${request.operatorNote.isEmpty ? '-' : request.operatorNote}',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 4),
          Text(
            'Submitted ${adminHumanDateTime(request.submittedAt)}',
            style: AppTextStyles.mono11(color: AppColors.textMuted),
          ),
          const SizedBox(height: 8),
          if (isPending && editingEnabled)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  key: Key(
                    'admin_tier_change_request_approve_${request.requestId}',
                  ),
                  style: AdminButtonStyles.approval(selected: false),
                  onPressed: () =>
                      onResolve(request, TierChangeRequestStatus.approved),
                  child: const Text('Approve'),
                ),
                OutlinedButton(
                  key: Key(
                    'admin_tier_change_request_deny_${request.requestId}',
                  ),
                  style: AdminButtonStyles.reject(selected: false),
                  onPressed: () =>
                      onResolve(request, TierChangeRequestStatus.denied),
                  child: const Text('Deny'),
                ),
                OutlinedButton(
                  key: Key(
                    'admin_tier_change_request_negotiate_${request.requestId}',
                  ),
                  style: AdminButtonStyles.secondary(
                    minWidth: 140,
                    minHeight: 36,
                  ),
                  onPressed: () =>
                      onResolve(request, TierChangeRequestStatus.negotiating),
                  child: const Text('Open negotiation'),
                ),
              ],
            )
          else if (!isPending)
            Text(
              'Resolved as ${request.status.wire}.',
              style: AppTextStyles.body12(color: AppColors.textMuted),
            ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final TierChangeRequestStatus status;

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color fg;
    switch (status) {
      case TierChangeRequestStatus.pending:
        bg = AppColors.warningBadgeBg;
        fg = AppColors.warning;
        break;
      case TierChangeRequestStatus.approved:
        bg = AppColors.positive.withValues(alpha: 0.15);
        fg = AppColors.positive;
        break;
      case TierChangeRequestStatus.denied:
        bg = AppColors.negative.withValues(alpha: 0.15);
        fg = AppColors.negative;
        break;
      case TierChangeRequestStatus.negotiating:
        bg = AppColors.sunset.withValues(alpha: 0.15);
        fg = AppColors.sunsetDark;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(status.wire, style: AppTextStyles.chipLabel(color: fg)),
    );
  }
}
