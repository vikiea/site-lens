import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../web_assets/media_lifecycle.js', import.meta.url), 'utf8');
const urlFor = (series, episode, version = 1) =>
  `https://media.example/stream.m3u8?series=${series}&episode=${episode}&version=${version}`;
const sourcesFor = (series, count = 8, version = 1) => Object.fromEntries(
  Array.from({length: count}, (_, index) => [index + 1, urlFor(series, index + 1, version)]),
);

// Run the real document script with deterministic timers, no I/O, and a fresh
// media prototype per case so instrumentation cannot leak between documents.
async function fixture(series = 42) {
  let now = 0, timerId = 0, command = 0, mutation, resourceObserver;
  let fetchImpl = async input => ({ok: true, url: new URL(input, document.baseURI).href,
    headers: {get: () => 'application/vnd.apple.mpegurl'}});
  const timers = new Map(), messages = [], nodes = [], elements = [], resources = [];
  const windowEvents = new Map();
  class Element {
    constructor(attributes = {}, text = '') { this.attributes = attributes; this.text = text; }
    getAttribute(name) { return this.attributes[name] ?? null; }
    get textContent() { return this.text; }
    closest() { return this.owner ?? null; }
  }
  class Media extends Element {
    paused = true;
    ended = false;
    isConnected = true;
    duration = 120;
    src = '';
    listeners = new Map();
    deferNextPlay = false;
    pendingPlay = null;
    get currentSrc() { return this.src; }
    addEventListener(name, callback) { this.listeners.set(name, callback); }
    async play() {
      if (this.deferNextPlay) {
        await new Promise(resolve => { this.pendingPlay = resolve; });
        this.deferNextPlay = false;
      }
      this.paused = false;
      this.listeners.get('playing')?.();
    }
    releasePlay() { this.pendingPlay?.(); this.pendingPlay = null; }
    pause() { this.paused = true; }
    load() {}
  }
  class Xhr {
    status = 200;
    responseType = '';
    listeners = [];
    open(method, url) { this.url = url; }
    getResponseHeader() { return this.contentType || 'application/json'; }
    addEventListener(name, callback) { if (name === 'load') this.listeners.push(callback); }
    complete(episode, url, seriesId = series) {
      this.responseURL = new URL(this.url, document.baseURI).href;
      this.responseText = JSON.stringify({status: 1, data: {id: seriesId, ep_num: episode, video_url: url}});
      for (const callback of this.listeners) callback();
    }
    completeMedia(finalUrl = this.url) {
      this.responseURL = new URL(finalUrl, document.baseURI).href;
      this.contentType = 'application/vnd.apple.mpegurl';
      for (const callback of this.listeners) callback();
    }
  }
  const initialData = new Element({type: 'application/json'});
  initialData.text = JSON.stringify({id: series, epPlaySrcs: sourcesFor(series)});
  const document = {
    title: 'Mapped fixture',
    get baseURI() { return window.location.href; },
    getElementById: () => initialData,
    querySelectorAll: selector => selector === 'video,audio' ? nodes : elements,
    addEventListener() {},
  };
  const bridge = {postMessage: raw => messages.push(JSON.parse(raw))};
  const window = {
    location: {href: `https://page.example/video/${series}/`}, document,
    frames: [], crypto: {randomUUID: () => 'identity-main'},
    lensMedia: bridge, XMLHttpRequest: Xhr,
    addEventListener(name, callback) { windowEvents.set(name, callback); },
    fetch: (...args) => fetchImpl(...args),
  };
  window.parent = window;
  window.history = {
    pushState: (_, __, url) => { window.location.href = new URL(url, window.location.href).href; },
  };
  const context = vm.createContext({
    window, document, HTMLMediaElement: Media, DOMException, URL, Promise, TextDecoder,
    Date: class extends Date { static now() { return now; } },
    performance: {now: () => now, getEntriesByType: () => resources},
    MutationObserver: class { constructor(callback) { mutation = callback; } observe() {} },
    PerformanceObserver: class {
      constructor(callback) { resourceObserver = callback; }
      observe() {}
      disconnect() {}
    },
    setTimeout: (callback, delay = 0) => {
      const id = ++timerId;
      timers.set(id, {callback, at: now + delay});
      return id;
    },
    clearTimeout: id => timers.delete(id),
  });
  vm.runInContext(source.replace('__SITE_LENS_MEDIA_CONFIG__', JSON.stringify({
    bridge: 'lensMedia', token: 'identity-token', blocked: false,
  })), context);
  function flush() {
    let budget = 100;
    while (timers.size) {
      assert.ok(budget-- > 0, 'report queue must settle');
      const [id, timer] = [...timers].sort((a, b) => a[1].at - b[1].at)[0];
      timers.delete(id);
      now = timer.at;
      timer.callback();
    }
  }
  async function native(action) {
    await bridge.onmessage({data: JSON.stringify({
      action, token: 'identity-token', frame: 'identity-main',
      document: 'identity-main', epoch: 0, command: ++command,
    })});
    flush();
    return messages.findLast(value => value.kind === 'ack').ok;
  }
  function snapshot() {
    mutation();
    flush();
    const start = messages.findLastIndex(value => value.kind === 'clear');
    return messages.slice(start + 1).filter(value => value.kind === 'candidates')
      .flatMap(value => value.candidates);
  }
  function update(seriesId, sources) {
    initialData.text = JSON.stringify({id: seriesId, title: 'Mapped fixture', epPlaySrcs: sources});
  }
  await native('unblock');
  return {window, document, initialData, nodes, elements, resources, Element, Media, snapshot, update, native, messages, flush,
    windowEvents,
    resourceEvent(entries) { resourceObserver({getEntries: () => entries}); flush(); },
    setFetch(implementation) { fetchImpl = implementation; }};
}

