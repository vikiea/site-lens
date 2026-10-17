(function (selector) {
  try {
    let root;
    if (selector === '@latest-addresses') {
      const heading = [...document.querySelectorAll('h1,h2,h3,h4,strong,b,p,span')].find(el => {
        const value = (el.textContent || '').replace(/\s+/g, ' ').trim();
        return /(?:最新(?:可用)?(?:站点|入口|地址)|(?:站点|入口|地址).{0,8}最新|官方地址|备用域名|可用域名)/.test(value) && value.length < 100;
      });
      if (heading) {
        const boundary = heading.closest('main,article') || heading.parentElement || document.body;
        const regions = [boundary, ...boundary.querySelectorAll('section,ul,ol,div')]
          .map(candidate => ({
            candidate,
            count: candidate.querySelectorAll('a[href]').length,
            text: (candidate.textContent || '').replace(/\s+/g, ' ').trim(),
            directHeading: [...candidate.children].some(child =>
              /^(H1|H2|H3|H4|STRONG|B|P|SPAN)$/.test(child.tagName || '') &&
              /(?:最新(?:可用)?(?:站点|入口|地址)|官方地址|备用域名|可用域名)/.test(
                (child.textContent || '').replace(/\s+/g, ' ').trim(),
              )),
          }))
          .filter(item => item.count > 0 && item.count <= 80)
          .sort((a, b) => {
            const score = item =>
              (/(官方地址|最新地址|备用域名|可用域名|站点入口)/.test(item.text) ? 8 : 0) +
              (item.directHeading ? 4 : 0) +
              (item.candidate.matches('section,ul,ol') ? 3 : 0) +
              (item.count <= 40 ? 2 : 0);
            return score(b) - score(a) || a.count - b.count;
          });
        root = regions[0]?.candidate;
        if (!root) {
          let candidate = heading.parentElement;
          for (let depth = 0; depth < 4 && candidate && candidate !== document.body && candidate !== document.documentElement; depth++, candidate = candidate.parentElement) {
            const count = candidate.querySelectorAll('a[href]').length;
            if (count > 0 && count <= 80) { root = candidate; break; }
          }
        }
      }
    } else { root = document.querySelector(selector); }
    const visible = el => !!el && el.getBoundingClientRect().width > 0 && el.getBoundingClientRect().height > 0;
    const text = (document.body && document.body.innerText || '').slice(0, 20000);
    const challenge = !!document.querySelector('.g-recaptcha,.h-captcha,iframe[src*="captcha"],input[name*="captcha"]') || /验证码|人机验证|verify (that )?you are human|checking your browser|attention required.*cloudflare/i.test(text);
    const interactionRequired = Array.from(document.querySelectorAll('input[type="password"]')).some(visible);
    const ready = document.readyState !== 'loading' && visible(root) && ((root.textContent || '').trim().length >= 16 || !!root.querySelector('a[href],video,audio,img,article'));
    const anchors = root ? [...(root.matches('a[href]') ? [root] : []), ...root.querySelectorAll('a[href]')] : [];
    const pageKey = raw => {
      try {
        const u = new URL(raw, document.baseURI);
        u.hash = '';
        if (!u.pathname) u.pathname = '/';
        return u.href;
      } catch (_) { return ''; }
    };
    const currentPage = pageKey(location.href);
    const positive = /入口|站点|网站|主站|官网|访问|进入|在线|播放|线路|镜像|可用地址|site|website|home|official|enter|open|visit|watch|play|line|mirror/i;
    const negative = /发布页|发布地址|备用.*发布|永久发布|邮箱|telegram|twitter|facebook|discord|github|下载|文档|教程|登录|注册|公告|联系|客服|隐私|条款|admin|wp-admin|publish|release|download|docs?|contact|about|login|register|rss|\.xml(?:$|[?#])/i;
    const visibleText = value => String(value || '').replace(/\s+/g, ' ').trim().slice(0, 240);
    const unwrapTarget = raw => {
      try {
        const source = new URL(raw, document.baseURI);
        if (!/\/(?:hop|go|out|redirect|redir|jump|link)(?:\/|$)/i.test(source.pathname)) return source.href;
        for (const key of ['to', 'url', 'target', 'redirect', 'link']) {
          const value = source.searchParams.get(key);
          if (!value) continue;
          const candidate = /^[a-z0-9.-]+\.[a-z]{2,}(?:[/:?#]|$)/i.test(value)
            ? new URL('https://' + value)
            : new URL(value, source.origin);
          if (/^https?:$/.test(candidate.protocol) && candidate.host && candidate.host !== location.host && !candidate.username && !candidate.password) {
            candidate.hash = '';
            return candidate.href;
          }
        }
        return source.href;
      } catch (_) { return raw; }
    };
    const links = anchors
      .map((a, index) => {
        const href = a.href || '';
        const target = unwrapTarget(href);
        const urlText = `${href} ${target} ${a.pathname || ''}`;
        const label = visibleText(`${a.textContent || ''} ${a.getAttribute('aria-label') || ''} ${a.getAttribute('title') || ''}`);
        const parentText = a.parentElement && a.parentElement !== root
          ? a.parentElement.textContent
          : '';
        const nearby = visibleText(parentText);
        let score = 0;
        if (positive.test(label)) score += 4;
        if (positive.test(nearby)) score += 2;
        if (/\/$|\/home(?:\.html?)?$|\/index(?:\.html?)?$|\/main(?:\.html?)?$/i.test(a.pathname || '/')) score += 2;
        if (/^[a-z0-9.-]+\.[a-z]{2,}$/i.test(label)) score += 2;
        if (negative.test(`${label} ${urlText}`)) score -= 6;
        if (!href || /^(?:mailto:|javascript:|tel:|data:)/i.test(href)) score = -99;
        return {href: target, score, index};
      })
      // A publishing page commonly links to itself through a canonical or
      // trailing-slash variant. It is a source document, never a candidate.
      .filter(item => item.score >= 3 && pageKey(item.href) !== currentPage)
      .sort((a, b) => b.score - a.score || a.index - b.index)
      .map(item => item.href)
      .filter((href, index, all) => all.indexOf(href) === index)
      .slice(0, 40);
    return JSON.stringify({title: document.title, ready, challenge, interactionRequired, links, text: (root && root.textContent || '').slice(0, 4096), error: ''});
  } catch (error) {
    return JSON.stringify({title: '', ready: false, challenge: false, interactionRequired: false, links: [], text: '', error: 'DOM selector/inspection error: ' + error});
  }
})(__LENS_SELECTOR__);
