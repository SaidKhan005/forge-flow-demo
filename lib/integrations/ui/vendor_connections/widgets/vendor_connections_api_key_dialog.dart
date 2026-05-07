// Phase 8.0 / 8.operator-self-service — API-key paste dialog for the
// shared Vendor Connections widget tree.
//
// Operators connecting an api-key vendor (Toast, Lightspeed LSK, Aloha
// NCR Voyix, Oracle MICROS Simphony, Revel, ADP, Tock, Push Operations,
// Agendrix, SevenRooms, OpenTable) need somewhere to paste the
// credentials they pulled from the vendor portal. The picker resolves
// the vendor; this dialog captures the key + optional secret and hands
// the bundle back to the parent widget which calls
// `VendorConnectionsGateway.connectWithApiKey`.
//
// UX writing standard: vendor-specific labels and help text guide the
// operator to the right page in the vendor portal. Errors render as
// inline form errors so the operator can see exactly which field
// failed and what to do next.

part of '../vendor_connections_widget.dart';

/// Result returned by the api-key paste dialog. `null` means the
/// operator cancelled.
class _VendorApiKeyPasteResult {
  const _VendorApiKeyPasteResult({required this.apiKey, this.apiSecret});

  final String apiKey;
  final String? apiSecret;
}

class _VendorApiKeyPasteDialog extends StatefulWidget {
  const _VendorApiKeyPasteDialog({required this.entry});

  final VendorPickerEntry entry;

  @override
  State<_VendorApiKeyPasteDialog> createState() =>
      _VendorApiKeyPasteDialogState();
}

class _VendorApiKeyPasteDialogState extends State<_VendorApiKeyPasteDialog> {
  late final TextEditingController _apiKeyController;
  late final TextEditingController _apiSecretController;
  late final bool _showsSecretField;

  @override
  void initState() {
    super.initState();
    _apiKeyController = TextEditingController();
    _apiSecretController = TextEditingController();
    _showsSecretField = widget.entry.apiSecretFieldLabel != null;
    _apiKeyController.addListener(_handleChanged);
    _apiSecretController.addListener(_handleChanged);
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _apiSecretController.dispose();
    super.dispose();
  }

  void _handleChanged() {
    if (mounted) setState(() {});
  }

  bool get _canSubmit {
    if (_apiKeyController.text.trim().isEmpty) return false;
    if (_showsSecretField && _apiSecretController.text.trim().isEmpty) {
      return false;
    }
    return true;
  }

  void _onSubmit() {
    if (!_canSubmit) return;
    final apiKey = _apiKeyController.text.trim();
    final apiSecret = _showsSecretField
        ? _apiSecretController.text.trim()
        : null;
    Navigator.of(context).pop(
      _VendorApiKeyPasteResult(apiKey: apiKey, apiSecret: apiSecret),
    );
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final apiKeyLabel = entry.apiKeyFieldLabel ?? 'API key';
    final secretLabel = entry.apiSecretFieldLabel;
    final help = entry.credentialsHelpText;
    final portal = entry.credentialsPortalUrl;
    final viewport = MediaQuery.sizeOf(context);
    final dialogWidth = (viewport.width - 48).clamp(280.0, 520.0).toDouble();

    return AlertDialog(
      key: const Key('vendor_connections_api_key_dialog'),
      title: Text('Connect ${entry.displayName}'),
      content: SizedBox(
        width: dialogWidth,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Paste the credentials ${entry.displayName} issued for this '
                'location. Forge & Flow stores them encrypted and uses them '
                'to read sales, schedule, or reservation data.',
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
              if (help != null) ...<Widget>[
                const SizedBox(height: 12),
                _DialogNotice(
                  icon: Icons.info_outline,
                  title: 'Where to find these',
                  body: help,
                  color: AppColors.peacockDark,
                ),
              ],
              if (portal != null) ...<Widget>[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Vendor portal: ${portal.toString()}',
                    key: const Key(
                      'vendor_connections_api_key_dialog_portal_link',
                    ),
                    style: AppTextStyles.mono11(color: AppColors.textMuted),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              TextField(
                key: const Key('vendor_connections_api_key_field'),
                controller: _apiKeyController,
                autofocus: true,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: apiKeyLabel,
                  helperText: 'Required',
                  border: const OutlineInputBorder(),
                ),
              ),
              if (_showsSecretField) ...<Widget>[
                const SizedBox(height: 12),
                TextField(
                  key: const Key('vendor_connections_api_secret_field'),
                  controller: _apiSecretController,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: secretLabel,
                    helperText: 'Required',
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Text(
                'Forge & Flow stores credentials encrypted at rest. You can '
                'rotate or disconnect them later from this same page.',
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('vendor_connections_api_key_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          key: const Key('vendor_connections_api_key_submit'),
          onPressed: _canSubmit ? _onSubmit : null,
          icon: const Icon(Icons.check, size: 16),
          label: const Text('Connect'),
        ),
      ],
    );
  }
}
