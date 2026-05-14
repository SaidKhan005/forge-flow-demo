// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

// Wave 2 W-5 — Flutter Web file picker for the business logo upload.
//
// Uses the browser's native `<input type="file">` element so the
// repo does not need to absorb a new file-picker package. The native
// picker:
//   * Restricts the picker to `.png` via the `accept` attribute (the
//     proxy validates again — defence-in-depth, since browser
//     `accept` is suggestion-only).
//   * Lets the operator cancel without raising an error.
//   * Reads the bytes off-thread via [FileReader.readAsArrayBuffer].

import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

import 'business_logo_file_picker.dart';

Future<PickedBusinessLogoFile?> pickBusinessLogoFile() {
  final completer = Completer<PickedBusinessLogoFile?>();
  final input = html.FileUploadInputElement()
    ..accept = 'image/png,.png'
    ..multiple = false;

  // Resolve to `null` when the operator navigates away or focuses
  // back without choosing a file. The browser does not surface a
  // dedicated cancel event, so we lean on `change` to fire only when
  // a file IS chosen.
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
          PickedBusinessLogoFile(bytes: bytes, filename: file.name),
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