test('retired DOM text or episode-label changes cannot reauthorize its media source', async () => {
  const f = await fixture();
  const old = new f.Element({'data-play-src': urlFor(42, 8), 'data-episode': '8'}, '0 likes');
  f.elements.push(old);
  assert.equal(f.snapshot().length, 8);
  f.window.history.pushState({}, '', '/video/77/');
  f.update(77, sourcesFor(77, 7));
  assert.equal(f.snapshot().length, 7);
  old.text = '1 likes';
  old.attributes['data-episode'] = '8';
  const result = f.snapshot();
  assert.equal(result.length, 7);
  assert.ok(result.every(item => !item.url.includes('series=42')));
  delete old.attributes['data-play-src'];
  old.attributes['data-video-src'] = urlFor(42, 8) + '&token=rotated';
  assert.equal(f.snapshot().length, 7, 'moving attributes or rotating auth cannot refresh identity');
  old.attributes['data-video-src'] = urlFor(77, 8);
  assert.equal(f.snapshot().length, 8, 'a real new resource can be observed');
});

test('new explicit episode sources replace older responses even with the same eight labels', async () => {
  const f = await fixture();
  const xhr = new f.window.XMLHttpRequest();
  xhr.open('GET', '/api/videos/42/play?ep=4');
  xhr.complete(4, urlFor(42, 4, 0));
  assert.equal(f.snapshot().find(item => item.episodeNumber === 4).url, urlFor(42, 4, 0));
  f.window.history.pushState({}, '', '/video/42/ep-4/');
  f.update(42, sourcesFor(42, 8, 2));
  const result = f.snapshot();
  assert.equal(result.length, 8);
  assert.deepEqual(Object.fromEntries(result.map(item => [item.episodeNumber, item.url])), sourcesFor(42, 8, 2));
});

