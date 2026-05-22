// QA rAF worker — drives the requestAnimationFrame polyfill tick.
// Runs in a Web Worker so its setInterval fires at full cadence even
// when the host page is "hidden" (headless Electron / background tab).
// Chromium throttles timers in hidden PAGES to ~1 Hz, but Web Worker
// timers in a separate thread are not subject to the same throttling.
// NOT shipped to production — only present in the QA build.
setInterval(function () { postMessage(1); }, 16);
