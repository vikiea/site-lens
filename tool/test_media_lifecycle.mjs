import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const handlers = new Map();
const outbound = [];
const nodes = [];
const dataElements = [];
const performanceEntries = [];

class Media {
  paused = true;
  ended = false;
  isConnected = true;
  currentSrc = 'https://example.test/current.mp4';
  src = this.currentSrc;
  duration = 120;
  addEventListener(name, callback) { handlers.set(name, callback); }
  async play() { this.paused = false; return undefined; }
  pause() { this.paused = true; }
  load() {}
}

class DataElement {
  constructor(attributes) { this.attributes = attributes; }
  getAttribute(name) { return this.attributes[name] ?? null; }
  get textContent() { return ''; }
}

class Audio {
  state = 'running';
  handlers = [];
  addEventListener(name, callback) { this.handlers.push(callback); }
  async suspend() { this.state = 'suspended'; this.handlers.forEach(fn => fn()); }
  async resume() { this.state = 'running'; this.handlers.forEach(fn => fn()); }
}

const bridge = {
  onmessage: null,
  postMessage(raw) { outbound.push(JSON.parse(raw)); },
};
const document = {
  title: '测试媒体',
  baseURI: 'https://example.test/video/3520/',
  querySelectorAll(selector) {
    return selector === 'video,audio' ? nodes : dataElements;
  },
  addEventListener(name, callback) { handlers.set(name, callback); },
};
const window = {
  document,
  location: {href: 'https://example.test/video/episode-1'},
  frames: [],
  crypto: { randomUUID: () => 'frame-main' },
  AudioContext: Audio,
  addEventListener(name, callback) { handlers.set(name, callback); },
  lensMedia: bridge,
};
window.parent = window;
window.history = {
  pushState(_state, _title, url) { window.location.href = new URL(url, window.location.href).href; },
  replaceState(_state, _title, url) { window.location.href = new URL(url, window.location.href).href; },
};

let mutation;
class Observer { constructor(callback) { mutation = callback; } observe() {} }

const scope = {
  window,
  document,
  HTMLMediaElement: Media,
  DOMException,
  Promise,
  URL,
  MutationObserver: Observer,
  performance: { getEntriesByType: () => performanceEntries },
  console,
  setTimeout,
  clearTimeout,
};
vm.createContext(scope);
const source = fs.readFileSync(new URL('../web_assets/media_lifecycle.js', import.meta.url), 'utf8')
  .replace('__SITE_LENS_MEDIA_CONFIG__', JSON.stringify({
    bridge: 'lensMedia',
    token: 'document-token',
    blocked: false,
  }));
vm.runInContext(source, scope);

const waitForReport = () => new Promise(resolve => setTimeout(resolve, 1000));

const hello = outbound.find(value => value.kind === 'hello');
assert.ok(hello, 'each frame must establish an explicit native handshake');
assert.equal(hello.token, 'document-token');
assert.equal(hello.frame, 'frame-main');

let command = 0;
async function native(action, overrides = {}) {
  assert.equal(typeof bridge.onmessage, 'function');
  await bridge.onmessage({
    data: JSON.stringify({
      token: 'document-token',
      frame: 'frame-main',
      document: 'frame-main',
      epoch: 0,
      command: ++command,
      action,
      ...overrides,
    }),
  });
}

nodes.push(new Media());
dataElements.push(new DataElement({'data-play-src': '/assets/movie.m3u8?token=1'}));
performanceEntries.push({name: 'https://cdn.example.test/movie.mp4?token=2', initiatorType: 'fetch'});
await native('unblock');
await nodes[0].play();
handlers.get('playing')?.({target: nodes[0]});
mutation();
await waitForReport();
assert.equal(outbound.filter(value => value.kind === 'candidates').at(-1).kind, 'candidates');
assert.ok(outbound.some(value => value.kind === 'state' && value.playing === true));
assert.ok(outbound.every(value => JSON.stringify(value).length <= 4096));
const mimeValues = outbound.filter(value => value.kind === 'candidates')
  .flatMap(value => value.candidates).map(value => value.mime);
assert.ok(mimeValues.includes('application/vnd.apple.mpegurl'));
assert.ok(mimeValues.includes('video/mp4'));
console.log('Direct frame handshake and split state/candidate telemetry PASS.');