test('deleting or replacing another attribute cannot refresh a retired media URL', async () => {
  const f = await fixture();
  const old = new f.Element({
    'data-play-src': urlFor(42, 8), 'data-episode': '8',
    'data-src': 'https://media.example/placeholder.jpg',
  });
  f.elements.push(old);
  f.snapshot();
  f.window.history.pushState({}, '', '/video/77/');
  f.update(77, sourcesFor(77, 7));
  assert.equal(f.snapshot().length, 7);
  delete old.attributes['data-src'];
  assert.equal(f.snapshot().length, 7);
  old.attributes['data-src'] = urlFor(77, 7);
  assert.equal(f.snapshot().length, 7);
});

test('rotating an old player token or hash cannot bind its bytes to a new series', async () => {
  const f = await fixture();
  const old = new f.Media();
  old.src = urlFor(42, 8) + '&token=before';
  f.nodes.push(old);
  await old.play();
  f.snapshot();
  f.window.history.pushState({}, '', '/video/77/');
  f.update(77, sourcesFor(77, 7));
  assert.equal(f.snapshot().length, 7);
  old.src = urlFor(42, 8) + '&token=after#different';
  assert.equal(f.snapshot().length, 7);
  old.src = urlFor(77, 8);
  assert.equal(f.snapshot().length, 8);
});

test('a retired DOM source with a fragment stays retired after cross-series navigation', async () => {
  const f = await fixture();
  const old = new f.Element({'data-play-src': urlFor(42, 8) + '#preview', 'data-episode': '8'});
  f.elements.push(old);
  f.snapshot();
  f.window.history.pushState({}, '', '/video/77/');
  f.update(77, sourcesFor(77, 7));
  assert.equal(f.snapshot().length, 7);
  old.attributes['data-play-src'] = urlFor(42, 8) + '#different';
  assert.equal(f.snapshot().length, 7);
});

test('next targets the current-series player after a foreign player becomes active', async () => {
  const f = await fixture();
  const own = new f.Media();
  own.src = urlFor(42, 1);
  own.owner = new f.Element({'data-play-id': '42'});
  const foreign = new f.Media();
  foreign.src = urlFor(42, 4);
  foreign.owner = new f.Element({'data-play-id': '77'});
  f.nodes.push(own, foreign);
  f.snapshot();
  await own.play();
  await foreign.play();
  assert.equal(f.snapshot().length, 8);
  assert.equal(await f.native('next'), true);
  assert.equal(own.src, urlFor(42, 2));
  assert.equal(foreign.src, urlFor(42, 4));
});

test('map revisions reject late responses only for changed episodes and preserve other prefetches', async () => {
  const f = await fixture();
  const late = new f.window.XMLHttpRequest();
  late.open('GET', '/api/videos/42/play?ep=4');
  const unaffected = new f.window.XMLHttpRequest();
  unaffected.open('GET', '/api/videos/42/play?ep=5');
  unaffected.complete(5, urlFor(42, 5, 3));
  const revised = {...sourcesFor(42), 4: urlFor(42, 4, 2)};
  f.update(42, revised);
  late.complete(4, urlFor(42, 4, 0));
  let result = f.snapshot();
  assert.equal(result.find(item => item.episodeNumber === 4).url, urlFor(42, 4, 2));
  assert.equal(result.find(item => item.episodeNumber === 5).url, urlFor(42, 5, 3));
  const fresh = new f.window.XMLHttpRequest();
  fresh.open('GET', '/api/videos/42/play?ep=4');
  fresh.complete(4, urlFor(42, 4, 3));
  result = f.snapshot();
  assert.equal(result.find(item => item.episodeNumber === 4).url, urlFor(42, 4, 3));
  f.initialData.text = JSON.stringify({id: 42, title: 'Changed only the title', epPlaySrcs: revised});
  assert.equal(f.snapshot().find(item => item.episodeNumber === 4).url, urlFor(42, 4, 3));
});

