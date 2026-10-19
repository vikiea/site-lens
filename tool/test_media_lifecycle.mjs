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
  frames: [],
  crypto: { randomUUID: () => 'frame-main' },
  AudioContext: Audio,
  addEventListener(name, callback) { handlers.set(name, callback); },
  lensMedia: bridge,
};
window.parent = window;

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

const waitForReport = () => new Promise(resolve => setTimeout(resolve, 150));

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

handlers.get('pagehide')?.({});
assert.equal(outbound.at(-1).kind, 'gone');
console.log('Frame lifecycle retirement PASS.');

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
  },
});
assert.equal(nestedMessages.at(-1).kind, 'site-lens-media-frame-id');
assert.equal(nestedMessages.at(-1).document, timingMainHello.document);
console.log('Nested iframe parent response and child reconnect broadcast PASS.');
