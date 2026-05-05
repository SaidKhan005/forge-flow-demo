// Phase 11W.live - conditional URL redirect helper.

import 'operator_web_url_launcher_stub.dart'
    if (dart.library.html) 'operator_web_url_launcher_web.dart'
    as impl;

Future<void> openOperatorWebRedirect(String url) {
  return impl.openOperatorWebRedirect(url);
}