test('next refreshes pending DOM mappings before choosing its target URL', async () => {
  const f = await fixture();
  const own = new f.Media();
  own.src = urlFor(42, 1);
  f.nodes.push(own);
  f.snapshot();
  await own.play();
  f.snapshot();
  f.update(42, {...sourcesFor(42), 2: urlFor(42, 2, 2)});
  assert.equal(await f.native('next'), true);
  assert.equal(own.src, urlFor(42, 2, 2));
});

test('foreign-only or ambiguous own playback cannot receive episode switching', async () => {
  const f = await fixture();
  const foreign = new f.Media();
  foreign.src = urlFor(42, 4);
  foreign.owner = new f.Element({'data-play-id': '77'});
  f.nodes.push(foreign);
  f.snapshot();
  await foreign.play();
  f.snapshot();
  assert.equal(await f.native('next'), false);
  assert.equal(foreign.src, urlFor(42, 4));
  for (const episode of [1, 2]) {
    const own = new f.Media();
    own.src = urlFor(42, episode);
    own.paused = false;
    f.nodes.push(own);
  }
  f.snapshot();
  assert.equal(await f.native('next'), false);
  assert.deepEqual(f.nodes.map(node => node.src), [urlFor(42, 4), urlFor(42, 1), urlFor(42, 2)]);
});

test('playing blob keeps timing HLS beside a paused recommendation', async () => {
  const f = await fixture();
  f.document.getElementById = () => null;
  const hls = 'https://media.example/live.m3u8';
  const active = new f.Media();
  active.src = 'blob:https://page.example/live';
  f.nodes.push(active);
  await active.play();
  f.resources.push({name: hls, initiatorType: 'fetch', startTime: 1000});
  assert.ok(f.snapshot().some(item => item.url === hls));

  const recommendation = new f.Media();
  recommendation.src = 'https://media.example/recommendation.mp4';
  f.nodes.push(recommendation);
  assert.ok(f.snapshot().some(item => item.url === hls));
});

test('a typed blob never counts as an HTTP playback source', async () => {
  const f = await fixture();
  f.document.getElementById = () => null;
  const active = new f.Media();
  active.src = 'blob:https://page.example/live';
  active.type = 'video/mp4';
  f.nodes.push(active);
  await active.play();
  f.resources.push({name: 'https://media.example/live.m3u8', initiatorType: 'fetch', startTime: 1000});
  const result = f.snapshot();
  assert.ok(result.some(item => item.url === 'https://media.example/live.m3u8'));
  assert.ok(result.every(item => item.episodeNumber == null));
  assert.equal(f.messages.findLast(item => item.kind === 'state').canSkip, false);
});

test('a retained pause target cannot resume after its owner becomes foreign', async () => {
  const f = await fixture();
  const own = new f.Media();
  own.src = urlFor(42, 1);
  own.owner = new f.Element({'data-play-id': '42'});
  f.nodes.push(own);
  await own.play();
  await f.native('pause');
  own.owner.attributes['data-play-id'] = '77';
  f.snapshot();
  assert.equal(f.messages.findLast(item => item.kind === 'state').resumable, false);
  assert.equal(await f.native('resume'), false);
  assert.equal(own.paused, true);
});

test('same source and owner retain playback controls across an SPA route', async () => {
  const f = await fixture();
  const own = new f.Media();
  own.src = urlFor(42, 1);
  own.owner = new f.Element({'data-play-id': '42'});
  f.nodes.push(own);
  await own.play();
  f.snapshot();
  f.window.history.pushState({}, '', '/video/77/');
  f.update(77, sourcesFor(77));
  f.snapshot();
  await f.native('pause');
  assert.equal(await f.native('resume'), true);
  assert.equal(own.paused, false);
});

test('never-attached audio keeps playback state and notification pause resume', async () => {
  const f = await fixture();
  const audio = new f.Media();
  audio.isConnected = false;
  audio.src = urlFor(42, 1);
  await audio.play();
  f.snapshot();
  assert.equal(f.messages.findLast(item => item.kind === 'state').playing, true);
  await f.native('pause');
  assert.equal(audio.paused, true);
  assert.equal(await f.native('resume'), true);
  assert.equal(audio.paused, false);
});

