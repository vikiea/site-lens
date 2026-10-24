import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const handlers = new Map();
const outbound = [];
const nodes = [];
const dataElements = [];
const performanceEntries = [];
let initialData = null;

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
  closest(selector) { return selector === '[data-play-id]' ? (this.owner || null) : null; }
}

class DataElement {
  constructor(attributes, text = '') { this.attributes = attributes; this.text = text; }
  getAttribute(name) { return this.attributes[name] ?? null; }
  get textContent() { return this.text; }
  closest(selector) {
    if (selector !== '[data-play-id]') return null;
    return this.attributes['data-play-id'] == null ? (this.owner || null) : this;
  }
}

class JsonElement {
  constructor(value) { this.value = value; }
  getAttribute(name) { return name === 'type' ? 'application/json' : null; }
  get textContent() { return this.value; }
}

class Xhr {
  responseType = '';
  status = 200;
  listeners = [];
  open(...args) { this.openArgs = args; }
  addEventListener(type, callback) { if (type === 'load') this.listeners.push(callback); }
  complete(value, url = new URL(this.openArgs[1], document.baseURI).href) {
    this.responseURL = url;
    this.responseText = JSON.stringify(value);
    this.response = value;
    this.listeners.forEach(callback => callback());
  }
}
let fetchResult;
let fetchCalls = 0;

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
  getElementById(id) { return id === 'videoInitialData' ? initialData : null; },
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
  XMLHttpRequest: Xhr,
  fetch(...args) { fetchCalls++; return fetchResult; },
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
  TextDecoder,
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
const firstEvidence = outbound.filter(value => value.kind === 'state').at(-1).evidence;
assert.equal(firstEvidence.state, 'playing');
assert.equal(firstEvidence.frame, 'frame-main');
assert.equal(firstEvidence.document, 'frame-main');
assert.equal(firstEvidence.epoch, 0);
assert.equal(firstEvidence.sourceUrl, nodes[0].currentSrc);
assert.equal(firstEvidence.confirmed, true);
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
dataElements.push(new DataElement({'data-play-src': 'https://cdn.example.test/explicit/episode-1.m3u8?token=mirror'}, '第1集 第2集 第3集 第4集'));
initialData = new JsonElement(JSON.stringify({
  videoTitle: '显式剧集映射',
  tracking: {total_episode: 8},
  recommendations: [{url: 'https://cdn.example.test/recommendation.mp4'}],
  epPlaySrcs: {
    '1': 'https://cdn.example.test/explicit/episode-1.m3u8?token=one',
    '2': 'https://cdn.example.test/explicit/episode-2.m3u8?token=two',
    '3': '/video/series/ep-3/',
    '4': 'https://user:password@cdn.example.test/episode-4.m3u8',
    '5': 'javascript:alert(1)',
    'invalid': 'https://cdn.example.test/invalid.mp4',
    '6': '/watch/6?source=https://cdn.example.test/not-media.m3u8',
    '7': '/watch/7#not-media.mp4',
  },
}));
mutation();
await waitForReport();
const explicitCandidates = outbound.filter(value => value.kind === 'candidates').at(-1).candidates;
assert.equal(explicitCandidates.length, 2);
assert.ok(explicitCandidates.some(value => value.episodeNumber === 1 && value.url.includes('episode-1')));
assert.ok(explicitCandidates.some(value => value.episodeNumber === 2 && value.url.includes('episode-2')));
console.log('Explicit page episode-to-media mapping is discovered without inferring missing episodes PASS.');
const beforeExplicitRoute = outbound.length;
window.history.pushState({}, '', '/video/explicit-route');
await waitForReport();
assert.equal(outbound.slice(beforeExplicitRoute).filter(value => value.kind === 'candidates').length, 0);
assert.equal(outbound.slice(beforeExplicitRoute).filter(value => value.kind === 'clear').at(-1).reason, 'snapshot');
const titleOnlyData = JSON.parse(initialData.value);
titleOnlyData.videoTitle = 'A changed title does not refresh episode sources';
initialData.value = JSON.stringify(titleOnlyData);
mutation();
await waitForReport();
assert.equal(outbound.slice(beforeExplicitRoute).filter(value => value.kind === 'candidates').length, 0);
initialData.value = JSON.stringify({epPlaySrcs: {
  '7': 'https://cdn.example.test/explicit/episode-7.m3u8',
  '8': 'https://cdn.example.test/explicit/episode-8.m3u8',
}});
mutation();
await waitForReport();
assert.deepEqual(
  Array.from(outbound.filter(value => value.kind === 'candidates').at(-1).candidates, item => item.episodeNumber),
  [7, 8],
);
console.log('Unchanged JSON is revoked after SPA navigation and changed explicit sources are rebound PASS.');
for (const value of ['not-json', JSON.stringify({epPlaySrcs: []}), ' '.repeat(256 * 1024 + 1)]) {
  initialData.value = value;
  const beforeInvalid = outbound.length;
  mutation();
  await waitForReport();
  assert.equal(outbound.slice(beforeInvalid).filter(item => item.kind === 'candidates').length, 0);
}
initialData.value = JSON.stringify({epPlaySrcs: {
  '1': 'https://cdn.example.test/shared.m3u8?token=old',
  '2': 'https://cdn.example.test/shared.m3u8?token=new',
}});
mutation();
await waitForReport();
const conflictingJson = outbound.filter(value => value.kind === 'candidates').at(-1).candidates;
assert.equal(conflictingJson.length, 1);
assert.equal(conflictingJson[0].episodeNumber, undefined);
assert.match(conflictingJson[0].title, /集数未确认/);
console.log('Malformed/oversized JSON and same-address episode conflicts are fail closed PASS.');
dataElements.length = 0;
window.history.replaceState({}, '', '/video/42/');
initialData.value = JSON.stringify({id: 42, epPlaySrcs: {}});
mutation();
await waitForReport();
const responsePayload = (id, ep, url) => ({status: 1, data: {id, ep_num: ep, video_url: url}});
const prefetched = new window.XMLHttpRequest();
prefetched.open('GET', '/api/videos/42/play?ep=3&page_texts=0', true);
assert.deepEqual(prefetched.openArgs, ['GET', '/api/videos/42/play?ep=3&page_texts=0', true]);
prefetched.complete(responsePayload(42, 3, 'https://cdn.example.test/explicit/episode-3.m3u8'));
await waitForReport();
window.history.replaceState({}, '', '/video/42/ep-3/');
await waitForReport();
let responseCandidates = outbound.filter(value => value.kind === 'candidates').at(-1).candidates;
assert.equal(responseCandidates.length, 1);
assert.equal(responseCandidates[0].episodeNumber, 3);
assert.equal(responseCandidates[0].pageUrl, 'https://example.test/video/42/ep-3/');
assert.ok(responseCandidates[0].url.includes('episode-3.m3u8'));
const invalidResponseStart = outbound.length;
for (const [requestUrl, payload, finalUrl] of [
  ['/api/videos/42/play?ep=4', responsePayload(42, 5, 'https://cdn.example.test/wrong.m3u8')],
  ['/api/videos/42/play?ep=4', responsePayload(77, 4, 'https://cdn.example.test/wrong.m3u8')],
  ['https://other.example/api/videos/42/play?ep=4', responsePayload(42, 4, 'https://cdn.example.test/wrong.m3u8')],
  ['/api/videos/42/play?ep=4', responsePayload(42, 4, 'https://cdn.example.test/wrong.m3u8'), 'https://other.example/api/videos/42/play?ep=4'],
  ['/api/videos/42/play?ep=4', responsePayload(42, 4, '/watch/4?source=https://cdn.example.test/not-media.m3u8')],
  ['/api/videos/42/play?ep=4', responsePayload(42, 4, '/watch/4#not-media.mp4')],
]) {
  const xhr = new window.XMLHttpRequest();
  xhr.open('GET', requestUrl);
  xhr.complete(payload, finalUrl);
}
await waitForReport();
assert.equal(outbound.slice(invalidResponseStart).filter(value => value.kind === 'candidates').length, 0);
const fetchedUrl = 'https://example.test/api/videos/42/play?ep=4';
const response = new Response(JSON.stringify(responsePayload(42, 4, 'https://cdn.example.test/explicit/episode-4.m3u8')));
Object.defineProperty(response, 'url', {value: fetchedUrl});
fetchResult = Promise.resolve(response);
const returned = window.fetch(fetchedUrl);
assert.equal(returned, fetchResult);
assert.equal(fetchCalls, 1);
assert.equal(window.fetch({get url() { throw new Error('telemetry input'); }}), fetchResult);
assert.equal((await (await returned).json()).data.ep_num, 4, 'the original response remains readable');
await waitForReport();
responseCandidates = outbound.filter(value => value.kind === 'candidates').at(-1).candidates;
assert.deepEqual(Array.from(responseCandidates, value => value.episodeNumber), [3, 4]);
const jsonXhr = new window.XMLHttpRequest();
jsonXhr.open('GET', '/api/videos/42/play?ep=6');
jsonXhr.responseType = 'json';
jsonXhr.complete(responsePayload(42, 6, 'https://cdn.example.test/explicit/episode-6.m3u8'));
await waitForReport();
responseCandidates = outbound.filter(value => value.kind === 'candidates').at(-1).candidates;
assert.ok(responseCandidates.some(value => value.episodeNumber === 6));
for (const number of [2, 1, 2]) {
  const xhr = new window.XMLHttpRequest();
  xhr.open('GET', '/api/videos/42/play?ep=' + number);
  xhr.complete(responsePayload(42, number, 'https://cdn.example.test/explicit/episode-' + number + '.m3u8'));
}
await waitForReport();
responseCandidates = outbound.filter(value => value.kind === 'candidates').at(-1).candidates;
assert.deepEqual(Array.from(responseCandidates, value => value.episodeNumber), [1, 2, 3, 4, 6]);
const orderedPlayer = new Media();
orderedPlayer.currentSrc = 'https://cdn.example.test/explicit/episode-2.m3u8';
orderedPlayer.src = orderedPlayer.currentSrc;
nodes.push(orderedPlayer);
await orderedPlayer.play();
handlers.get('playing')?.({target: orderedPlayer});
await waitForReport();
await native('next');
assert.ok(orderedPlayer.src.includes('episode-3.m3u8'), 'next uses episode order, not response arrival order');
nodes.forEach(node => { node.isConnected = false; });
nodes.length = 0;
const late = new window.XMLHttpRequest();
late.open('GET', '/api/videos/42/play?ep=5');
window.history.replaceState({}, '', '/video/77/');
initialData.value = JSON.stringify({id: 77, epPlaySrcs: {}});
const lateStart = outbound.length;
late.complete(responsePayload(42, 5, 'https://cdn.example.test/old-series-5.m3u8'));
await waitForReport();
assert.equal(outbound.slice(lateStart).filter(value => value.kind === 'candidates').length, 0);
console.log('Page-owned XHR/fetch episode responses preserve prefetch identity and reject stale/cross-origin/mismatched data PASS.');

