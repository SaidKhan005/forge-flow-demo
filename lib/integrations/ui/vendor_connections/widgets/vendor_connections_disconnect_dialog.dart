// Phase 8.0 / Wave C1 — Disconnect-confirmation dialog for the shared
// Vendor Connections widget tree.
//
// Extracted from `vendor_connections_widget.dart` (Wave C1 code-health
// pass). Behavior is byte-stable.

part of '../vendor_connections_widget.dart';

class _DisconnectConfirmDialog extends StatelessWidget {
  const _DisconnectConfirmDialog({required this.row});

  final VendorConnectionRow row;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('vendor_connections_disconnect_dialog'),
      title: Text('Disconnect ${row.displayName}?'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'This only stops the live integration for this location. It does not delete historical Forge & Flow data.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            const _DialogBullet(
              icon: Icons.history_outlined,
              title: 'Historical data stays',
              body: 'Reports keep the data that was already imported.',
            ),
            const _DialogBullet(
              icon: Icons.sync_disabled_outlined,
              title: 'New vendor events stop',
              body: 'Fresh sales, booking, or labor records will stop syncing.',
            ),
            const _DialogBullet(
              icon: Icons.key_off_outlined,
              title: 'Stored credentials are removed',
              body:
                  'Forge & Flow forgets the connection token for this vendor.',
            ),
            const _DialogBullet(
              icon: Icons.restart_alt_outlined,
              title: 'Reconnect later if needed',
              body:
                  'A future reconnect resumes from the latest safe checkpoint.',
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('vendor_connections_disconnect_cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          key: const Key('vendor_connections_disconnect_confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          icon: const Icon(Icons.link_off, size: 16),
          label: const Text('Disconnect vendor'),
        ),
      ],
    );
  }
}