dataElements.length = 0;
performanceEntries.length = 0;
nodes.forEach(node => { node.isConnected = false; });
nodes.length = 0;
dataElements.push(
  new DataElement({'data-play-src': '/assets/one.m3u8?line=54&t=first'}),
  new DataElement({'data-play-src': '/assets/one.m3u8?line=55&t=second'}),
);
mutation();
await waitForReport();
const lineCandidates = outbound.filter(value => value.kind === 'candidates').at(-1).candidates;
assert.equal(lineCandidates.length, 2);
assert.ok(lineCandidates.every(value => value.url.includes('line=')));
console.log('Episode selection parameters remain distinct page candidates PASS.');

dataElements.length = 0;
dataElements.push(
  new DataElement({'data-play-src': '/assets/same.m3u8', 'data-episode': '1'}),
  new DataElement({'data-play-src': '/assets/same.m3u8', 'data-episode': '2'}),
);
mutation();
await waitForReport();
const conflictingCandidates = outbound
  .filter(value => value.kind === 'candidates')
  .findLast(value => value.candidates.some(item => /集数未确认/.test(item.title)))
  ?.candidates || [];
assert.equal(conflictingCandidates.length, 1);
assert.equal(conflictingCandidates[0].episodeNumber, undefined);
assert.match(conflictingCandidates[0].title, /集数未确认/);
console.log('Conflicting episode labels for one normalized URL remain unconfirmed PASS.');

dataElements.length = 0;
nodes.forEach(node => { node.isConnected = false; });
nodes.length = 0;
const singlePlaylist = new Media();
singlePlaylist.currentSrc = 'https://cdn.example.test/one.m3u8?line=77&t=live';
singlePlaylist.src = singlePlaylist.currentSrc;
nodes.push(singlePlaylist);
dataElements.push(new DataElement({
  'data-play-src': 'https://cdn.example.test/one.m3u8?line=77&t=playlist',
  'data-episode': '7',
}));
mutation();
await waitForReport();
const mappedEpisode = outbound.filter(value => value.kind === 'candidates').at(-1).candidates;
assert.equal(mappedEpisode.length, 1);
assert.equal(mappedEpisode[0].episodeNumber, 7);
console.log('Single playlist entry binds the explicit episode marker PASS.');

nodes.push(new Media());
await nodes[0].play();
await native('pause');
assert.equal(nodes[0].paused, true);
assert.ok(outbound.some(value => value.kind === 'ack' && value.ok === true));
await native('resume');
assert.equal(nodes[0].paused, false);
console.log('Notification pause/resume policy reservation PASS.');

const stateBeforeStale = outbound.filter(value => value.kind === 'state').at(-1);
await native('pause', {token: 'stale-token'});
assert.equal(outbound.filter(value => value.kind === 'state').at(-1), stateBeforeStale);
await native('resume', {frame: 'retired-frame'});
assert.equal(outbound.filter(value => value.kind === 'state').at(-1), stateBeforeStale);
console.log('Stale token and frame ownership boundaries PASS.');

dataElements.length = 0;
for (let index = 0; index < 80; index++) {
  dataElements.push(new DataElement({
    'data-play-src': 'https://cdn.example.test/episode-' + index +
      '.mp4?token=' + 'x'.repeat(100),
  }));
}
mutation();
await waitForReport();
const candidateMessages = outbound.filter(value => value.kind === 'candidates');
assert.ok(candidateMessages.length > 1, 'large candidate sets must be chunked');
assert.ok(candidateMessages.every(value => JSON.stringify(value).length <= 4096));
await nodes[0].play();
handlers.get('playing')?.({target: nodes[0]});
await waitForReport();
assert.equal(outbound.filter(value => value.kind === 'state').at(-1).playing, true);
console.log('Large candidate set keeps state telemetry and chunks candidates under the native limit PASS.');

for (let index = 1; index < nodes.length; index++) nodes[index].isConnected = false;
nodes[0].paused = true;
nodes[0].ended = false;
nodes[0].currentSrc = 'https://example.test/placeholder.m3u8?token=placeholder';
nodes[0].src = nodes[0].currentSrc;
nodes.length = 1;
dataElements.length = 0;
performanceEntries.length = 0;
dataElements.push(new DataElement({'data-play-src': '/assets/placeholder.m3u8?token=placeholder'}));
performanceEntries.push({name: 'https://cdn.example.test/real.m3u8?token=real', initiatorType: 'fetch'});
mutation();
await waitForReport();
const fallbackCandidates = outbound.filter(value => value.kind === 'candidates').at(-1).candidates;
assert.ok(fallbackCandidates.some(value => value.url.includes('/real.m3u8')));
console.log('Resource timing recovers a real media URL when the page only exposes a placeholder PASS.');

