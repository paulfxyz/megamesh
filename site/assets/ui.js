/* megamesh.sh — shared UI. No tracking; network only for flag images and the public GitHub repo stats. */
(() => {
  const $ = (s, r = document) => r.querySelector(s);
  const store = { get: (k) => { try { return localStorage.getItem(k); } catch { return null; } }, set: (k, v) => { try { localStorage.setItem(k, v); } catch {} } };
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const root = document.documentElement;

  // ── i18n ─────────────────────────────────────────────────────────────────
  // English lives in the HTML. Other languages are JSON files keyed by data-i18n; applied client-side, remembered in mm-lang.
  const PAGE = location.pathname.startsWith('/deploy') ? 'd' : 'i';
  const RTL = new Set(['ar', 'ur', 'fa', 'sd', 'pa']);
  const orig = new Map();
  const MM = window.MM = { lang: 'en', dict: null, t: (k, fb) => (MM.dict && typeof MM.dict[k] === 'string' ? MM.dict[k] : fb) };
  const VER = (document.querySelector('script[src*="ui.js"]') || {}).src?.match(/v=(\d+)/)?.[1] || '0';
  const applyDict = (code, dict) => {
    document.querySelectorAll('[data-i18n]').forEach((el) => {
      const k = el.dataset.i18n; if (!orig.has(k)) orig.set(k, el.innerHTML);
      const v = dict ? dict[k] : orig.get(k); if (typeof v === 'string') el.innerHTML = v;
    });
    document.querySelectorAll('[data-i18n-attrs]').forEach((el) => {
      el.dataset.i18nAttrs.split(',').forEach((pair) => { const [attr, k] = pair.split(':'); const ok = 'attr:' + k; if (!orig.has(ok)) orig.set(ok, el.getAttribute(attr)); const v = dict ? dict[k] : orig.get(ok); if (typeof v === 'string') el.setAttribute(attr, v); });
    });
    const meta = (sel, k) => { const m = document.querySelector(sel); if (!m) return; const ok = 'meta:' + k; if (!orig.has(ok)) orig.set(ok, m.content); const v = dict ? dict[k] : orig.get(ok); if (typeof v === 'string') m.content = v; };
    if (!orig.has('title')) orig.set('title', document.title);
    document.title = (dict && dict[`m.${PAGE}.title`]) || orig.get('title');
    meta('meta[name="description"]', `m.${PAGE}.description`); meta('meta[property="og:title"]', `m.${PAGE}.og_title`); meta('meta[property="og:description"]', `m.${PAGE}.og_description`);
    root.lang = code; root.dir = RTL.has(code) ? 'rtl' : 'ltr'; root.classList.toggle('rtl', RTL.has(code));
    MM.lang = code; MM.dict = dict;
    document.dispatchEvent(new CustomEvent('mm:lang', { detail: { lang: code } }));
  };
  const setLang = async (code) => {
    if (code === 'en') { applyDict('en', null); return true; }
    try {
      const r = await fetch(`/assets/i18n/${code}.json?v=${VER}`, { cache: 'force-cache' });
      if (!r.ok) throw new Error(String(r.status));
      applyDict(code, await r.json()); return true;
    } catch { applyDict('en', null); return false; }
  };
  MM.setLang = setLang;
  const savedLang = store.get('mm-lang') || 'en';
  const langReady = savedLang !== 'en' ? setLang(savedLang) : Promise.resolve(true);

  // ── theme ────────────────────────────────────────────────────────────────
  const themeBtn = $('#theme');
  const applyTheme = (t) => {
    root.setAttribute('data-theme', t);
    themeBtn && themeBtn.setAttribute('aria-pressed', String(t === 'dark'));
    const m = $('meta[name="theme-color"]'); if (m) m.content = t === 'dark' ? '#05070b' : '#f2f4f6';
  };
  applyTheme(store.get('mm-theme') || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'));
  themeBtn && themeBtn.addEventListener('click', () => { const t = root.getAttribute('data-theme') === 'dark' ? 'light' : 'dark'; store.set('mm-theme', t); applyTheme(t); });

  // ── nav: scrolled state, menu, progress, dock, top ───────────────────────
  const nav = $('#nav'), menu = $('#menu'), links = $('#links'), prog = $('#prog'), dock = $('#dock'), top = $('#top');
  if (menu && links) {
    menu.addEventListener('click', () => { const o = links.classList.toggle('open'); menu.setAttribute('aria-expanded', String(o)); });
    links.addEventListener('click', (e) => { if (e.target.tagName === 'A') { links.classList.remove('open'); menu.setAttribute('aria-expanded', 'false'); } });
    document.addEventListener('click', (e) => { if (!links.contains(e.target) && !menu.contains(e.target)) { links.classList.remove('open'); menu.setAttribute('aria-expanded', 'false'); } });
  }
  const onScroll = () => {
    const y = scrollY, h = document.documentElement.scrollHeight - innerHeight;
    nav && nav.classList.toggle('scrolled', y > 8);
    if (prog) prog.style.transform = `scaleX(${h > 0 ? y / h : 0})`;
    dock && dock.classList.toggle('on', y > innerHeight * 0.7 && y < h - 200);
    top && top.classList.toggle('on', y > innerHeight);
  };
  addEventListener('scroll', onScroll, { passive: true }); onScroll();
  top && top.addEventListener('click', () => scrollTo({ top: 0, behavior: reduced ? 'auto' : 'smooth' }));

  // ── copy buttons ─────────────────────────────────────────────────────────
  document.addEventListener('click', async (e) => {
    const b = e.target.closest('[data-copy]'); if (!b) return;
    const t = b.textContent;
    try { await navigator.clipboard.writeText(b.dataset.copy); b.textContent = 'Copied'; b.classList.add('did'); } catch { b.textContent = 'Select it'; }
    setTimeout(() => { b.textContent = t; b.classList.remove('did'); }, 1500);
  });

  // ── logo ping ────────────────────────────────────────────────────────────
  const brand = $('#brand');
  brand && brand.addEventListener('click', (e) => {
    brand.classList.remove('ping'); void brand.offsetWidth; brand.classList.add('ping');
    if (location.pathname === '/' || location.pathname === '/index.html') { e.preventDefault(); scrollTo({ top: 0, behavior: reduced ? 'auto' : 'smooth' }); }
  });

  // ── reveals ──────────────────────────────────────────────────────────────
  const io = new IntersectionObserver((es) => es.forEach((en) => { if (en.isIntersecting) { en.target.classList.add('in'); io.unobserve(en.target); } }), { rootMargin: '0px 0px -10% 0px', threshold: 0.05 });
  document.querySelectorAll('.rv').forEach((el) => io.observe(el));

  // ── manifesto: words brighten as you scroll ─────────────────────────────
  const manif = $('#manif');
  if (manif) {
    let words = [];
    const build = () => {
      const walk = (node) => {
        [...node.childNodes].forEach((n) => {
          if (n.nodeType === 3 && n.textContent.trim()) {
            const frag = document.createDocumentFragment();
            n.textContent.split(/(\s+)/).forEach((p) => { if (!p) return; if (/^\s+$/.test(p)) frag.appendChild(document.createTextNode(p)); else { const w = document.createElement('span'); w.className = 'w'; w.textContent = p; frag.appendChild(w); } });
            n.replaceWith(frag);
          } else if (n.nodeType === 1 && !n.classList.contains('w')) walk(n);
        });
      };
      walk(manif);
      words = [...manif.querySelectorAll('.w')];
    };
    const upd = () => {
      const r = manif.getBoundingClientRect(); const start = innerHeight * 0.85, end = innerHeight * 0.25;
      const p = Math.min(1, Math.max(0, (start - r.top) / (r.height + start - end)));
      const n = Math.round(p * words.length * 1.15);
      words.forEach((w, i) => w.classList.toggle('on', i < n || reduced));
    };
    build(); addEventListener('scroll', upd, { passive: true }); addEventListener('resize', upd); upd();
    document.addEventListener('mm:lang', () => { build(); upd(); });
  }

  // ── count-up ─────────────────────────────────────────────────────────────
  document.querySelectorAll('[data-count]').forEach((el) => {
    const end = +el.dataset.count; const fmt = (n) => n.toLocaleString('en-US');
    if (reduced) { el.textContent = fmt(end); return; }
    const o = new IntersectionObserver((es) => { if (!es[0].isIntersecting) return; o.disconnect(); const t0 = performance.now(), d = 1800;
      const step = (t) => { const p = Math.min(1, (t - t0) / d); el.textContent = fmt(Math.round(end * (1 - Math.pow(1 - p, 3)))); if (p < 1) requestAnimationFrame(step); }; requestAnimationFrame(step); }, { threshold: .4 });
    o.observe(el);
  });

  // ── terminal with tabs + typing ──────────────────────────────────────────
  const term = $('#term-body');
  if (term) {
    const esc = (s) => s.replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
    const SCRIPTS = {
      script: [
        ['c', '# One file. Read it first.'], ['p', '$ ', 'curl -fsSLO https://megamesh.sh/megamesh.sh'], ['p', '$ ', 'less megamesh.sh'],
        ['p', '$ ', 'MEGAMESH_DOMAIN=vpn.example.com MEGAMESH_EMAIL=you@example.com bash megamesh.sh'],
        ['o', '▶ megamesh 1.5.4 on CentOS Stream 9 (1 vCPU, 1 GB)'], ['ok', '✔ swap active · ✔ system updated · ✔ docker from signed repo'],
        ['ok', '✔ firewalld: public DROP, 22/tcp 51820/udp 443/tcp'], ['ok', '✔ sshd hardened · ✔ fail2ban sshd jail · ✔ sysctl'],
        ['ok', '✔ wg-easy up, admin account created before 443 opened'], ['ok', '✔ caddy up — waiting for DNS to issue the certificate'],
        ['o', '  credentials: /root/megamesh-admin-credentials'], ['o', '  next: A record vpn.example.com → 203.0.113.10, then https://vpn.example.com/'],
      ],
      agent: [
        ['c', '# Paste PROMPT.md into any agent with SSH'], ['p', '> ', 'Here is the server: 203.0.113.10, root, CentOS Stream 9, domain vpn.example.com.'],
        ['o', 'Agent: Changing the root password first. Reading state before touching anything…'], ['o', 'Agent: Swapfile exists but is inactive — enabling before dnf update (OOM trap #1).'],
        ['o', 'Agent: daemon.json has "iptables": false — Docker would publish nothing (trap #2).'], ['o', 'Agent: Opening the firewall before restarting sshd. Key login verified; disabling passwords.'],
        ['ok', 'Agent: ✔ 3 ports public · ✔ handshake OK · ✔ certificate issued. Here is your QR code.'],
      ],
      status: [
        ['p', '$ ', 'megamesh-status'], ['o', 'tunnel    wg0 up · 1 peer · last handshake 14 s ago'], ['o', 'firewall  public DROP · 22/tcp 51820/udp 443/tcp · icmp allow-list'],
        ['o', 'ssh       key-only · fail2ban: 7 banned · 0 failed today'], ['o', 'tls       vpn.example.com · expires in 89 days · auto-renew'],
        ['o', 'upgrades  megamesh-upgrade.timer → Mon 04:30 · last run ok · rollback armed'], ['ok', 'mode      VPN-only (outsiders → 302 https://example.com)'],
      ],
    };
    let run = 0;
    const play = async (key) => {
      const id = ++run; term.innerHTML = '';
      for (const [cls, a, b] of SCRIPTS[key]) {
        if (id !== run) return;
        const line = document.createElement('div');
        if (cls === 'p') { line.innerHTML = `<span class="p">${esc(a)}</span><b></b>`; term.appendChild(line); const bEl = line.querySelector('b');
          if (reduced) bEl.textContent = b; else { for (let i = 0; i <= b.length; i++) { if (id !== run) return; bEl.textContent = b.slice(0, i); await new Promise((r) => setTimeout(r, 14)); } } }
        else { line.innerHTML = `<span class="${cls}">${esc(a)}</span>`; term.appendChild(line); if (!reduced) await new Promise((r) => setTimeout(r, 160)); }
      }
      const c = document.createElement('span'); c.className = 'cur'; term.appendChild(c);
    };
    document.querySelectorAll('.term__tabs button').forEach((b) => b.addEventListener('click', () => { document.querySelectorAll('.term__tabs button').forEach((x) => x.setAttribute('aria-selected', 'false')); b.setAttribute('aria-selected', 'true'); play(b.dataset.tab); }));
    const o = new IntersectionObserver((es) => { if (es[0].isIntersecting) { o.disconnect(); play('script'); } }, { threshold: .3 }); o.observe(term);
  }

  // ── GitHub stats (public API, cached 10 min) ─────────────────────────────
  const ghEls = document.querySelectorAll('[data-gh]');
  if (ghEls.length) {
    const set = (k, v) => ghEls.forEach((el) => { if (el.dataset.gh === k) el.textContent = v; });
    let last = null;
    const pushedText = (d) => d.days == null ? (d.pushed || '—') : d.days === 0 ? MM.t('j.gh.today', 'today') : d.days === 1 ? MM.t('j.gh.yesterday', 'yesterday') : MM.t('j.gh.days_ago', '{n} days ago').replace('{n}', d.days);
    const render = (d) => { last = d; set('stars', String(d.stars)); set('release', d.release || '—'); set('pushed', pushedText(d)); const l = $('#gh-live'); if (l && d.at) l.textContent = MM.t('j.gh.live', 'Live from GitHub') + ' · ' + new Date(d.at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) + ' · github.com/paulfxyz/megamesh'; };
    document.addEventListener('mm:lang', () => { if (last) render(last); });
    const cached = (() => { try { return JSON.parse(sessionStorage.getItem('mm-gh') || 'null'); } catch { return null; } })();
    if (cached && Date.now() - cached.at < 600000) render(cached);
    else Promise.all([fetch('https://api.github.com/repos/paulfxyz/megamesh').then((r) => r.ok ? r.json() : null), fetch('https://api.github.com/repos/paulfxyz/megamesh/releases/latest').then((r) => r.ok ? r.json() : null)])
      .then(([repo, rel]) => { if (!repo) return; const days = Math.round((Date.now() - new Date(repo.pushed_at)) / 864e5);
        const d = { stars: repo.stargazers_count, release: rel ? rel.tag_name.replace(/^v/, '') : '', days, at: Date.now() };
        try { sessionStorage.setItem('mm-gh', JSON.stringify(d)); } catch {} render(d); }).catch(() => {});
  }

  // ── languages (50 most spoken; machine-translated from the English original) ──
  const LANGS = [
    ['en','English','English','gb'],['zh','中文','Mandarin Chinese','cn'],['hi','हिन्दी','Hindi','in'],['es','Español','Spanish','es'],['fr','Français','French','fr'],
    ['ar','العربية','Arabic','sa'],['bn','বাংলা','Bengali','bd'],['pt','Português','Portuguese','br'],['ru','Русский','Russian','ru'],['ur','اردو','Urdu','pk'],
    ['id','Bahasa Indonesia','Indonesian','id'],['de','Deutsch','German','de'],['ja','日本語','Japanese','jp'],['pcm','Naijá','Nigerian Pidgin','ng'],['mr','मराठी','Marathi','in'],
    ['te','తెలుగు','Telugu','in'],['tr','Türkçe','Turkish','tr'],['ta','தமிழ்','Tamil','in'],['yue','粵語','Cantonese','hk'],['vi','Tiếng Việt','Vietnamese','vn'],
    ['wuu','吳語','Wu Chinese','cn'],['tl','Filipino','Tagalog / Filipino','ph'],['ko','한국어','Korean','kr'],['fa','فارسی','Persian','ir'],['ha','Hausa','Hausa','ng'],
    ['sw','Kiswahili','Swahili','ke'],['jv','Basa Jawa','Javanese','id'],['it','Italiano','Italian','it'],['pa','پنجابی / ਪੰਜਾਬੀ','Punjabi','pk'],['gu','ગુજરાતી','Gujarati','in'],
    ['th','ไทย','Thai','th'],['kn','ಕನ್ನಡ','Kannada','in'],['am','አማርኛ','Amharic','et'],['bho','भोजपुरी','Bhojpuri','in'],['nan','閩南語','Min Nan (Hokkien)','tw'],
    ['yo','Yorùbá','Yoruba','ng'],['my','မြန်မာ','Burmese','mm'],['pl','Polski','Polish','pl'],['or','ଓଡ଼ିଆ','Odia','in'],['ln','Lingála','Lingala','cd'],
    ['uk','Українська','Ukrainian','ua'],['ig','Igbo','Igbo','ng'],['ml','മലയാളം','Malayalam','in'],['ms','Bahasa Melayu','Malay','my'],['nl','Nederlands','Dutch','nl'],
    ['ne','नेपाली','Nepali','np'],['si','සිංහල','Sinhala','lk'],['sd','سنڌي','Sindhi','pk'],['uz','Oʻzbekcha','Uzbek','uz'],['ro','Română','Romanian','ro'],
  ];
  const langBtn = $('#lang');
  if (langBtn) {
    const modal = document.createElement('div');
    modal.className = 'modal'; modal.id = 'lang-modal'; modal.hidden = true;
    modal.setAttribute('role', 'dialog'); modal.setAttribute('aria-modal', 'true'); modal.setAttribute('aria-labelledby', 'lang-title');
    const chrome = () => `<div class="bd" data-close></div><div class="pane">
      <div class="hd"><h2 id="lang-title">${MM.t('j.lang.title', 'Choose your language')}</h2><button class="ib sq" type="button" data-close aria-label="${MM.t('j.lang.close', 'Close')}"><svg viewBox="0 0 24 24"><path d="M6 6l12 12M18 6L6 18"/></svg></button></div>
      <div class="search"><input type="search" id="lang-q" placeholder="${MM.t('j.lang.search', 'Search 50 languages…')}" autocomplete="off" aria-label="${MM.t('j.lang.search_label', 'Search languages')}"></div>
      <p class="note">${MM.t('j.lang.note', 'Translated by machine from the English original, which stays the reference — technical terms and the terminal stay in English. Your choice is remembered on this device.')}</p>
      <ul class="lang-grid" id="lang-grid"></ul></div>`;
    modal.innerHTML = chrome();
    document.body.appendChild(modal);
    let grid = $('#lang-grid', modal), q = $('#lang-q', modal);
    let current = store.get('mm-lang') || 'en';
    const flag = (c) => `https://flagcdn.com/h24/${c}.png`;
    const setBtn = () => { const l = LANGS.find((x) => x[0] === current) || LANGS[0]; langBtn.querySelector('span').textContent = l[0].toUpperCase().slice(0, 3); };
    const render = (f = '') => {
      const t = f.trim().toLowerCase();
      const rows = LANGS.filter((l) => !t || l.join(' ').toLowerCase().includes(t));
      grid.innerHTML = rows.length ? rows.map((l) => `<li><button type="button" data-l="${l[0]}" aria-pressed="${l[0] === current}"><img alt="" loading="lazy" src="${flag(l[3])}" width="28" height="20"><span class="nm">${l[1]}<small>${l[2]}</small></span></button></li>`).join('') : `<li class="empty">${MM.t('j.lang.empty', 'No language matches that. Try the English name.')}</li>`;
    };
    let lastFocus = null;
    const open = () => { lastFocus = document.activeElement; modal.innerHTML = chrome(); grid = $('#lang-grid', modal); q = $('#lang-q', modal); q.addEventListener('input', () => render(q.value)); render(''); modal.hidden = false; document.body.classList.add('modal-open'); setTimeout(() => q.focus(), 30); };
    const close = () => { modal.hidden = true; document.body.classList.remove('modal-open'); lastFocus && lastFocus.focus(); };
    langBtn.addEventListener('click', open);
    modal.addEventListener('click', (e) => { if (e.target.closest('[data-close]')) return close(); const b = e.target.closest('button[data-l]'); if (b) { current = b.dataset.l; store.set('mm-lang', current); setBtn(); render(q.value); b.classList.add('busy'); setLang(current).then((ok) => { if (!ok) { current = 'en'; store.set('mm-lang', 'en'); setBtn(); } setTimeout(close, 120); }); } });
    document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !modal.hidden) close(); });
    setBtn();
  }
})();
