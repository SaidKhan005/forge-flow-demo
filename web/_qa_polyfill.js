// QA harness polyfill — makes Flutter Web paint in a headless Electron
// where document.visibilityState === 'hidden' would otherwise pause
// requestAnimationFrame. NOT shipped to production — only present in
// the local build/web directory served by dhttpd for in-browser QA.
(function () {
  'use strict';

  // 1) Lie about visibility — some Flutter / engine paths look at
  // document.hidden or document.visibilityState directly.
  try {
    Object.defineProperty(document, 'hidden', {
      configurable: true,
      get: function () { return false; },
    });
    Object.defineProperty(document, 'visibilityState', {
      configurable: true,
      get: function () { return 'visible'; },
    });
    Object.defineProperty(document, 'webkitHidden', {
      configurable: true,
      get: function () { return false; },
    });
    Object.defineProperty(document, 'webkitVisibilityState', {
      configurable: true,
      get: function () { return 'visible'; },
    });
  } catch (e) {
    console.warn('[qa-polyfill] visibility override failed:', e);
  }

  // 2) Force-fire a "visibilitychange" event with the hidden page now
  // claiming to be visible — wakes anyone listening.
  try {
    document.dispatchEvent(new Event('visibilitychange'));
  } catch (_) {}

  // 3) Replace requestAnimationFrame with a setInterval-driven tick.
  // Chrome suspends real rAF when the page is hidden; setInterval keeps
  // firing regardless. 60fps target → 16ms.
  var nativeRAF = window.requestAnimationFrame;
  var nativeCAF = window.cancelAnimationFrame;
  var nextId = 1;
  var queue = new Map();
  var ticking = false;

  function startTicker() {
    if (ticking) return;
    ticking = true;
    setInterval(function () {
      if (queue.size === 0) return;
      var t = performance.now();
      var pending = Array.from(queue.entries());
      queue.clear();
      for (var i = 0; i < pending.length; i++) {
        try { pending[i][1](t); } catch (e) { console.error('[qa-polyfill] rAF cb threw:', e); }
      }
    }, 16);
  }

  window.requestAnimationFrame = function (cb) {
    var id = nextId++;
    queue.set(id, cb);
    startTicker();
    return id;
  };
  window.cancelAnimationFrame = function (id) {
    queue.delete(id);
  };

  // 4) Focus signaling — some engines also gate on document.hasFocus().
  var origHasFocus = document.hasFocus;
  document.hasFocus = function () { return true; };

  console.log('[qa-polyfill] visibility forced visible; rAF replaced with setInterval(16ms).');
})();
