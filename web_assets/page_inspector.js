(function (selector) {
  try {
    let root;
    if (selector === '@latest-addresses') {
      const heading = [...document.querySelectorAll('h1,h2,h3,h4,strong,b,p,span')].find(el => /^(最新地址|最新(可用)?(站点|入口|地址))/.test((el.textContent || '').trim()) && (el.textContent || '').trim().length < 80);
      if (heading) {
        let candidate = heading.parentElement;
        for (let depth = 0; depth < 4 && candidate && candidate !== document.body && candidate !== document.documentElement; depth++, candidate = candidate.parentElement) {
          const count = candidate.querySelectorAll('a[href]').length;
          if (count > 0 && count <= 40) { root = candidate; break; }
        }
      }
    } else { root = document.querySelector(selector); }
    const visible = el => !!el && el.getBoundingClientRect().width > 0 && el.getBoundingClientRect().height > 0;
    const text = (document.body && document.body.innerText || '').slice(0, 20000);
    const challenge = !!document.querySelector('.g-recaptcha,.h-captcha,iframe[src*="captcha"],input[name*="captcha"]') || /验证码|人机验证|verify (that )?you are human|checking your browser|attention required.*cloudflare/i.test(text);
    const interactionRequired = Array.from(document.querySelectorAll('input[type="password"]')).some(visible);
    const ready = document.readyState !== 'loading' && visible(root) && ((root.textContent || '').trim().length >= 16 || !!root.querySelector('a[href],video,audio,img,article'));
    const anchors = root ? [...(root.matches('a[href]') ? [root] : []), ...root.querySelectorAll('a[href]')] : [];
    return JSON.stringify({title: document.title, ready, challenge, interactionRequired, links: anchors.filter(a => !/备用.*发布|发布页|发布地址|永久发布|邮箱|telegram|twitter/i.test(a.textContent || '')).slice(0, 100).map(a => a.href), text: (root && root.textContent || '').slice(0, 4096), error: ''});
  } catch (error) {
    return JSON.stringify({title: '', ready: false, challenge: false, interactionRequired: false, links: [], text: '', error: 'DOM selector/inspection error: ' + error});
  }
})(__LENS_SELECTOR__);
