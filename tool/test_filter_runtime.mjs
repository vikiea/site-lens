import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync('web_assets/filter_runtime.js', 'utf8');
assert.equal(/\beval\s*\(|new\s+Function\s*\(/.test(source), false);

const removed = [];
const nodes = [
  {remove: () => removed.push('valid')},
  {remove: () => removed.push('excluded')},
];
const styles = [];
const document = {
  documentElement: {
    querySelectorAll: selector => selector === '.ad' ? [nodes[0]] : [],
  },
  head: {
    appendChild: style => styles.push(style),
  },
  createElement: () => ({dataset: {}, set textContent(value) { this.css = value; }}),
};
document.querySelectorAll = document.documentElement.querySelectorAll;
const context = {
  document,
  location: {hostname: 'example.com'},
  MutationObserver: class { observe() {} },
};
const config = {
    enabled: true,
    snapshotId: 'snapshot-test',
    selectors: [
      {selector: '.ad', domains: ['example.com']},
      {selector: '.sponsor', domains: ['example.com']},
      {selector: '.sponsor', domains: ['example.com'], exception: true},
      {selector: 'div:has-text(ad)', domains: ['example.com']},
      {selector: '.excluded', domains: ['example.com'], excludedDomains: ['example.com']},
    ],
    scriptlets: [],
};
vm.runInNewContext(source.replace('__SITE_LENS_FILTER_CONFIG__', JSON.stringify(config)), context);
assert.deepEqual(removed, ['valid']);
assert.equal(styles.length, 1);
assert.equal(styles[0].css.includes('.sponsor{display:none!important}'), false);
assert.equal(styles[0].css.includes('.ad{display:none!important}'), true);
assert.equal(styles[0].css.includes('has-text'), false);
const runFrame = (hostname, selectors, scriptlets = []) => {
  const styles = [];
  const context = {
    location: {hostname},
    document: {
      documentElement: {},
      head: {appendChild: style => styles.push(style)},
      querySelectorAll: () => [],
      createElement: () => ({dataset: {}}),
    },
    MutationObserver: class { observe() {} },
  };
  context.window = context;
  vm.runInNewContext(source.replace('__SITE_LENS_FILTER_CONFIG__', JSON.stringify({
    enabled: true, selectors, scriptlets,
  })), context);
  return {css: styles.map(style => style.textContent).join('\n'), window: context};
};
const domainRules = [
  ...Array.from({length: 128}, (_, i) => ({selector: `.other${i}`, domains: ['other.example']})),
  // Exceptions win even if they occur before a blocking rule in source order.
  {selector: '.global', domains: ['top.example'], exception: true},
  {selector: '.global'},
  {selector: '.frame', domains: ['frame.example']},
  {selector: '.landing', domains: ['redirect.example']},
];
assert.equal(runFrame('top.example', domainRules).css.includes('.global{'), false);
assert.equal(runFrame('frame.example', domainRules).css.includes('.global{'), true);
assert.equal(runFrame('frame.example', domainRules).css.includes('.frame{'), true);
assert.equal(runFrame('redirect.example', domainRules).css.includes('.landing{'), true);
const budgetRules = [
  ...Array.from({length: 129}, (_, i) => ({selector: `.budget${i}`})),
  {selector: '.budget0', exception: true},
];
const budgetCss = runFrame('top.example', budgetRules).css;
assert.equal(budgetCss.includes('.budget0{'), false);
assert.equal(budgetCss.includes('.budget128{'), true);
assert.equal(budgetCss.split('\n').length, 128);
const scriptletRules = [
  ...Array.from({length: 32}, (_, i) => ({domain: 'other.example', name: 'set-constant', args: [`other${i}`, 'true']})),
  {domain: 'frame.example', name: 'set-constant', args: ['current', 'true']},
  ...Array.from({length: 32}, (_, i) => ({domain: 'frame.example', name: 'set-constant', args: [`limited${i}`, 'true']})),
];
const scriptletFrame = runFrame('frame.example', [], scriptletRules);
assert.equal(scriptletFrame.window.current, true);
assert.equal(scriptletFrame.window.limited30, true);
assert.equal(scriptletFrame.window.limited31, undefined);
console.log('filter runtime contract: ok');
