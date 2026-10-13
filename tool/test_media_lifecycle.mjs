import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const handlers = new Map();
const nodes = [];
class Media {
  paused = true; ended = false; isConnected = true;
  async play() { this.paused = false; }
  pause() { this.paused = true; }
}
class Audio {
  state = 'running';
  handlers=[];
  addEventListener(name,callback) { this.handlers.push(callback); }
  async suspend() { this.state='suspended';this.handlers.forEach(fn=>fn()); }
  async resume() { this.state='running';this.handlers.forEach(fn=>fn()); }
}
const document = {title:'测试媒体',querySelectorAll:()=>nodes,addEventListener:(name,fn)=>handlers.set(name,fn)};
const telemetry=[];
const window = {document, frames:[],AudioContext:Audio,addEventListener:(name,fn)=>handlers.set(name,fn),bridge:{postMessage:raw=>telemetry.push(JSON.parse(raw))}};
window.parent=window;
let mutation;
class Observer { constructor(callback){mutation=callback;} observe(){} }
const scope = {window,document,HTMLMediaElement:Media,DOMException,console,Promise,MutationObserver:Observer};
vm.createContext(scope);
const source=fs.readFileSync(new URL('../web_assets/media_lifecycle.js',import.meta.url),'utf8')
  .replace('__SITE_LENS_MEDIA_CONFIG__',JSON.stringify({bridge:'bridge',token:'test',blocked:false}));
vm.runInContext(source,scope);
const media=new Media();nodes.push(media);
await media.play();
assert.equal(media.paused,false);
window.__siteLensMediaControl.apply('pause');
assert.equal(media.paused,true);
await assert.rejects(media.play(),{name:'NotAllowedError'});
window.__siteLensMediaControl.apply('unblock');
await assert.rejects(media.play(),{name:'NotAllowedError'});
handlers.get('pointerdown')({isTrusted:false});
await assert.rejects(media.play(),{name:'NotAllowedError'});
handlers.get('pointerdown')({isTrusted:true});
await media.play();
const audio=new window.AudioContext();
window.__siteLensMediaControl.apply('pause');
assert.equal(audio.state,'suspended');
window.__siteLensMediaControl.apply('resume');
assert.equal(media.paused,false);
assert.equal(audio.state,'running');
assert.equal(telemetry.at(-1).playing,true);
window.__siteLensMediaControl.apply('pause');
media.isConnected=false;
window.__siteLensMediaControl.apply('resume');
assert.equal(media.paused,true,'removed nodes must never be restarted');
console.log('Media lifecycle pause, explicit gesture, resume, WebAudio and detached-element regression PASS.');
// Natural completion must retire an earlier policy-pause reservation.
window.__siteLensMediaControl.apply('unblock');
handlers.get('pointerdown')({isTrusted:true});
const old = new Media(), current = new Media(); nodes.push(old,current);
await old.play(); window.__siteLensMediaControl.apply('pause');
window.__siteLensMediaControl.apply('unblock');handlers.get('pointerdown')({isTrusted:true});
await old.play();handlers.get('playing')({target:old});
old.pause();old.ended=true;handlers.get('ended')({target:old});
await current.play();window.__siteLensMediaControl.apply('pause');
window.__siteLensMediaControl.apply('resume');
assert.equal(old.paused,true,'naturally ended media must not be restarted');
assert.equal(current.paused,false);
console.log('Naturally ended media reservation regression PASS.');

window.__siteLensMediaControl.apply('pause');
const child = {};window.frames=[child];
handlers.get('message')({source:child,data:{kind:'site-lens-media-state',token:'test',playing:true}});
assert.equal(telemetry.at(-1).playing,true);
window.frames=[];mutation();
assert.equal(telemetry.at(-1).playing,false,'removed final iframe must clear playback telemetry');
console.log('Removed iframe playback telemetry regression PASS.');

window.frames=[];window.__siteLensMediaControl.apply('unblock');
handlers.get('pointerdown')({isTrusted:true});
const detached = new Media();detached.isConnected=false;
await detached.play();
window.__siteLensMediaControl.apply('pause');
assert.equal(detached.paused,true,'new Audio() must be paused even without DOM insertion');
window.__siteLensMediaControl.apply('unblock');
assert.equal(detached.paused,true,'visibility alone must not restart detached audio');
window.__siteLensMediaControl.apply('resume');
assert.equal(detached.paused,false,'system resume restores the policy-paused detached audio');
console.log('Detached Audio lifecycle regression PASS.');

window.__siteLensMediaControl.apply('unblock');handlers.get('pointerdown')({isTrusted:true});
const oldContext = new window.AudioContext();
window.__siteLensMediaControl.apply('pause');
window.__siteLensMediaControl.apply('unblock');handlers.get('pointerdown')({isTrusted:true});
await oldContext.resume();await oldContext.suspend();
const activeContext = new window.AudioContext();
window.__siteLensMediaControl.apply('pause');window.__siteLensMediaControl.apply('resume');
assert.equal(oldContext.state,'suspended','page-paused old context must not restart');
assert.equal(activeContext.state,'running');
console.log('Retired WebAudio policy reservation regression PASS.');