// A real media element can expose the page URL while Resource Timing exposes
// the redirected CDN URL. Once the element has a meaningful HTTP media URL,
// timing entries must stay a fallback instead of creating a duplicate item.
nodes.forEach(node => { node.isConnected = false; });
nodes.length = 0;
dataElements.length = 0;
performanceEntries.length = 0;
const redirected = new Media();
redirected.currentSrc = 'https://example.test/play/series/1.m3u8';
redirected.src = redirected.currentSrc;
nodes.push(redirected);
performanceEntries.push({name: 'https://cdn.example.test/video/series-1.m3u8?token=rotated', initiatorType: 'fetch'});
mutation();
await waitForReport();
const redirectedCandidates = outbound.filter(value => value.kind === 'candidates').at(-1).candidates;
assert.equal(redirectedCandidates.length, 1);
assert.ok(redirectedCandidates[0].url.includes('/play/series/1.m3u8'));
console.log('Meaningful media element suppresses redirected Resource Timing duplicates PASS.');

const oldConnectedPlayer = nodes[0];
dataElements.length = 0;
performanceEntries.length = 0;
const beforeRoute = outbound.length;
window.history.pushState({}, '', '/video/episode-2');
await waitForReport();
assert.equal(outbound.slice(beforeRoute).filter(value => value.kind === 'candidates').length, 0);
for (const type of ['play', 'playing', 'loadedmetadata', 'emptied']) {
  handlers.get(type)?.({target: oldConnectedPlayer});
}
await oldConnectedPlayer.play();
await waitForReport();
assert.equal(outbound.slice(beforeRoute).filter(value => value.kind === 'candidates').length, 0);
console.log('SPA route does not rebind a still-connected old player to the new episode PASS.');

oldConnectedPlayer.currentSrc = 'https://example.test/play/series/2.m3u8';
oldConnectedPlayer.src = oldConnectedPlayer.currentSrc;
mutation();
await waitForReport();
const newRouteCandidates = outbound.filter(value => value.kind === 'candidates').at(-1).candidates;
assert.equal(newRouteCandidates[0].pageUrl, 'https://example.test/video/episode-2');
assert.ok(newRouteCandidates[0].url.includes('/2.m3u8'));
const cleared = outbound.filter(value => value.kind === 'clear').at(-1);
assert.equal(cleared?.pageUrl, 'https://example.test/video/episode-2');
console.log('SPA route changes clear the previous media snapshot PASS.');

nodes.forEach(node => { node.isConnected = false; });
nodes.length = 0;
mutation();
await waitForReport();
const emptySnapshot = outbound.filter(value => value.kind === 'clear').at(-1);
assert.equal(emptySnapshot?.reason, 'snapshot');
console.log('Empty media snapshots revoke the previous frame candidates PASS.');

handlers.get('pagehide')?.({});
assert.notEqual(outbound.at(-1)?.kind, 'gone');
console.log('Frame lifecycle retirement avoids a pagehide bridge post PASS.');

function timingFrame({main, parent, bridge, frameName}) {
  const localHandlers = new Map();
  const localDocument = {
    title: frameName,
    baseURI: 'https://example.test/',
    querySelectorAll: () => [],
    addEventListener(name, callback) { localHandlers.set(name, callback); },
  };
  const localWindow = {
    document: localDocument,
    frames: [],
    crypto: {randomUUID: () => frameName},
    addEventListener(name, callback) { localHandlers.set(name, callback); },
    lensMedia: bridge,
    parent: parent || null,
  };
  if (main) localWindow.parent = localWindow;
  localWindow.postMessage = (data, _) => {
    localHandlers.get('message')?.({source: parent || localWindow, data});
  };
  const localScope = {
    window: localWindow,
    document: localDocument,
    HTMLMediaElement: Media,
    DOMException,
    Promise,
    URL,
    MutationObserver: class { observe() {} },
    performance: {getEntriesByType: () => []},
    console,
    setTimeout,
    clearTimeout,
  };
  vm.createContext(localScope);
  vm.runInContext(
    source,
    localScope,
  );
  return {window: localWindow, handlers: localHandlers};
}

