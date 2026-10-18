(function (selector) {
  try {
    const compact = value => String(value || '').replace(/\s+/g, ' ').trim();
    const regionSignal = /(?:最新(?:可用)?(?:站点|入口|地址)|(?:站点|入口|地址).{0,8}最新|官方地址|备用域名|可用域名|地址列表|线路地址|永久地址)/i;
    const publishSignal = /(?:发布页|地址发布|备用网址|回家看看|永久地址)/i;
    const directHostSignal = /(?:latest|address|domain|site|line|url|link|content|list)/i;

    let root;
    if (selector === '@latest-addresses') {
      const headings = [...document.querySelectorAll('h1,h2,h3,h4,strong,b,p,span')];
      const heading = headings.find(el => {
        const value = compact(el.textContent);
        return regionSignal.test(value) && value.length < 120;
      }) || headings.find(el => {
        const value = compact(el.textContent);
        return publishSignal.test(value) && value.length < 160;
      });

      if (heading) {
        const boundary = heading.closest('main,article') || heading.parentElement || document.body;
        const regions = [boundary, ...boundary.querySelectorAll('section,ul,ol,div')]
          .map(candidate => {
            const children = [...candidate.children];
            const headingsInside = [
              ...candidate.querySelectorAll('h1,h2,h3,h4,strong,b,p,span'),
            ];
            const text = compact(candidate.textContent);
            const directHeading = children.some(child =>
              /^(H1|H2|H3|H4|STRONG|B|P|SPAN)$/.test(child.tagName || '') &&
              (regionSignal.test(compact(child.textContent)) ||
                publishSignal.test(compact(child.textContent))),
            );
            const containsRegionHeading = headingsInside.some(el =>
              regionSignal.test(compact(el.textContent)),
            );
            const classSignal = `${candidate.id || ''} ${candidate.className || ''}`;
            return {
              candidate,
              count: candidate.querySelectorAll('a[href]').length,
              text,
              directHeading,
              containsRegionHeading,
              structural: candidate.matches('section,ul,ol'),
              classSignal: directHostSignal.test(classSignal),
            };
          })
          .filter(item => item.count > 0 && item.count <= 120)
          .sort((a, b) => {
            const score = item =>
              (regionSignal.test(item.text) ? 10 : 0) +
              (item.directHeading ? 8 : 0) +
              (item.containsRegionHeading ? 4 : 0) +
              (item.structural ? 4 : 0) +
              (item.classSignal ? 2 : 0) +
              (item.count <= 40 ? 1 : 0) +
              (item.candidate === boundary ? -2 : 0);
            return score(b) - score(a) || a.count - b.count;
          });
        root = regions[0]?.candidate;
      }

      // A few old publishing pages render their heading and link list through
      // different fragments. Only use a broad main/article fallback when the
      // document itself has publishing-page language; never harvest the whole
      // page merely because it contains anchors.
      if (!root && publishSignal.test(compact(document.title))) {
        root = [...document.querySelectorAll('main,article,body')]
          .map(candidate => ({candidate, count: candidate.querySelectorAll('a[href]').length}))
          .filter(item => item.count > 0 && item.count <= 120)
          .sort((a, b) => a.count - b.count)[0]?.candidate;
      }
    } else {
      root = document.querySelector(selector);
    }

    const visible = el =>
      !!el && el.getBoundingClientRect().width > 0 && el.getBoundingClientRect().height > 0;
    const text = (document.body && document.body.innerText || '').slice(0, 20000);
    const challenge = !!document.querySelector(
      '.g-recaptcha,.h-captcha,iframe[src*="captcha"],input[name*="captcha"]',
    ) || /验证码|人机验证|verify (that )?you are human|checking your browser|attention required.*cloudflare/i.test(text);
    const interactionRequired = Array.from(document.querySelectorAll('input[type="password"]')).some(visible);
    const anchors = root
      ? [...(root.matches('a[href]') ? [root] : []), ...root.querySelectorAll('a[href]')]
      : [];
    const ready = document.readyState !== 'loading' && visible(root) &&
      ((root.textContent || '').trim().length >= 16 || !!root.querySelector('a[href],video,audio,img,article')) &&
      (selector !== '@latest-addresses' || anchors.length > 0);
    const pageKey = raw => {
      try {
        const u = new URL(raw, document.baseURI);
        u.hash = '';
        if (!u.pathname) u.pathname = '/';
        return u.href;
      } catch (_) { return ''; }
    };
    const currentPage = pageKey(location.href);
    const positive = /入口|站点|网站|主站|官网|访问|进入|立即进入|在线|播放|线路|镜像|可用地址|最新地址|永久地址|site|website|home|official|enter|open|visit|watch|play|line|mirror/i;
    const negative = /发布页|发布地址|备用.*发布|永久发布|邮箱|telegram|twitter|facebook|discord|github|下载|文档|教程|登录|注册|公告|联系|客服|隐私|条款|admin|wp-admin|publish|release|download|docs?|contact|about|login|register|rss|\.xml(?:$|[?#])/i;
    const visibleText = value => compact(value).slice(0, 240);
    const domainHost = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$/i;
    const ipv4Host = /^(?:\d{1,3}\.){3}\d{1,3}$/;
    const isPublicHostShape = host => domainHost.test(host) || ipv4Host.test(host);
    const rootPath = path => /^\/(?:|home(?:\.html?)?|index(?:\.html?)?|main(?:\.html?)?)$/i.test(path || '/');
    const domainLabel = value => {
      const label = compact(value).replace(/[：:]\s*$/, '');
      return /^(?:https?:\/\/)?(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\/?$/i.test(label) ||
        /^(?:https?:\/\/)?(?:\d{1,3}\.){3}\d{1,3}\/?$/i.test(label);
    };
    const redirectPath = /\/(?:hop|go|out|redirect|redir|jump|link)(?:\/|$)/i;
    const parseTarget = raw => {
      try {
        const source = new URL(raw, document.baseURI);
        if (!/^https?:$/.test(source.protocol)) return null;
        let target = source;
        let unwrapped = false;
        if (redirectPath.test(source.pathname)) {
          for (const key of ['to', 'url', 'target', 'redirect', 'link']) {
            const value = source.searchParams.get(key);
            if (!value) continue;
            const candidate = /^[a-z0-9.-]+\.[a-z]{2,}(?:[/:?#]|$)/i.test(value)
              ? new URL('https://' + value)
              : new URL(value, source.origin);
            if (/^https?:$/.test(candidate.protocol) && candidate.host &&
                !candidate.username && !candidate.password &&
                isPublicHostShape(candidate.hostname)) {
              target = candidate;
              unwrapped = true;
              break;
            }
          }
        }
        if (!target.host || !isPublicHostShape(target.hostname)) return null;
        target.hash = '';
        return {source, target, unwrapped};
      } catch (_) { return null; }
    };
    const links = anchors
      .map((a, index) => {
        const raw = a.href || a.getAttribute('href') || '';
        const parsed = parseTarget(raw);
        if (!parsed) return {href: '', score: -99, index};
        const {source, target, unwrapped} = parsed;
        const href = target.href;
        const urlText = `${raw} ${href} ${a.pathname || ''}`;
        const label = visibleText(`${a.textContent || ''} ${a.getAttribute('aria-label') || ''} ${a.getAttribute('title') || ''}`);
        const parentText = a.parentElement && a.parentElement !== root
          ? a.parentElement.textContent
          : '';
        const nearby = visibleText(parentText);
        let score = 0;
        if (positive.test(label)) score += 4;
        if (positive.test(nearby)) score += 2;
        if (domainLabel(label)) score += 5;
        if (label.includes(target.hostname)) score += 2;
        if (unwrapped) score += 3;
        if (rootPath(target.pathname)) score += 2;
        if (negative.test(`${label} ${urlText}`)) score -= 8;
        // A publishing page is its own source, never a landing candidate.
        if (target.hostname.toLowerCase() === location.hostname.toLowerCase()) score = -99;
        if (score < 5) score = -99;
        return {href, score, index, source};
      })
      .filter(item => item.score >= 5 && pageKey(item.href) !== currentPage)
      .sort((a, b) => b.score - a.score || a.index - b.index)
      .map(item => item.href)
      .filter((href, index, all) => all.indexOf(href) === index)
      .slice(0, 40);
    return JSON.stringify({title: document.title, ready, challenge, interactionRequired, links, text: (root && root.textContent || '').slice(0, 4096), error: ''});
  } catch (error) {
    return JSON.stringify({title: '', ready: false, challenge: false, interactionRequired: false, links: [], text: '', error: 'DOM selector/inspection error: ' + error});
  }
})(__LENS_SELECTOR__);
