// Phase 11A.4 - Integration management admin screen.
//
// F&F internal Integrations surface. Reads the masked-display
// ledger via [IntegrationAdminGateway] and renders one row per
// rotatable provider (Anthropic / Voyage / Azure DB / Gemini /
// SendGrid) plus status placeholders for vendor connectors
// (Phase 8) and the FX-rate source.
//
// Phase 9.8 extension: SendGrid joins the rotatable provider lanes
// alongside the existing four. The lane lights up automatically
// because the screen iterates `ProviderKeyKind.values` - adding
// `sendgrid` to the enum at `lib/admin/models/integration_admin_models.dart`
// is the only change needed for the visual surface. The rotate
// flow reuses the shared `RotateKeyCommand` pattern so no per-kind
// branching lands here. Demo-mode rotation flows through
// `InMemoryIntegrationAdminGateway`; live-mode rotation extends
// downstream when the SendGrid key path through the proxy lands
// (the `email_credentials` pgcrypto envelope from the migration is
// the production-mode rotation target).
//
// Rotation flow (super_admin only):
//
//   1. Tap "Rotate" → confirmation dialog explains audit visibility.
//   2. Confirm → enter the new plaintext value (paste from KMS / env).
//   3. Submit → proxy hands plaintext to the KMS provider, persists
//      only the masked-display + KMS pointer, returns plaintext ONCE.
//   4. One-time reveal modal echoes the plaintext + Copy button. The
//      modal cannot be reopened; closing it returns to the masked
//      list.
//
// `editingEnabled = false` (ff_support) hides every rotate button
// and renders a read-only banner; the proxy enforces the same gate
// server-side.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forge_and_flow/widgets/console/console_screen_body.dart';
import 'package:forge_and_flow/widgets/console/console_screen_header.dart';
import 'package:forge_and_flow/widgets/console/console_surface.dart';

import '../../theme/app_theme.dart';

import '../admin_button_styles.dart';
import '../admin_console_style.dart';
import '../admin_human_labels.dart';
import '../models/integration_admin_models.dart';
import '../services/integration_admin_gateway.dart';
import '../../integrations/ui/vendor_connections/vendor_connections_models.dart'
    show VendorCategory;

class IntegrationAdminScreen extends StatefulWidget {
  const IntegrationAdminScreen({
    super.key,
    required this.gateway,
    this.editingEnabled = true,
    this.idempotencyKeyFactory,
  });

  final IntegrationAdminGateway gateway;

  /// When false, the screen hides every rotate affordance - used for
  /// the `ff_support` walkthrough path. The proxy enforces the same
  /// gate server-side; this flag keeps the UI honest about it.
  final bool editingEnabled;

  /// Factory for the idempotency key the gateway attaches to each
  /// rotation POST. Production binds this to a UUID-shaped generator;
  /// widget tests inject a deterministic counter so retries can be
  /// asserted.
  final String Function()? idempotencyKeyFactory;

  @override
  State<IntegrationAdminScreen> createState() => _IntegrationAdminScreenState();
}

class _IntegrationAdminScreenState extends State<IntegrationAdminScreen> {
  bool _loading = true;
  String? _loadError;
  IntegrationBundle? _bundle;
  String? _actionError;
  ProviderKeyKind? _rotatingKind;
  int _idempotencyCounter = 0;

