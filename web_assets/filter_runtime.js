(() => {
  'use strict';
  let config;
  try { config = __SITE_LENS_FILTER_CONFIG__; } catch (_) { return; }
  if (!config || !config.enabled) return;

  // Cosmetic rules are intentionally selector-only.  Arbitrary JavaScript
  // from a remote rule source is never evaluated in the page.
  const selectors = Array.isArray(config.selectors)
    ? config.selectors.filter(value => typeof value === 'string' && value.length < 512)
    : [];
  const remove = root => {
    for (const selector of selectors) {
      try { root.querySelectorAll(selector).forEach(node => node.remove()); } catch (_) {}
    }
  };
  const install = () => {
    if (!document.documentElement) return;
    remove(document);
    if (selectors.length) {
      const style = document.createElement('style');
      style.dataset.siteLensFilter = String(config.snapshotId || '');
      style.textContent = selectors.map(selector => `${selector}{display:none!important}`).join('\n');
      (document.head || document.documentElement).appendChild(style);
    }
  };
  install();
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
