// Phase 11A.4 — Integration management admin screen.
//
// F&F internal Integrations surface. Reads the masked-display
// ledger via [IntegrationAdminGateway] and renders one row per
// rotatable provider (Anthropic / Voyage / Azure DB) plus status
// placeholders for vendor connectors (Phase 8), the FX-rate source,
// and the email provider (Phase 9.8).
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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import '../models/integration_admin_models.dart';
import '../services/integration_admin_gateway.dart';

class IntegrationAdminScreen extends StatefulWidget {
  const IntegrationAdminScreen({
    super.key,
    required this.gateway,
    this.editingEnabled = true,
  });

  final IntegrationAdminGateway gateway;

  /// When false, the screen hides every rotate affordance — used for
  /// the `ff_support` walkthrough path. The proxy enforces the same
  /// gate server-side; this flag keeps the UI honest about it.
  final bool editingEnabled;

  @override
  State<IntegrationAdminScreen> createState() =>
      _IntegrationAdminScreenState();
}

class _IntegrationAdminScreenState extends State<IntegrationAdminScreen> {
  bool _loading = true;
  String? _loadError;
  IntegrationBundle? _bundle;
  String? _actionError;
  ProviderKeyKind? _rotatingKind;

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
        title: 'Rotate ${kind.displayName} key?',
        message:
            'A confirmation row will be written to the audit log. The new '
            'plaintext value is shown ONCE in a follow-up modal. Close the '
            'modal and the masked list resumes — there is no second chance '
            'to read the plaintext from this screen.',
        confirmLabel: 'Continue',
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;

    final command = await showDialog<RotateKeyCommand>(
      context: context,
      builder: (_) => _RotatePlaintextDialog(keyKind: kind),
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
      ),
    );
  }

  void _onPlaintextCopied(ProviderKeyKind kind) {
    // Audit-on-copy lands as a separate slice (the proxy does not
    // expose the audit-write endpoint outside rotation). Surface a
    // SnackBar so the operator knows the copy event happened — the
    // real audit hook plugs in here once the audit endpoint lands.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied ${kind.displayName} plaintext to clipboard.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_integrations_screen'),
      color: AppColors.backgroundDeep,
      child: Padding(
        padding: const EdgeInsets.all(20),
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
            Expanded(child: _buildBody()),
          ],
        ),
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
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Provider keys',
                  style: AppTextStyles.mono15(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
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
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Vendor connectors',
                  style: AppTextStyles.mono15(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                if (bundle.vendorConnectors.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      'No vendor connectors configured. Lights up in '
                      'Phase 8.',
                      style: AppTextStyles.body13(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  )
                else
                  ...bundle.vendorConnectors.map(_StatusRowTile.new),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Other integrations',
                  style: AppTextStyles.mono15(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Integrations',
          style: AppTextStyles.display28(color: AppColors.textPrimary),
        ),
        const SizedBox(height: 4),
        Text(
          'Provider key rotation, vendor connector status, FX-rate '
          'source, and email-provider readiness. Plaintext keys are '
          'never displayed after rotation closes.',
          style: AppTextStyles.body13(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

class _ReadOnlyBanner extends StatelessWidget {
  const _ReadOnlyBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.lock_outline,
            size: 16,
            color: AppColors.textMuted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'View-only: rotating provider keys requires the '
              'super_admin role.',
              style: AppTextStyles.mono11(color: AppColors.textSecondary),
            ),
          ),
        ],
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
                  style: AppTextStyles.mono14(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  hasRow
                      ? 'masked: ${row!.maskedValue}'
                      : 'No active credential. Rotate to seed the lane.',
                  key: Key(
                    'admin_integrations_masked_${kind.wireName}',
                  ),
                  style: AppTextStyles.mono11(color: AppColors.textSecondary),
                ),
                if (hasRow) ...[
                  const SizedBox(height: 2),
                  Text(
                    'rotated by ${row!.updatedBy ?? row!.createdBy ?? '—'} '
                    'at ${row!.rotatedAt.toUtc().toIso8601String()}',
                    style: AppTextStyles.mono8(color: AppColors.textMuted),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'kms: ${row!.kmsSecretName}',
                    style: AppTextStyles.mono8(color: AppColors.textMuted),
                  ),
                ],
              ],
            ),
          ),
          if (editingEnabled)
            FilledButton.icon(
              key: Key('admin_integrations_rotate_${kind.wireName}'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.sunset,
                foregroundColor: AppColors.backgroundSurface,
              ),
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
              label: const Text('Rotate'),
            ),
        ],
      ),
    );
  }
}

