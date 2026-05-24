// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

// Advisor Knowledge Activation B1 — Flutter Web file picker for corpus uploads.
//
// Uses the browser's native `<input type="file">` element so the repo
// does not need to absorb a new file-picker package. The native picker:
//   * Restricts the picker to `.md` and `.txt` via the `accept`
//     attribute ([CorpusAdminScreen] re-validates — defence-in-depth,
//     since browser `accept` is suggestion-only).
//   * Lets the admin cancel without raising an error.
//   * Reads the bytes off-thread via [FileReader.readAsArrayBuffer].
//   * Supports drag-and-drop by wiring a [DragEvent] listener on a
//     full-screen drop zone rendered by [CorpusDropZone]; the same
//     [pickCorpusFile] path returns the first dropped file.
//
// Mirrors the pattern at
// `lib/operator_web/services/business_logo_file_picker_web.dart`.

import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

import 'corpus_file_picker.dart';

Future<PickedCorpusFile?> pickCorpusFile() {
  final completer = Completer<PickedCorpusFile?>();
  final input = html.FileUploadInputElement()
    ..accept = '.md,.txt,text/markdown,text/plain'
    ..multiple = false;

  // Resolve to null when the admin closes the picker without choosing.
  // The browser does not fire a dedicated cancel event; `change` only
  // fires when a file IS chosen, so unresolved cancels are benign
  // (the completer is eventually GC'd without completion, matching the
  // logo-picker pattern).
  input.onChange.first.then((_) async {
    final files = input.files;
    if (files == null || files.isEmpty) {
      if (!completer.isCompleted) completer.complete(null);
      return;
    }
    final file = files.first;
    try {
      final reader = html.FileReader();
      reader.readAsArrayBuffer(file);
      await reader.onLoadEnd.first;
      final result = reader.result;
      Uint8List bytes;
      if (result is Uint8List) {
        bytes = result;
      } else if (result is List<int>) {
        bytes = Uint8List.fromList(result);
      } else {
        if (!completer.isCompleted) completer.complete(null);
        return;
      }
      if (!completer.isCompleted) {
        completer.complete(
          PickedCorpusFile(bytes: bytes, filename: file.name),
        );
      }
    } catch (_) {
      if (!completer.isCompleted) completer.complete(null);
    }
  }).catchError((_) {
    if (!completer.isCompleted) completer.complete(null);
  });

  input.click();
  return completer.future;
}

/// Reads a single [html.File] from a drag-and-drop event into a
/// [PickedCorpusFile]. Shared by [CorpusDropZone] so it does not
/// duplicate the [FileReader] logic above.
Future<PickedCorpusFile?> readDroppedFile(html.File file) async {
  try {
    final reader = html.FileReader();
    reader.readAsArrayBuffer(file);
    await reader.onLoadEnd.first;
    final result = reader.result;
    Uint8List bytes;
    if (result is Uint8List) {
      bytes = result;
    } else if (result is List<int>) {
      bytes = Uint8List.fromList(result);
    } else {
      return null;
    }
    return PickedCorpusFile(bytes: bytes, filename: file.name);
  } catch (_) {
    return null;
  }
}
