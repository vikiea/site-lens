/*
 * Generic publishing-page inspector.  @latest-addresses accepts normal links,
 * data attributes, redirect targets such as /hop?to=example.com, and plain
 * text domains.  It scores the surrounding DOM so navigation and footer blocks
 * are less likely to be selected.
 *
 * Site-specific rules can be stored as the region selector:
 * @extract:{"root":".address-list","linkSelector":"a,[data-domain]","urlAttributes":["data-domain","data-url"],"includeText":true,"exclude":[".ad"],"limit":40}
 */
(function (selector) {
  try {
    const MAX_LINKS = 100;
    // Keep the expression compatible with older Android WebViews: avoid
    // lookbehind and take capture group 1 below.
    const ADDRESS_RE = /(?:^|[^@\w])((?:https?:\/\/|www\.)[^\s<>'"\`]+|(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}(?::\d{1,5})?(?:[/?#][^\s<>'"\`]*)?)/ig;
    const POSITIVE_RE = /最新|最新地址|官方地址|备用网址|备用地址|地址列表|站点列表|入口列表|访问地址|域名|主站|备用|入口|官网|address|domain|mirror|official|backup|site/i;
    const NEGATIVE_RE = /导航|菜单|页脚|footer|广告|推广|友链|友情链接|社交|登录|注册|下载|客服|版权|隐私|telegram|twitter|facebook|github|sponsor|nav|menu|sidebar|float|banner|ad-/i;
    const LINK_LABEL_NOISE_RE = /备用.*发布|发布页|发布地址|永久发布|邮箱|telegram|twitter/i;
    const NOISE_HOST_RE = /(?:facebook\.com|twitter\.com|x\.com|t\.me|telegram\.me|github\.com|cloudflareinsights\.com|google-analytics\.com)$/i;
    const URL_ATTRS = ['data-copy-domain', 'data-domain', 'data-domains', 'data-dm-domains', 'data-addresses', 'data-sites', 'data-url', 'data-href', 'data-link', 'data-target', 'value'];

    const trimPunctuation = value => String(value || '').trim()
      .replace(/^[([{<（【「]+/, '')
      .replace(/[\]})}>.,;:!?。，、；：！？）】」]+$/, '');
    const normaliseUrl = (raw, base) => {
      let value = trimPunctuation(raw);
      if (!value || /^(?:javascript|mailto|tel|data|blob):/i.test(value)) return null;
      try {
        const parsed = new URL(value, base || document.baseURI || location.href);
        const target = parsed.searchParams.get('to') || parsed.searchParams.get('url') || parsed.searchParams.get('target');
        if (target && /(?:^|\/)(?:hop|go|redirect|jump|link)(?:\/|$)/i.test(parsed.pathname)) value = target;
      } catch (_) { /* allow the bare-domain parser below */ }
      if (/^\/\//.test(value)) value = (location.protocol || 'https:') + value;
      if (!/^[a-z][a-z\d+.-]*:\/\//i.test(value)) {
        if (!/^(?:www\.)?(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}(?::\d{1,5})?(?:[/?#]|$)/i.test(value)) return null;
        value = 'https://' + value;
      }
      try {
        const parsed = new URL(value, base || document.baseURI || location.href);
        if (!['http:', 'https:'].includes(parsed.protocol) || !parsed.hostname || parsed.username || parsed.password) return null;
        parsed.hash = '';
        return parsed.href;
      } catch (_) { return null; }
    };
    const visible = element => {
      if (!element) return false;
      try {
        const style = getComputedStyle(element);
        if (style && (style.display === 'none' || style.visibility === 'hidden')) return false;
        const rect = element.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0;
      } catch (_) { return true; }
    };
    const nodeText = node => ((node && (node.innerText || node.textContent)) || '').replace(/\s+/g, ' ').trim();
    const classText = node => [node && node.id, node && node.className, node && node.getAttribute && node.getAttribute('aria-label')].filter(Boolean).join(' ');
    const isNoise = (url, text) => {
      try { if (NOISE_HOST_RE.test(new URL(url).hostname)) return true; } catch (_) {}
      return /(?:\.gif|\.jpe?g|\.png|\.webp|\.svg|\.css|\.js)(?:[?#]|$)/i.test(url) && !/进入|地址|站点|入口/i.test(text || '');
    };
    const add = (out, raw, sourceText, base) => {
      const value = normaliseUrl(raw, base);
      if (!value || isNoise(value, sourceText)) return;
      if (!out.some(item => item.url === value)) out.push({url: value, text: sourceText || ''});
    };
    const extract = (root, options) => {
      const out = [];
      if (!root) return out;
      const attributes = Array.isArray(options && options.urlAttributes) && options.urlAttributes.length
        ? options.urlAttributes.filter(value => typeof value === 'string') : URL_ATTRS;
      const excluded = Array.isArray(options && options.exclude) ? options.exclude : [];
      const isExcluded = node => {
        if (!excluded.length) return false;
        try {
          return excluded.some(rule => {
            if (!node.matches || !node.matches(rule)) return !!(node.closest && node.closest(rule));
            return true;
          });
        } catch (_) { return false; }
      };
      const selectorForLinks = options && typeof options.linkSelector === 'string' && options.linkSelector.trim()
        ? options.linkSelector : 'a[href]';
      let nodes = [];
      try { nodes = [...root.querySelectorAll(selectorForLinks)]; } catch (_) { nodes = []; }
      if (root.matches && root.matches(selectorForLinks)) nodes.unshift(root);
      for (const node of nodes) {
        if (isExcluded(node)) continue;
        const text = nodeText(node);
        const href = node.getAttribute && node.getAttribute('href');
        if (href && !LINK_LABEL_NOISE_RE.test(text)) add(out, href, text);
        for (const attr of attributes) {
          const value = node.getAttribute && node.getAttribute(attr);
          if (value) {
            const values = /(?:domains|addresses|sites|links)$/i.test(attr) ? value.split(/[\s,，;；|]+/) : [value];
            for (const item of values) add(out, item, text);
          }
        }
        if (options == null || options.includeText !== false) add(out, text, text);
      }
      let attrNodes = [];
      try { attrNodes = [...root.querySelectorAll('*')]; } catch (_) { attrNodes = []; }
      if (root.getAttribute) attrNodes.unshift(root);
      for (const node of attrNodes) {
        if (isExcluded(node)) continue;
        const text = nodeText(node);
        for (const attr of attributes) {
          const value = node.getAttribute && node.getAttribute(attr);
          if (value) {
            const values = /(?:domains|addresses|sites|links)$/i.test(attr) ? value.split(/[\s,，;；|]+/) : [value];
            for (const item of values) add(out, item, text);
          }
        }
      }
      if (options == null || options.includeText !== false) {
        for (const match of nodeText(root).matchAll(ADDRESS_RE)) add(out, match[1] || match[0], match[1] || match[0]);
      }
      const limitValue = Number(options && options.limit);
      const limit = Number.isFinite(limitValue) ? Math.max(1, Math.min(MAX_LINKS, limitValue)) : MAX_LINKS;
      return out.slice(0, limit);
    };
    const parseCustom = raw => {
      if (typeof raw !== 'string' || !raw.startsWith('@extract:')) return null;
      try {
        const config = JSON.parse(raw.substring('@extract:'.length));
        if (!config || typeof config !== 'object' || Array.isArray(config)) return null;
        const root = typeof config.root === 'string' && config.root.trim() ? document.querySelector(config.root) : document.body;
        return {root, options: config};
      } catch (_) { return null; }
    };
    const nodeScore = (node, links) => {
      let nearbyHeading = '';
      try {
        const previous = node.previousElementSibling;
        if (previous && /^H[1-6]$/i.test(previous.tagName)) nearbyHeading = nodeText(previous);
        if (!nearbyHeading && node.parentElement) {
          const heading = node.parentElement.querySelector('h1,h2,h3,h4,h5,h6');
          if (heading && heading !== node) nearbyHeading = nodeText(heading);
        }
      } catch (_) {}
      const label = classText(node) + ' ' + nearbyHeading + ' ' + nodeText(node).slice(0, 1200);
      let score = Math.min(links.length, 40) * 3;
      const positive = POSITIVE_RE.test(label);
      if (positive) score += 30;
      if (NEGATIVE_RE.test(label)) score -= 38;
      if (node === document.body) score -= 28 + Math.min(80, links.length * 2);
      // A data-domain/copy-domain attribute is a stronger signal than a bare
      // href.  Give small, otherwise unlabelled address blocks a chance to
      // pass the confidence floor without allowing the whole body to win.
      let hasAddressData = false;
      try {
        hasAddressData = URL_ATTRS.some(attr => node.hasAttribute(attr));
        if (hasAddressData) score += 20;
      } catch (_) {}
      if (node === document.body && !positive && !hasAddressData) score -= 30;
      if (node !== document.body && links.length >= 2) score += 10;
      if (links.length > 60) score -= Math.min(50, links.length - 60);
      const textLength = nodeText(node).length;
      if (textLength > 12000) score -= Math.min(30, Math.floor((textLength - 12000) / 2000));
      return score;
    };
    const heuristic = () => {
      const nodes = [];
      try { nodes.push(...document.querySelectorAll('main,section,article,ul,ol,table,div,body')); } catch (_) {}
      let best = null;
      let metadataFallback = false;
      for (const node of nodes) {
        if (!visible(node)) continue;
        const links = extract(node, {includeText: true});
        if (!links.length) continue;
        const score = nodeScore(node, links);
        if (!best || score > best.score || (score === best.score && links.length < best.links.length)) best = {node, links, score};
      }
      if (!best || best.score < 12) {
        const metadata = [];
        try {
          for (const node of document.querySelectorAll('meta[content],script[type="application/ld+json"]')) {
            for (const match of (node.getAttribute('content') || node.textContent || '').matchAll(ADDRESS_RE)) add(metadata, match[1] || match[0], match[1] || match[0]);
          }
        } catch (_) {}
        if (metadata.length && (!best || best.score < 12)) {
          best = {node: document.body, links: metadata, score: 5};
          metadataFallback = true;
        }
      }
      return best && (metadataFallback || best.score >= 12) ? best : null;
    };

    let root;
    let links = [];
    const custom = parseCustom(selector);
    const requiresLinks = !!custom || selector === '@latest-addresses' || selector === '@all-addresses';
    if (custom) {
      root = custom.root;
      links = extract(root, custom.options);
    } else if (selector === '@latest-addresses' || selector === '@all-addresses') {
      const picked = heuristic();
      root = picked && picked.node;
      links = picked ? picked.links : [];
    } else {
      root = document.querySelector(selector);
      links = extract(root, {includeText: true});
    }
    const text = nodeText(root).slice(0, 4096);
    const bodyText = nodeText(document.body).slice(0, 20000);
    const challenge = !!document.querySelector('.g-recaptcha,.h-captcha,iframe[src*="captcha"],input[name*="captcha"]') || /验证码|人机验证|verify (that )?you are human|checking your browser|attention required.*cloudflare/i.test(bodyText);
    const interactionRequired = [...document.querySelectorAll('input[type="password"]')].some(visible);
    const hasContentRoot = root && (root.querySelector('a[href],video,audio,img,article') || links.length > 0);
    const readyContent = text.length >= 16 || !!hasContentRoot || root === document.body;
    const ready = document.readyState !== 'loading' && visible(root) && readyContent && (!requiresLinks || links.length > 0);
    return JSON.stringify({title: document.title, ready, challenge, interactionRequired, links: links.map(item => item.url).slice(0, MAX_LINKS), text, error: ''});
  } catch (error) {
    return JSON.stringify({title: '', ready: false, challenge: false, interactionRequired: false, links: [], text: '', error: 'DOM selector/inspection error: ' + error});
  }
})(__LENS_SELECTOR__);
