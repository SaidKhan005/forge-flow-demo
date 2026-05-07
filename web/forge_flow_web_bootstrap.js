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
