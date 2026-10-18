(() => {
  'use strict';
  let config;
  try { config = __SITE_LENS_FILTER_CONFIG__; } catch (_) { return; }
  if (!config || !config.enabled) return;

  // Cosmetic rules are intentionally selector-only.  Arbitrary JavaScript
  // from a remote rule source is never evaluated in the page.
  const safeSelector = value => {
    const selector = typeof value === 'string' ? value : value && value.selector;
    if (typeof selector !== 'string' || selector.length === 0 || selector.length > 256) return false;
    if (/[{};]/.test(selector)) return false;
    return !/:(?:has-text|contains|matches-css|xpath|style|remove-attr|remove-class)/i.test(selector)
      && /^[A-Za-z0-9_.*#\-\[\]="': >+~(),]+$/.test(selector);
  };
  const selectorRules = Array.isArray(config.selectors)
    ? config.selectors.filter(safeSelector)
    : [];
  const scriptlets = Array.isArray(config.scriptlets) ? config.scriptlets : [];
  const hostMatches = (domain, domains, excludedDomains) => {
    const host = String(location.hostname || '').toLowerCase();
    const excluded = Array.isArray(excludedDomains) && excludedDomains.some(item => {
      const value = String(item || '').toLowerCase().replace(/^\*\./, '');
      return value && (host === value || host.endsWith('.' + value));
    });
    if (excluded) return false;
    const values = Array.isArray(domains) && domains.length ? domains : [domain || '*'];
    return values.some(item => {
      const value = String(item || '*').toLowerCase().replace(/^\*\./, '');
      return value === '*' || host === value || host.endsWith('.' + value);
    });
  };
  const resolvePath = path => String(path || '').split('.').filter(Boolean).slice(0, 8);
  const applyScriptlet = item => {
    if (!item || !hostMatches(item.domain, item.domains, item.excludedDomains)) return;
    const args = Array.isArray(item.args) ? item.args : [];
    const path = resolvePath(args[0]);
    if (!path.length || !['abort-on-property-read', 'set-constant'].includes(item.name)) return;
    let owner = window;
    for (let i = 0; i < path.length - 1; i++) {
      if (!owner || typeof owner !== 'object') return;
      owner = owner[path[i]];
    }
    if (!owner || typeof owner !== 'object') return;
    const key = path[path.length - 1];
    try {
      Object.defineProperty(owner, key, {
        configurable: true,
        enumerable: true,
        get: () => item.name === 'set-constant' ? (args[1] === 'true' ? true : args[1] === 'false' ? false : args[1] === 'undefined' ? undefined : args[1] || undefined) : undefined,
        set: () => true,
      });
    } catch (_) {}
  };
  const effectiveSelectors = () => {
    const blocked = new Set();
    for (const item of selectorRules) {
      const selector = typeof item === 'string' ? item : item.selector;
      const domain = typeof item === 'string' ? '*' : item.domain;
      if (!hostMatches(domain, typeof item === 'string' ? null : item.domains, typeof item === 'string' ? null : item.excludedDomains)) continue;
      if (typeof item !== 'string' && item.exception) blocked.delete(selector);
      else blocked.add(selector);
    }
    return [...blocked];
  };
  const remove = root => {
    for (const selector of effectiveSelectors()) {
      try { root.querySelectorAll(selector).forEach(node => node.remove()); } catch (_) {}
    }
  };
  const install = () => {
    if (!document.documentElement) return false;
    scriptlets.slice(0, 32).forEach(applyScriptlet);
    remove(document);
    const selectors = effectiveSelectors();
    if (selectors.length) {
      const style = document.createElement('style');
      style.dataset.siteLensFilter = String(config.snapshotId || '');
      style.textContent = selectors
        .map(selector => `${selector}{display:none!important}`)
        .join('\n');
      (document.head || document.documentElement).appendChild(style);
    }
    return true;
  };
  if (!install()) {
    document.addEventListener('DOMContentLoaded', install, { once: true });
    setTimeout(install, 0);
  }
  try {
    new MutationObserver(records => {
      for (const record of records) {
        for (const node of record.addedNodes || []) {
          if (node.nodeType === 1) remove(node);
        }
      }
    }).observe(document.documentElement || document, {childList: true, subtree: true});
  } catch (_) {}
})();