  /// Mints a fresh idempotency key per rotation submit so the proxy
  /// dedups in `admin_request_idempotency` - a network-timeout retry
  /// collapses to one KMS write + one audit row.
  String _nextIdempotencyKey() {
    final factory = widget.idempotencyKeyFactory;
    if (factory != null) return factory();
    _idempotencyCounter += 1;
    return 'integration-${DateTime.now().toUtc().microsecondsSinceEpoch}-'
        '$_idempotencyCounter';
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final bundle = await widget.gateway.list();
      if (!mounted) return;
      setState(() {
        _bundle = bundle;
        _loading = false;
      });
    } on IntegrationAdminGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error.message;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Could not load integrations: $error';
        _loading = false;
      });
    }
  }

  Future<void> _onRotateRequested(ProviderKeyKind kind) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _ConfirmDialog(
        title: 'Replace ${kind.displayName} key?',
        message:
            'This change is logged. The new key is shown once; after you close it, only the saved preview remains.',
        confirmLabel: 'Continue',
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;

    final command = await showDialog<RotateKeyCommand>(
      context: context,
      builder: (_) => _RotatePlaintextDialog(
        keyKind: kind,
        idempotencyKey: _nextIdempotencyKey(),
      ),
    );
    if (command == null) return;

    setState(() {
      _rotatingKind = kind;
      _actionError = null;
    });
    RotateKeyResult? result;
    try {
      result = await widget.gateway.rotateKey(command);
    } on IntegrationAdminGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _actionError = error.message;
        _rotatingKind = null;
      });
      return;
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _actionError = error.toString();
        _rotatingKind = null;
      });
      return;
    }
    if (!mounted) return;
    setState(() => _rotatingKind = null);
    await _refresh();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _OneTimeRevealDialog(
        keyKind: kind,
        plaintextValue: result!.plaintextValue,
        onCopied: _onPlaintextCopied,
        onCopyFailed: _onPlaintextCopyFailed,
      ),
    );
  }

  void _showSnackBar(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    try {
      messenger.showSnackBar(SnackBar(content: Text(message)));
    } catch (_) {
      // Some isolated widget harnesses mount the screen without a Scaffold.
      // Browser/runtime copy failures should still be contained.
    }
  }

  void _onPlaintextCopied(ProviderKeyKind kind) {
    // Audit-on-copy lands as a separate slice (the proxy does not
    // expose the audit-write endpoint outside rotation). Surface a
    // SnackBar so the operator knows the copy event happened - the
    // real audit hook plugs in here once the audit endpoint lands.
    _showSnackBar('Copied ${kind.displayName} key to clipboard.');
  }

  void _onPlaintextCopyFailed(ProviderKeyKind kind) {
    _showSnackBar('Could not copy ${kind.displayName} key.');
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_integrations_screen'),
      color: AppColors.backgroundDeep,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            // Pinned header + banners keep operator-web edge insets; the
            // scrollable body below carries its own OperatorWebScreenBody
            // padding so it is not double-padded.
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _Header(),
                const SizedBox(height: 14),
                if (!widget.editingEnabled)
                  const _ReadOnlyBanner(
                    key: Key('admin_integrations_readonly_banner'),
                  ),
                if (_actionError != null)
                  _ErrorBanner(
                    key: const Key('admin_integrations_action_error'),
                    message: _actionError!,
                  ),
              ],
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        key: Key('admin_integrations_loading'),
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.sunsetDark,
          ),
        ),
      );
    }
    if (_loadError != null) {
      return _ErrorBanner(
        key: const Key('admin_integrations_load_error'),
        message: _loadError!,
      );
    }
    final bundle = _bundle;
    if (bundle == null) {
      return const SizedBox.shrink();
    }
    return OperatorWebScreenBody(
      maxContentWidth: AdminConsoleLayout.maxContentWidth,
      padding: AdminConsoleLayout.screenPadding.copyWith(top: 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OperatorWebPanel(
            title: 'Service Access',
            subtitle: 'Platform provider keys. Saved rows show a preview only.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final kind in ProviderKeyKind.values)
                  _ProviderKeyTile(
                    kind: kind,
                    row: _findRow(bundle.providerKeys, kind),
                    editingEnabled: widget.editingEnabled,
                    rotating: _rotatingKind == kind,
                    onRotate: () => _onRotateRequested(kind),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          OperatorWebPanel(
            title: 'Vendor connector catalog',
            subtitle:
                'Global vendor API health. Operator edits stay on Operator Web.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (bundle.vendorConnectors.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      'Integration status will appear here after providers are connected.',
                      style: AppTextStyles.body13(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  )
                else
                  _VendorCatalogGroups(statuses: bundle.vendorConnectors),
              ],
            ),
          ),
          const SizedBox(height: 16),
          OperatorWebPanel(
            title: 'Shared Services',
            subtitle: 'Platform utilities used across operators.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _StatusRowTile(bundle.fxRateSource),
                _StatusRowTile(bundle.emailProvider),
              ],
            ),
          ),
        ],
      ),
    );
  }

  ProviderKeyRow? _findRow(List<ProviderKeyRow> rows, ProviderKeyKind kind) {
    for (final r in rows) {
      if (r.keyKind == kind) return r;
    }
    return null;
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return const OperatorWebScreenHeader(
      icon: Icons.extension_outlined,
      title: 'Connected services',
      subtitle:
          'Review global provider health and platform keys. Operator edits live on Operator Web; this view is for F&F support.',
    );
  }
}

