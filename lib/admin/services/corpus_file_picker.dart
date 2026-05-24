// Advisor Knowledge Activation B1 — File picker seam for corpus uploads.
//
// The admin Knowledge Base screen needs a "Choose file" button that
// hands raw bytes + a filename to [CorpusAdminGateway.previewDiff].
// Flutter does not ship a file picker in the SDK, and the repo does not
// depend on `file_picker` / `image_picker` packages.
//
// This seam wraps the browser's native `<input type="file">` element on
// Flutter Web; on the VM it returns null (the picker is web-only). The
// conditional import keeps the VM target buildable and the web import
// gated to `dart.library.html`.
//
// Mirrors the pattern at
// `lib/operator_web/services/business_logo_file_picker.dart`.

import 'dart:typed_data';

import 'corpus_file_picker_stub.dart'
    if (dart.library.html) 'corpus_file_picker_web.dart' as impl;

/// Returned by [pickCorpusFile] when the admin selects a file.
/// Holds the raw bytes + the original filename so the upload gateway
/// can forward the filename to the proxy for logging and validation.
class PickedCorpusFile {
  const PickedCorpusFile({required this.bytes, required this.filename});

  final Uint8List bytes;
  final String filename;
}

/// Opens the browser's native file picker and returns the first
/// `.md` or `.txt` file the admin selected. Returns null when:
///   * The admin cancels the picker.
///   * The current platform is not Flutter Web (the VM stub).
///
/// The picker restricts to `.md,.txt` via the `accept` attribute as
/// a UX hint; [CorpusAdminScreen] repeats content-type and size
/// validation client-side before building the [UploadCommand].
Future<PickedCorpusFile?> pickCorpusFile() {
  return impl.pickCorpusFile();
}
