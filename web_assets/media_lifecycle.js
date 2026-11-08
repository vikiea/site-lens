// App-owned, unprivileged media lifecycle support. This object cannot access
// GM storage, network, cookies, native navigation or script authorization.
(function () {
  'use strict';
  if (window.__siteLensMediaControl) return;
  const config = __SITE_LENS_MEDIA_CONFIG__;
  const nodes = new Set();
  const connectedBefore = new WeakSet();
  const watched = new WeakSet();
  const staleNodeSources = new WeakMap();
  const observedNodeSources = new WeakMap();
  const staleElementSources = new WeakMap();
  const observedInitialData = new WeakMap();
  const staleInitialData = new WeakMap();
  const episodeResponses = new Map();
  let explicitEpisodeIdentities = new Map();
  const candidatePriorities = new WeakMap();
  const playbackBindings = new WeakMap();
  const networkResources = new Map();
  const latestEpisodeRequests = new Map();
  const episodePageRequests = new Map();
  const episodePageControllers = new Map();
  const episodePageAttempts = new Set();
  let episodePageQueue = [];
  let episodePageActive = 0;
  let episodePageSequence = 0;
  const knownForeignSources = new Map();
  // Ownership survives SPA visits: a partially updated page map or reused
  // player cannot relabel a previously observed series' bytes. Bound this
  // document-local ledger without evicting old ownership and accepting it
  // again later. A full ledger rejects new identities until document reload.
  const knownSeriesSources = new Map();
  let knownSeriesSourceChars = 0;
  let responseSeries = null;
  let seriesVisit = 0;
  let requestSequence = 0;
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
  let lastPageUrl = pageUrl();
  let snapshotStartedAt = typeof performance !== 'undefined' && typeof performance.now === 'function'
    ? performance.now()
    : 0;
  let snapshotSequence = 0;
  let evidenceSequence = 0;
  let nextMediaElementId = 0;
  const mediaElementIds = new WeakMap();
  let reportScheduled = false;
  let reportAgain = false;
  let lastReportAt = 0;
  const originalPlay = HTMLMediaElement.prototype.play;

  function mediaElementId(node) {
    if (!node || typeof node !== 'object') return '';
    let id = mediaElementIds.get(node);
    if (!id) {
      id = `media-${++nextMediaElementId}`;
      mediaElementIds.set(node, id);
    }
    return id;
  }

  function track(node) {
    if (connectedBefore.has(node) && !node.isConnected) return;
    nodes.add(node);
    mediaElementId(node);
    if (node.isConnected) connectedBefore.add(node);
    if (!watched.has(node) && typeof node.addEventListener === 'function') {
      watched.add(node);
      for (const type of ['play','playing','pause','ended','emptied','loadstart','loadedmetadata','durationchange']) {
        node.addEventListener(type, () => mediaEvent(type,node));
      }
    }
  }
  function mediaEvent(type,node) {
    beginSnapshotIfNeeded();
    track(node);
    // Buffered playback can emit these events after a SPA route change.
    // Only a changed source (or a new media element) can bind to the new page.
    if ((type === 'play' || type === 'playing') && !node.paused && !node.ended &&
        isCurrentPlaybackNode(node)) {
      rememberPlaybackBinding(node);
      lastActiveNode = node;
    }
    if (['ended','emptied'].includes(type) || (['play','playing'].includes(type) && !node.paused && !node.ended)) resumeNodes.delete(node);
    if (blocked && type!=='pause' && type!=='ended') pause(); else scheduleReport();
  }
  function isFreshNode(node) {
    const raw = mediaSourceIdentity(node.currentSrc || node.src || '');
    if (staleNodeSources.has(node)) {
      if (raw === staleNodeSources.get(node)) return false;
      staleNodeSources.delete(node);
    }
    if (!acceptSeriesSource(node.currentSrc || node.src || '')) return false;
    observedNodeSources.set(node, raw);
    return true;
  }
  function mediaSourceIdentity(raw) {
    try {
      const url = new URL(raw, document.baseURI);
      url.hash = '';
      return candidateKey(url);
    } catch (_) { return raw; }
  }
  function elementSourceIdentities(element) {
    // Counters, labels and rotating credentials cannot reauthorize a retired
    // node on a new SPA page. Only a changed media resource can do that.
    const identities = new Set();
    for (const name of mediaAttributes) {
      const raw = element.getAttribute(name);
      if (typeof raw !== 'string' || !raw.trim()) continue;
      try {
        const url = new URL(raw, document.baseURI);
        if (['http:', 'https:'].includes(url.protocol) && !url.username && !url.password) {
          identities.add(mediaSourceIdentity(raw));
        }
      } catch (_) {}
    }
    return identities;
  }
  function elementEpisode(element) {
    if (!element || typeof element.getAttribute !== 'function') return null;
    const explicit = element.getAttribute('data-episode') ||
      element.getAttribute('data-episode-index') || element.getAttribute('data-num');
    if (explicit) return episodeNumber(explicit);
    const text = String(element.textContent || '').trim();
    // A player container may include every episode label in its descendants.
    // Only a short, single episode label can annotate its own media URL.
    if (text.length > 120) return null;
    const matches = [...text.matchAll(/第\s*(\d+)\s*[集话期]/g)];
    const values = new Set(matches.map(match => episodeNumber(match[1])).filter(value => value != null));
    return values.size === 1 ? values.values().next().value : null;
  }
  function initialDataElement() {
    return typeof document.getElementById === 'function'
      ? document.getElementById('videoInitialData')
      : null;
  }
  function pageCdnHeaders(scope) {
    const element = initialDataElement();
    if (!element || element.getAttribute('type') !== 'application/json') return {};
    try {
      const data = JSON.parse(element.textContent || '{}');
      const key = String(data.cdnAuthKey || '').trim().toLowerCase();
      const value = String(data.cdnAuthValue || '').trim();
      const app = String(data.cdnApp || '').trim();
      if (key !== 'x-cdn-auth' || !value || !app) return {};
      if (scope === 'manifest' && data.cdnM3u8Enabled !== true) return {};
      if (scope === 'resource' && data.cdnOtherEnabled !== true) return {};
      return {'x-cdn-auth': value, 'x-cdn-app': app};
    } catch (_) { return {}; }
  }
  function explicitMediaUrl(raw) {
    if (typeof raw !== 'string') return null;
    try {
      const url = new URL(raw, document.baseURI);
      return ['http:', 'https:'].includes(url.protocol) && !url.username && !url.password &&
        looksMedia(url.pathname, '') ? url : null;
    } catch (_) { return null; }
  }
  function acceptSeriesSource(raw, context = routeSeriesContext()) {
    if (!context) return true;
    if (typeof raw !== 'string' || !raw.trim()) return true;
    let url;
    try { url = new URL(raw, document.baseURI); } catch (_) { return true; }
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) return true;
    const key = mediaSourceIdentity(url.href);
    const owner = knownSeriesSources.get(key);
    if (owner != null) return owner === context.series;
    const chars = key.length + context.series.length;
    if (knownSeriesSources.size >= 4096 || knownSeriesSourceChars + chars > 1024 * 1024) return false;
    knownSeriesSources.set(key, context.series);
    knownSeriesSourceChars += chars;
    return true;
  }
  function readEpisodeSources() {
    const element = initialDataElement();
    if (!element || element.getAttribute('type') !== 'application/json') return [];
    const raw = element.textContent || '';
    // Read explicit data only; never execute page code, fetch episode pages,
    // or treat a declared episode count/recommendation list as media URLs.
    if (raw.length > 256 * 1024) return [];
    try {
      const data = JSON.parse(raw);
      if (!data || typeof data !== 'object' || Array.isArray(data)) return [];
      const sources = data.epPlaySrcs;
      if (!sources || typeof sources !== 'object' || Array.isArray(sources)) return [];
      const entries = Object.entries(sources);
      if (entries.length > 256) return [];
      const route = /^\/video\/([1-9]\d{0,11})(?:\/ep-([1-9]\d{0,4}))?\/?$/.exec(new URL(pageUrl()).pathname);
      if (route && data.id != null && String(data.id) !== route[1]) return [];
      // A title/counter/like update cannot authorize the previous route's URLs.
      const identity = JSON.stringify(sources);
      if (staleInitialData.has(element)) {
        if (identity === staleInitialData.get(element)) return [];
        staleInitialData.delete(element);
      }
      observedInitialData.set(element, identity);
      return entries.filter(([number, url]) =>
        /^[1-9]\d{0,4}$/.test(number) && explicitMediaUrl(url) != null &&
        acceptSeriesSource(url)
      ).map(([number, url]) => ({
        number: Number(number), url,
        title: typeof data.title === 'string'
          ? data.title
          : (typeof data.videoTitle === 'string' ? data.videoTitle : document.title),
        poster: typeof data.posterSrc === 'string' ? data.posterSrc : '',
      }));
    } catch (_) { return []; }
  }

  function readEpisodeLinks() {
    const context = episodeContext();
    if (!context || typeof document.querySelectorAll !== 'function') return [];
    const found = new Map();
    let elements = [];
    try {
      elements = Array.from(document.querySelectorAll(
        '[data-ep-id],[data-episode],[data-episode-index],[data-num],a[href*="/ep-"]',
      ));
    } catch (_) { return []; }
    for (const element of elements) {
      if (!element || typeof element.getAttribute !== 'function') continue;
      const rawHref = element.getAttribute('href') || element.href || '';
      let url;
      try { url = new URL(rawHref, document.baseURI); } catch (_) { continue; }
      if (url.origin !== context.origin || url.username || url.password) continue;
      const route = /^\/video\/([1-9]\d{0,11})(?:\/ep-([1-9]\d{0,4}))?\/?$/.exec(url.pathname);
      if (!route || route[1] !== context.id) continue;
      const explicit = element.getAttribute('data-ep-id') ||
        element.getAttribute('data-episode') ||
        element.getAttribute('data-episode-index') || element.getAttribute('data-num');
      const number = episodeNumber(explicit || route[2]);
      if (number == null) continue;
      const title = String(
        element.getAttribute('aria-label') || element.getAttribute('data-title') ||
        element.textContent || `第${number}集`,
      ).trim().slice(0, 512);
      if (!found.has(number)) found.set(number, {
        number,
        url: url.href,
        title: title || `第${number}集`,
      });
    }
    return [...found.values()].sort((left, right) => left.number - right.number);
  }

  function decodeEpisodePageJson(raw) {
    return String(raw)
      .replace(/&quot;/g, '"')
      .replace(/&#34;/g, '"')
      .replace(/&#39;/g, "'")
      .replace(/&#x27;/g, "'")
      .replace(/&amp;/g, '&');
  }

  function episodePageSource(text, request, context, ownerPage = request.url) {
    if (typeof text !== 'string' || text.length > 256 * 1024) return null;
    const match = text.match(
      /<script[^>]*id=["']videoInitialData["'][^>]*>([\s\S]*?)<\/script>/i,
    );
    if (!match || !match[1]) return null;
    try {
      const data = JSON.parse(decodeEpisodePageJson(match[1]));
      if (!data || typeof data !== 'object' || Array.isArray(data) ||
          String(data.id) !== context.id) return null;
      const sources = data.epPlaySrcs && typeof data.epPlaySrcs === 'object'
        ? data.epPlaySrcs : {};
      let raw = sources[String(request.number)];
      if (!raw && Number(data.ep) === request.number) raw = data.videoSrc;
      const url = explicitMediaUrl(raw);
      if (!url || !acceptSeriesSource(url.href, context)) return null;
      return {
        number: request.number,
        url: url.href,
        pageUrl: ownerPage,
        title: typeof data.title === 'string' && data.title.trim()
          ? `${data.title.trim()} - 第${request.number}集`
          : request.title,
        poster: typeof data.posterSrc === 'string' ? data.posterSrc : '',
        priority: 2,
      };
    } catch (_) { return null; }
  }

  async function resolveEpisodePage(request) {
    const context = episodeContext();
    if (!alive || !context || context.series !== request.series ||
        request.visit !== seriesVisit || typeof window.fetch !== 'function') return;
    let controller = null;
    let timer = null;
    try {
      if (typeof AbortController === 'function') controller = new AbortController();
      if (controller) episodePageControllers.set(request.number, controller);
      timer = typeof setTimeout === 'function'
        ? setTimeout(() => controller?.abort(), 10000)
        : null;
      const response = await window.fetch(request.url, {
        method: 'GET',
        credentials: 'same-origin',
        redirect: 'follow',
        ...(controller ? {signal: controller.signal} : {}),
      });
      const current = episodeContext();
      const finalUrl = new URL(response.url || request.url, request.url);
      if (!response?.ok || !current || current.series !== request.series ||
          request.visit !== seriesVisit || finalUrl.origin !== current.origin ||
          typeof response.text !== 'function') return;
      const item = episodePageSource(await response.text(), request, current, finalUrl.href);
      if (!item || episodePageRequests.get(request.number)?.sequence !== request.sequence) return;
      episodeResponses.delete(request.number);
      episodeResponses.set(request.number, item);
      scheduleReport();
    } catch (_) {
      // Page-owned discovery is best effort; the current media remains usable.
    } finally {
      if (timer != null) clearTimeout(timer);
      if (episodePageControllers.get(request.number) === controller) {
        episodePageControllers.delete(request.number);
      }
      if (episodePageRequests.get(request.number)?.sequence === request.sequence) {
        episodePageRequests.delete(request.number);
      }
      episodePageActive = Math.max(0, episodePageActive - 1);
      pumpEpisodePages();
    }
  }

  function pumpEpisodePages() {
    while (episodePageActive < 2 && episodePageQueue.length > 0) {
      const context = episodeContext();
      if (!alive || !context || blocked || !connected) {
        episodePageQueue = [];
        return;
      }
      const link = episodePageQueue.shift();
      if (!link || episodePageRequests.has(link.number)) continue;
      const request = {
        ...link,
        series: context.series,
        visit: seriesVisit,
        sequence: ++episodePageSequence,
      };
      episodePageRequests.set(request.number, request);
      episodePageActive += 1;
      void resolveEpisodePage(request);
    }
  }

  function scheduleEpisodePageResolution() {
    const context = episodeContext();
    if (!alive || blocked || !connected || !context) return;
    const explicit = new Set([...explicitEpisodeIdentities.keys(), ...episodeResponses.keys()]);
    for (const link of readEpisodeLinks()) {
      if (explicit.has(link.number)) continue;
      const attempt = `${link.number}\u0000${link.url}`;
      if (episodePageAttempts.has(attempt) || episodePageRequests.has(link.number)) continue;
      episodePageAttempts.add(attempt);
      episodePageQueue.push(link);
    }
    pumpEpisodePages();
  }
  function routeSeriesContext(raw = pageUrl()) {
    try {
      const page = new URL(raw);
      const match = /^\/video\/([1-9]\d{0,11})(?:\/ep-([1-9]\d{0,4}))?\/?$/.exec(page.pathname);
      return match ? {series: page.origin + '/video/' + match[1], id: match[1], origin: page.origin} : null;
    } catch (_) { return null; }
  }
  function episodeContext() {
    try {
      const route = routeSeriesContext();
      const element = initialDataElement();
      if (!route || !element || element.getAttribute('type') !== 'application/json') return null;
      const raw = element.textContent || '';
      if (raw.length > 256 * 1024) return null;
      const data = JSON.parse(raw);
      if (!data || String(data.id) !== route.id) return null;
      return route;
    } catch (_) { return null; }
  }
  // The page's own episode field, used only when neither the path nor the
  // query names one. It keeps a single-resource player attributable without
  // guessing across a series.
  function initialEpisode() {
    const element = initialDataElement();
    if (!element) return null;
    try {
      const data = JSON.parse(element.textContent || '{}');
      const value = Number(data.ep);
      return Number.isFinite(value) && value > 0 && value < 100000 ? value : null;
    } catch (_) { return null; }
  }
  function explicitSeriesIdentity(element) {
    const candidates = [];
    const add = value => {
      if (typeof value !== 'string') return;
      const normalized = value.trim();
      if (normalized && normalized.length <= 256) candidates.push(normalized);
    };
    const owner = element?.closest?.(
      '[data-series-id],[data-series-key],[data-show-id],[data-play-id]'
    );
    if (owner && typeof owner.getAttribute === 'function') {
      add(owner.getAttribute('data-series-id'));
      add(owner.getAttribute('data-series-key'));
      add(owner.getAttribute('data-show-id'));
      add(owner.getAttribute('data-play-id'));
    }
    const root = document.documentElement;
    if (root && typeof root.getAttribute === 'function') {
      add(root.getAttribute('data-series-id'));
      add(root.getAttribute('data-series-key'));
      add(root.getAttribute('data-show-id'));
    }
    const elementData = initialDataElement();
    if (elementData && elementData.getAttribute?.('type') === 'application/json') {
      try {
        const raw = elementData.textContent || '';
        if (raw.length <= 256 * 1024) {
          const data = JSON.parse(raw);
          if (data && typeof data === 'object' && !Array.isArray(data)) {
            add(String(data.seriesId ?? ''));
            add(String(data.seriesKey ?? ''));
          }
        }
      } catch (_) { /* Explicit page identity is advisory and fail-closed. */ }
    }
    const value = candidates[0];
    if (!value) return null;
    let origin = '';
    try { origin = new URL(pageUrl()).origin; } catch (_) {}
    return `explicit:${origin}:${value}`.slice(0, 512);
  }
  function belongsToSeries(element, context) {
    if (!context || typeof element.closest !== 'function') return true;
    const owner = element.closest('[data-play-id]');
    if (!owner || typeof owner.getAttribute !== 'function') return true;
    return owner.getAttribute('data-play-id') === context.id;
  }
  function isCurrentPlaybackNode(node) {
    return belongsToSeries(node, routeSeriesContext());
  }
  function playbackOwner(node) {
    if (!node || typeof node.closest !== 'function') return null;
    const owner = node.closest('[data-play-id]');
    const value = owner?.getAttribute?.('data-play-id');
    return typeof value === 'string' && value ? value : null;
  }
  function playbackSource(node) {
    return mediaSourceIdentity(node?.currentSrc || node?.src || '');
  }
  function rememberPlaybackBinding(node) {
    if (!isCurrentPlaybackNode(node)) return;
    playbackBindings.set(node, {
      source: playbackSource(node),
      owner: playbackOwner(node),
    });
  }
  function isPlaybackControlNode(node) {
    if (!node || !nodes.has(node) || (!node.isConnected && connectedBefore.has(node))) return false;
    if (isCurrentPlaybackNode(node)) return true;
    const binding = playbackBindings.get(node);
    return Boolean(binding) && binding.source === playbackSource(node) &&
      binding.owner === playbackOwner(node);
  }
  function rememberForeignSource(element, raw) {
    if (typeof element.closest !== 'function') return;
    const owner = element.closest('[data-play-id]');
    const id = owner?.getAttribute('data-play-id');
    const url = explicitMediaUrl(raw);
    if (!id || !url) return;
    const key = candidateKey(url);
    knownForeignSources.delete(key);
    knownForeignSources.set(key, id);
    while (knownForeignSources.size > 512) knownForeignSources.delete(knownForeignSources.keys().next().value);
  }
  function episodeRequest(raw, method) {
    if (String(method || 'GET').toUpperCase() !== 'GET' || typeof raw !== 'string') return null;
    const context = episodeContext();
    if (!context) return null;
    try {
      const url = new URL(raw, document.baseURI);
      if (url.origin !== context.origin || url.username || url.password ||
          url.pathname !== '/api/videos/' + context.id + '/play') return null;
      const values = url.searchParams.getAll('ep');
      if (values.length !== 1 || !/^[1-9]\d{0,4}$/.test(values[0])) return null;
      return {...context, episode: Number(values[0]), url: url.href};
    } catch (_) { return null; }
  }
  function syncEpisodeSeries() {
    const series = episodeContext()?.series || null;
    if (series !== responseSeries) {
      responseSeries = series;
      seriesVisit++;
      episodeResponses.clear();
      latestEpisodeRequests.clear();
      explicitEpisodeIdentities.clear();
      episodePageQueue = [];
      episodePageAttempts.clear();
      episodePageSequence++;
      for (const controller of episodePageControllers.values()) controller.abort();
      episodePageControllers.clear();
      episodePageRequests.clear();
    }
    const explicit = readEpisodeSources();
    const next = new Map(explicit.map(item =>
      [item.number, new URL(item.url, document.baseURI).href]));
    // A later page map supersedes older responses for the changed episodes,
    // including in-flight requests. Unchanged episodes retain their prefetch.
    for (const number of new Set([...explicitEpisodeIdentities.keys(), ...next.keys()])) {
      if (explicitEpisodeIdentities.get(number) !== next.get(number)) {
        episodeResponses.delete(number);
        latestEpisodeRequests.delete(number);
      }
    }
    explicitEpisodeIdentities = next;
    return explicit;
  }
  // Endpoints that answer with a media address. A site is free to change its
  // route, so the check is on the shape of the path rather than one exact
  // string; the episode number is read from whichever segment carries it.
  const PLAYBACK_PATH = /^\/api\/videos\/([1-9]\d{0,11})(?:\/(?:episodes\/)?(\d{1,5}))?(?:\/(?:play|playback))?\/?$/i;
  // Every rejection below is counted so a missing observation names its
  // reason instead of leaving an empty payload unexplained.
  let requestDiagnostics = {};
  function noteRequestReject(reason) {
    requestDiagnostics[reason] = (requestDiagnostics[reason] || 0) + 1;
  }
  // Names the endpoints the page actually calls, so a missing match can be
  // traced to the hook never seeing that URL at all.
  function noteSeen(raw, method) {
    try {
      const text = String(raw && raw.url ? raw.url : raw || '');
      if (text.length > 512) return;
      const path = new URL(text, document.baseURI).pathname;
      // Skip only static assets. Any other path can be the one the match rule
      // rejects, and a keyword filter here would hide exactly that case.
      if (/\.(?:js|css|png|jpe?g|gif|webp|svg|ico|woff2?|ttf|otf|ts|m4s)$/i.test(path)) return;
      // Path only: a query string can push the counters past the log budget,
      // and the path is what decides whether the match rule is wrong.
      const key = String(method || 'GET').toUpperCase() + ' ' + path.slice(0, 80);
      requestDiagnostics['seen:' + key] = (requestDiagnostics['seen:' + key] || 0) + 1;
    } catch (_) {}
  }
  function playbackRequest(raw, method) {
    const verb = String(method || 'GET').toUpperCase();
    if (verb !== 'GET' && verb !== 'POST') return null;
    const context = episodeContext();
    if (!context) { noteRequestReject('no_context'); return null; }
    try {
      const url = new URL(raw, document.baseURI);
      if (url.origin !== context.origin || url.username || url.password) {
        noteRequestReject('origin');
        return null;
      }
      const match = PLAYBACK_PATH.exec(url.pathname);
      if (!match) { noteRequestReject('path_shape'); return null; }
      if (match[1] !== context.id) { noteRequestReject('id_mismatch'); return null; }
      // Prefer the path segment, then the query, then the current episode.
      const fromPath = match[2] ? Number(match[2]) : null;
      const queryValues = url.searchParams.getAll('ep');
      const fromQuery = queryValues.length === 1 && /^[1-9]\d{0,4}$/.test(queryValues[0])
        ? Number(queryValues[0]) : null;
      const episode = fromPath ?? fromQuery ?? initialEpisode() ?? null;
      if (!episode) { noteRequestReject('no_episode'); return null; }
      requestDiagnostics['accepted'] = (requestDiagnostics['accepted'] || 0) + 1;
      return {...context, episode, url: url.href};
    } catch (_) { noteRequestReject('parse'); return null; }
  }
  function startEpisodeRequest(raw, method) {
    if (!alive) return null;
    beginSnapshotIfNeeded();
    syncEpisodeSeries();
    const request = playbackRequest(raw, method) || episodeRequest(raw, method);
    if (!request) return null;
    const sequence = ++requestSequence;
    latestEpisodeRequests.delete(request.episode);
    latestEpisodeRequests.set(request.episode, sequence);
    while (latestEpisodeRequests.size > 256) latestEpisodeRequests.delete(latestEpisodeRequests.keys().next().value);
    return {...request, visit: seriesVisit, sequence};
  }
  function observeEpisodeResponse(request, text, finalUrl) {
    if (!alive || !request || typeof text !== 'string' || text.length > 256 * 1024) return;
    beginSnapshotIfNeeded();
    syncEpisodeSeries();
    const current = episodeContext();
    // Re-check with the same rule that accepted the request: a POST playback
    // call has no GET equivalent, so validating the final URL with the legacy
    // matcher discarded every response the modern rule had accepted.
    const finalRequest = playbackRequest(finalUrl, 'GET') || episodeRequest(finalUrl, 'GET');
    if (request.visit !== seriesVisit || latestEpisodeRequests.get(request.episode) !== request.sequence ||
        !current || current.series !== request.series || !finalRequest ||
        finalRequest.episode !== request.episode) return;
    try {
      const response = JSON.parse(text);
      // The address is not required to sit at a fixed field. Any string that
      // names a media manifest is a candidate, as long as the payload still
      // identifies this series and this episode.
      const found = mediaUrlsIn(response);
      if (!found.length) return;
      if (!payloadMatchesEpisode(response, request)) return;
      for (const raw of found) {
        const url = explicitMediaUrl(raw);
        if (!url || !acceptSeriesSource(url.href, current)) continue;
        episodeResponses.delete(request.episode);
        episodeResponses.set(request.episode, {number: request.episode, url: url.href, priority: 2});
        while (episodeResponses.size > 256) episodeResponses.delete(episodeResponses.keys().next().value);
        scheduleReport();
        return;
      }
    } catch (_) {}
  }
  // Every string in the payload that names a manifest, bounded so a large
  // response cannot turn into an unbounded scan.
  function mediaUrlsIn(value, depth = 0, out = []) {
    if (depth > 6 || out.length >= 32) return out;
    if (typeof value === 'string') {
      if (value.length <= 2048 && looksMedia(value, '')) out.push(value);
      return out;
    }
    if (!value || typeof value !== 'object') return out;
    const entries = Array.isArray(value) ? value.slice(0, 64) : Object.values(value);
    for (const entry of entries) mediaUrlsIn(entry, depth + 1, out);
    return out;
  }
  // A payload may describe many episodes. Only its own identity fields may
  // confirm which one it answers; when they are absent the request is trusted,
  // because the caller already matched the series and the episode.
  function payloadMatchesEpisode(response, request) {
    const ids = [];
    const episodes = [];
    (function walk(value, depth) {
      if (depth > 6 || !value || typeof value !== 'object') return;
      for (const [key, entry] of Object.entries(value)) {
        if (/^(id|video_id|series_id)$/i.test(key)) ids.push(String(entry));
        if (/^(ep_num|ep_num_id|episode|ep|episode_num)$/i.test(key)) episodes.push(String(entry));
        walk(entry, depth + 1);
      }
    })(response, 0);
    if (ids.length && !ids.includes(String(request.id))) return false;
    if (episodes.length && !episodes.includes(String(request.episode))) return false;
    return true;
  }
  function networkRequest(raw, method) {
    beginSnapshotIfNeeded();
    if (String(method || 'GET').toUpperCase() !== 'GET' || typeof raw !== 'string') return null;
    try {
      const url = new URL(raw, document.baseURI);
      if (url.href.length > 2048 || !['http:', 'https:'].includes(url.protocol) || url.username || url.password) return null;
      return {url: url.href, snapshot: snapshotSequence};
    } catch (_) { return null; }
  }
  function isManifest(raw, mime = '') {
    if (/mpegurl|dash\+xml/i.test(mime)) return true;
    try { return /\.(?:m3u8?|mpd)$/i.test(new URL(raw, document.baseURI).pathname); }
    catch (_) { return false; }
  }
  function rememberNetworkResource(request, raw, mime = '', initiatorType = null) {
    if (!alive || !request) return;
    beginSnapshotIfNeeded();
    if (request.snapshot !== snapshotSequence) return;
    try {
      const url = new URL(raw || request.url, document.baseURI);
      if (url.href.length > 2048 || !['http:', 'https:'].includes(url.protocol) ||
          url.username || url.password || !isManifest(url.href, mime) || isTransportResource(url.href)) return;
      const key = mediaSourceIdentity(url.href);
      if (initiatorType != null && networkResources.get(key)?.initiatorType === null) return;
      networkResources.delete(key);
      networkResources.set(key, {name: url.href, mime: String(mime).slice(0, 128), requestUrl: request.url, initiatorType});
      while (networkResources.size > 256) networkResources.delete(networkResources.keys().next().value);
      scheduleReport();
    } catch (_) {}
  }
  // Observe only this explicit page-data schema. The page owns every
  // request; no discovery request, cookie access, or media-source mutation is
  // performed. A prefetch can finish before a same-series SPA route changes.
  if (typeof window.XMLHttpRequest === 'function') {
    const originalOpen = window.XMLHttpRequest.prototype.open;
    const requests = new WeakMap();
    const resourceRequests = new WeakMap();
    const listening = new WeakSet();
    window.XMLHttpRequest.prototype.open = function (method, url, ...rest) {
      const result = Reflect.apply(originalOpen, this, [method, url, ...rest]);
      try {
        noteSeen(url, method);
        requests.set(this, startEpisodeRequest(url, method));
        resourceRequests.set(this, networkRequest(url, method));
        if (!listening.has(this)) {
          listening.add(this);
          this.addEventListener('load', () => {
            try {
              if (this.status >= 200 && this.status < 300) {
                rememberNetworkResource(resourceRequests.get(this), this.responseURL,
                  typeof this.getResponseHeader === 'function' ? this.getResponseHeader('Content-Type') || '' : '');
              }
              const request = requests.get(this);
              if (request && this.status >= 200 && this.status < 300) {
                if (this.responseType === '' || this.responseType === 'text') {
                  observeEpisodeResponse(request, this.responseText, this.responseURL);
                } else if (this.responseType === 'json') {
                  observeEpisodeResponse(request, JSON.stringify(this.response), this.responseURL);
                }
              }
            } catch (_) {}
          });
        }
      } catch (_) { /* Telemetry must not change the page request's result. */ }
      return result;
    };
  }
  if (typeof window.fetch === 'function') {
    const originalFetch = window.fetch;
    window.fetch = function (input, init) {
      const result = Reflect.apply(originalFetch, this, arguments);
      try {
        const raw = typeof input === 'string' ? input : input instanceof URL ? input.href : input?.url;
        const method = init?.method || input?.method;
        noteSeen(raw, method);
        const request = startEpisodeRequest(raw, method);
        const resourceRequest = networkRequest(raw, method);
        Promise.resolve(result).then(response => {
          if (response?.ok) rememberNetworkResource(resourceRequest, response.url,
            response.headers?.get?.('Content-Type') || '');
        }).catch(() => {});
        if (request) Promise.resolve(result).then(async response => {
          if (!response.ok || !response.body || typeof response.clone !== 'function') return;
          const reader = response.clone().body.getReader();
          const decoder = new TextDecoder();
          let text = '', size = 0;
          let expired = false;
          const timer = setTimeout(() => { expired = true; reader.cancel().catch(() => {}); }, 5000);
          try {
            while (true) {
              const part = await reader.read();
              if (part.done) break;
              size += part.value.byteLength;
              if (size > 256 * 1024) return;
              text += decoder.decode(part.value, {stream: true});
            }
            if (expired) return;
            text += decoder.decode();
            observeEpisodeResponse(request, text, response.url);
          } finally { clearTimeout(timer); reader.cancel().catch(() => {}); }
        }).catch(() => {});
      } catch (_) { /* Telemetry must not change the page request's result. */ }
      return result;
    };
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
    if (/^(?:video|audio)\//i.test(mime) || /mpegurl|dash\+xml/i.test(mime)) return true;
    try { return /\.(?:m3u8?|mp4|mpd|webm)$/i.test(new URL(raw, document.baseURI).pathname); }
    catch (_) { return false; }
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
    // `line` can select an episode or a stream variant. It is content
    // identity, not authorization rotation, and must survive discovery.
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
  function candidateFits(candidate) {
    return JSON.stringify({kind:'candidates', token:config.token, frame:frameId,
      document:documentId, epoch, candidates:[candidate]}).length <= 4096;
  }
  function addCandidate(output, seen, raw, mime = '', durationMs, force = false, title, poster = '', episode = null, identitySuffix = '', priority = 0, ownerPage = '') {
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
      if (!acceptSeriesSource(url.href)) return;
      const candidate = {
        url: url.href,
        title: String(title ?? document.title ?? '').slice(0, 512),
        mime: resolvedMime.slice(0, 128),
        pageUrl: ownerPage || pageUrl(),
      };
      const manifestHeaders = pageCdnHeaders('manifest');
      const resourceHeaders = pageCdnHeaders('resource');
      if (Object.keys(manifestHeaders).length) candidate.manifestHeaders = manifestHeaders;
      if (Object.keys(resourceHeaders).length) candidate.resourceHeaders = resourceHeaders;
      if (Number.isFinite(priority) && priority > 0 && !force) {
        candidate.representationRank = priority;
      }
      const thumbnail = thumbnailUrl(poster);
      if (thumbnail) candidate.thumbnail = thumbnail;
      const number = episodeNumber(episode);
      if (number != null) {
        candidate.episodeNumber = number;
        const series = routeSeriesContext()?.series || null;
        if (series) candidate.seriesKey = series;
      }
      if (Number.isFinite(durationMs)) candidate.durationMs = Math.round(durationMs);
      // An unsendable duplicate must not replace a valid playing URL and then
      // silently disappear at the bridge's message budget.
      if (!candidateFits(candidate)) return;
      candidatePriorities.set(candidate, priority);
      const baseKey = candidateKey(url);
      const key = baseKey + identitySuffix;
      if (
        identitySuffix === '' &&
        [...seen.keys()].some(item => item.startsWith(`${baseKey}|episode=`))
      ) return;
      const previous = seen.get(key);
      if (previous == null) {
        seen.set(key, output.length);
        output.push(candidate);
      } else {
        const existing = output[previous];
        const score = (value) => (value.mime ? 4 : 0) + (value.thumbnail ? 2 : 0) + (value.url.includes('?') ? 2 : 0) + value.url.length / 100000;
        const oldPriority = candidatePriorities.get(existing) || 0;
        if (priority > oldPriority || (priority === oldPriority && score(candidate) > score(existing))) output[previous] = candidate;
      }
    } catch (_) {}
  }
  // The manifest a player actually fetched on a page that names no sources.
  //
  // Only the newest eligible candidate survives, and eligibility mirrors what
  // the picker can defend: the request came from fetch/XHR (not an image or
  // script), it was issued for this document, and it is not owned by another
  // series. A prefetch is fetched after its own switch, so it is newer than
  // the stream it replaced - the newest entry is the one on screen.
  function newestPlayerManifest(entry, resources, mediaNodes, context, timingEntries = []) {
    if (!entry || typeof entry.name !== 'string') return null;
    const fromPlayer = entry.initiatorType == null ||
      ['fetch', 'xmlhttprequest'].includes(entry.initiatorType);
    if (!fromPlayer) return null;
    if (!isManifest(entry.name, entry.mime || '')) return null;
    if (isTransportResource(entry.name)) return null;
    const owner = knownForeignSources.get(candidateKey(new URL(entry.name, document.baseURI)));
    if (owner && owner !== context?.id) return null;
    if (!mediaNodes.some(node => belongsToSeries(node, context) && isFreshNode(node))) return null;
    // Newest wins: compare against every other manifest the page requested,
    // from the observed requests first and then from resource timing, which is
    // the only record when the player used a transport the hooks do not wrap.
    let newest = null;
    for (const candidate of [...resources.values(), ...timingEntries]) {
      if (candidate.initiatorType != null &&
          !['fetch', 'xmlhttprequest'].includes(candidate.initiatorType)) continue;
      if (!isManifest(candidate.name, candidate.mime || '')) continue;
      if (isTransportResource(candidate.name)) continue;
      const otherOwner = knownForeignSources.get(candidateKey(new URL(candidate.name, document.baseURI)));
      if (otherOwner && otherOwner !== context?.id) continue;
      newest = candidate.name;
    }
    return newest === entry.name ? entry.name : null;
  }
  // The episode the page is showing, taken from its own markup.
  //
  // A series page lists every episode as a link carrying data-ep-id and marks
  // the visible one as active. That is page-owned data, so it survives a site
  // that ships no playable sources and never loads an episode API.
  function episodeFromMarkup() {
    if (typeof document.querySelectorAll !== 'function') return null;
    let elements = [];
    try {
      elements = Array.from(document.querySelectorAll(
        '[data-ep-id],[data-episode],[data-episode-index],[data-num],a[href*="/ep-"]',
      ));
    } catch (_) { return null; }
    const numbers = new Set();
    let active = null;
    for (const element of elements) {
      if (!element || typeof element.getAttribute !== 'function') continue;
      const explicit = element.getAttribute('data-ep-id') ||
        element.getAttribute('data-episode') ||
        element.getAttribute('data-episode-index') || element.getAttribute('data-num');
      let number = episodeNumber(explicit);
      if (number == null) {
        const rawHref = element.getAttribute('href') || '';
        try {
          const route = /\/ep-([1-9]\d{0,4})\/?$/.exec(new URL(rawHref, document.baseURI).pathname);
          number = route ? episodeNumber(route[1]) : null;
        } catch (_) { number = null; }
      }
      if (number == null) continue;
      numbers.add(number);
      const className = typeof element.className === 'string' ? element.className : '';
      if (/\b(?:is-active|active|current|selected)\b/i.test(className) ||
          element.getAttribute('aria-current') === 'true' ||
          element.getAttribute('aria-selected') === 'true') active = number;
    }
    if (!numbers.size) return null;
    const sorted = [...numbers].sort((left, right) => left - right);
    // The URL names the episode when the markup marks none: this site uses
    // /video/{id}/ep-{n}/ and the visible link always agrees with it.
    let locator = null;
    try {
      const route = /\/ep-([1-9]\d{0,4})\/?$/.exec(new URL(pageUrl()).pathname);
      locator = route ? episodeNumber(route[1]) : null;
    } catch (_) { locator = null; }
    const current = active ?? locator ?? null;
    if (current == null) return null;
    return {current, total: sorted[sorted.length - 1]};
  }
  function episodeCandidateTitle() {
    const seenEpisodes = episodeFromMarkup();
    if (!seenEpisodes) return genericDiscoveryTitle();
    const series = String(document.title || '')
      .replace(/第\s*\d+\s*[集话期]|\b(?:episode|ep)\s*[:=_-]?\s*\d+\b/gi, '')
      .replace(/\s+/g, ' ').replace(/\s*[-–—|]\s*$/g, '').trim();
    return `${series || '媒体'} - 第${seenEpisodes.current}集（共${seenEpisodes.total}集）`;
  }
  function genericDiscoveryTitle() {
    const raw = String(document.title || '').slice(0, 512);
    const series = raw.replace(/第\s*\d+\s*[集话期]|\b(?:episode|ep|e)\s*[:=_-]?\s*\d+\b/gi, '')
      .replace(/(?:vodplay|play)\/[0-9]+-[0-9]+-[0-9]+(?:[.\/?#]|$)/gi, '')
      .replace(/\s+/g, ' ').replace(/\s*[-–—|]\s*$/g, '').trim();
    return `${series || '媒体'} · 集数未确认`;
  }
  function report() {
    if (!alive) return;
    beginSnapshotIfNeeded();
    collect();
    // Playback control follows actual elements, even when their old source
    // must not be authorized as a candidate for a new SPA page.
    const playing = Array.from(nodes).some(node =>
      !node.paused && !node.ended && isPlaybackControlNode(node)) ||
      Array.from(contexts).some(ctx => ctx.state === 'running');
    const candidates = [];
    const seen = new Map();
    const episodes = [];
    const episodeSeen = new Map();
    const explicit = syncEpisodeSeries();
    const context = routeSeriesContext();
    // A malformed or temporarily unavailable page-data block must only disable
    // episode mapping. It must never hide the actual media element or manifest
    // that the page is already playing.
    const episodeMappingUnavailable = Boolean(
      context && initialDataElement() && !episodeContext(),
    );
    const mapped = episodeMappingUnavailable
      ? []
      : [...explicit.filter(item => !episodeResponses.has(item.number)), ...episodeResponses.values()]
          .sort((left, right) => left.number - right.number);
    // Reserve the leading slots for actual media, especially the playing
    // element. A full episode map must never evict the current stream.
    const mediaNodes = [...nodes].sort((left, right) =>
      Number(!right.paused && !right.ended) - Number(!left.paused && !left.ended));
    for (const node of mediaNodes) {
      if (!belongsToSeries(node, context)) {
        rememberForeignSource(node, node.currentSrc || node.src || '');
        continue;
      }
      if (!isFreshNode(node)) continue;
      const raw = node.currentSrc || node.src || '';
      addCandidate(candidates, seen, raw, node.type, Number.isFinite(node.duration) ? node.duration * 1000 : undefined,
        true, undefined, node.poster || '', null, '', 3);
    }
    for (const item of mapped) {
      let mappedKey = '';
      try { mappedKey = candidateKey(new URL(item.url, document.baseURI)); }
      catch (_) { mappedKey = ''; }
      // An active media element already owns this URL in the current
      // snapshot. Keep that candidate and let the episode reconciliation below
      // attach a unique explicit episode label; otherwise the same stream
      // would appear twice in the picker.
      const hasExisting = mappedKey && [...seen.keys()].some(key =>
        key === mappedKey || key.startsWith(`${mappedKey}|episode=`));
      if (!mappedKey || !hasExisting) {
        addCandidate(
          candidates,
          seen,
          item.url,
          '',
          undefined,
          false,
          item.title,
          item.poster,
          item.number,
          item.number == null ? '' : `|episode=${item.number}`,
          item.priority || 1,
          item.pageUrl || pageUrl(),
        );
      }
      addCandidate(episodes, episodeSeen, item.url, '', undefined, false, item.title, item.poster,
        item.number, `|episode=${item.number}`, item.priority || 1, item.pageUrl || pageUrl());
    }
    const selector = mediaAttributes.map(name => `[${name}]`).join(',');
    document.querySelectorAll(selector).forEach(element => {
      if (!element || typeof element.getAttribute !== 'function') return;
      if (!belongsToSeries(element, context)) {
        for (const name of mediaAttributes) {
          rememberForeignSource(element, element.getAttribute(name));
        }
        return;
      }
      const retired = staleElementSources.get(element);
      const mime = element.getAttribute('type') || '';
      const poster = element.getAttribute('poster') || element.getAttribute('data-poster') || '';
      const episode = elementEpisode(element);
      const number = episode;
      for (const name of mediaAttributes) {
        const raw = element.getAttribute(name);
        // Changing one attribute never refreshes the other retired URLs.
        if (retired?.has(mediaSourceIdentity(raw))) continue;
        addCandidate(
          candidates,
          seen,
          raw,
          mime,
          undefined,
          false,
          undefined,
          poster,
          episode,
        );
        addCandidate(
          episodes,
          episodeSeen,
          raw,
          mime,
          undefined,
          false,
          undefined,
          poster,
          episode,
          number == null ? '' : `|episode=${number}`,
        );
      }
    });
    // Resource timing is a fallback until a media element has confirmed real
    // playback. A placeholder or not-yet-loaded currentSrc must not hide the
    // manifest that the page actually fetched; the identity map removes exact
    // repeats and known signature changes.
    const currentNodes = Array.from(nodes).filter(node => isCurrentPlaybackNode(node));
    const hasPlayingNode = currentNodes.some(node => !node.paused && !node.ended);
    // An MSE player reports a blob: source, so playback is proven by the
    // element running rather than by the shape of its source URL.
    const hasPlayingMediaElement = currentNodes.some(node =>
      !node.paused && !node.ended && isPlaybackControlNode(node));
    const hasConfirmedPlayback = currentNodes.some(node => {
      if (!belongsToSeries(node, context)) return false;
      if (!isFreshNode(node)) return false;
      const raw = node.currentSrc || node.src || '';
      return /^https?:/i.test(raw) && looksMedia(raw, node.type || '') &&
        !node.paused && !node.ended;
    });
    const hasMeaningfulMediaElement = currentNodes.some(node => {
      if (!belongsToSeries(node, context)) return false;
      if (!isFreshNode(node)) return false;
      const raw = node.currentSrc || node.src || '';
      // A paused HTTP element can suppress a redirected timing duplicate when
      // the page has no active player. Once a current player is running,
      // paused recommendations must not hide a blob/MSE manifest fallback.
      if (node.paused || node.ended) return !hasPlayingNode &&
        /^https?:/i.test(raw) && looksMedia(raw, node.type || '') &&
        !/placeholder|loading|blank/i.test(raw);
      return /^https?:/i.test(raw) && looksMedia(raw, node.type || '') &&
        !/placeholder|loading|blank/i.test(raw);
    });
    const timingFallback = !hasConfirmedPlayback && !hasMeaningfulMediaElement;
    const mediaKeys = new Set(mediaNodes.filter(node =>
      belongsToSeries(node, context) && isFreshNode(node))
      .map(node => mediaSourceIdentity(node.currentSrc || node.src || '')));
    const timingEntries = typeof performance !== 'undefined' && typeof performance.getEntriesByType === 'function'
      ? performance.getEntriesByType('resource').slice(-4096)
        .filter(entry => !isTransportResource(entry.name) && looksMedia(entry.name, '')).slice(-256)
      : [];
    {
      for (const entry of [...Array.from(networkResources.values()).reverse(), ...timingEntries]) {
        const requestObserved = entry.initiatorType === null;
        // A blob-backed element confirms playback just as an http source does:
        // an MSE player attaches a MediaSource, so currentSrc never looks like
        // a media URL even while the stream is running.
        const playingMedia = hasConfirmedPlayback || hasPlayingMediaElement;
        const manifestRequest = playingMedia && isManifest(entry.name, entry.mime || '') &&
          ['fetch', 'xmlhttprequest'].includes(entry.initiatorType);
        if (!timingFallback && !requestObserved && !manifestRequest) continue;
        if (Number.isFinite(entry.startTime) && entry.startTime < snapshotStartedAt) continue;
        if (isTransportResource(entry.name)) continue;
        // Keep the DOM URL for a known redirect of that same request. A new
        // manifest request can still be discovered while the old player runs.
        const observed = networkResources.get(mediaSourceIdentity(entry.name));
        if (observed && mediaKeys.has(mediaSourceIdentity(observed.requestUrl))) continue;
        const resourceUrl = explicitMediaUrl(entry.name);
        const foreignOwner = resourceUrl && knownForeignSources.get(candidateKey(resourceUrl));
        if (foreignOwner && foreignOwner !== context?.id) continue;
        // Resource timing has no element/series owner. On a recognized series
        // page it may corroborate an explicit map, never invent another
        // playable episode from a recommendation or background fetch.
        if (context && initialDataElement() && !episodeMappingUnavailable &&
            (!resourceUrl || !mapped.some(item =>
              candidateKey(new URL(item.url, document.baseURI)) === candidateKey(resourceUrl)))) {
          // A page that ships no playable sources in its document - the common
          // shape for an MSE player - still has to expose the manifest the
          // player itself fetched. Without an explicit map the newest
          // player-issued manifest is the current one: a prefetch is fetched
          // after the switch it belongs to, so it supersedes nothing older.
          const fallback = newestPlayerManifest(entry, networkResources, mediaNodes, context, timingEntries);
          if (!fallback || fallback !== entry.name) continue;
        }
        // Resource timing has no page-owned episode identity. Strip any
        // stale episode marker from the document title instead of presenting
        // a prefetched/new manifest as the currently visible episode.
        addCandidate(candidates, seen, entry.name, entry.mime || entry.initiatorType || '',
          undefined, false, episodeCandidateTitle());
      }
    }
    const episodeByUrl = new Map();
    if (episodes.length > 0) {
      episodes.forEach(item => {
        const number = item.episodeNumber;
        if (number != null) {
          const series = item.title.replace(/\s*[-–—|]?\s*(?:第\s*\d+\s*[集话期]|\b(?:episode|ep|e)\s*[:=_-]?\s*\d+\b)\s*$/gi, '').trim();
          item.title = `${series} - 第${number}集`;
        }
        const key = candidateKey(new URL(item.url, document.baseURI));
        const entries = episodeByUrl.get(key) || [];
        entries.push(item);
        episodeByUrl.set(key, entries);
      });
      for (const item of candidates) {
        const original = {...item};
        const entries = episodeByUrl.get(candidateKey(new URL(item.url, document.baseURI))) || [];
        // An unlabelled DOM mirror (for example the active slide's data-src)
        // cannot erase an explicit URL-to-episode mapping from page data.
        const labelled = entries.filter(entry => entry.episodeNumber != null);
        const matches = labelled.length ? labelled : entries;
        // Several playlist entries with one normalized URL do not provide
        // enough evidence to choose an episode safely. Keep the stream visible
        // while leaving its episode unknown instead of copying the last label.
        if (matches.length === 1) {
          const episode = matches[0];
          item.title = episode.title;
          item.episodeNumber = episode.episodeNumber;
          item.seriesKey = routeSeriesContext()?.series || null;
          if (!item.thumbnail && episode.thumbnail) item.thumbnail = episode.thumbnail;
        } else if (matches.length > 1) {
          delete item.episodeNumber;
          delete item.seriesKey;
          item.title = item.title.replace(/\s*[-–—|]?\s*(?:第\s*\d+\s*[集话期]|\b(?:episode|ep|e)\s*[:=_-]?\s*\d+\b)\s*$/gi, '').trim();
          item.title = `${item.title || '媒体'} · 集数未确认`;
        }
        if (!candidateFits(item)) {
          // Optional page metadata cannot remove a sendable active stream.
          for (const key of Object.keys(item)) delete item[key];
          Object.assign(item, original);
          if (matches.length > 1) {
            delete item.episodeNumber;
            delete item.seriesKey;
            item.title = '媒体 · 集数未确认';
            if (!candidateFits(item)) {
              item.title = '';
            }
          }
        }
      }
    }
    // Resource timing can contain ads and manifests; only a page-exposed
    // playlist may advertise episode switching.
    lastCandidateList = Array.from(episodeByUrl.values()).flatMap(entries => {
      const labelled = entries.filter(entry => entry.episodeNumber != null);
      const matches = labelled.length ? labelled : entries;
      return matches.length === 1 ? matches : [];
    }).sort((left, right) => (left.episodeNumber ?? Infinity) - (right.episodeNumber ?? Infinity));
    if (!connected) { connect(); return; }
    // Resolve missing episode sources through explicit same-origin episode
    // links. This keeps the page authoritative while allowing a batch picker
    // to obtain short-lived HLS URLs before the WebView is closed.
    scheduleEpisodePageResolution();
    let activeNode = null;
    if (lastActiveNode && nodes.has(lastActiveNode) &&
        isPlaybackControlNode(lastActiveNode)) {
      activeNode = lastActiveNode;
    } else {
      const playingNodes = currentNodes.filter(node =>
        !node.paused && !node.ended && isPlaybackControlNode(node));
      if (playingNodes.length === 1) activeNode = playingNodes[0];
    }
    let sourceUrl = null;
    let sourceKey = '';
    let episodeNumber = null;
    let explicitSeries = null;
    let evidenceTitle = String(document.title || '').slice(0, 512);
    if (activeNode) {
      explicitSeries = explicitSeriesIdentity(activeNode);
      const rawSource = activeNode.currentSrc || activeNode.src || '';
      try {
        const source = new URL(rawSource, document.baseURI);
        if (['http:', 'https:'].includes(source.protocol) && !source.username &&
            !source.password && looksMedia(source.href, activeNode.type || '')) {
          sourceUrl = source.href;
          sourceKey = candidateKey(source);
        }
      } catch (_) {}
      episodeNumber = elementEpisode(activeNode);
      const matches = sourceKey
        ? candidates.filter(item => {
          try { return candidateKey(new URL(item.url, document.baseURI)) === sourceKey; }
          catch (_) { return false; }
        })
        : [];
      const labelled = matches.filter(item => item.episodeNumber != null);
      if (episodeNumber == null && labelled.length === 1) {
        episodeNumber = labelled[0].episodeNumber;
      }
      if (matches.length === 1 && matches[0].title) evidenceTitle = matches[0].title;
    }
    const evidenceState = playing
      ? 'playing'
      : (activeNode?.ended ? 'ended' : (activeNode ? 'paused' : 'idle'));
    const sourceRevision = sourceKey
      ? `${snapshotSequence}:${sourceKey}`
      : '';
    const positionMs = activeNode && Number.isFinite(activeNode.currentTime)
      ? Math.max(0, Math.round(activeNode.currentTime * 1000))
      : 0;
    const durationMs = activeNode && Number.isFinite(activeNode.duration)
      ? Math.max(0, Math.round(activeNode.duration * 1000))
      : null;
    const evidence = {
      frame: frameId,
      document: documentId,
      epoch,
      mediaElementId: mediaElementId(activeNode),
      snapshot: snapshotSequence,
      eventSequence: ++evidenceSequence,
      positionMs,
      durationMs,
      sourceRevision,
      pageUrl: pageUrl(),
      sourceUrl,
      sourceKey,
      seriesKey: context?.series || explicitSeries || null,
      episodeNumber,
      title: evidenceTitle,
      state: evidenceState,
      confirmed: Boolean(sourceUrl && sourceKey && candidates.some(item => {
        try { return candidateKey(new URL(item.url, document.baseURI)) === sourceKey; }
        catch (_) { return false; }
      })),
    };
    // Keep the bridge fail-closed when an unusual page URL or media URL would
    // consume the entire native message budget. A missing source then remains
    // visible as an unconfirmed observation instead of being truncated into a
    // different identity.
    const state = {
      playing,
      resumable: Array.from(resumeNodes).some(isPlaybackControlNode) || resumeContexts.size > 0 ||
        (lastActiveNode != null && nodes.has(lastActiveNode) && !lastActiveNode.ended &&
          isPlaybackControlNode(lastActiveNode)),
      canSkip: canSwitchCandidate(),
      title: (document.title || '').slice(0, 512),
      evidence: JSON.stringify(evidence).length <= 3500
        ? evidence
        : {...evidence, sourceUrl: null, sourceKey: '', title: '', seriesKey: null, confirmed: false},
    };
    const stateKey = JSON.stringify(state);
    if (stateKey !== lastState) {
      lastState = stateKey;
      // Counts only: a missing candidate is then attributable to the stage
      // that produced nothing instead of to the whole pipeline.
      post('state', state);
      post('diag', {
        nodes: nodes.size,
        contexts: contexts.size,
        explicit: explicit.length,
        episodeResponses: episodeResponses.size,
        networkResources: networkResources.size,
        mapped: mapped.length,
        candidates: candidates.length,
        episodeMappingUnavailable,
        context: Boolean(context),
        playing,
        requests: requestDiagnostics,
      });
    }
    const candidatePayloadKey = JSON.stringify(candidates);
    if (candidatePayloadKey === lastCandidates) return;
    lastCandidates = candidatePayloadKey;
    // Replace this frame's snapshot, including the empty set. A stream that
    // disappears without navigation must not remain authorized in the picker.
    post('clear', {reason: 'snapshot', pageUrl: pageUrl(), snapshot: snapshotSequence});
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

  function pageUrl() {
    try {
      const value = window.location && window.location.href;
      return typeof value === 'string' ? value.slice(0, 2048) : '';
    } catch (_) { return ''; }
  }

  function beginSnapshotIfNeeded(reason = 'route') {
    const next = pageUrl();
    if (!next || next === lastPageUrl) return false;
    const previous = lastPageUrl;
    lastPageUrl = next;
    snapshotSequence += 1;
    networkResources.clear();
    snapshotStartedAt = typeof performance !== 'undefined' && typeof performance.now === 'function'
      ? performance.now()
      : 0;
    for (const node of nodes) staleNodeSources.set(node, observedNodeSources.get(node) ?? mediaSourceIdentity(node.currentSrc || node.src || ''));
    const selector = mediaAttributes.map(name => `[${name}]`).join(',');
    document.querySelectorAll(selector).forEach(element => {
      if (element && typeof element.getAttribute === 'function') staleElementSources.set(element, elementSourceIdentities(element));
    });
    const initialData = initialDataElement();
    if (initialData) {
      let identity = observedInitialData.get(initialData);
      if (identity == null) {
        try {
          const raw = initialData.textContent || '';
          if (raw.length <= 256 * 1024) identity = JSON.stringify(JSON.parse(raw).epPlaySrcs);
        } catch (_) {}
      }
      const beforeSeries = routeSeriesContext(previous)?.series;
      const nextSeries = routeSeriesContext(next)?.series;
      // Episode navigation within one confirmed series does not invalidate
      // its explicit complete playlist. Cross-series or unconfirmed routes
      // still require changed page data before the sources can be rebound.
      const sameConfirmedSeries = beforeSeries && beforeSeries === nextSeries &&
        episodeContext()?.series === nextSeries;
      if (!sameConfirmedSeries) staleInitialData.set(initialData, identity);
    }
    // Same-document navigation does not stop existing audio/video. Keep its
    // pause/resume ownership while revoking discovery and episode switching.
    lastCandidateList = [];
    lastCandidates = '';
    syncEpisodeSeries();
    post('clear', {
      reason,
      pageUrl: next,
      previousPageUrl: previous,
      snapshot: snapshotSequence,
    });
    return true;
  }

  function routeChanged(reason) {
    beginSnapshotIfNeeded(reason);
    scheduleReport();
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
  function switchingNode() {
    const context = routeSeriesContext();
    if (lastCandidateList.length < 2 ||
        (context && initialDataElement() && !episodeContext())) return null;
    function eligible(node) {
      if (!node || !nodes.has(node) || !node.isConnected ||
          !belongsToSeries(node, context) || !isFreshNode(node)) return false;
      try {
        const current = new URL(node.currentSrc || node.src || '', document.baseURI);
        // Never replace a MediaSource/blob player with a raw manifest URL.
        if (!['http:', 'https:'].includes(current.protocol)) return false;
        return lastCandidateList.some(item => candidateKey(new URL(item.url)) === candidateKey(current));
      } catch (_) { return false; }
    }
    if (eligible(lastActiveNode)) return lastActiveNode;
    // A recommendation's play event cannot take over the current series. If
    // several own players remain active, there is no unambiguous target.
    const playing = [...nodes].filter(node => !node.paused && !node.ended && eligible(node));
    return playing.length === 1 ? playing[0] : null;
  }
  function canSwitchCandidate() {
    return switchingNode() !== null;
  }
  function switchCandidate(direction) {
    // Refresh a queued DOM update before selecting either the player or URL.
    report();
    const node = switchingNode();
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
      if (!node.paused && isPlaybackControlNode(node)) {
        resumeNodes.add(node);
        needsGesture = true;
      }
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
    const targets = Array.from(resumeNodes).filter(isPlaybackControlNode);
    // A system play command can resume the active element paused by the site,
    // without reviving every old paused/ended player in the document.
    if (!targets.length) {
      const node = lastActiveNode;
      if (node && nodes.has(node) && !node.ended && isPlaybackControlNode(node)) targets.push(node);
    }
    const results = await Promise.all(targets.map(async node => {
      const expectedSource = playbackSource(node);
      const expectedOwner = playbackOwner(node);
      try {
        await originalPlay.call(node);
        if (blocked || !alive || !isPlaybackControlNode(node) || node.ended ||
            playbackSource(node) !== expectedSource || playbackOwner(node) !== expectedOwner) {
          node.pause();
          resumeNodes.delete(node);
          return false;
        }
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
    if (isCurrentPlaybackNode(this)) {
      rememberPlaybackBinding(this);
      lastActiveNode = this;
    }
    return originalPlay.apply(this, args);
  };
  for (const type of ['play', 'playing', 'pause', 'ended', 'emptied', 'loadstart', 'loadedmetadata', 'durationchange']) {
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
  if (window.history) {
    for (const name of ['pushState', 'replaceState']) {
      const original = window.history[name];
      if (typeof original !== 'function') continue;
      window.history[name] = function (...args) {
        const result = original.apply(this, args);
        routeChanged(name);
        return result;
      };
    }
    window.addEventListener('popstate', () => routeChanged('popstate'));
    window.addEventListener('hashchange', () => routeChanged('hashchange'));
  }
  window.addEventListener('pagehide', () => {
    resourceObserver?.disconnect();
    snapshotSequence++;
    // A response captured before BFCache suspension must not be accepted after
    // restoration, even when the same series and URL are restored. Keep
    // already confirmed mappings, but invalidate every in-flight request.
    seriesVisit++;
    latestEpisodeRequests.clear();
    episodePageQueue = [];
    episodePageSequence++;
    for (const controller of episodePageControllers.values()) controller.abort();
    episodePageControllers.clear();
    episodePageRequests.clear();
    networkResources.clear();
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
      snapshotSequence++;
      frameId = newFrameId();
      documentId = window.parent === window ? frameId : null;
      parentFrameId = null;
      epoch = -1; commandSequence = -1;
      connected = false; alive = true; lastState = ''; lastCandidates = '';
      lastPageUrl = pageUrl();
      lastCandidateList = [];
      episodePageQueue = [];
      episodePageAttempts.clear();
      episodePageSequence++;
      networkResources.clear();
      snapshotStartedAt = typeof performance !== 'undefined' && typeof performance.now === 'function'
        ? performance.now()
        : 0;
      startResourceObserver();
    }
    connect();
  });
  if (typeof MutationObserver === 'function') {
    new MutationObserver(() => scheduleReport()).observe(document, {
      childList: true, subtree: true, characterData: true, attributes: true,
      attributeFilter: [...mediaAttributes, 'src', 'type', 'poster', 'data-poster', 'data-play-id', 'data-series-id', 'data-series-key', 'data-show-id', 'data-episode', 'data-episode-index', 'data-num'],
    });
  }
  let resourceObserver = null;
  function startResourceObserver() {
    if (typeof PerformanceObserver !== 'function') return;
    try {
      resourceObserver ??= new PerformanceObserver(list => {
        if (!alive) return;
        beginSnapshotIfNeeded();
        for (const entry of list.getEntries().slice(-4096).filter(entry => isManifest(entry.name)).slice(-256)) {
          if (!Number.isFinite(entry.startTime) || entry.startTime < snapshotStartedAt) continue;
          rememberNetworkResource({url: entry.name, snapshot: snapshotSequence}, entry.name, '', entry.initiatorType || '');
        }
      });
      resourceObserver.observe({type: 'resource', buffered: true});
    } catch (_) { /* Polling still covers older WebView providers. */ }
  }
  startResourceObserver();
  document.addEventListener('DOMContentLoaded', () => { collect(); if (blocked) pause(); else scheduleReport(); });
  if (typeof setInterval === 'function') setInterval(() => { connect(); if (connected) scheduleReport(); }, 1500);
  connect();
})();
