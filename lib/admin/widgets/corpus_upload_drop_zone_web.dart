// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

// Advisor Knowledge Activation B1 — Web drag-and-drop implementation
// for the corpus upload drop zone.
//
// Listens on `window.document.body` for dragover, dragleave, and drop
// events while the drop zone widget is mounted. The opaque handle
// returned by [attachDropListener] is a [_DragHandle] that carries the
// three [StreamSubscription]s; [detachDropListener] cancels them.
//
// Using the window-level listener (rather than a HtmlElementView
// platform view) keeps the implementation equivalent to the existing
// logo-picker pattern and avoids the platform-view-factory registration
// overhead.

import 'dart:async';
import 'dart:html' as html;

import '../services/corpus_file_picker.dart';
import '../services/corpus_file_picker_web.dart' show readDroppedFile;

class _DragHandle {
  _DragHandle(this.subs);
  final List<StreamSubscription<dynamic>> subs;
}

/// Attaches OS-level drag-and-drop listeners to the browser document
/// body. Returns an opaque [_DragHandle]; pass it to [detachDropListener]
/// on dispose.
Object? attachDropListener({
  required void Function() onDragOver,
  required void Function() onDragLeave,
  required void Function(PickedCorpusFile file) onDrop,
}) {
  final body = html.document.body;
  if (body == null) return null;

  final subs = <StreamSubscription<dynamic>>[];

  // Prevent the default browser behaviour (open the file) on drag events.
  subs.add(
    body.onDragOver.listen((event) {
      event.preventDefault();
      onDragOver();
    }),
  );

  subs.add(
    body.onDragLeave.listen((event) {
      event.preventDefault();
      onDragLeave();
    }),
  );

  subs.add(
    body.onDrop.listen((event) async {
      event.preventDefault();
      final dataTransfer = event.dataTransfer;
      final files = dataTransfer.files;
      if (files == null || files.isEmpty) {
        onDragLeave();
        return;
      }
      final file = files.first;
      final picked = await readDroppedFile(file);
      if (picked != null) {
        onDrop(picked);
      } else {
        onDragLeave();
      }
    }),
  );

  return _DragHandle(subs);
}

/// Cancels the drag subscriptions returned by [attachDropListener].
void detachDropListener(Object? handle) {
  if (handle is _DragHandle) {
    for (final sub in handle.subs) {
      sub.cancel();
    }
  }
}
