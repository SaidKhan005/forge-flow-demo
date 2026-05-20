// Wave 2 W-5 — Business logo upload section.
//
// Drops into the Business identity card on the operator-web Business
// Account screen. The existing card already accepts a pasted https
// URL; this section sits beside it and offers a real file upload UX
// for operators who would rather pick a PNG from their machine.
//
// Flow:
//   1. Operator clicks "Choose PNG". The web file picker
//      (`business_logo_file_picker.dart`) returns bytes + filename.
//   2. The widget runs client-side validation (extension + size +
//      PNG magic). Failures render an inline error.
//   3. On click of "Upload", the gateway POSTs the file to the
//      proxy. The returned URL is handed back to the parent via
//      [onUploaded] — the parent writes it into the existing
//      `logoUrl` text controller so the next "Save business
//      account" persists the new URL.
//
// The section never persists on its own. The PATCH /v1/operator/
// account call inside the parent screen is the single source of
// truth for the operator row.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../services/business_logo_file_picker.dart';
import '../services/business_logo_upload_gateway.dart';
import '../services/operator_web_proxy_client.dart';

/// Test-only override for the file picker. When null the section
/// falls back to the conditional-imported web picker. Widget tests
/// drive the upload through a synthetic [PickedBusinessLogoFile]
/// without bringing up `dart:html`.
typedef BusinessLogoFilePickerFn = Future<PickedBusinessLogoFile?> Function();

class BusinessLogoUploadSection extends StatefulWidget {
  const BusinessLogoUploadSection({
    super.key,
    required this.gateway,
    required this.enabled,
    required this.onUploaded,
    this.disabledReason,
    this.filePicker,
  });

  /// Live upload gateway. When null the section renders an explainer
  /// banner instead of the upload button so the operator still sees
  /// "the URL paste still works" wording.
  final BusinessLogoUploadGateway? gateway;

  /// Disabled when the parent screen is submitting or the operator
  /// lacks edit permission.
  final bool enabled;

  /// Optional plain-English reason shown when the parent disables this
  /// control for a product rule, for example when logo edits belong
  /// at Business scope while the operator is viewing a Location.
  final String? disabledReason;

  /// Fires when the upload succeeds. The parent writes [logoUrl]
  /// into its existing controller so PATCH /v1/operator/account
  /// commits the new URL.
  final ValueChanged<String> onUploaded;

  /// Test-only file picker. Widget tests pass a stub that returns a
  /// canned [PickedBusinessLogoFile]; production leaves this null
  /// and the section uses [pickBusinessLogoFile].
  @visibleForTesting
  final BusinessLogoFilePickerFn? filePicker;

  @override
  State<BusinessLogoUploadSection> createState() =>
      _BusinessLogoUploadSectionState();
}

class _BusinessLogoUploadSectionState extends State<BusinessLogoUploadSection> {
  PickedBusinessLogoFile? _picked;
  String? _errorMessage;
  String? _successMessage;
  bool _uploading = false;

