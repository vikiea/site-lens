// App-owned, unprivileged media lifecycle support. This object cannot access
// GM storage, network, cookies, native navigation or script authorization.
(function () {
  'use strict';
  if (window.__siteLensMediaControl) return;
  const config = __SITE_LENS_MEDIA_CONFIG__;
  const nodes = new Set();
  const connectedBefore = new WeakSet();
  const watched = new WeakSet();
  const resumeNodes = new Set();
  const contexts = new Set();
  const resumeContexts = new Set();
  const childPlaying = new Map();
  let blocked = config.blocked !== false;
  let needsGesture = false;
  let lastPlaying = null;
  let lastCandidates = '';
  const originalPlay = HTMLMediaElement.prototype.play;

  function track(node) {
    if (connectedBefore.has(node) && !node.isConnected) return;
    nodes.add(node);
    if (node.isConnected) connectedBefore.add(node);
    if (!watched.has(node) && typeof node.addEventListener === 'function') {
      watched.add(node);
      for (const type of ['play','playing','pause','ended','emptied']) {
        node.addEventListener(type, () => mediaEvent(type,node));
      }
    }
  }
  function mediaEvent(type,node) {
    track(node);
    if (['ended','emptied'].includes(type) || (['play','playing'].includes(type) && !node.paused && !node.ended)) resumeNodes.delete(node);
    if (blocked && type!=='pause' && type!=='ended') pause(); else report();
  }
  function collect() {
    const children = Array.from({length:Math.min(window.frames.length,64)}, (_,i) => window.frames[i]);
    for (const frame of childPlaying.keys()) if (!children.includes(frame)) childPlaying.delete(frame);
    for (const node of nodes) {
      if (node.isConnected) connectedBefore.add(node);
      if ((!node.isConnected && connectedBefore.has(node)) ||
          (!node.isConnected && (node.paused || node.ended) && !resumeNodes.has(node))) {
        nodes.delete(node); resumeNodes.delete(node);
      }
    }
    document.querySelectorAll('video,audio').forEach(track);
  }
  function report() {
    collect();
    const playing = Array.from(nodes).some(node => !node.paused && !node.ended) ||
      Array.from(contexts).some(ctx => ctx.state === 'running') || Array.from(childPlaying.values()).some(Boolean);
    const candidates = [];
    for (const node of nodes) {
      const raw = node.currentSrc || node.src || '';
      try {
        const url = new URL(raw, document.baseURI);
        if ((url.protocol === 'http:' || url.protocol === 'https:') && !url.username && !url.password) {
          candidates.push({url: url.href, title: (document.title || '').slice(0, 512), mime: String(node.type || '').slice(0, 128), durationMs: Number.isFinite(node.duration) ? Math.round(node.duration * 1000) : undefined});
        }
      } catch (_) {}
    }
    const candidateKey = JSON.stringify(candidates);
    if (playing === lastPlaying && candidateKey === lastCandidates) return;
    lastPlaying = playing;
    lastCandidates = candidateKey;
    try {
      if (window.parent !== window) {
        window.parent.postMessage({kind:'site-lens-media-state',token:config.token,playing}, '*');
      } else {
        window[config.bridge].postMessage(JSON.stringify({playing, title: (document.title || '').slice(0,512), candidates}));
      }
    } catch (_) { /* Detached or unsupported frames have no native authority. */ }
  }
  function pause() {
    collect();
    for (const node of nodes) {
      if (!node.paused) { resumeNodes.add(node); needsGesture = true; }
      try { node.pause(); } catch (_) { }
    }
    for (const ctx of contexts) {
      if (ctx.state === 'running') {
        needsGesture = true;
        resumeContexts.add(ctx);
        try { Promise.resolve(ctx.suspend()).catch(() => {}); } catch (_) { }
      }
    }
    report();
  }
  function relay(data) {
    for (let i = 0; i < window.frames.length; i++) {
      try { window.frames[i].postMessage(data, '*'); } catch (_) { }
    }
  }
  function apply(action) {
    collect();
    if (action === 'pause') { blocked = true; pause(); }
    else if (action === 'unblock') { blocked = false; }
    else if (action === 'resume') {
      blocked = false;
      needsGesture = false;
      for (const node of resumeNodes) {
        try { Promise.resolve(originalPlay.call(node)).catch(() => {}); } catch (_) { }
      }
      resumeNodes.clear();
      for (const ctx of resumeContexts) {
        try { Promise.resolve(ctx.resume()).catch(() => {}); } catch (_) {}
      }
      resumeContexts.clear();
      report();
    }
    relay({kind: 'site-lens-media', token: config.token, action});
  }
  Object.defineProperty(window, '__siteLensMediaControl', {value: {apply}, configurable: false});
  HTMLMediaElement.prototype.play = function (...args) {
    if (!this.isConnected) connectedBefore.delete(this);
    track(this);
    if (blocked || needsGesture) {
      return Promise.reject(new DOMException('Media paused by application policy', 'NotAllowedError'));
    }
    return originalPlay.apply(this, args);
  };
  for (const type of ['play', 'playing', 'pause', 'ended', 'emptied']) {
    document.addEventListener(type,event => {
      if (event.target instanceof HTMLMediaElement) mediaEvent(type,event.target);
    },true);
  }
  for (const type of ['pointerdown', 'touchstart', 'keydown']) {
    document.addEventListener(type, event => {
      if (event.isTrusted && !blocked) needsGesture = false;
    }, true);
  }
  for (const name of ['AudioContext', 'webkitAudioContext']) {
    const Ctor = window[name];
    if (typeof Ctor !== 'function') continue;
    window[name] = new Proxy(Ctor, {
      construct(target, args) {
        const ctx = Reflect.construct(target, args);
        contexts.add(ctx);
        ctx.addEventListener('statechange', () => {
          if (ctx.state === 'closed') { contexts.delete(ctx); resumeContexts.delete(ctx); }
          if (ctx.state === 'running' && !blocked) resumeContexts.delete(ctx);
          if (blocked && ctx.state === 'running') pause(); else report();
        });
        if (blocked) Promise.resolve(ctx.suspend()).catch(() => {});
        const resume = ctx.resume.bind(ctx);
        ctx.resume = function () {
          if (blocked || needsGesture) return Promise.reject(new DOMException('Media paused', 'NotAllowedError'));
          return resume();
        };
        return ctx;
      },
    });
  }
  window.addEventListener('message', event => {
    const data = event.data;
    if (data && data.kind === 'site-lens-media-state' && data.token === config.token && typeof data.playing === 'boolean') {
      const children = Array.from({length:Math.min(window.frames.length,64)}, (_,i) => window.frames[i]);
      if (children.includes(event.source)) {
        for (const frame of childPlaying.keys()) if (!children.includes(frame)) childPlaying.delete(frame);
        childPlaying.set(event.source,data.playing); report();
      }
    }
    if (event.source === window.parent && data && data.kind === 'site-lens-media' &&
        data.token === config.token && ['pause', 'unblock', 'resume'].includes(data.action)) {
      apply(data.action);
    }
  });
  if (typeof MutationObserver === 'function') {
    new MutationObserver(() => report()).observe(document, {childList:true,subtree:true});
  }
  document.addEventListener('DOMContentLoaded', () => { collect(); if (blocked) pause(); else report(); });
})();
