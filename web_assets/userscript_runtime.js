// Executed in a native per-script world; configuration is supplied as a JSON
// literal by Dart. The bridge token is prepended by the native navigation owner.
(function (config) {
  'use strict';
  if (window.top !== window) return;
  // Same shape as Dart and Kotlin: drop the fragment and make sure an empty path
  // is `/`, so a `*://*/*` rule also covers `https://host`.
  const href = location.href.split('#')[0].replace(
    /^([a-zA-Z][a-zA-Z0-9+.-]*:\/\/[^/?#]+)(?=[?#]|$)/,
    '$1/'
  );
  const rules = config.rules;
  if (!rules.matches.some(r => new RegExp(r).test(href)) || rules.excludes.some(r => new RegExp(r).test(href))) return;
  const grants = new Set(config.grants);
  const committed = Object.assign(Object.create(null), config.values);
  const values = Object.assign(Object.create(null), committed);
  const pendingWrites = [];
  const menus = new Map();
  const changeListeners = new Map();
  let nextId = 0;
  const pending = new Map();
  let writeQueue = Promise.resolve();
  const token = typeof __lensBridgeToken === 'string' ? __lensBridgeToken : '';
  function bridge(op, args) {
    if (config.pageWorld) return Promise.reject(new Error('@grant none has no native bridge'));
    const id = String(++nextId);
    const message = JSON.stringify({ id, token, op, args });
    if (globalThis.webkit && globalThis.webkit.messageHandlers && globalThis.webkit.messageHandlers.lensBridge) {
      return globalThis.webkit.messageHandlers.lensBridge.postMessage(message).then(raw => {
        const result = typeof raw === 'string' ? JSON.parse(raw) : raw;
        if (!result.ok) throw new Error(result.error || 'Native operation rejected');
        return result.value;
      });
    }
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      try { globalThis.lensBridge.postMessage(message); }
      catch (e) { pending.delete(id); reject(e); }
    });
  }
  if (!config.pageWorld && globalThis.lensBridge) {
    globalThis.lensBridge.onmessage = event => {
      const result = JSON.parse(event.data);
      const waiter = pending.get(result.id);
      if (!waiter) return;
      pending.delete(result.id);
      if (result.ok) waiter.resolve(result.value); else waiter.reject(new Error(result.error || 'Native operation rejected'));
    };
  }
  function report(error) {
    const message = String(error && error.stack || error);
    console.error('[Site Lens script] ' + message);
    if (!config.pageWorld) bridge('error', { message }).catch(() => {});
  }
  function serialize(value) {
    if (value === undefined) throw new TypeError('GM values must be JSON serializable, not undefined');
    return JSON.parse(JSON.stringify(value));
  }
  function queue(op, args) {
    const operation = writeQueue.then(() => bridge(op, args));
    // Recover the queue after failures; never silently mark a failed write saved.
    writeQueue = operation.catch(report);
    return operation;
  }
  function recompute(key) {
    if (Object.prototype.hasOwnProperty.call(committed, key)) values[key] = committed[key]; else delete values[key];
    for (const item of pendingWrites) if (item.key === key) {
      if (item.remove) delete values[key]; else values[key] = item.value;
    }
  }
  function mutate(key, value, remove) {
    key = String(key);
    const oldValue = Object.prototype.hasOwnProperty.call(committed, key) ? serialize(committed[key]) : undefined;
    const operation = { key, value: remove ? undefined : serialize(value), remove };
    pendingWrites.push(operation); recompute(key);
    const finish = accepted => {
      if (accepted) { if (remove) delete committed[key]; else committed[key] = operation.value; }
      pendingWrites.splice(pendingWrites.indexOf(operation), 1); recompute(key);
    };
    return queue(remove ? 'deleteValue' : 'setValue', remove ? { key } : { key, value: operation.value }).then(result => {
      finish(true);
      const nextValue = remove ? undefined : operation.value;
      for (const [listenerId, listener] of changeListeners) {
        if (listener.key !== key) continue;
        try { listener.callback(key, oldValue, nextValue, false); }
        catch (error) { report(error); }
      }
      return result;
    }, error => { finish(false); throw error; });
  }
  function setValue(key, value) { return mutate(key, value, false); }
  function deleteValue(key) { return mutate(key, null, true); }
  function addStyle(css) {
    const style = document.createElement('style'); style.textContent = String(css);
    (document.head || document.documentElement).appendChild(style); return style;
  }
  function resourceText(name) {
    const key = String(name);
    const table = config.resources || {};
    if (!Object.prototype.hasOwnProperty.call(table, key)) throw new Error('未知 @resource: ' + key);
    return table[key];
  }
  function resourceUrl(name) {
    // Only ever a blob: URL derived from the pinned snapshot, never the
    // remote @resource URL, so a script cannot use it to bypass @connect.
    const blob = new Blob([resourceText(name)], { type: 'text/plain' });
    return URL.createObjectURL(blob);
  }
  function addElement(...args) {
    let parent = null;
    if (args[0] && typeof args[0] === 'object' && args[0].nodeType === 1) parent = args.shift();
    let tag = null;
    let attributes = {};
    if (typeof args[0] === 'string') {
      tag = args[0];
      if (args[1] && typeof args[1] === 'object') attributes = args[1];
    } else if (args[0] && typeof args[0] === 'object') {
      attributes = args[0];
      tag = attributes.tagName || attributes.tag || null;
    }
    if (typeof tag !== 'string' || !tag) throw new TypeError('GM_addElement requires a tag name');
    const element = document.createElement(tag);
    for (const [key, value] of Object.entries(attributes || {})) {
      if (key === 'tagName' || key === 'tag') continue;
      if (key === 'textContent' || key === 'innerText') { element.textContent = String(value); continue; }
      if (key === 'style' && value && typeof value === 'object') { Object.assign(element.style, value); continue; }
      if (key.startsWith('on') && typeof value === 'function') { element[key.toLowerCase()] = value; continue; }
      element.setAttribute(key, String(value));
    }
    (parent || document.head || document.documentElement).appendChild(element);
    return element;
  }
  function logMessage(...args) { console.log('[Site Lens script]', ...args); }
  function registerMenu(label, callback) {
    if (typeof callback !== 'function') throw new TypeError('Menu callback must be a function');
    const id = 'menu-' + (++nextId); menus.set(id, callback);
    queue('registerMenu', { menuId: id, label: String(label) }).catch(report);
    return id;
  }
  function unregisterMenu(id) { menus.delete(String(id)); return queue('unregisterMenu', { menuId: String(id) }); }
  function addValueChangeListener(key, callback) {
    if (typeof callback !== 'function') throw new TypeError('Value change callback must be a function');
    const id = 'change-' + (++nextId);
    changeListeners.set(id, { key: String(key), callback });
    return id;
  }
  function removeValueChangeListener(id) { return changeListeners.delete(String(id)); }
  function setClipboard(text) { return bridge('setClipboard', { text: String(text) }).then(() => undefined); }
  function notify(details) {
    const value = typeof details === 'string' ? { title: details } : (details || {});
    return bridge('notify', { title: String(value.title || value.text || 'Site Lens'), body: String(value.body || value.text || '') }).then(() => undefined);
  }
  function openInTab(details) {
    const url = typeof details === 'string' ? details : details && details.url;
    if (typeof url !== 'string') throw new TypeError('url is required');
    return bridge('openExternal', { url }).then(() => undefined);
  }
  // Only native evaluation in this SAME world invokes this function. Page JS
  // cannot access the world, and the native API checks the active document.
  if (!config.pageWorld) Object.defineProperty(globalThis, '__lensInvokeMenu', { value: id => {
    const fn = menus.get(String(id)); if (!fn) throw new Error('Menu no longer exists');
    try { fn(); } catch (e) { report(e); }
  }, configurable: false });
  function xhr(details, modern) {
    if (!details || typeof details.url !== 'string') throw new TypeError('url is required');
    if (details.synchronous || details.user || details.password || details.cookie || details.upload || details.binary || details.responseType && !['text', 'json'].includes(details.responseType)) {
      throw new Error('Unsupported GM_xmlhttpRequest option (only asynchronous text/json, no credentials)');
    }
    const requestId = 'xhr-' + (++nextId);
    let aborted = false;
    const abort = () => { aborted = true; bridge('xhrAbort', { requestId }).catch(report); };
    const operation = bridge('xhr', { requestId, url: details.url, method: details.method || 'GET', headers: details.headers || {}, data: details.data == null ? null : String(details.data), timeout: details.timeout || 15000 }).then(result => {
      if (aborted) throw new Error('Request aborted');
      const response = Object.assign({}, result, { readyState: 4, context: details.context });
      response.response = details.responseType === 'json' ? JSON.parse(response.responseText) : response.responseText;
      if (typeof details.onreadystatechange === 'function') details.onreadystatechange(response);
      if (typeof details.onload === 'function') details.onload(response);
      return response;
    }).catch(error => {
      const callback = aborted ? details.onabort : /timeout/i.test(String(error)) ? details.ontimeout : details.onerror;
      if (typeof callback === 'function') callback({ error: String(error), context: details.context });
      else if (!modern) report(error);
      throw error;
    });
    if (modern) { operation.abort = abort; return operation; }
    operation.catch(() => {}); return { abort };
  }
  const classic = {
    GM_getValue: (key, fallback) => Object.prototype.hasOwnProperty.call(values, String(key)) ? serialize(values[String(key)]) : fallback,
    GM_setValue: (key, value) => { setValue(key, value).catch(report); },
    GM_deleteValue: key => { deleteValue(key).catch(report); },
    GM_listValues: () => Object.keys(values),
    GM_addStyle: addStyle,
    GM_addElement: addElement,
    GM_getResourceText: resourceText,
    GM_getResourceURL: resourceUrl,
    GM_log: logMessage,
    GM_registerMenuCommand: registerMenu,
    GM_unregisterMenuCommand: id => { unregisterMenu(id).catch(report); },
    GM_xmlhttpRequest: details => xhr(details, false),
    GM_info: config.info,
    GM_setClipboard: text => { setClipboard(text).catch(report); },
    GM_notification: details => { notify(details).catch(report); },
    GM_openInTab: (url, options) => { openInTab(url).catch(report); },
    GM_addValueChangeListener: addValueChangeListener,
    GM_removeValueChangeListener: removeValueChangeListener
  };
  const modern = {
    getValue: async (key, fallback) => classic.GM_getValue(key, fallback),
    setValue, deleteValue, listValues: async () => Object.keys(values),
    addStyle: async css => addStyle(css),
    addElement: async (...args) => addElement(...args),
    getResourceText: async name => resourceText(name),
    getResourceURL: async name => resourceUrl(name),
    log: async (...args) => logMessage(...args),
    registerMenuCommand: async (label, cb) => registerMenu(label, cb),
    unregisterMenuCommand: unregisterMenu,
    xmlHttpRequest: details => xhr(details, true),
    info: config.info,
    setClipboard: setClipboard,
    notification: notify,
    openInTab: openInTab,
    addValueChangeListener: addValueChangeListener,
    removeValueChangeListener: removeValueChangeListener
  };
  // Page-world scripts really do run against the page's own window, so
  // `unsafeWindow` is an honest alias there. Privileged scripts never reach
  // this branch: metadata rejects unsafeWindow combined with GM grants,
  // because an isolated world cannot share page JavaScript objects.
  if (config.pageWorld) {
    try { Object.defineProperty(globalThis, 'unsafeWindow', { value: globalThis, writable: false, configurable: true }); }
    catch (_) { /* a page that froze the property keeps its own definition */ }
  }
  for (const [name, fn] of Object.entries(classic)) if (grants.has(name)) Object.defineProperty(globalThis, name, { value: fn });
  const GM = Object.create(null);
  for (const [name, fn] of Object.entries(modern)) if (grants.has('GM.' + name)) GM[name] = fn;
  if (!config.pageWorld) Object.defineProperty(globalThis, 'GM', { value: Object.freeze(GM) });
  function execute() {
    try {
      // Pinned dependencies execute in declared order, in the same environment.
      // Indirect eval gives dependencies their usual global declarations.
      for (const dependency of config.dependencies) (0, eval)(dependency);
      (0, eval)(config.source + '\n//# sourceURL=site-lens-' + config.id + '.user.js');
    } catch (error) { report(error); }
  }
  if (config.runAt === 'document-start') execute();
  else {
    const run = () => config.runAt === 'document-idle' ? setTimeout(execute, 0) : execute();
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', run, { once: true }); else run();
  }
})(__LENS_CONFIG__);