test('async resume is rejected when the playback owner changes before play resolves', async () => {
  const f = await fixture();
  const own = new f.Media();
  own.src = urlFor(42, 1);
  own.owner = new f.Element({'data-play-id': '42'});
  f.nodes.push(own);
  await own.play();
  f.snapshot();
  await f.native('pause');
  own.deferNextPlay = true;
  const pending = f.native('resume');
  await Promise.resolve();
  own.owner.attributes['data-play-id'] = '77';
  own.releasePlay();
  assert.equal(await pending, false);
  assert.equal(own.paused, true);
});

test('async resume is rejected when the source changes inside the current series', async () => {
  const f = await fixture();
  const own = new f.Media();
  own.src = urlFor(42, 1);
  own.owner = new f.Element({'data-play-id': '42'});
  f.nodes.push(own);
  await own.play();
  await f.native('pause');
  own.deferNextPlay = true;
  const pending = f.native('resume');
  await Promise.resolve();
  own.src = urlFor(42, 2);
  own.releasePlay();
  assert.equal(await pending, false);
  assert.equal(own.paused, true);
});

test('resume keeps a foreign player out of the current series target', async () => {
  const f = await fixture();
  const own = new f.Media();
  own.src = urlFor(42, 1);
  own.owner = new f.Element({'data-play-id': '42'});
  const foreign = new f.Media();
  foreign.src = urlFor(42, 4);
  foreign.owner = new f.Element({'data-play-id': '77'});
  f.nodes.push(own, foreign);
  await own.play();
  await foreign.play();
  f.snapshot();
  await f.native('pause');
  assert.equal(own.paused, true);
  assert.equal(foreign.paused, true);
  assert.equal(await f.native('resume'), true);
  assert.equal(own.paused, false);
  assert.equal(foreign.paused, true);
});

test('partially replaced cross-series maps cannot relabel already observed old resources', async () => {
  const f = await fixture();
  f.snapshot();
  f.window.history.pushState({}, '', '/video/77/');
  const mixed = {...sourcesFor(42), 1: urlFor(77, 1)};
  f.update(77, mixed);
  let result = f.snapshot();
  assert.deepEqual(result.map(item => item.url), [urlFor(77, 1)]);
  f.update(77, sourcesFor(77));
  result = f.snapshot();
  assert.deepEqual(Object.fromEntries(result.map(item => [item.episodeNumber, item.url])), sourcesFor(77));
  f.window.history.pushState({}, '', '/video/42/');
  f.update(42, sourcesFor(42));
  assert.equal(f.snapshot().length, 8, 'returning to the source owner accepts its own map');
});

test('a reused player cannot resurrect its old series after visiting a fresh source', async () => {
  const f = await fixture();
  const player = new f.Media();
  player.src = urlFor(42, 8);
  f.nodes.push(player);
  f.snapshot();
  f.window.history.pushState({}, '', '/video/77/');
  f.update(77, sourcesFor(77, 7));
  player.src = urlFor(77, 8);
  assert.equal(f.snapshot().length, 8);
  player.src = urlFor(42, 8) + '&token=late#late';
  assert.equal(f.snapshot().length, 7);
  assert.ok(f.snapshot().every(item => !item.url.includes('series=42')));
});

test('unowned timing manifests cannot join a recognized series but its mapped resources remain visible', async () => {
  const f = await fixture();
  f.resources.push({name: urlFor(77, 1), initiatorType: 'fetch', startTime: 1000});
  const result = f.snapshot();
  assert.equal(result.length, 8);
  assert.ok(result.every(item => item.url.includes('series=42')));
});

test('numeric video routes without the explicit schema keep generic timing discovery', async () => {
  const f = await fixture();
  f.document.getElementById = () => null;
  f.resources.push({name: 'https://media.example/generic.m3u8', initiatorType: 'fetch', startTime: 1000});
  assert.deepEqual(f.snapshot().map(item => item.url), ['https://media.example/generic.m3u8']);
});