// Changing unrelated JSON fields must not bind series 42's explicit URLs to 77.
initialData.value = JSON.stringify({id: 42, videoTitle: 'Retired series', epPlaySrcs: {'1': '/retired.m3u8'}});
const mismatchStart = outbound.length;
mutation();
await waitForReport();
assert.equal(outbound.slice(mismatchStart).filter(value => value.kind === 'candidates').length, 0);
initialData.value = JSON.stringify({id: 42, epPlaySrcs: {}});
window.history.replaceState({}, '', '/video/42/');
await waitForReport();
const previousVisit = new window.XMLHttpRequest();
previousVisit.open('GET', '/api/videos/42/play?ep=5');
window.history.replaceState({}, '', '/video/77/');
initialData.value = JSON.stringify({id: 77, epPlaySrcs: {}});
window.history.replaceState({}, '', '/video/42/');
initialData.value = JSON.stringify({id: 42, epPlaySrcs: {}});
const visitStart = outbound.length;
previousVisit.complete(responsePayload(42, 5, 'https://cdn.example.test/revoked-visit.m3u8'));
await waitForReport();
assert.equal(outbound.slice(visitStart).filter(value => value.kind === 'candidates').length, 0);
const oldRequest = new window.XMLHttpRequest();
const newRequest = new window.XMLHttpRequest();
oldRequest.open('GET', '/api/videos/42/play?ep=2');
newRequest.open('GET', '/api/videos/42/play?ep=2');
dataElements.push(new DataElement({
  'data-play-src': 'https://cdn.example.test/episode-2.m3u8?token=OLD-LONGER',
  'data-episode': '2',
}));
newRequest.complete(responsePayload(42, 2, 'https://cdn.example.test/episode-2.m3u8?token=NEW'));
await waitForReport();
oldRequest.complete(responsePayload(42, 2, 'https://cdn.example.test/episode-2.m3u8?token=OLD'));
await waitForReport();
assert.ok(outbound.filter(value => value.kind === 'candidates').at(-1).candidates[0].url.includes('token=NEW'));
dataElements.length = 0;
console.log('Series identity, visit revocation and newer request ordering reject stale episode URLs PASS.');

