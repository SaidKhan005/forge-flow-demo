// Wave 2 W-5 — Business logo upload gateway (operator-web).
//
// Thin client over POST /v1/operator/business/logo. The Business
// Account screen calls [BusinessLogoUploadGateway.uploadLogo] with
// the chosen PNG file's bytes + filename; the gateway:
//
//   1. Base64-encodes the bytes (the proxy route reads the bytes from
//      a JSON envelope so we do not need a multipart parser inside
//      the bleed-stopped advisor_proxy.dart monolith).
//   2. POSTs the envelope through [OperatorWebProxyClient.postJson]
//      so token + Idempotency-Key + step-up replay logic is shared
//      with the rest of the operator-web HTTP surface.
//   3. Returns the resolved logo URL the operator-web client should
//      persist via the existing PATCH /v1/operator/account route's
//      `logoUrl` field.
//
// Route contract is pinned by:
//   * `tool/advisor_proxy/business_logo_upload_routes.dart`
//   * `tool/advisor_proxy/operator_routes.dart` (dispatch)

import 'dart:convert';
import 'dart:typed_data';

import 'operator_web_proxy_client.dart';

/// Hard cap on the PNG byte length the gateway accepts client-side.
/// Mirrors `kBusinessLogoMaxBytes` in the proxy; surfacing it here
/// avoids a network round-trip for an over-large file.
///
/// 600 KiB matches the proxy-side cap. See the rationale comment on
/// `kBusinessLogoMaxBytes` in `tool/advisor_proxy/business_logo_upload_routes.dart`.
const int kOperatorWebBusinessLogoMaxBytes = 600 * 1024;

/// PNG magic-number prefix. Client-side magic-byte check guards
/// against a "logo.png" upload that is actually a JPEG. The proxy
/// repeats the check (defence-in-depth).
const List<int> kOperatorWebPngMagic = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
];

/// Returned by [BusinessLogoUploadGateway.uploadLogo] on success.
class BusinessLogoUploadOutcome {
  const BusinessLogoUploadOutcome({
    required this.logoUrl,
    required this.sizeBytes,
  });

  /// Fully-qualified https URL of the uploaded logo. The Business
  /// Account screen writes this into the existing `logoUrl` text
  /// controller and persists it via PATCH /v1/operator/account.
  final String logoUrl;

  /// Decoded byte length the proxy committed to Azure Blob.
  final int sizeBytes;
}

/// Operator-scoped logo upload surface. Implementations:
///   * [HttpBusinessLogoUploadGateway] — production, talks to the proxy.
///   * Test fakes return a canned URL or throw an
///     [OperatorWebProxyException].
abstract class BusinessLogoUploadGateway {
  /// Validates client-side (size + PNG magic), encodes, and POSTs the
  /// upload through the proxy. Returns the resolved URL.
  ///
  /// Throws [BusinessLogoValidationException] when the client-side
  /// check fails (so the UI can render the precise reason without
  /// hitting the network). Throws [OperatorWebProxyException] on a
  /// proxy-side failure (auth, size limit, AAD outage, etc.).
  Future<BusinessLogoUploadOutcome> uploadLogo({
    required Uint8List pngBytes,
    required String filename,
  });
}

/// Default HTTP implementation. Routes through the operator-web
/// proxy client so token + idempotency + step-up replay logic is
/// shared with every other operator-web write.
class HttpBusinessLogoUploadGateway implements BusinessLogoUploadGateway {
  HttpBusinessLogoUploadGateway({
    required OperatorWebProxyClient client,
    required Future<String?> Function() idTokenProvider,
  })  : _client = client,
        _idTokenProvider = idTokenProvider;

  final OperatorWebProxyClient _client;
  final Future<String?> Function() _idTokenProvider;

  /// Operator-scoped route. Pinned by the proxy contract; never
  /// `/admin/`.
  static const String operatorBusinessLogoUploadPath =
      '/v1/operator/business/logo';

  @override
  Future<BusinessLogoUploadOutcome> uploadLogo({
    required Uint8List pngBytes,
    required String filename,
  }) async {
    if (operatorBusinessLogoUploadPath.contains('/admin/')) {
      // Belt and suspenders: the operator-web console must never
      // resolve an /admin/ path.
      throw const _AdminRouteForbidden();
    }
    final trimmedName = filename.trim();
    if (trimmedName.isEmpty) {
      throw const BusinessLogoValidationException(
        code: 'invalid_filename',
        message: 'Pick a file before uploading.',
      );
    }
    if (!trimmedName.toLowerCase().endsWith('.png')) {
      throw const BusinessLogoValidationException(
        code: 'invalid_filename',
        message: 'Only PNG files are accepted. Rename or convert your '
            'image and try again.',
      );
    }
    if (pngBytes.length > kOperatorWebBusinessLogoMaxBytes) {
      throw BusinessLogoValidationException(
        code: 'payload_too_large',
        message:
            'That file is larger than 600 KB. Pick a smaller logo or '
            'compress it first. (Yours: ${pngBytes.length} bytes.)',
      );
    }
    if (!_hasPngMagic(pngBytes)) {
      throw const BusinessLogoValidationException(
        code: 'invalid_png_magic',
        message:
            'That file is not a valid PNG. Save it again from your '
            'image editor and try once more.',
      );
    }

    final token = await _idTokenProvider();
    if (token == null || token.trim().isEmpty) {
      throw const OperatorWebProxyException(
        code: 'unauthenticated',
        message: 'Sign in again to upload your business logo.',
      );
    }
    final response = await _client.postJson(
      operatorBusinessLogoUploadPath,
      idToken: token.trim(),
      body: <String, Object?>{
        'filename': trimmedName,
        'contentBase64': base64Encode(pngBytes),
      },
    );
    final logoUrl = _readString(response.body['logoUrl']);
    final sizeBytes = response.body['sizeBytes'];
    if (logoUrl == null || sizeBytes is! int) {
      throw const OperatorWebProxyException(
        code: 'malformed_logo_upload_response',
        message: 'The proxy returned an incomplete logo upload response.',
      );
    }
    return BusinessLogoUploadOutcome(logoUrl: logoUrl, sizeBytes: sizeBytes);
  }

  static bool _hasPngMagic(Uint8List bytes) {
    if (bytes.length < kOperatorWebPngMagic.length) return false;
    for (var i = 0; i < kOperatorWebPngMagic.length; i++) {
      if (bytes[i] != kOperatorWebPngMagic[i]) return false;
    }
    return true;
  }

  static String? _readString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// Thrown when the client-side validation fails (extension, size,
/// PNG magic). The Business Account screen catches this and renders
/// the message verbatim.
class BusinessLogoValidationException implements Exception {
  const BusinessLogoValidationException({
    required this.code,
    required this.message,
  });

  final String code;
  final String message;

  @override
  String toString() => 'BusinessLogoValidationException(code: $code)';
}

class _AdminRouteForbidden implements Exception {
  const _AdminRouteForbidden();
  @override
  String toString() =>
      'BusinessLogoUploadGateway must never resolve an /admin/ path.';
}
