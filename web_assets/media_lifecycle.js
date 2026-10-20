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
  // Keep the last known direct-child identity even after the iframe has been
  // detached from window.frames. A pagehide message can arrive after the DOM
  // removal, so the live frame list is not a reliable ownership check.
  const childFrames = new WeakMap();
  let frameId = newFrameId();
  let documentId = window.parent === window ? frameId : null;
  let parentFrameId = null;
  let epoch = -1;
  let commandSequence = -1;
  let connected = false;
  let alive = true;
  let lastState = '';
  const bridge = window[config.bridge];
  function newFrameId() {
    if (window.crypto && typeof window.crypto.randomUUID === 'function') return window.crypto.randomUUID();
    return 'f' + Date.now().toString(36) + Math.random().toString(36).slice(2);
  }
  function post(kind, fields = {}) {
    try {
      if (!documentId) return;
      const raw = JSON.stringify({kind, token: config.token, frame: frameId, document: documentId, epoch, ...fields});
      if (raw.length <= 4096 && bridge) bridge.postMessage(raw);
    } catch (_) {}
  }
  function connect() {
    if (!alive) return;
    if (window.parent !== window) {
      try {
        window.parent.postMessage({
          kind: 'site-lens-media-frame-hello',
          token: config.token,
          frame: frameId,
        }, '*');
      } catch (_) {}
    }
    if (documentId) post('hello');
  }
  function directChildren() {
    return Array.from(
      {length: Math.min(window.frames.length, 64)},
      (_, index) => window.frames[index],
    );
  }
  function broadcastDocumentId() {
    if (!documentId) return;
    const message = {
      kind: 'site-lens-media-frame-id',
      token: config.token,
      document: documentId,
    };
    for (const child of directChildren()) {
      try { child.postMessage(message, '*'); } catch (_) {}
    }
  }
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
  let lastActiveNode = null;
  let lastCandidates = '';
  let lastCandidateList = [];
  let reportScheduled = false;
  let reportAgain = false;
  let lastReportAt = 0;
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
    if ((type === 'play' || type === 'playing') && !node.paused && !node.ended) lastActiveNode = node;
    if (['ended','emptied'].includes(type) || (['play','playing'].includes(type) && !node.paused && !node.ended)) resumeNodes.delete(node);
    if (blocked && type!=='pause' && type!=='ended') pause(); else scheduleReport();
  }
  function collect() {
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
  function thumbnailUrl(raw) {
    if (typeof raw !== 'string' || !raw.trim()) return '';
    try {
      const url = new URL(raw, document.baseURI);
      if (url.protocol !== 'http:' && url.protocol !== 'https:') return '';
      if (url.username || url.password) return '';
      url.hash = '';
      return url.href;
    } catch (_) { return ''; }
  }
  function episodeNumber(raw) {
    const value = Number.parseInt(String(raw ?? '').trim(), 10);
    return Number.isFinite(value) && value > 0 && value < 100000 ? value : null;
  }
  function candidateKey(url) {
    const volatile = /^(?:auth|auth_key|expires?|exp|hmac|sig(?:nature)?|sign|t|time|timestamp|token|via|via_bm)$/i;
    for (const key of Array.from(url.searchParams.keys())) {
      if (volatile.test(key)) url.searchParams.delete(key);
    }
    return url.href;
  }
  // Resource timing exposes every HLS segment as a media resource. Those
  // short-lived transport files are not playable candidates and must never be
  // offered beside the manifest that references them. A real standalone TS
  // source attached to a media element may still be observed, but the Dart
  // validator keeps transport segments out of playback and download actions.
  function isTransportResource(raw) {
    try {
      const path = new URL(raw, document.baseURI).pathname.toLowerCase();
      return /\.(?:ts|m4s|aac|vtt)(?:$|\/)/i.test(path) ||
        /(?:^|\/)(?:segment|chunk|fragment|part)[-_]?\d+/i.test(path);
    } catch (_) { return false; }
  }
  function addCandidate(output, seen, raw, mime = '', durationMs, force = false, title, poster = '', episode = null) {
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
      const thumbnail = thumbnailUrl(poster);
      if (thumbnail) candidate.thumbnail = thumbnail;
      const number = episodeNumber(episode);
      if (number != null) candidate.episodeNumber = number;
      if (Number.isFinite(durationMs)) candidate.durationMs = Math.round(durationMs);
      const key = candidateKey(url);
      const previous = seen.get(key);
      if (previous == null) {
        seen.set(key, output.length);
        output.push(candidate);
      } else {
        const existing = output[previous];
        const score = (value) => (value.mime ? 4 : 0) + (value.thumbnail ? 2 : 0) + (value.url.includes('?') ? 2 : 0) + value.url.length / 100000;
        if (score(candidate) > score(existing)) output[previous] = candidate;
      }
    } catch (_) {}
  }
  function report() {
    if (!alive) return;
    collect();
    const playing = Array.from(nodes).some(node => !node.paused && !node.ended) ||
      Array.from(contexts).some(ctx => ctx.state === 'running');
    const candidates = [];
    const seen = new Map();
    const episodes = [];
    const episodeSeen = new Map();
    for (const node of nodes) {
      const raw = node.currentSrc || node.src || '';
      addCandidate(candidates, seen, raw, node.type, Number.isFinite(node.duration) ? node.duration * 1000 : undefined, true, undefined, node.poster || '');
    }
    const selector = mediaAttributes.map(name => `[${name}]`).join(',');
    document.querySelectorAll(selector).forEach(element => {
      if (!element || typeof element.getAttribute !== 'function') return;
      const mime = element.getAttribute('type') || '';
      const poster = element.getAttribute('poster') || element.getAttribute('data-poster') || '';
      const episode = element.getAttribute('data-episode') ||
        element.getAttribute('data-episode-index') || element.getAttribute('data-num') ||
        /第\s*(\d+)\s*[集话期]/.exec(element.textContent || '')?.[1] || '';
      for (const name of mediaAttributes) {
        const raw = element.getAttribute(name);
        addCandidate(candidates, seen, raw, mime, undefined, false, undefined, poster, episode);
        addCandidate(episodes, episodeSeen, raw, mime, undefined, false, undefined, poster, episode);
      }
    });
    // Resource timing is a fallback until a media element has confirmed real
    // playback. A placeholder or not-yet-loaded currentSrc must not hide the
    // manifest that the page actually fetched; the identity map removes exact
    // repeats and known signature changes.
    const hasConfirmedPlayback = Array.from(nodes).some(node => {
      const raw = node.currentSrc || node.src || '';
      return Boolean(raw) && looksMedia(raw, node.type || '') &&
        !node.paused && !node.ended;
    });
    const hasMeaningfulMediaElement = Array.from(nodes).some(node => {
      const raw = node.currentSrc || node.src || '';
      return /^https?:/i.test(raw) && looksMedia(raw, node.type || '') &&
        !/placeholder|loading|blank/i.test(raw);
    });
    if ((!hasConfirmedPlayback && !hasMeaningfulMediaElement) &&
        typeof performance !== 'undefined' && typeof performance.getEntriesByType === 'function') {
      for (const entry of performance.getEntriesByType('resource').slice(-256)) {
        if (isTransportResource(entry.name)) continue;
        addCandidate(candidates, seen, entry.name, entry.initiatorType || '');
      }
    }
    if (episodes.length > 1) {
      const episodeByUrl = new Map();
      episodes.forEach((item, index) => {
        const number = item.episodeNumber;
        if (number != null) {
          const series = item.title.replace(/\s*[-–—|]?\s*(?:第\s*\d+\s*[集话期]|\b(?:episode|ep|e)\s*[:=_-]?\s*\d+\b)\s*$/gi, '').trim();
          item.title = `${series} - 第${number}集`;
        }
        episodeByUrl.set(item.url, item);
      });
      for (const item of candidates) {
        const episode = episodeByUrl.get(item.url);
        if (episode) {
          item.title = episode.title;
          item.episodeNumber = episode.episodeNumber;
          if (!item.thumbnail && episode.thumbnail) item.thumbnail = episode.thumbnail;
        }
      }
    }
    // Resource timing can contain ads and manifests; only a page-exposed
    // playlist may advertise episode switching.
    lastCandidateList = episodes;
    if (!connected) { connect(); return; }
    const state = {
      playing,
      resumable: resumeNodes.size > 0 || resumeContexts.size > 0 ||
        (lastActiveNode != null && nodes.has(lastActiveNode) && !lastActiveNode.ended),
      canSkip: canSwitchCandidate(),
      title: (document.title || '').slice(0, 512),
    };
    const stateKey = JSON.stringify(state);
    if (stateKey !== lastState) { lastState = stateKey; post('state', state); }
    const candidateKey = JSON.stringify(candidates);
    if (candidateKey === lastCandidates) return;
    lastCandidates = candidateKey;
    // Discovery must never make playback state exceed the native message limit.
    let batch = [];
    for (const candidate of candidates.slice(0, 256)) {
      const message = {kind:'candidates', token:config.token, frame:frameId, document:documentId, epoch, candidates:[...batch,candidate]};
      if (JSON.stringify(message).length > 4096) {
        if (batch.length) post('candidates', {candidates:batch});
        batch = [];
      }
      if (JSON.stringify({...message,candidates:[candidate]}).length <= 4096) batch.push(candidate);
    }
    if (batch.length) post('candidates', {candidates:batch});
  }

  // Video pages often mutate their player DOM hundreds of times per second.
  // Coalesce those callbacks so discovery cannot starve the renderer or the
  // page's own playback thread.
  function scheduleReport() {
    if (reportScheduled) { reportAgain = true; return; }
    reportScheduled = true;
    if (typeof setTimeout !== 'function') {
      reportScheduled = false;
      try { report(); } catch (_) {}
      return;
    }
    const delay = Math.max(0, 120 - (Date.now() - lastReportAt));
    setTimeout(() => {
      reportScheduled = false;
      lastReportAt = Date.now();
      try { report(); } catch (_) {}
      if (reportAgain) {
        reportAgain = false;
        scheduleReport();
      }
    }, delay);
  }
  // Best-effort episode switching for pages that expose their playlist through
  // data-play-src/data-video-src attributes. The page remains authoritative;
  // this only changes the already-discovered media element and never invents
  // a URL or performs a network request itself.
  function canSwitchCandidate() {
    const node = lastActiveNode;
    if (!node || !node.isConnected || lastCandidateList.length < 2) return false;
    try {
      const current = new URL(node.currentSrc || node.src || '', document.baseURI);
      // Never replace a MediaSource/blob player with a raw manifest URL.
      if (!['http:', 'https:'].includes(current.protocol)) return false;
      return lastCandidateList.some(item => candidateKey(new URL(item.url)) === candidateKey(current));
    } catch (_) { return false; }
  }
  function switchCandidate(direction) {
    collect();
    if (!canSwitchCandidate()) return false;
    const node = lastActiveNode;
    if (!node) return false;
    const current = node.currentSrc || node.src || '';
    let currentKey = '';
    try { currentKey = candidateKey(new URL(current, document.baseURI)); } catch (_) {}
    const index = lastCandidateList.findIndex(candidate => {
      try { return candidateKey(new URL(candidate.url, document.baseURI)) === currentKey; }
      catch (_) { return false; }
    });
    const targetIndex = index < 0
      ? (direction > 0 ? 0 : lastCandidateList.length - 1)
      : index + direction;
    if (targetIndex < 0 || targetIndex >= lastCandidateList.length) return false;
    const target = lastCandidateList[targetIndex];
    if (!target || target.url === current) return false;
    try {
      blocked = false;
      needsGesture = false;
      node.pause();
      node.src = target.url;
      if (typeof node.load === 'function') node.load();
      return Promise.resolve(originalPlay.call(node)).then(() => { scheduleReport(); return true; }, () => false);
    } catch (_) { return false; }
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
    scheduleReport();
  }
  async function resume() {
    collect();
    blocked = false;
    needsGesture = false;
    const targets = Array.from(resumeNodes);
    // A system play command can resume the active element paused by the site,
    // without reviving every old paused/ended player in the document.
    if (!targets.length) {
      const node = lastActiveNode;
      if (node && nodes.has(node) && !node.ended) targets.push(node);
    }
    const results = await Promise.all(targets.map(async node => {
      try {
        await originalPlay.call(node);
        if (blocked || !alive) { node.pause(); return false; }
        lastActiveNode = node;
        resumeNodes.delete(node);
        return true;
      } catch (_) { resumeNodes.add(node); return false; }
    }));
    const audioResults = await Promise.all(Array.from(resumeContexts).map(async ctx => {
      try {
        await ctx.resume();
        if (blocked || !alive) { await ctx.suspend(); return false; }
        resumeContexts.delete(ctx); return true;
      }
      catch (_) { return false; }
    }));
    scheduleReport();
    return results.length + audioResults.length > 0 && [...results,...audioResults].every(Boolean);
  }
  async function apply(action) {
    collect();
    if (action === 'pause') { blocked = true; pause(); return true; }
    if (action === 'unblock') { blocked = false; return true; }
    if (action === 'resume') return resume();
    if (action === 'next' || action === 'previous') {
      blocked = false;
      needsGesture = false;
      return switchCandidate(action === 'next' ? 1 : -1);
    }
    return false;
  }
  if (bridge) bridge.onmessage = async event => {
    let data;
    try { data = JSON.parse(event.data); } catch (_) { return; }
    if (!alive || data.token !== config.token || data.frame !== frameId || data.document !== documentId ||
        !Number.isSafeInteger(data.epoch) || data.epoch < epoch ||
        !Number.isSafeInteger(data.command) || data.command <= commandSequence ||
        !['pause','unblock','resume','next','previous'].includes(data.action)) return;
    epoch = data.epoch;
    commandSequence = data.command;
    const first = !connected;
    connected = true;
    const ok = await apply(data.action);
    post('ack', {command:data.command, ok});
    if (first) { lastState = ''; lastCandidates = ''; }
    scheduleReport();
  };
  window.addEventListener('message', event => {
    const data = event.data;
    if (!data || data.token !== config.token) return;
    if (alive && documentId && data.kind === 'site-lens-media-frame-gone') {
      const knownFrame = event.source && childFrames.get(event.source);
      const targetFrame = data.childFrame || data.frame;
      const targetParent = data.childParentFrame || frameId;
      if (knownFrame === data.frame &&
          typeof targetFrame === 'string' && /^[a-zA-Z0-9_-]{1,96}$/.test(targetFrame) &&
          typeof targetParent === 'string' && /^[a-zA-Z0-9_-]{1,96}$/.test(targetParent)) {
        setTimeout(() => {
          if (!alive || !documentId) return;
          if (window.parent === window) {
            post('gone', {
              childFrame: targetFrame,
              childParentFrame: targetParent,
            });
            return;
          }
          try {
            window.parent.postMessage({
              kind: 'site-lens-media-frame-gone',
              token: config.token,
              frame: frameId,
              childFrame: targetFrame,
              childParentFrame: targetParent,
            }, '*');
          } catch (_) {}
        }, 0);
      }
      return;
    }
    if (alive && documentId && data.kind === 'site-lens-media-frame-hello') {
      if (directChildren().includes(event.source) &&
          typeof data.frame === 'string' && /^[a-zA-Z0-9_-]{1,96}$/.test(data.frame)) {
        childFrames.set(event.source, data.frame);
        try {
          event.source.postMessage({
            kind: 'site-lens-media-frame-id',
            token: config.token,
            document: documentId,
            parentFrame: frameId,
          }, '*');
        } catch (_) {}
      }
      return;
    }
    if (window.parent !== window &&
        event.source === window.parent &&
        data.kind === 'site-lens-media-frame-id' &&
        typeof data.document === 'string' && /^[a-zA-Z0-9_-]{1,96}$/.test(data.document) &&
        typeof data.parentFrame === 'string' && /^[a-zA-Z0-9_-]{1,96}$/.test(data.parentFrame)) {
      parentFrameId = data.parentFrame;
      if (documentId && documentId !== data.document) {
        blocked = true;
        pause();
        frameId = newFrameId();
        parentFrameId = data.parentFrame;
        epoch = -1; commandSequence = -1; connected = false;
        lastState = ''; lastCandidates = '';
      }
      if (documentId === data.document) {
        broadcastDocumentId();
        post('hello', {parentFrame: parentFrameId});
        return;
      }
      documentId = data.document;
      broadcastDocumentId();
      post('hello', {parentFrame: parentFrameId});
    }
  });
  Object.defineProperty(window, '__siteLensMediaControl', {value: {apply, connect}, configurable: false});
  HTMLMediaElement.prototype.play = function (...args) {
    if (!this.isConnected) connectedBefore.delete(this);
    track(this);
    if (blocked || needsGesture) {
      return Promise.reject(new DOMException('Media paused by application policy', 'NotAllowedError'));
    }
    lastActiveNode = this;
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
          if (blocked && ctx.state === 'running') pause(); else scheduleReport();
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
  window.addEventListener('pagehide', () => {
    if (window.parent !== window) {
      try {
        window.parent.postMessage({
          kind: 'site-lens-media-frame-gone',
          token: config.token,
          frame: frameId,
        }, '*');
      } catch (_) {}
    }
    alive = false;
    blocked = true;
    pause();
  });
  window.addEventListener('pageshow', event => {
    if (event.persisted) {
      frameId = newFrameId();
      documentId = window.parent === window ? frameId : null;
      parentFrameId = null;
      epoch = -1; commandSequence = -1;
      connected = false; alive = true; lastState = ''; lastCandidates = '';
    }
    connect();
  });
  if (typeof MutationObserver === 'function') {
    new MutationObserver(() => scheduleReport()).observe(document, {childList:true,subtree:true});
  }
  document.addEventListener('DOMContentLoaded', () => { collect(); if (blocked) pause(); else scheduleReport(); });
  if (typeof setInterval === 'function') setInterval(() => { connect(); if (connected) scheduleReport(); }, 1500);
  connect();
})();
