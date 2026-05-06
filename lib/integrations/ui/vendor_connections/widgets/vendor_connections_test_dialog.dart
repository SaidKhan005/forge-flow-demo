// Phase 8.0 / Wave C1 — Test-connection loading + result dialogs for
// the shared Vendor Connections widget tree.
//
// Extracted from `vendor_connections_widget.dart` (Wave C1 code-health
// pass). Behavior is byte-stable.

part of '../vendor_connections_widget.dart';

class _TestConnectionLoadingDialog extends StatelessWidget {
  const _TestConnectionLoadingDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('vendor_connections_test_loading_dialog'),
      title: const Text('Testing connection'),
      content: SizedBox(
        width: 320,
        child: Row(
          children: [
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                'Checking credentials and pulling a small sample.',
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TestConnectionResultDialog extends StatelessWidget {
  const _TestConnectionResultDialog({required this.row, required this.result});

  final VendorConnectionRow row;
  final VendorTestConnectionResult result;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('vendor_connections_test_result_dialog'),
      title: Text('Connection test: ${row.displayName}'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _DialogStatusRow(
              icon: result.authValid
                  ? Icons.check_circle_outline
                  : Icons.error_outline,
              color: result.authValid ? AppColors.positive : AppColors.negative,
              title: result.authValid
                  ? 'Credentials are working'
                  : 'Credentials need reconnecting',
              body: result.authValid
                  ? 'Forge & Flow can still read from this vendor.'
                  : 'Reconnect this vendor before relying on fresh data.',
            ),
            const SizedBox(height: 10),
            _DialogStatusRow(
              icon: Icons.download_done_outlined,
              color: AppColors.peacockDark,
              title: 'Sample read completed',
              body:
                  'The vendor returned a sample in ${result.elapsedMs}ms so mapping can be checked.',
            ),
            const SizedBox(height: 14),
            Text(
              'Sample from vendor',
              style: AppTextStyles.sectionTitle(color: AppColors.textPrimary),
            ),
            const SizedBox(height: 6),
            _DialogSurface(child: Text(result.sampleSummary)),
            const SizedBox(height: 12),
            Text(
              'Field mapping',
              style: AppTextStyles.sectionTitle(color: AppColors.textPrimary),
            ),
            const SizedBox(height: 6),
            for (final entry in result.fieldMapping.entries)
              _MappingRow(source: entry.key, target: entry.value),
            if (result.note != null) ...<Widget>[
              const SizedBox(height: 8),
              _DialogNotice(
                icon: Icons.info_outline,
                title: 'Note',
                body: result.note!,
                color: AppColors.peacockDark,
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('vendor_connections_test_close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