const timingMainOutbound = [];
const timingChildOutbound = [];
const timingMainBridge = {
  onmessage: null,
  postMessage(raw) { timingMainOutbound.push(JSON.parse(raw)); },
};
const timingChildBridge = {
  onmessage: null,
  postMessage(raw) { timingChildOutbound.push(JSON.parse(raw)); },
};
let timingMainMessage;
const timingMain = {
  document: {title: 'main', baseURI: 'https://example.test/', querySelectorAll: () => [], addEventListener() {}},
  frames: [],
  crypto: {randomUUID: () => 'timing-main'},
  lensMedia: timingMainBridge,
  parent: null,
  addEventListener(name, callback) { if (name === 'message') timingMainMessage = callback; },
};
timingMain.parent = timingMain;
timingMain.postMessage = () => {};
const timingMainScope = {
  window: timingMain,
  document: timingMain.document,
  HTMLMediaElement: Media,
  DOMException,
  Promise,
  URL,
  MutationObserver: class { observe() {} },
  performance: {getEntriesByType: () => []},
  console,
  setTimeout,
  clearTimeout,
};
vm.createContext(timingMainScope);
vm.runInContext(source, timingMainScope);
const deferredMainHello = timingMainOutbound.splice(0);

let timingChildMessage;
const timingChild = {
  document: {title: 'child', baseURI: 'https://example.test/', querySelectorAll: () => [], addEventListener() {}},
  frames: [],
  crypto: {randomUUID: () => 'timing-child'},
  lensMedia: timingChildBridge,
  parent: timingMain,
  addEventListener(name, callback) { if (name === 'message') timingChildMessage = callback; },
};
timingChild.postMessage = (data, _) => {
  timingChildMessage?.({source: timingMain, data});
};
timingMain.frames = [timingChild];
timingMain.postMessage = (data, _) => {
  timingMainMessage?.({source: timingChild, data});
};
const timingChildScope = {
  window: timingChild,
  document: timingChild.document,
  HTMLMediaElement: Media,
  DOMException,
  Promise,
  URL,
  MutationObserver: class { observe() {} },
  performance: {getEntriesByType: () => []},
  console,
  setTimeout,
  clearTimeout,
};
vm.createContext(timingChildScope);
vm.runInContext(source, timingChildScope);
const timingMainHello = deferredMainHello.find(value => value.kind === 'hello');
const timingChildHello = timingChildOutbound.find(value => value.kind === 'hello');
assert.ok(timingMainHello);
assert.ok(timingChildHello);
assert.equal(timingChildHello.document, timingMainHello.document);
console.log('Out-of-order main/child hello shares one document identity PASS.');

const nestedMessages = [];
const nestedChild = {
  postMessage(data, _) { nestedMessages.push(data); },
};
timingChild.frames = [nestedChild];
timingChildMessage?.({
  source: nestedChild,
  data: {
    kind: 'site-lens-media-frame-hello',
    token: 'document-token',
    frame: 'timing-grandchild',
  },
});
assert.equal(nestedMessages.at(-1).kind, 'site-lens-media-frame-id');
assert.equal(nestedMessages.at(-1).document, timingMainHello.document);
nestedMessages.length = 0;
timingChildMessage?.({
  source: timingMain,
  data: {
    kind: 'site-lens-media-frame-id',
    token: 'document-token',
    document: timingMainHello.document,
    parentFrame: 'timing-main',
  },
});
assert.equal(nestedMessages.at(-1).kind, 'site-lens-media-frame-id');
assert.equal(nestedMessages.at(-1).document, timingMainHello.document);
console.log('Nested iframe parent response and child reconnect broadcast PASS.');

timingMainOutbound.length = 0;
timingMain.frames = [];
timingChildMessage?.({
  source: nestedChild,
  data: {
    kind: 'site-lens-media-frame-gone',
    token: 'document-token',
    frame: 'timing-grandchild',
  },
});
await new Promise(resolve => setTimeout(resolve, 10));
assert.equal(timingMainOutbound.at(-1)?.kind, 'gone');
assert.equal(timingMainOutbound.at(-1)?.childFrame, 'timing-grandchild');
console.log('Detached nested iframe retirement reaches native after DOM removal PASS.');