class _ReadOnlyBanner extends StatelessWidget {
  const _ReadOnlyBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(bottom: 12),
      child: OperatorWebBanner(
        icon: Icons.lock_outline,
        message:
            'Operator edits live on Operator Web; this view is for F&F support. Global provider health stays here.',
      ),
    );
  }
}

class _ProviderKeyTile extends StatelessWidget {
  const _ProviderKeyTile({
    required this.kind,
    required this.row,
    required this.editingEnabled,
    required this.rotating,
    required this.onRotate,
  });

  final ProviderKeyKind kind;
  final ProviderKeyRow? row;
  final bool editingEnabled;
  final bool rotating;
  final VoidCallback onRotate;

  @override
  Widget build(BuildContext context) {
    final hasRow = row != null;
    return Container(
      key: Key('admin_integrations_provider_${kind.wireName}'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(
          color: AppColors.borderSubtle.withValues(alpha: 0.6),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  kind.displayName,
                  style: AppTextStyles.body14(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 4),
                Text(
                  hasRow
                      ? 'Saved key: ${row!.maskedValue}'
                      : 'No saved key yet. Use Replace key to add one.',
                  key: Key('admin_integrations_masked_${kind.wireName}'),
                  style: hasRow
                      ? AppTextStyles.mono11(color: AppColors.textSecondary)
                      : AppTextStyles.body13(color: AppColors.textSecondary),
                ),
                if (hasRow) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Last changed by ${row!.updatedBy ?? row!.createdBy ?? 'Unknown'} '
                    'at ${adminHumanDateTime(row!.rotatedAt)}',
                    style: AppTextStyles.mono8(color: AppColors.textMuted),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Stored securely. The full key is hidden after rotation.',
                    style: AppTextStyles.body12(color: AppColors.textMuted),
                  ),
                ],
              ],
            ),
          ),
          if (editingEnabled)
            FilledButton.icon(
              key: Key('admin_integrations_rotate_${kind.wireName}'),
              style: AdminButtonStyles.primary,
              onPressed: rotating ? null : onRotate,
              icon: rotating
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.backgroundSurface,
                      ),
                    )
                  : const Icon(Icons.refresh, size: 14),
              label: const Text('Replace key'),
            ),
        ],
      ),
    );
  }
}

class _VendorCatalogGroups extends StatelessWidget {
  const _VendorCatalogGroups({required this.statuses});

