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
console.log('filter runtime contract: ok');
