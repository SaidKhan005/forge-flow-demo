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

  // 5) Viewport dimensions — headless Electron reports window.innerWidth /
  // innerHeight = 0, which causes Flutter's layout engine to produce a 0×0
  // viewport and never emit a frame.  Override to a standard desktop size
  // BEFORE Flutter's bootstrap reads them.  Also covers devicePixelRatio
  // (must be ≥ 1) and screen dimensions used by some engine paths.
  try {
    Object.defineProperty(window, 'innerWidth',  { configurable: true, get: function () { return 1440; } });
    Object.defineProperty(window, 'innerHeight', { configurable: true, get: function () { return 900;  } });
    Object.defineProperty(window, 'outerWidth',  { configurable: true, get: function () { return 1440; } });
    Object.defineProperty(window, 'outerHeight', { configurable: true, get: function () { return 900;  } });
    Object.defineProperty(window, 'devicePixelRatio', { configurable: true, get: function () { return 1; } });
  } catch (e) {
    console.warn('[qa-polyfill] viewport override failed:', e);
  }
  try {
    Object.defineProperty(window.screen, 'width',  { configurable: true, get: function () { return 1440; } });
    Object.defineProperty(window.screen, 'height', { configurable: true, get: function () { return 900;  } });
  } catch (e) {
    console.warn('[qa-polyfill] screen override failed:', e);
  }

  // 6) getBoundingClientRect override — headless Electron CSS layout produces
  // 0×0 for every element (no real display context), so Flutter's engine calls
  // flutter-view.getBoundingClientRect() and gets an empty rect, initialises a
  // 0×0 viewport, and never schedules a render frame.  Patch
  // Element.prototype.getBoundingClientRect BEFORE Flutter creates any DOM so
  // the flutter-view and flt-glass-pane elements return a real desktop rect.
  // Also patches clientWidth / clientHeight / offsetWidth / offsetHeight on
  // HTMLElement.prototype for the same reason.
  try {
    var _W = 1440, _H = 900;
    var _fakeRect = function () {
      return { x: 0, y: 0, width: _W, height: _H,
               top: 0, left: 0, right: _W, bottom: _H,
               toJSON: function () { return this; } };
    };
    var _isFlutterRoot = function (el) {
      if (!el || !el.tagName) return false;
      var t = el.tagName.toUpperCase();
      return t === 'FLUTTER-VIEW' || t === 'FLT-GLASS-PANE' || t === 'BODY' || t === 'HTML';
    };
    var _origBCR = Element.prototype.getBoundingClientRect;
    Element.prototype.getBoundingClientRect = function () {
      if (_isFlutterRoot(this)) return _fakeRect();
      var r = _origBCR.call(this);
      // If layout returned a zero rect for any element, return fake to avoid
      // Flutter interpreting 0-size containers as collapsed views.
      if (r && r.width === 0 && r.height === 0) return _fakeRect();
      return r;
    };
    // clientWidth / clientHeight
    var _HTMLEl = window.HTMLElement ? window.HTMLElement.prototype : Element.prototype;
    Object.defineProperty(_HTMLEl, 'clientWidth',  { configurable: true, get: function () {
      if (_isFlutterRoot(this)) return _W; return 0;
    }});
    Object.defineProperty(_HTMLEl, 'clientHeight', { configurable: true, get: function () {
      if (_isFlutterRoot(this)) return _H; return 0;
    }});
  } catch (e) {
    console.warn('[qa-polyfill] BCR override failed:', e);
  }

  console.log('[qa-polyfill] visibility forced visible; rAF replaced; viewport 1440×900; BCR patched.');