test('an observed API source acquires ownership before its deferred report', async () => {
  const f = await fixture();
  const opaque = 'https://media.example/opaque.m3u8';
  const response = new f.window.XMLHttpRequest();
  response.open('GET', '/api/videos/42/play?ep=4');
  response.complete(4, opaque);
  f.window.history.pushState({}, '', '/video/77/');
  f.update(77, {...sourcesFor(77), 4: opaque});
  const result = f.snapshot();
  assert.equal(result.length, 7);
  assert.ok(result.every(item => item.url !== opaque));
});

test('a foreign API source cannot replace a valid current-series episode', async () => {
  const f = await fixture();
  f.snapshot();
  f.window.history.pushState({}, '', '/video/77/');
  f.update(77, sourcesFor(77));
  f.snapshot();
  const response = new f.window.XMLHttpRequest();
  response.open('GET', '/api/videos/77/play?ep=4');
  response.complete(4, urlFor(42, 4), 77);
  const result = f.snapshot();
  assert.equal(result.length, 8);
  assert.equal(result.find(item => item.episodeNumber === 4).url, urlFor(77, 4));
});

test('same-page playing HTTP source keeps discovering new manifest requests', async () => {
  const f = await fixture();
  f.document.getElementById = () => null;
  const player = new f.Media();
  player.src = 'https://media.example/ep1.m3u8';
  f.nodes.push(player);
  await player.play();
  f.snapshot();
  f.resources.push({name: 'https://media.example/ep2.m3u8', initiatorType: 'fetch', startTime: 1000});
  player.listeners.get('loadedmetadata')?.();
  assert.ok(f.snapshot().some(item => item.url === 'https://media.example/ep2.m3u8'));
});

test('manifest fallback survives more than 256 following transport entries', async () => {
  const f = await fixture();
  f.document.getElementById = () => null;
  const player = new f.Media();
  player.src = 'blob:https://page.example/mse';
  f.nodes.push(player);
  await player.play();
  f.resources.push({name: 'https://media.example/ep2.m3u8', initiatorType: 'fetch', startTime: 1000});
  f.resources.push(...Array.from({length: 300}, (_, i) => ({name: `https://media.example/segment-${i}.ts`, initiatorType: 'fetch', startTime: 1001 + i})));
  const result = f.snapshot();
  assert.deepEqual(result.map(item => item.url), ['https://media.example/ep2.m3u8']);
});

test('XHR completion automatically publishes a new manifest without timing or DOM events', async () => {
  const f = await fixture();
  f.document.getElementById = () => null;
  const player = new f.Media();
  player.src = 'https://media.example/ep1.m3u8';
  f.nodes.push(player);
  await player.play();
  f.snapshot();
  const xhr = new f.window.XMLHttpRequest();
  xhr.open('GET', 'https://media.example/ep2.m3u8');
  xhr.completeMedia();
  f.flush();
  assert.ok(f.messages.findLast(item => item.kind === 'candidates').candidates.some(item => item.url === 'https://media.example/ep2.m3u8'));
});

test('fetch completion observes manifest MIME without reading or replacing the response', async () => {
  const f = await fixture();
  f.document.getElementById = () => null;
  const response = {ok: true, url: 'https://media.example/play?id=2', headers: {get: () => 'application/vnd.apple.mpegurl'},
    clone() { assert.fail('Generic media observation must not read the response body'); }};
  const pending = Promise.resolve(response);
  f.setFetch(() => pending);
  assert.equal(f.window.fetch('https://media.example/play?id=2'), pending);
  await pending;
  await Promise.resolve();
  f.flush();
  const candidate = f.messages.findLast(item => item.kind === 'candidates').candidates[0];
  assert.equal(candidate.url, response.url);
  assert.equal(candidate.episodeNumber, undefined);
});

