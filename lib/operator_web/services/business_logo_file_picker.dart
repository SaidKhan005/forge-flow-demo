// Wave 2 W-5 — File picker seam for the business logo upload UX.
//
// The operator-web Business Account screen needs an "Upload PNG"
// button that hands raw bytes + a filename to the
// [BusinessLogoUploadGateway]. Flutter does not ship a file picker
// in the SDK, and the repo does not depend on `file_picker` /
// `image_picker` packages.
//
// This seam is a tiny wrapper around the browser's native
// `<input type="file">` element on Flutter Web; on the VM it returns
// `null` (the picker is web-only). The conditional import keeps the
// VM target buildable and the web import gated to `dart.library.html`.

import 'dart:typed_data';

import 'business_logo_file_picker_stub.dart'
    if (dart.library.html) 'business_logo_file_picker_web.dart' as impl;

/// Returned by [pickBusinessLogoFile] when the operator selects a
/// file. Holds the raw bytes + the original filename so the upload
/// gateway can echo the filename to the proxy for the validator.
class PickedBusinessLogoFile {
  const PickedBusinessLogoFile({
    required this.bytes,
    required this.filename,
  });

  final Uint8List bytes;
  final String filename;
}

/// Opens the browser's file picker and returns the first PNG file
/// the operator selected. Returns `null` when:
///   * The operator cancels the picker.
///   * The current platform is not Flutter Web (the VM stub).
///
/// The picker only suggests `.png` files via the `accept` attribute;
/// the upload gateway repeats every validation (extension + size +
/// PNG magic).
Future<PickedBusinessLogoFile?> pickBusinessLogoFile() {
  return impl.pickBusinessLogoFile();
}
