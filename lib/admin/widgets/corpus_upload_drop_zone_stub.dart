// Advisor Knowledge Activation B1 — VM stub for the corpus drop zone.
//
// Used by every build target except Flutter Web. The drop zone widget
// renders the visual but does not wire OS-level drag events (there is
// no browser drag API on the VM). All three callbacks are never called.

import '../services/corpus_file_picker.dart';

/// No-op on the VM. Returns null (the opaque handle); [detachDropListener]
/// accepts null and is a no-op.
Object? attachDropListener({
  required void Function() onDragOver,
  required void Function() onDragLeave,
  required void Function(PickedCorpusFile file) onDrop,
}) {
  return null;
}

/// No-op on the VM.
void detachDropListener(Object? handle) {}
