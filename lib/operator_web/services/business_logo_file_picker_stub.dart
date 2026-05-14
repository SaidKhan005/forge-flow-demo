// Wave 2 W-5 — VM stub for the business logo file picker.
//
// Used by every build target except Flutter Web. Widget tests render
// the upload UI but never invoke the picker (they exercise the
// gateway directly), so a `null` return is the right default — the
// upload button is then disabled / inert.

import 'business_logo_file_picker.dart';

Future<PickedBusinessLogoFile?> pickBusinessLogoFile() async {
  // No-op on the VM; the operator-web shell is web-only.
  return null;
}
