// Advisor Knowledge Activation B1 — VM stub for the corpus file picker.
//
// Used by every build target except Flutter Web. Widget tests inject a
// synthetic [CorpusUploadPicker] directly into [CorpusAdminScreen], so
// this stub is never invoked during testing; returning null is the
// correct no-op for the VM target.

import 'corpus_file_picker.dart';

Future<PickedCorpusFile?> pickCorpusFile() async {
  // No-op on the VM; the admin shell is web-only.
  return null;
}