test('observed redirects do not duplicate the DOM playback URL', async () => {
  const f = await fixture();
  f.document.getElementById = () => null;
  const player = new f.Media();
  player.src = 'https://page.example/ep1.m3u8';
  f.nodes.push(player);
  await player.play();
  const xhr = new f.window.XMLHttpRequest();
  xhr.open('GET', player.src);
  xhr.completeMedia('https://media.example/ep1-cdn.m3u8');
  f.resources.push({name: 'https://media.example/ep1-cdn.m3u8', initiatorType: 'fetch', startTime: 1000});
  assert.deepEqual(f.snapshot().map(item => item.url), [player.src]);
});

test('PerformanceObserver updates discovery when the timing buffer has no new entries', async () => {
  const f = await fixture();
  f.document.getElementById = () => null;
  f.snapshot();
  assert.equal(f.resources.length, 0);
  f.resourceEvent([{name: 'https://media.example/ep2.m3u8', initiatorType: 'fetch', startTime: 1000}]);
  const candidate = f.messages.findLast(item => item.kind === 'candidates').candidates[0];
  assert.equal(candidate.url, 'https://media.example/ep2.m3u8');
});

test('late generic manifest responses cannot repopulate the next SPA snapshot', async () => {
  const f = await fixture();
  f.document.getElementById = () => null;
  let complete;
  f.setFetch(() => new Promise(resolve => { complete = resolve; }));
  const pending = f.window.fetch('https://media.example/old.m3u8');
  f.window.history.pushState({}, '', '/next');
  f.snapshot();
  complete({ok: true, url: 'https://media.example/old.m3u8', headers: {get: () => 'application/vnd.apple.mpegurl'}});
  await pending;
  await Promise.resolve();
  assert.deepEqual(f.snapshot(), []);
});

test('observed unowned manifests cannot join an explicit series map', async () => {
  const f = await fixture();
  const xhr = new f.window.XMLHttpRequest();
  xhr.open('GET', 'https://media.example/recommendation.m3u8');
  xhr.completeMedia();
  const result = f.snapshot();
  assert.equal(result.length, 8);
  assert.ok(result.every(item => !item.url.includes('recommendation')));
});

test('the newest manifest stays visible after the network queue reaches its bound', async () => {
  const f = await fixture();
  f.document.getElementById = () => null;
  const player = new f.Media();
  player.src = 'https://media.example/current.m3u8';
  f.nodes.push(player);
  await player.play();
  for (let episode = 1; episode <= 257; episode++) {
    const xhr = new f.window.XMLHttpRequest();
    xhr.open('GET', `https://media.example/ep${episode}.m3u8`);
    xhr.completeMedia();
    if (episode >= 256) {
      const urls = f.snapshot().map(item => item.url);
      assert.ok(urls.includes(player.src));
      assert.ok(urls.includes(`https://media.example/ep${episode}.m3u8`));
      assert.ok(urls.length <= 256);
    }
  }
});

test('BFCache restoration rejects a request captured before pagehide', async () => {
  const f = await fixture();
  f.document.getElementById = () => null;
  let complete;
  f.setFetch(() => new Promise(resolve => { complete = resolve; }));
  const pending = f.window.fetch('https://media.example/old.m3u8');
  f.windowEvents.get('pagehide')();
  f.windowEvents.get('pageshow')({persisted: true});
  await f.native('unblock');
  const response = {ok: true, url: 'https://media.example/old.m3u8', headers: {get: () => 'application/vnd.apple.mpegurl'}};
  complete(response);
  assert.equal(await pending, response);
  await Promise.resolve();
  assert.deepEqual(f.snapshot(), []);
});