const ownSource = new DataElement({'data-play-src': '/own-episode-1.m3u8', 'data-play-id': '42'});
const recommended = new DataElement({'data-play-src': '/recommended.m3u8', 'data-play-id': '77'});
const nestedRecommendation = new DataElement({'data-video-src': '/nested-recommended.m3u8'});
nestedRecommendation.owner = recommended;
initialData.value = JSON.stringify({id: 42, epPlaySrcs: {'1': '/own-episode-1.m3u8', '2': '/own-episode-2.m3u8'}});
dataElements.push(ownSource, recommended, nestedRecommendation);
performanceEntries.push(
  {name: 'https://example.test/recommended.m3u8?token=rotated', initiatorType: 'fetch'},
  {name: 'https://example.test/nested-recommended.m3u8', initiatorType: 'fetch'},
);
const recommendationStart = outbound.length;
mutation();
await waitForReport();
const recommendationMessages = outbound.slice(recommendationStart);
const recommendationClear = recommendationMessages.findLastIndex(value => value.kind === 'clear');
const currentSeries = recommendationMessages.slice(recommendationClear + 1)
  .filter(value => value.kind === 'candidates').flatMap(value => value.candidates);
assert.deepEqual(Array.from(currentSeries, value => value.episodeNumber), [1, 2]);
assert.ok(currentSeries.every(value => !value.url.includes('recommended')));
window.history.replaceState({}, '', '/video/42/ep-2/');
await waitForReport();
const sameSeriesCandidates = outbound.filter(value => value.kind === 'candidates').at(-1).candidates;
assert.deepEqual(Array.from(sameSeriesCandidates, value => value.episodeNumber), [1, 2]);
assert.ok(sameSeriesCandidates.every(value => value.pageUrl.endsWith('/video/42/ep-2/')));
console.log('Same-series SPA episode navigation retains an unchanged confirmed playlist PASS.');
// Removing recommendation cards must not revoke their known foreign identity.
dataElements.length = 0;
const removedRecommendationStart = outbound.length;
mutation();
await waitForReport();
assert.equal(outbound.slice(removedRecommendationStart).filter(value => value.kind === 'candidates').length, 0);
// A different series' attached/playing video must not suppress an explicitly
// owned source. Unowned timing entries cannot establish current-series identity.
initialData.value = JSON.stringify({id: 42, epPlaySrcs: {'1': '/current-from-timing.m3u8'}});
const foreignPlayer = new Media();
foreignPlayer.currentSrc = foreignPlayer.src = 'https://example.test/foreign-playing.mp4';
foreignPlayer.owner = recommended;
foreignPlayer.paused = false;
nodes.push(foreignPlayer);
performanceEntries.push({name:'https://example.test/current-from-timing.m3u8', initiatorType:'fetch'});
performanceEntries.push({name:'https://example.test/unowned-recommendation.m3u8', initiatorType:'fetch'});
mutation();
await waitForReport();
const foreignTimingCandidates = outbound.filter(value => value.kind === 'candidates').at(-1).candidates;
assert.ok(foreignTimingCandidates.some(value => value.url === 'https://example.test/current-from-timing.m3u8'));
assert.ok(foreignTimingCandidates.every(value => !value.url.includes('recommended')));
assert.ok(foreignTimingCandidates.every(value => !value.url.includes('unowned-recommendation')));
foreignPlayer.isConnected = false;
nodes.length = 0;
performanceEntries.length = 0;
window.history.replaceState({}, '', '/video/77/');
dataElements.push(new DataElement({'data-play-id':'42','data-play-src':'/new-old-series-node.m3u8'}));
const mismatchedSeriesStart = outbound.length;
mutation();
await waitForReport();
assert.equal(outbound.slice(mismatchedSeriesStart).filter(value => value.kind === 'candidates').length, 0);
initialData.value = JSON.stringify({id:77,epPlaySrcs:{'1':'/new-series.m3u8'}});
mutation();
await waitForReport();
assert.deepEqual(Array.from(outbound.filter(value => value.kind === 'candidates').at(-1).candidates,
  value => value.url), ['https://example.test/new-series.m3u8']);
