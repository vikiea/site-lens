import fs from 'node:fs';
import assert from 'node:assert/strict';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../web_assets/page_inspector.js', import.meta.url), 'utf8');

class Element {
  constructor(tag, {id = '', className = '', attrs = {}, text = '', children = [], width = 100, height = 30} = {}) {
    this.tagName = tag.toUpperCase();
    this.id = id;
    this.className = className;
    this.attrs = {...attrs};
    this.textContent = text;
    this.children = [];
    this.parentElement = null;
    this.width = width;
    this.height = height;
    for (const child of children) this.append(child);
  }
  append(child) { child.parentElement = this; this.children.push(child); return this; }
  get innerText() { return this.textContent + this.children.map(child => child.innerText).join(' '); }
  getAttribute(name) {
    if (name === 'id') return this.id || null;
    if (name === 'class') return this.className || null;
    return Object.hasOwn(this.attrs, name) ? String(this.attrs[name]) : null;
  }
  getBoundingClientRect() { return {width: this.width, height: this.height}; }
  matches(selector) { return selector.split(',').some(part => matchesSimple(this, part.trim())); }
  closest(selector) {
    for (let node = this; node; node = node.parentElement) if (node.matches(selector)) return node;
    return null;
  }
  querySelectorAll(selector) {
    const result = [];
    const visit = node => {
      for (const child of node.children) {
        if (child.matches(selector)) result.push(child);
        visit(child);
      }
    };
    visit(this);
    return result;
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
}

function matchesSimple(node, selector) {
  if (!selector || selector.includes(' ')) return false;
  const tag = selector.match(/^[a-z][\w-]*/i)?.[0];
  if (tag && node.tagName.toLowerCase() !== tag.toLowerCase()) return false;
  const id = selector.match(/#([\w-]+)/)?.[1];
  if (id && node.id !== id) return false;
  for (const cls of selector.matchAll(/\.([\w-]+)/g)) {
    if (!node.className.split(/\s+/).includes(cls[1])) return false;
  }
  for (const attr of selector.matchAll(/\[([\w-]+)(?:(\^=|\$=|\*=|=)\s*["']?([^\]"']+)["']?)?\]/g)) {
    const actual = node.getAttribute(attr[1]);
    if (actual == null) return false;
    if (attr[2] === '=' && actual !== attr[3]) return false;
    if (attr[2] === '*=' && !actual.includes(attr[3])) return false;
    if (attr[2] === '^=' && !actual.startsWith(attr[3])) return false;
    if (attr[2] === '$=' && !actual.endsWith(attr[3])) return false;
  }
  return tag || id || selector.includes('.') || selector.includes('[') || selector === '*';
}

class TestDocument extends Element {
  constructor(body) {
    super('document', {children: [body], width: 100, height: 100});
    this.body = body;
    this.readyState = 'interactive';
    this.title = '通用发布页';
    this.baseURI = 'https://publish.example/dizhi/';
  }
  querySelectorAll(selector) { return this.body.matches(selector) ? [this.body, ...this.body.querySelectorAll(selector)] : this.body.querySelectorAll(selector); }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
}

function inspect(document, selector) {
  const context = vm.createContext({
    document,
    location: {href: document.baseURI, protocol: 'https:'},
    URL,
    URLSearchParams,
    getComputedStyle: () => ({display: 'block', visibility: 'visible'}),
  });
  return JSON.parse(vm.runInContext(source.replace('__LENS_SELECTOR__', JSON.stringify(selector)), context));
}

const addressItems = [
  ['hddj.tv', '主站'],
  ['hdmgdj.tv', '备用'],
  ['huangdoudj.com', '备用'],
].map(([domain, label]) => new Element('li', {
  children: [
    new Element('b', {attrs: {'data-copy-domain': domain}, text: domain}),
    new Element('a', {attrs: {href: `/hop?to=${domain}`}, text: '进入'}),
    new Element('span', {text: label}),
  ],
}));
const section = new Element('section', {
  className: 'dm-dz-list-wrap',
  children: [new Element('h2', {text: '官方地址列表'}), new Element('ul', {className: 'dm-dz-list', children: addressItems})],
});
const body = new Element('body', {
  children: [new Element('nav', {children: [new Element('a', {attrs: {href: 'https://github.com/example'}, text: 'GitHub'})]}), section],
});
const generic = inspect(new TestDocument(body), '@latest-addresses');
assert.equal(generic.ready, true);
assert.deepEqual(generic.links, ['https://hddj.tv/', 'https://hdmgdj.tv/', 'https://huangdoudj.com/']);

const customBody = new Element('body', {
  children: [new Element('section', {id: 'addresses', children: [
    new Element('span', {className: 'domain', text: 'one.example'}),
    new Element('span', {className: 'ad', text: 'bad.example'}),
    new Element('span', {className: 'domain', text: 'two.example'}),
  ]})],
});
const custom = inspect(new TestDocument(customBody), '@extract:{"root":"#addresses","linkSelector":".domain","includeText":true,"exclude":[".ad"],"limit":1}');
assert.equal(custom.ready, true);
assert.deepEqual(custom.links, ['https://one.example/']);

const attributeBody = new Element('body', {
  children: [new Element('section', {className: 'address-list', attrs: {'data-domains': 'first.example, second.example'}})],
});
const attributeOnly = inspect(new TestDocument(attributeBody), '@latest-addresses');
assert.deepEqual(attributeOnly.links, ['https://first.example/', 'https://second.example/']);

const homepage = new Element('body', {children: [new Element('main', {text: '播放器首页已加载，正在加载剧集内容'})]});
const homepageSnapshot = inspect(new TestDocument(homepage), 'main');
assert.equal(homepageSnapshot.ready, true, 'homepage readiness must not require address links');

const navigationOnly = new Element('body', {
  children: [new Element('nav', {children: [new Element('a', {attrs: {href: 'https://menu.example'}, text: '首页'})]})],
});
const rejected = inspect(new TestDocument(navigationOnly), '@latest-addresses');
assert.equal(rejected.ready, false);
assert.deepEqual(rejected.links, [], 'navigation links must not become candidates');

console.log('Page inspector contract PASS: semantic block scoring, data-copy-domain, /hop targets, plain text and custom rules.');