class _StatusRowTile extends StatelessWidget {
  const _StatusRowTile(this.status);

  final VendorConnectorStatus status;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('admin_integrations_status_${status.id}'),
      margin: const EdgeInsets.only(bottom: 8),
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
                  status.displayName,
                  style: AppTextStyles.mono14(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  status.detailMessage,
                  style: AppTextStyles.mono11(color: AppColors.textSecondary),
                ),
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
              style: AppTextStyles.mono8(color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _RotatePlaintextDialog extends StatefulWidget {
  const _RotatePlaintextDialog({required this.keyKind});

  final ProviderKeyKind keyKind;

  @override
  State<_RotatePlaintextDialog> createState() =>
      _RotatePlaintextDialogState();
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
    return AlertDialog(
      key: const Key('admin_integrations_rotate_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        'Rotate ${widget.keyKind.displayName}',
        style: AppTextStyles.display20(color: AppColors.textPrimary),
      ),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Paste the new plaintext value. The proxy stores only the '
                'masked display and the KMS pointer.',
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('admin_integrations_rotate_plaintext_field'),
                controller: _controller,
                obscureText: _obscured,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'New plaintext value',
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
                    onPressed: () =>
                        setState(() => _obscured = !_obscured),
                  ),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Required';
                  }
                  if (value.trim().length < 9) {
                    return 'Plaintext must be at least 9 characters '
                        'so the masked display has prefix + suffix.';
                  }
                  return null;
                },
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('admin_integrations_rotate_cancel_button'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_integrations_rotate_submit_button'),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.sunset,
            foregroundColor: AppColors.backgroundSurface,
          ),
          onPressed: () {
            if (!(_formKey.currentState?.validate() ?? false)) return;
            Navigator.of(context).pop(
              RotateKeyCommand(
                keyKind: widget.keyKind,
                plaintextValue: _controller.text.trim(),
              ),
            );
          },
          child: const Text('Rotate'),
        ),
      ],
    );
  }
}

class _OneTimeRevealDialog extends StatefulWidget {
  const _OneTimeRevealDialog({
    required this.keyKind,
    required this.plaintextValue,
    required this.onCopied,
  });

  final ProviderKeyKind keyKind;
  final String plaintextValue;
  final void Function(ProviderKeyKind) onCopied;

  @override
  State<_OneTimeRevealDialog> createState() => _OneTimeRevealDialogState();
}

class _OneTimeRevealDialogState extends State<_OneTimeRevealDialog> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('admin_integrations_reveal_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        '${widget.keyKind.displayName} rotated',
        style: AppTextStyles.display20(color: AppColors.textPrimary),
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This is the only time the plaintext value is shown. '
              'Copy it into your KMS / env now — the masked grid '
              'cannot reveal it again.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                color: AppColors.backgroundDeep,
                border:
                    Border.all(color: AppColors.borderSubtle, width: 1),
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
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.sunset,
                    foregroundColor: AppColors.backgroundSurface,
                  ),
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: widget.plaintextValue),
                    );
                    if (!mounted) return;
                    setState(() => _copied = true);
                    widget.onCopied(widget.keyKind);
                  },
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
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('admin_integrations_reveal_close_button'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(16),
      child: child,
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
    return AlertDialog(
      key: const Key('admin_integrations_confirm_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        title,
        style: AppTextStyles.display20(color: AppColors.textPrimary),
      ),
      content: Text(
        message,
        style: AppTextStyles.body13(color: AppColors.textSecondary),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('admin_integrations_confirm_cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_integrations_confirm_ok'),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.sunset,
            foregroundColor: AppColors.backgroundSurface,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}