dataElements.length = 0;
window.history.replaceState({}, '', '/video/42/');
initialData.value = JSON.stringify({id:42,epPlaySrcs:{}});
mutation();
await waitForReport();
console.log('Declared recommendation owners and their timing resources stay outside the current series PASS.');

const capacityPlayer = new Media();
capacityPlayer.currentSrc = 'https://cdn.example.test/actual-playing.m3u8';
capacityPlayer.src = capacityPlayer.currentSrc;
nodes.push(capacityPlayer);
await capacityPlayer.play();
initialData.value = JSON.stringify({id: 42, epPlaySrcs: Object.fromEntries(
  Array.from({length: 256}, (_, index) => [String(index + 1), index === 0
    ? 'https://cdn.example.test/actual-playing.m3u8?token=' + 'x'.repeat(5000)
    : '/mapped-' + index + '.m3u8']),
)});
const capacityStart = outbound.length;
mutation();
await waitForReport();
const capacityMessages = outbound.slice(capacityStart);
const capacityClear = capacityMessages.findLastIndex(value => value.kind === 'clear');
const capacityCandidates = capacityMessages.slice(capacityClear + 1)
  .filter(value => value.kind === 'candidates').flatMap(value => value.candidates);
assert.equal(capacityCandidates.length, 256);
assert.equal(capacityCandidates[0].url, capacityPlayer.currentSrc);
assert.equal(outbound.filter(value => value.kind === 'state').at(-1).playing, true);
const longTitle = 'x'.repeat(512);
const posterPrefix = 'https://cdn.example.test/poster.jpg?x=';
const envelope = {
  kind: 'candidates', token: 'document-token', frame: 'frame-main',
  document: 'frame-main', epoch: 0,
  candidates: [{url: capacityPlayer.currentSrc, title: longTitle,
    mime: 'application/vnd.apple.mpegurl', pageUrl: window.location.href,
    thumbnail: posterPrefix, episodeNumber: 1}],
};
const poster = posterPrefix + 'p'.repeat(4086 - JSON.stringify(envelope).length);
initialData.value = JSON.stringify({id: 42, title: longTitle,
  posterSrc: poster, epPlaySrcs: {'1': capacityPlayer.currentSrc}});
