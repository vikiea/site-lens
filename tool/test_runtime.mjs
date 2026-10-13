import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const runtime = fs.readFileSync(new URL('../web_assets/userscript_runtime.js', import.meta.url), 'utf8');
function harness({phase = 'document-end', pageWorld = false, dependencies = [], source = '', grants = [], resources = {}, href = 'https://example.com/test', matches = ['^https://example\\.com/.*$']} = {}) {
  const calls = []; let domReady; let urlSeq = 0;
  const document = {readyState:'loading', documentElement:{appendChild(x){this.style = x}}, createElement(){return {style:{}, attrs:{}, setAttribute(k,v){this.attrs[k]=String(v); this[k]=v;}, appendChild(){}}}, addEventListener(name, fn){domReady = fn}};
  const context = vm.createContext({ document, location:{href}, console, setTimeout, Object, JSON, Map, Set, Promise, __lensBridgeToken: 'native', marker: {} });
  context.window = context;
  context.top = context;
  context.Blob = Blob;
  context.URL = { createObjectURL: () => 'blob:site-lens/' + (++urlSeq), revokeObjectURL() {} };
  context.lensBridge = {postMessage(raw){const p = JSON.parse(raw); calls.push(p); queueMicrotask(()=>context.lensBridge.onmessage({data:JSON.stringify({id:p.id,ok:true,value:p.op === 'xhr' ? {status:200,responseText:'{"ok":true}',finalUrl:'https://api.example.com'} : null})}));}};
  const config = {id:'one', info:{script:{name:'Harness'}}, rules:{matches,excludes:[]}, grants, values:{cached:3}, pageWorld, runAt:phase, dependencies, source, resources};
  vm.runInContext(runtime.replace('__LENS_CONFIG__', JSON.stringify(config)), context);
  return {context, calls, ready(){document.readyState='interactive'; domReady?.();}};
}
const h = harness({grants:['GM_getValue','GM_setValue','GM_deleteValue','GM_listValues','GM_addStyle','GM.setValue','GM.getValue','GM.registerMenuCommand','GM.unregisterMenuCommand','GM.xmlHttpRequest','GM_info','GM_setClipboard','GM_notification','GM_openInTab','GM_addValueChangeListener','GM_removeValueChangeListener','GM.setClipboard','GM.notification','GM.openInTab','GM.addValueChangeListener','GM.removeValueChangeListener','GM.info'], dependencies:['globalThis.order = [1];','order.push(2);'], source:`
(async () => { marker.start = document.readyState; marker.cache = GM_getValue('cached'); GM_setValue('x', 4); marker.sync = GM_getValue('x'); await GM.setValue('y', 8); marker.async = await GM.getValue('y'); marker.keys = GM_listValues(); marker.changed = []; marker.listener = GM_addValueChangeListener('cached', (key, oldValue, newValue) => marker.changed.push([key, oldValue, newValue])); GM_setValue('cached', 5); await GM.setClipboard('copied'); await GM.notification({title:'Notice', body:'Body'}); await GM.openInTab('https://example.com/next'); GM_removeValueChangeListener(marker.listener); marker.info = GM_info.script.name; GM_deleteValue('x'); GM_addStyle('body{}'); marker.menu = await GM.registerMenuCommand('Menu', () => {marker.clicked = true}); marker.response = await GM.xmlHttpRequest({url:'https://api.example.com',responseType:'json'}); })();`});
assert.equal(h.context.marker.cache, undefined, 'document-end cannot run before DOMContentLoaded'); h.ready();
await new Promise(r=>setTimeout(r,10));
assert.equal(h.context.marker.cache,3); assert.equal(h.context.marker.sync,4); assert.equal(h.context.marker.async,8);
assert.deepEqual(Array.from(h.context.order),[1,2]); assert.deepEqual(h.calls.filter(p=>p.op==='setValue').map(p=>p.args.key),['x','y','cached']);
assert.deepEqual(JSON.parse(JSON.stringify(h.context.marker.changed)),[['cached',3,5]]); assert.equal(h.context.marker.info,'Harness');
assert.deepEqual(h.calls.filter(p=>['setClipboard','notify','openExternal'].includes(p.op)).map(p=>p.op),['setClipboard','notify','openExternal']);
assert.equal(h.context.marker.response.response.ok,true); h.context.__lensInvokeMenu(h.context.marker.menu); assert.equal(h.context.marker.clicked,true);
await h.context.GM.unregisterMenuCommand(h.context.marker.menu); assert.throws(()=>h.context.__lensInvokeMenu(h.context.marker.menu));
assert.throws(()=>h.context.GM.xmlHttpRequest({url:'https://example.com',synchronous:true}));
const start = harness({phase:'document-start',source:'marker.start = document.readyState;',grants:['GM_addStyle']}); assert.equal(start.context.marker.start,'loading');
const plain = harness({pageWorld:true,grants:['unsafeWindow'],source:'marker.executed = true; marker.unsafe = unsafeWindow === globalThis;'}); plain.ready(); assert.equal(plain.context.marker.executed,true); assert.equal(plain.context.GM,undefined); assert.equal(plain.context.GM_getValue,undefined);
// unsafeWindow is an honest alias only in the page world, where the script
// already shares the page's window and has no native capability.
assert.equal(plain.context.marker.unsafe, true); assert.equal(typeof plain.context.unsafeWindow, 'object');
const extras = harness({grants:['GM_log','GM_addElement','GM.log','GM.addElement'],source:`
GM_log('hello from the script');
marker.el = GM_addElement('div', { id: 'added', textContent: 'hi' });
(async () => {
  marker.modern = await GM.addElement('span', { id: 'modern' });
  await GM.log('modern log');
  marker.modernId = marker.modern.id;
})();
`}); extras.ready();
await new Promise(r=>setTimeout(r,10));
assert.equal(extras.context.marker.el.id,'added'); assert.equal(extras.context.marker.el.textContent,'hi');
assert.equal(extras.context.marker.modernId,'modern');
// @resource: text is a frozen snapshot; the URL form is a blob:, never remote.
const res = harness({grants:['GM_getResourceText','GM_getResourceURL','GM.getResourceText','GM.getResourceURL'],resources:{'data.json':'{"pinned":true}'},source:`
marker.text = GM_getResourceText('data.json');
marker.url = GM_getResourceURL('data.json');
(async () => {
  marker.modernText = await GM.getResourceText('data.json');
  marker.modernUrl = await GM.getResourceURL('data.json');
})();
`}); res.ready();
await new Promise(r=>setTimeout(r,10));
assert.equal(res.context.marker.text,'{"pinned":true}');
assert.equal(res.context.marker.modernText,'{"pinned":true}');
assert.equal(res.context.marker.url.startsWith('blob:'),true);
assert.equal(res.context.marker.modernUrl.startsWith('blob:'),true);
assert.equal(/https?:/.test(res.context.marker.url),false, 'resource URL must not leak http(s)');
assert.throws(()=>res.context.GM_getResourceText('missing'));
// A URL without a path must still match a `/*` rule: the runtime normalizes the
// href to `/` exactly like the Dart and Kotlin matchers do, so a bare origin is
// not silently excluded from every script.
const bare = harness({href:'https://example.com', source:'marker.executed = true;'});
bare.ready();
assert.equal(bare.context.marker.executed, true, 'a path-less href must still match /*');
const bareQuery = harness({href:'https://example.com?a=1', source:'marker.executed = true;'});
bareQuery.ready();
assert.equal(bareQuery.context.marker.executed, true, 'a path-less href with a query must match too');
console.log('Runtime contract PASS: timing, snapshot, ordered writes, modern API, dependencies, menu, network, grant-none, unsafeWindow, log, addElement, resource, bare-origin.');
// Regression: two failed writes cannot roll back to an uncommitted optimistic value.
const failures = harness({grants:['GM_getValue','GM.setValue'],source:''});
failures.context.lensBridge.postMessage = raw => { const p = JSON.parse(raw); queueMicrotask(()=>failures.context.lensBridge.onmessage({data:JSON.stringify({id:p.id,ok:false,error:'simulated persistence failure'})})); };
const rejected = await Promise.allSettled([failures.context.GM.setValue('cached',1), failures.context.GM.setValue('cached',2)]);
assert.equal(rejected.every(x=>x.status==='rejected'),true); assert.equal(failures.context.GM_getValue('cached'),3);
console.log('Persistence rollback regression PASS.');