  Future<void> _handlePick() async {
    if (!widget.enabled || _uploading) return;
    setState(() {
      _errorMessage = null;
      _successMessage = null;
    });
    final picker = widget.filePicker ?? pickBusinessLogoFile;
    PickedBusinessLogoFile? picked;
    try {
      picked = await picker();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Could not open the file picker: $error';
      });
      return;
    }
    if (!mounted || picked == null) return;
    setState(() {
      _picked = picked;
    });
  }

  Future<void> _handleUpload() async {
    final gateway = widget.gateway;
    final picked = _picked;
    if (gateway == null || picked == null || _uploading) return;
    setState(() {
      _uploading = true;
      _errorMessage = null;
      _successMessage = null;
    });
    try {
      final outcome = await gateway.uploadLogo(
        pngBytes: picked.bytes,
        filename: picked.filename,
      );
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _successMessage =
            'Logo uploaded. Click "Save business account" to make it live.';
      });
      widget.onUploaded(outcome.logoUrl);
    } on BusinessLogoValidationException catch (failure) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _errorMessage = failure.message;
      });
    } on OperatorWebProxyException catch (failure) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _errorMessage = failure.message;
      });
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _errorMessage = 'Could not upload the logo: $failure';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final gateway = widget.gateway;
    final picked = _picked;
    return Container(
      key: const Key('operator_web_account_logo_upload_section'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.cloud_upload_outlined,
                size: 16,
                color: AppColors.sunsetDark,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Upload a PNG (recommended)',
                  style: AppTextStyles.body14(color: AppColors.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'PNG files only, up to 600 KB. We store the file securely '
            'and put the link into the field below for you.',
            style: AppTextStyles.body12(color: AppColors.textMuted),
          ),
          const SizedBox(height: 10),
          if (gateway == null)
            _UnavailableNote()
          else ...[
            Row(
              children: [
                OutlinedButton.icon(
                  key: const Key('operator_web_account_logo_pick'),
                  onPressed: widget.enabled && !_uploading ? _handlePick : null,
                  icon: const Icon(Icons.attach_file_outlined, size: 16),
                  label: Text(
                    picked == null ? 'Choose PNG' : 'Choose another PNG',
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  key: const Key('operator_web_account_logo_upload'),
                  onPressed: picked != null && widget.enabled && !_uploading
                      ? _handleUpload
                      : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.sunset,
                    foregroundColor: AppColors.backgroundSurface,
                  ),
                  icon: _uploading
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.backgroundSurface,
                          ),
                        )
                      : const Icon(Icons.cloud_upload_outlined, size: 16),
                  label: Text(_uploading ? 'Uploading' : 'Upload'),
                ),
              ],
            ),
            if (picked != null) ...[
              const SizedBox(height: 10),
              _PickedFileTile(picked: picked),
            ],
            if (!widget.enabled && widget.disabledReason != null) ...[
              const SizedBox(height: 10),
              _DisabledNote(message: widget.disabledReason!),
            ],
          ],
          if (_errorMessage != null) ...[
            const SizedBox(height: 10),
            _InlineBanner(
              key: const Key('operator_web_account_logo_error'),
              message: _errorMessage!,
              negative: true,
            ),
          ],
          if (_successMessage != null) ...[
            const SizedBox(height: 10),
            _InlineBanner(
              key: const Key('operator_web_account_logo_success'),
              message: _successMessage!,
              negative: false,
            ),
          ],
        ],
      ),
    );
  }
}

class _PickedFileTile extends StatelessWidget {
  const _PickedFileTile({required this.picked});

  final PickedBusinessLogoFile picked;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_account_logo_picked_tile'),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          _PickedPreview(bytes: picked.bytes),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  picked.filename,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.body13(color: AppColors.textPrimary),
                ),
                Text(
                  '${(picked.bytes.length / 1024).toStringAsFixed(1)} KB',
                  style: AppTextStyles.mono8(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PickedPreview extends StatelessWidget {
  const _PickedPreview({required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.memory(
        bytes,
        fit: BoxFit.cover,
        // The picked bytes may not be a valid PNG (e.g. a corrupt
        // file the operator picked by mistake). Render a calm icon
        // fallback so the preview never blank-flashes; the upload
        // gateway repeats the PNG-magic check and refuses the file.
        errorBuilder: (_, __, ___) => const Icon(
          Icons.image_not_supported_outlined,
          size: 18,
          color: AppColors.textMuted,
        ),
      ),
    );
  }
}

class _UnavailableNote extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_account_logo_upload_unavailable'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 14, color: AppColors.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'File upload is not available on this build. Paste an '
              'https link below instead.',
              style: AppTextStyles.body12(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _DisabledNote extends StatelessWidget {
  const _DisabledNote({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_account_logo_upload_disabled_reason'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 14, color: AppColors.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body12(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _InlineBanner extends StatelessWidget {
  const _InlineBanner({
    super.key,
    required this.message,
    required this.negative,
  });

  final String message;
  final bool negative;

  @override
  Widget build(BuildContext context) {
    final color = negative ? AppColors.negative : AppColors.positive;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.45), width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          Icon(
            negative ? Icons.error_outline : Icons.check_circle_outline,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message, style: AppTextStyles.body12(color: color)),
          ),
        ],
      ),
    );
  }
}