const metadataStart = outbound.length;
mutation();
await waitForReport();
const metadataMessages = outbound.slice(metadataStart);
const metadataClear = metadataMessages.findLastIndex(value => value.kind === 'clear');
const metadataCandidates = metadataMessages.slice(metadataClear + 1)
  .filter(value => value.kind === 'candidates').flatMap(value => value.candidates);
assert.ok(metadataCandidates.some(value => value.url === capacityPlayer.currentSrc));
assert.ok(metadataMessages.every(value => JSON.stringify(value).length <= 4096));
initialData.value = JSON.stringify({id: 77, epPlaySrcs: {}});
window.history.replaceState({}, '', '/video/77/');
initialData.value = JSON.stringify({id: 42, epPlaySrcs: {}});
window.history.replaceState({}, '', '/video/42/');
document.title = '';
const emptyEnvelope = {...envelope, candidates: [{
  url: '', title: '', mime: 'application/vnd.apple.mpegurl',
  pageUrl: window.location.href, durationMs: 120000,
}]};
const hugeUrlPrefix = 'https://cdn.example.test/budget.m3u8?token=';
const hugeUrl = hugeUrlPrefix + 'x'.repeat(4094 - JSON.stringify(emptyEnvelope).length - hugeUrlPrefix.length);
capacityPlayer.currentSrc = capacityPlayer.src = hugeUrl;
initialData.value = JSON.stringify({id: 42, epPlaySrcs: {'1': hugeUrl, '2': hugeUrl}});
const ambiguousBudgetStart = outbound.length;
mutation();
await waitForReport();
const ambiguousBudgetMessages = outbound.slice(ambiguousBudgetStart);
const ambiguousBudgetClear = ambiguousBudgetMessages.findLastIndex(value => value.kind === 'clear');
const ambiguousBudgetCandidates = ambiguousBudgetMessages.slice(ambiguousBudgetClear + 1)
  .filter(value => value.kind === 'candidates').flatMap(value => value.candidates);
