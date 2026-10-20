import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../web_assets/page_inspector.js', import.meta.url), 'utf8');

// Minimal DOM fixtures execute the shipped inspector without a browser or an
// added runtime dependency. Only standard DOM operations used by it are needed.
class Element {
  constructor(tag, attrs = {}, ...children) {
    this.tagName = tag.toUpperCase();
    this.attrs = attrs;
    this.nodes = children.flat();
    for (const node of this.children) node.parentElement = this;
  }
  get children() { return this.nodes.filter(node => node instanceof Element); }
  get textContent() { return this.nodes.map(node => node.textContent ?? node).join(''); }
  get innerText() { return this.textContent; }
  get id() { return this.attrs.id ?? ''; }
  get className() { return this.attrs.class ?? ''; }
  get href() { return this.attrs.href == null ? '' : new URL(this.attrs.href, this.baseURI).href; }
  get pathname() { return this.href ? new URL(this.href).pathname : ''; }
  get baseURI() { return this.parentElement?.baseURI ?? this.documentUrl; }
  getAttribute(name) { return this.attrs[name] ?? null; }
  getBoundingClientRect() { return {width: 320, height: 40}; }
  matches(selector) {
    return selector.split(',').some(part => {
      const rule = part.trim();
      const tag = rule.match(/^[a-z][a-z0-9-]*/i)?.[0];
      if (tag && this.tagName !== tag.toUpperCase()) return false;
      const id = rule.match(/#([\w-]+)/)?.[1];
      if (id && this.id !== id) return false;
      const className = rule.match(/\.([\w-]+)/)?.[1];
      if (className && !this.className.split(/\s+/).includes(className)) return false;
      const attr = rule.match(/\[([\w-]+)(\*?=)?["']?([^\]"']*)["']?\]/);
      if (attr) {
        const value = this.getAttribute(attr[1]);
        if (value == null) return false;
        if (attr[2] === '=' && value !== attr[3]) return false;
        if (attr[2] === '*=' && !value.includes(attr[3])) return false;
      }
      return true;
    });
  }
  querySelectorAll(selector) {
    return this.children.flatMap(child => [
      ...(child.matches(selector) ? [child] : []),
      ...child.querySelectorAll(selector),
    ]);
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] ?? null; }
  closest(selector) {
    return this.matches(selector) ? this : this.parentElement?.closest(selector) ?? null;
  }
}

const element = (...args) => new Element(...args);
const link = (href, text) => element('a', {href}, text);

function inspect(body, selector = '@latest-addresses', href = 'https://publish.example/') {
  body.documentUrl = href;
  const document = {
    body, title: '最新地址发布页', baseURI: href, readyState: 'complete',
    querySelector: selector => body.matches(selector) ? body : body.querySelector(selector),
    querySelectorAll: selector => [
      ...(body.matches(selector) ? [body] : []), ...body.querySelectorAll(selector),
    ],
  };
  const result = vm.runInNewContext(
    source.replace('__LENS_SELECTOR__', JSON.stringify(selector)),
    {document, location: new URL(href), URL},
  );
  const value = JSON.parse(result);
  assert.equal(value.error, '');
  return value;
}

const directEntry = element('body', {},
  element('section', {id: 'latest-addresses'},
    element('h2', {}, '最新地址'),
    link('http://127.0.0.2:7890/site', '可用入口'),
  ),
);
for (const selector of ['@latest-addresses', '#latest-addresses']) {
  const result = inspect(directEntry, selector, 'http://127.0.0.1:7890/publish');
  assert.equal(result.ready, true);
  assert.deepEqual(result.links, ['http://127.0.0.2:7890/site']);
}

const mixedRegion = element('body', {},
  element('section', {},
    element('h2', {}, '最新地址'),
    link('https://publish.example/', '站点入口'),
    link('https://mirror.example/site', '可用入口'),
    link('https://mirror.example/site#again', '可用入口'),
    link('https://docs.example/guide', '访问文档'),
    link('https://app.example/download', '下载客户端'),
    link('https://account.example/login', '进入登录'),
    link('https://backup.example/publish', '备用发布页'),
  ),
);
assert.deepEqual(inspect(mixedRegion).links, ['https://mirror.example/site']);

const plainNavigation = element('body', {},
  element('main', {}, link('https://other.example/article', '访问')),
);
assert.deepEqual(inspect(plainNavigation, 'main').links, []);

const domainList = element('body', {},
  element('div', {id: 'main'},
    element('div', {class: 'field'},
      element('h4', {}, '最新地址'),
      element('ul', {},
        element('li', {}, link('https://a.example/', 'https://a.example/')),
        element('li', {}, link('https://b.example/', 'https://b.example/')),
      ),
    ),
    element('div', {class: 'field'},
      element('h4', {}, '备用发布页'),
      link('https://backup.example/', '备用发布页'),
    ),
  ),
);
assert.deepEqual(inspect(domainList).links, ['https://a.example/', 'https://b.example/']);

console.log('Page inspector: explicit entries, exclusion rules and publishing lists PASS');
