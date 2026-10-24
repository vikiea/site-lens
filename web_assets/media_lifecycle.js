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
  function startEpisodeRequest(raw, method) {
    if (!alive) return null;
    beginSnapshotIfNeeded();
    syncEpisodeSeries();
    const request = episodeRequest(raw, method);
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
    const finalRequest = episodeRequest(finalUrl, 'GET');
    if (request.visit !== seriesVisit || latestEpisodeRequests.get(request.episode) !== request.sequence ||
        !current || current.series !== request.series || !finalRequest ||
        finalRequest.episode !== request.episode) return;
    try {
      const response = JSON.parse(text);
      const data = response && response.status === 1 ? response.data : null;
      if (!data || String(data.id) !== request.id || data.ep_num !== request.episode ||
          typeof data.video_url !== 'string') return;
      const url = explicitMediaUrl(data.video_url);
      if (!url || !acceptSeriesSource(url.href, current)) return;
      episodeResponses.delete(request.episode);
      episodeResponses.set(request.episode, {number: request.episode, url: url.href, priority: 2});
      while (episodeResponses.size > 256) episodeResponses.delete(episodeResponses.keys().next().value);
      scheduleReport();
    } catch (_) {}
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
  function addCandidate(output, seen, raw, mime = '', durationMs, force = false, title, poster = '', episode = null, identitySuffix = '', priority = 0) {
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
        pageUrl: pageUrl(),
      };
      const thumbnail = thumbnailUrl(poster);
      if (thumbnail) candidate.thumbnail = thumbnail;
      const number = episodeNumber(episode);
      if (number != null) candidate.episodeNumber = number;
      if (Number.isFinite(durationMs)) candidate.durationMs = Math.round(durationMs);
      // An unsendable duplicate must not replace a valid playing URL and then
      // silently disappear at the bridge's message budget.
      if (!candidateFits(candidate)) return;
      candidatePriorities.set(candidate, priority);
      const key = candidateKey(url) + identitySuffix;
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
    // A recognized page-data schema must catch up with its SPA route before
    // any source can be rebound. Playback controls keep their existing owner.
    const awaitingSeriesData = context && initialDataElement() && !episodeContext();
    const mapped = [...explicit.filter(item => !episodeResponses.has(item.number)), ...episodeResponses.values()]
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
      if (awaitingSeriesData) continue;
      if (!isFreshNode(node)) continue;
      const raw = node.currentSrc || node.src || '';
      addCandidate(candidates, seen, raw, node.type, Number.isFinite(node.duration) ? node.duration * 1000 : undefined,
        true, undefined, node.poster || '', null, '', 3);
    }
    for (const item of mapped) {
      if (awaitingSeriesData) continue;
      addCandidate(candidates, seen, item.url, '', undefined, false, item.title, item.poster, item.number, '', item.priority || 1);
      addCandidate(episodes, episodeSeen, item.url, '', undefined, false, item.title, item.poster,
        item.number, `|episode=${item.number}`, item.priority || 1);
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
      if (awaitingSeriesData) return;
      const retired = staleElementSources.get(element);
      const mime = element.getAttribute('type') || '';
      const poster = element.getAttribute('poster') || element.getAttribute('data-poster') || '';
      const episode = elementEpisode(element);
      const number = episode;
      for (const name of mediaAttributes) {
        const raw = element.getAttribute(name);
        // Changing one attribute never refreshes the other retired URLs.
        if (retired?.has(mediaSourceIdentity(raw))) continue;
        addCandidate(candidates, seen, raw, mime, undefined, false, undefined, poster, episode);
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
    const hasConfirmedPlayback = currentNodes.some(node => {
      if (!belongsToSeries(node, context) || awaitingSeriesData) return false;
      if (!isFreshNode(node)) return false;
      const raw = node.currentSrc || node.src || '';
      return /^https?:/i.test(raw) && looksMedia(raw, node.type || '') &&
        !node.paused && !node.ended;
    });
    const hasMeaningfulMediaElement = currentNodes.some(node => {
      if (!belongsToSeries(node, context) || awaitingSeriesData) return false;
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
    if (!awaitingSeriesData) {
      for (const entry of [...Array.from(networkResources.values()).reverse(), ...timingEntries]) {
        const requestObserved = entry.initiatorType === null;
        const manifestRequest = hasConfirmedPlayback && isManifest(entry.name, entry.mime || '') &&
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
        if (context && initialDataElement() && (!resourceUrl || !mapped.some(item =>
          candidateKey(new URL(item.url, document.baseURI)) === candidateKey(resourceUrl)))) continue;
        // Resource timing has no page-owned episode identity. Strip any
        // stale episode marker from the document title instead of presenting
        // a prefetched/new manifest as the currently visible episode.
        addCandidate(candidates, seen, entry.name, entry.mime || entry.initiatorType || '',
          undefined, false, genericDiscoveryTitle());
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
          if (!item.thumbnail && episode.thumbnail) item.thumbnail = episode.thumbnail;
        } else if (matches.length > 1) {
          delete item.episodeNumber;
          item.title = item.title.replace(/\s*[-–—|]?\s*(?:第\s*\d+\s*[集话期]|\b(?:episode|ep|e)\s*[:=_-]?\s*\d+\b)\s*$/gi, '').trim();
          item.title = `${item.title || '媒体'} · 集数未确认`;
        }
        if (!candidateFits(item)) {
          // Optional page metadata cannot remove a sendable active stream.
          for (const key of Object.keys(item)) delete item[key];
          Object.assign(item, original);
          if (matches.length > 1) {
            delete item.episodeNumber;
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
    let evidenceTitle = String(document.title || '').slice(0, 512);
    if (activeNode) {
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
    const evidence = {
      frame: frameId,
      document: documentId,
      epoch,
      pageUrl: pageUrl(),
      sourceUrl,
      sourceKey,
      seriesKey: context?.series || null,
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
    if (stateKey !== lastState) { lastState = stateKey; post('state', state); }
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
      attributeFilter: [...mediaAttributes, 'src', 'type', 'poster', 'data-poster', 'data-play-id', 'data-episode', 'data-episode-index', 'data-num'],
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