assert.equal(ambiguousBudgetCandidates.length, 1);
assert.equal(ambiguousBudgetCandidates[0].url, hugeUrl);
assert.equal(ambiguousBudgetCandidates[0].episodeNumber, undefined);
assert.ok(ambiguousBudgetMessages.every(value => JSON.stringify(value).length <= 4096));
document.title = '测试媒体';
nodes.forEach(node => { node.isConnected = false; });
nodes.length = 0;
console.log('Full episode mappings reserve candidate capacity for the actual playing media PASS.');
initialData = null;
window.history.replaceState({}, '', '/video/episode-1');

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
await oldConnectedPlayer.play();
handlers.get('playing')?.({target: oldConnectedPlayer});
await waitForReport();
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
assert.equal(outbound.filter(value => value.kind === 'state').at(-1).playing, true);
assert.equal(outbound.filter(value => value.kind === 'state').at(-1).resumable, true);
await native('pause');
await waitForReport();
assert.equal(oldConnectedPlayer.paused, true);
assert.equal(outbound.filter(value => value.kind === 'state').at(-1).playing, false);
assert.equal(outbound.filter(value => value.kind === 'state').at(-1).resumable, true);
await native('resume');
await waitForReport();
assert.equal(oldConnectedPlayer.paused, false);
assert.equal(outbound.filter(value => value.kind === 'state').at(-1).playing, true);
assert.equal(outbound.slice(beforeRoute).filter(value => value.kind === 'candidates').length, 0);
console.log('SPA route does not rebind a still-connected old player to the new episode PASS.');
console.log('SPA candidate isolation preserves actual playback state and notification pause/resume PASS.');

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
