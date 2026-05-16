// Forge & Flow web bootstrap.
//
// FlutterFire Web injects Firebase JS modules during `Firebase.initializeApp`.
// The Forge & Flow web shells run with a strict CSP that does not permit that
// generated inline shim, so preload the supported Firebase modules from this
// external, self-hosted bootstrap before loading Flutter's generated bootstrap.

const firebaseVersion = '12.12.0';
const firebaseBaseUrl = `https://www.gstatic.com/firebasejs/${firebaseVersion}`;

const [firebaseCore, firebaseAuth, firebaseMessaging] = await Promise.all([
  import(`${firebaseBaseUrl}/firebase-app.js`),
  import(`${firebaseBaseUrl}/firebase-auth.js`),
  import(`${firebaseBaseUrl}/firebase-messaging.js`),
]);

window.flutterfire_web_sdk_version = firebaseVersion;
if (!window.firebase_core) window.firebase_core = firebaseCore;
if (!window.firebase_auth) window.firebase_auth = firebaseAuth;
if (!window.firebase_messaging) window.firebase_messaging = firebaseMessaging;

const flutterBootstrap = document.createElement('script');
flutterBootstrap.src = 'flutter_bootstrap.js';
flutterBootstrap.async = true;
document.body.appendChild(flutterBootstrap);

// Splash-removal fallback. `flutter_native_splash` injects a call to
// `removeSplashFromWeb()` into the generated `flutter_bootstrap.js` during
// `flutter build web` (release), but NOT during `flutter run` (debug). Without
// this fallback, the `<picture id="splash">` block in `web/index.html` stays
// on top of the Flutter canvas forever in dev mode and the operator sees a
// splash that never clears. Watch for Flutter's first paint signal
// (`flt-glass-pane` appearing in the DOM) and call the existing removal helper.
// Idempotent: `removeSplashFromWeb()` itself uses `?.remove()` so a duplicate
// call from the production-build injection is a safe no-op.
const splashObserver = new MutationObserver(() => {
  if (document.querySelector('flt-glass-pane')) {
    splashObserver.disconnect();
    if (typeof window.removeSplashFromWeb === 'function') {
      window.removeSplashFromWeb();
    }
  }
});
splashObserver.observe(document.body, { childList: true, subtree: true });