  final List<VendorConnectorStatus> statuses;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (final group in _VendorCatalogGroup.values) {
      final rows = statuses
          .where((status) => _groupForVendor(status) == group)
          .toList(growable: false);
      if (rows.isEmpty) continue;
      if (children.isNotEmpty) children.add(const SizedBox(height: 12));
      children.add(_VendorCatalogGroupBlock(group: group, statuses: rows));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

class _VendorCatalogGroupBlock extends StatelessWidget {
  const _VendorCatalogGroupBlock({required this.group, required this.statuses});

  final _VendorCatalogGroup group;
  final List<VendorConnectorStatus> statuses;

  @override
  Widget build(BuildContext context) {
    final readyCount = statuses.where((status) {
      return status.apiReachable == true ||
          status.statusLabel.toLowerCase().contains('reachable');
    }).length;
    return Container(
      key: Key('admin_integrations_vendor_group_${group.keyName}'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundDeep.withValues(alpha: 0.38),
        border: Border.all(
          color: AppColors.borderSubtle.withValues(alpha: 0.7),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(group.icon, size: 17, color: AppColors.sunsetDark),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  group.label,
                  style: AppTextStyles.body14(
                    color: AppColors.textPrimary,
                  ).copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              _CatalogCountChip(
                label: '$readyCount/${statuses.length} reachable',
              ),
            ],
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 780 ? 2 : 1;
              final gap = columns == 2 ? 10.0 : 0.0;
              final width = columns == 2
                  ? (constraints.maxWidth - gap) / 2
                  : constraints.maxWidth;
              return Wrap(
                spacing: gap,
                runSpacing: 8,
                children: [
                  for (final status in statuses)
                    SizedBox(
                      width: width,
                      child: _StatusRowTile(status, compact: true),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

enum _VendorCatalogGroup {
  pos(keyName: 'pos', label: 'POS', icon: Icons.point_of_sale_outlined),
  labor(keyName: 'labor', label: 'Labor', icon: Icons.badge_outlined),
  reservation(
    keyName: 'reservation',
    label: 'Reservation',
    icon: Icons.event_available_outlined,
  );

  const _VendorCatalogGroup({
    required this.keyName,
    required this.label,
    required this.icon,
  });

  final String keyName;
  final String label;
  final IconData icon;
}

_VendorCatalogGroup _groupForVendor(VendorConnectorStatus status) {
  switch (status.category) {
    case VendorCategory.pos:
      return _VendorCatalogGroup.pos;
    case VendorCategory.labor:
      return _VendorCatalogGroup.labor;
    case VendorCategory.reservation:
      return _VendorCatalogGroup.reservation;
    case null:
      return _fallbackGroupForVendorId(status.id);
  }
}

_VendorCatalogGroup _fallbackGroupForVendorId(String vendorId) {
  switch (vendorId) {
    case 'aloha_ncr_voyix':
    case 'clover':
    case 'lightspeed_lsk':
    case 'oracle_micros_simphony':
    case 'revel':
    case 'square':
    case 'toast':
      return _VendorCatalogGroup.pos;
    case 'adp':
    case 'agendrix':
    case 'humanity':
    case 'push_operations':
    case 'quickbooks_time':
    case 'seven_shifts':
      return _VendorCatalogGroup.labor;
    default:
      return _VendorCatalogGroup.reservation;
  }
}

class _StatusRowTile extends StatelessWidget {
  const _StatusRowTile(this.status, {this.compact = false});

  final VendorConnectorStatus status;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('admin_integrations_status_${status.id}'),
      margin: compact ? EdgeInsets.zero : const EdgeInsets.only(bottom: 8),
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: compact ? 9 : 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(
          color: AppColors.borderSubtle.withValues(alpha: 0.6),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: compact
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  status.displayName,
                  style: AppTextStyles.body14(color: AppColors.textPrimary),
                ),
                if (!compact && status.detailMessage.trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    status.detailMessage,
                    style: AppTextStyles.body13(color: AppColors.textSecondary),
                  ),
                ],
                if (status.healthSourceLabel != null ||
                    status.unlockLabel != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    compact
                        ? _compactSemanticsLine(status)
                        : _semanticsLine(status),
                    maxLines: compact ? 1 : null,
                    overflow: compact ? TextOverflow.ellipsis : null,
                    style: compact
                        ? AppTextStyles.body12(color: AppColors.textMuted)
                        : AppTextStyles.mono8(color: AppColors.textMuted),
                  ),
                ],
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.backgroundDeep,
              border: Border.all(color: AppColors.borderSubtle, width: 1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              status.statusLabel,
              style: AppTextStyles.chipLabel(color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  String _semanticsLine(VendorConnectorStatus status) {
    final parts = <String>[
      if (status.healthSourceLabel != null)
        'Source: ${status.healthSourceLabel}',
      if (status.unlockLabel != null) 'Setup: ${status.unlockLabel}',
    ];
    return parts.join(' - ');
  }

  String _compactSemanticsLine(VendorConnectorStatus status) {
    final setup = status.unlockLabel;
    if (setup != null && setup.trim().isNotEmpty) return setup;
    final source = status.healthSourceLabel;
    if (source != null && source.trim().isNotEmpty) return source;
    return status.detailMessage;
  }
}

class _CatalogCountChip extends StatelessWidget {
  const _CatalogCountChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: AppTextStyles.mono10(color: AppColors.textMuted),
      ),
    );
  }
}

class _RotatePlaintextDialog extends StatefulWidget {
  const _RotatePlaintextDialog({
    required this.keyKind,
    required this.idempotencyKey,
  });

  final ProviderKeyKind keyKind;

  /// Per-action idempotency key minted by the screen.
  final String idempotencyKey;

  @override
  State<_RotatePlaintextDialog> createState() => _RotatePlaintextDialogState();
}

class _RotatePlaintextDialogState extends State<_RotatePlaintextDialog> {
  final _controller = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _obscured = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return OperatorWebDialog(
      key: const Key('admin_integrations_rotate_dialog'),
      title: 'Replace ${widget.keyKind.displayName} key',
      showCloseButton: false,
      actions: <Widget>[
        TextButton(
          key: const Key('admin_integrations_rotate_cancel_button'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_integrations_rotate_submit_button'),
          style: AdminButtonStyles.primary,
          onPressed: () {
            if (!(_formKey.currentState?.validate() ?? false)) return;
            Navigator.of(context).pop(
              RotateKeyCommand(
                keyKind: widget.keyKind,
                plaintextValue: _controller.text.trim(),
                idempotencyKey: widget.idempotencyKey,
              ),
            );
          },
          child: const Text('Save key'),
        ),
      ],
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Paste the new key. Only the saved preview is shown after rotation.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('admin_integrations_rotate_plaintext_field'),
              controller: _controller,
              obscureText: _obscured,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'New key',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(
                    color: AppColors.borderSubtle,
                    width: 1,
                  ),
                ),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscured
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    size: 18,
                  ),
                  onPressed: () => setState(() => _obscured = !_obscured),
                ),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Required';
                }
                if (value.trim().length < 9) {
                  return 'Key must be at least 9 characters.';
                }
                return null;
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _OneTimeRevealDialog extends StatefulWidget {
  const _OneTimeRevealDialog({
    required this.keyKind,
    required this.plaintextValue,
    required this.onCopied,
    required this.onCopyFailed,
  });

  final ProviderKeyKind keyKind;
  final String plaintextValue;
  final void Function(ProviderKeyKind) onCopied;
  final void Function(ProviderKeyKind) onCopyFailed;

  @override
  State<_OneTimeRevealDialog> createState() => _OneTimeRevealDialogState();
}

class _OneTimeRevealDialogState extends State<_OneTimeRevealDialog> {
  bool _copied = false;

  Future<void> _copyPlaintext() async {
    if (kIsWeb) {
      widget.onCopyFailed(widget.keyKind);
      return;
    }
    try {
      await Clipboard.setData(ClipboardData(text: widget.plaintextValue));
    } catch (_) {
      if (!mounted) return;
      widget.onCopyFailed(widget.keyKind);
      return;
    }
    if (!mounted) return;
    setState(() => _copied = true);
    widget.onCopied(widget.keyKind);
  }

  @override
  Widget build(BuildContext context) {
    return OperatorWebDialog(
      key: const Key('admin_integrations_reveal_dialog'),
      title: '${widget.keyKind.displayName} key saved',
      showCloseButton: false,
      actions: <Widget>[
        TextButton(
          key: const Key('admin_integrations_reveal_close_button'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This is the only time this key is shown. Store it now; the console cannot reveal it again.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.backgroundDeep,
              border: Border.all(color: AppColors.borderSubtle, width: 1),
              borderRadius: BorderRadius.circular(6),
            ),
            child: SelectableText(
              widget.plaintextValue,
              key: const Key('admin_integrations_reveal_plaintext'),
              style: AppTextStyles.mono14(color: AppColors.textPrimary),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              FilledButton.icon(
                key: const Key('admin_integrations_reveal_copy_button'),
                style: AdminButtonStyles.primary,
                onPressed: _copyPlaintext,
                icon: Icon(
                  _copied ? Icons.check : Icons.content_copy,
                  size: 14,
                ),
                label: Text(_copied ? 'Copied' : 'Copy'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: OperatorWebBanner(
        tone: OperatorWebBannerTone.error,
        message: message,
      ),
    );
  }
}

class _ConfirmDialog extends StatelessWidget {
  const _ConfirmDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
  });

  final String title;
  final String message;
  final String confirmLabel;

  @override
  Widget build(BuildContext context) {
    return OperatorWebDialog(
      key: const Key('admin_integrations_confirm_dialog'),
      title: title,
      showCloseButton: false,
      actions: <Widget>[
        TextButton(
          key: const Key('admin_integrations_confirm_cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_integrations_confirm_ok'),
          style: AdminButtonStyles.primary,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
      child: Text(
        message,
        style: AppTextStyles.body13(color: AppColors.textSecondary),
      ),
    );
  }
}