test('BFCache restoration rejects a late explicit episode response after the same map returns', async () => {
  const f = await fixture();
  const late = new f.window.XMLHttpRequest();
  late.open('GET', '/api/videos/42/play?ep=4');
  f.windowEvents.get('pagehide')();
  f.windowEvents.get('pageshow')({persisted: true});
  late.complete(4, urlFor(42, 4, 99));
  const episode = f.snapshot().find(item => item.episodeNumber === 4);
  assert.equal(episode.url, urlFor(42, 4, 1));
});

test('an explicit episode request started while hidden cannot bind after BFCache restoration', async () => {
  const f = await fixture();
  f.windowEvents.get('pagehide')();
  const hidden = new f.window.XMLHttpRequest();
  hidden.open('GET', '/api/videos/42/play?ep=4');
  f.windowEvents.get('pageshow')({persisted: true});
  hidden.complete(4, urlFor(42, 4, 99));
  assert.equal(f.snapshot().find(item => item.episodeNumber === 4).url, urlFor(42, 4, 1));
});

test('an explicit fetch body finishing after BFCache restoration keeps its old lifetime', async () => {
  const f = await fixture();
  let release, started;
  const reading = new Promise(resolve => { started = resolve; });
  const chunk = new Promise(resolve => { release = resolve; });
  let reads = 0;
  const reader = {
    read() { if (reads++ === 0) { started(); return chunk; } return Promise.resolve({done: true}); },
    cancel() { return Promise.resolve(); },
  };
  const response = {ok: true, url: 'https://page.example/api/videos/42/play?ep=4',
    headers: {get: () => 'application/json'}, body: {}, clone: () => ({body: {getReader: () => reader}})};
  f.setFetch(async () => response);
  const pending = f.window.fetch(response.url);
  await reading;
  f.windowEvents.get('pagehide')();
  f.windowEvents.get('pageshow')({persisted: true});
  release({done: false, value: new TextEncoder().encode(JSON.stringify({status: 1,
    data: {id: 42, ep_num: 4, video_url: urlFor(42, 4, 99)}}))});
  assert.equal(await pending, response);
  for (let turn = 0; turn < 8; turn++) await Promise.resolve();
  assert.equal(f.snapshot().find(item => item.episodeNumber === 4).url, urlFor(42, 4, 1));
});

test('an unbound manifest does not inherit the visible episode title', async () => {
  const f = await fixture();
  f.document.getElementById = () => null;
  f.resources.push({
    name: 'https://media.example/episode-2.m3u8',
    initiatorType: 'fetch',
    startTime: 1000,
  });
  for (const title of ['剧名 - 第1集', '剧名 第1集 在线观看', '剧名 Episode 1 - HD', '剧名 play/123-1-4']) {
    f.document.title = title;
    const candidate = f.snapshot().find(item => item.url === 'https://media.example/episode-2.m3u8');
    assert.ok(candidate);
    assert.match(candidate.title, /集数未确认/);
    assert.match(candidate.title, /剧名/);
    assert.doesNotMatch(candidate.title, /第\s*\d+\s*集|episode\s*\d+|play\/[0-9]+-[0-9]+-[0-9]+/i);
  }
});

test('an explicit episode mapping keeps its title while a generic manifest remains unconfirmed', async () => {
  const f = await fixture();
  f.document.title = '剧名 - 第1集';
  f.update(42, sourcesFor(42));
  const candidate = f.snapshot().find(item => item.episodeNumber === 2);
  assert.equal(candidate.title, 'Mapped fixture - 第2集');
  assert.doesNotMatch(candidate.title, /集数未确认|第1集/);
});

test('a media filename in a JSON API query never becomes a manifest', async () => {
  const f = await fixture();
  f.document.getElementById = () => null;
  const url = 'https://page.example/api/report?target=https%3A%2F%2Fcdn.example%2Fep2.m3u8';
  f.setFetch(async () => ({ok: true, url, headers: {get: () => 'application/json'}}));
  await f.window.fetch(url);
  await Promise.resolve();
  f.resources.push({name: url, initiatorType: 'fetch', startTime: 1000});
  assert.deepEqual(f.snapshot(), []);
});
