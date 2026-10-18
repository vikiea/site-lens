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
  const childCandidates = new Map();
  const mediaAttributes = [
    'data-play-src',
    'data-video-src',
    'data-media-src',
    'data-m3u8',
    'data-hls',
    'data-src',
  ];
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
    for (const frame of childCandidates.keys()) if (!children.includes(frame)) childCandidates.delete(frame);
    for (const node of nodes) {
      if (node.isConnected) connectedBefore.add(node);
      if ((!node.isConnected && connectedBefore.has(node)) ||
          (!node.isConnected && (node.paused || node.ended) && !resumeNodes.has(node))) {
        nodes.delete(node); resumeNodes.delete(node);
      }
    }
    document.querySelectorAll('video,audio').forEach(track);
  }
  function looksMedia(raw, mime) {
    return /(?:\.m3u8|\.mp4|\.m3u|\.mpd|\.webm)(?:[?#]|$)/i.test(raw) ||
      /^(?:video|audio)\//i.test(mime) || /mpegurl|dash\+xml/i.test(mime);
  }
  function inferMime(raw) {
    const path = String(raw).split(/[?#]/, 1)[0].toLowerCase();
    if (/\.m3u8?$/.test(path)) return 'application/vnd.apple.mpegurl';
    if (/\.mpd$/.test(path)) return 'application/dash+xml';
    if (/\.(?:mp4|m4v)$/.test(path)) return 'video/mp4';
    if (/\.webm$/.test(path)) return 'video/webm';
    if (/\.mov$/.test(path)) return 'video/quicktime';
    if (/\.mkv$/.test(path)) return 'video/x-matroska';
    if (/\.ts$/.test(path)) return 'video/mp2t';
    if (/\.mp3$/.test(path)) return 'audio/mpeg';
    if (/\.m4a$/.test(path)) return 'audio/mp4';
    if (/\.ogg?$/.test(path)) return 'audio/ogg';
    return '';
  }
  function candidateKey(url) {
    const volatile = /^(?:auth|auth_key|expires?|exp|hmac|sig(?:nature)?|sign|t|time|timestamp|token|v|via|via_bm)$/i;
    for (const key of Array.from(url.searchParams.keys())) {
      if (volatile.test(key)) url.searchParams.delete(key);
    }
    return url.href;
  }
  function addCandidate(output, seen, raw, mime = '', durationMs, force = false, title) {
    if (typeof raw !== 'string' || !raw.trim()) return;
    try {
      const url = new URL(raw, document.baseURI);
      const suppliedMime = String(mime || '').trim();
      const resolvedMime = /^(?:video|audio)\//i.test(suppliedMime) ||
          /mpegurl|dash\+xml/i.test(suppliedMime)
        ? suppliedMime
        : inferMime(url.href);
      if ((url.protocol !== 'http:' && url.protocol !== 'https:') || url.username || url.password ||
          (!force && !looksMedia(url.href, resolvedMime))) return;
      const candidate = {
        url: url.href,
        title: String(title ?? document.title ?? '').slice(0, 512),
        mime: resolvedMime.slice(0, 128),
      };
      if (Number.isFinite(durationMs)) candidate.durationMs = Math.round(durationMs);
      const key = candidateKey(url);
      const previous = seen.get(key);
      if (previous == null) {
        seen.set(key, output.length);
        output.push(candidate);
      } else {
        const existing = output[previous];
        const score = (value) => (value.mime ? 4 : 0) + (value.url.includes('?') ? 2 : 0) + value.url.length / 100000;
        if (score(candidate) > score(existing)) output[previous] = candidate;
      }
    } catch (_) {}
  }
  function report() {
    collect();
    const playing = Array.from(nodes).some(node => !node.paused && !node.ended) ||
      Array.from(contexts).some(ctx => ctx.state === 'running') || Array.from(childPlaying.values()).some(Boolean);
    const candidates = [];
    const seen = new Map();
    for (const node of nodes) {
      const raw = node.currentSrc || node.src || '';
      addCandidate(candidates, seen, raw, node.type, Number.isFinite(node.duration) ? node.duration * 1000 : undefined, true);
    }
    const selector = mediaAttributes.map(name => `[${name}]`).join(',');
    document.querySelectorAll(selector).forEach(element => {
      if (!element || typeof element.getAttribute !== 'function') return;
      const mime = element.getAttribute('type') || '';
      for (const name of mediaAttributes) {
        addCandidate(candidates, seen, element.getAttribute(name), mime);
      }
    });
    if (typeof performance !== 'undefined' && typeof performance.getEntriesByType === 'function') {
      for (const entry of performance.getEntriesByType('resource').slice(-256)) {
        addCandidate(candidates, seen, entry.name, entry.initiatorType || '');
      }
    }
    for (const child of childCandidates.values()) {
      if (!Array.isArray(child)) continue;
      for (const candidate of child) {
        addCandidate(candidates, seen, candidate?.url, candidate?.mime, candidate?.durationMs, true, candidate?.title);
      }
    }
    const candidateKey = JSON.stringify(candidates);
    if (playing === lastPlaying && candidateKey === lastCandidates) return;
    lastPlaying = playing;
    lastCandidates = candidateKey;
    try {
      if (window.parent !== window) {
        window.parent.postMessage({kind:'site-lens-media-state',token:config.token,playing,candidates}, '*');
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
        childCandidates.set(event.source, Array.isArray(data.candidates) ? data.candidates : []);
        report();
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
  if (typeof setInterval === 'function') setInterval(() => report(), 1500);
})();
