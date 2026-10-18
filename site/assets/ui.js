/* megamesh.sh — shared UI: theme, language picker, menu, reveals, hero effects. No tracking, no network except flag images. */
(() => {
  const $ = (s, r = document) => r.querySelector(s);
  const store = { get: (k) => { try { return localStorage.getItem(k); } catch { return null; } }, set: (k, v) => { try { localStorage.setItem(k, v); } catch {} } };
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;

  // ── theme ────────────────────────────────────────────────────────────────
  const root = document.documentElement;
  const themeBtn = $('#theme');
  const applyTheme = (t) => {
    if (t === 'dark') root.setAttribute('data-theme', 'dark'); else root.removeAttribute('data-theme');
    if (themeBtn) { themeBtn.setAttribute('aria-pressed', String(t === 'dark')); themeBtn.setAttribute('aria-label', t === 'dark' ? 'Switch to light mode' : 'Switch to dark mode'); }
    const m = $('meta[name="theme-color"]'); if (m) m.content = t === 'dark' ? '#141418' : '#F3F1EA';
  };
  applyTheme(store.get('mm-theme') || 'light');
  themeBtn && themeBtn.addEventListener('click', () => { const t = root.getAttribute('data-theme') === 'dark' ? 'light' : 'dark'; store.set('mm-theme', t); applyTheme(t); });

  // ── mobile menu ──────────────────────────────────────────────────────────
  const menu = $('#menu'), links = $('#links');
  if (menu && links) {
    menu.addEventListener('click', () => { const o = links.classList.toggle('open'); menu.setAttribute('aria-expanded', String(o)); });
    links.addEventListener('click', (e) => { if (e.target.tagName === 'A') { links.classList.remove('open'); menu.setAttribute('aria-expanded', 'false'); } });
  }

  // ── logo: ping on click, draw on hover (CSS) ─────────────────────────────
  const brand = $('#brand');
  if (brand) brand.addEventListener('click', (e) => {
    brand.classList.remove('ping'); void brand.offsetWidth; brand.classList.add('ping');
    if (location.pathname === '/' || location.pathname === '/index.html') { e.preventDefault(); window.scrollTo({ top: 0, behavior: reduced ? 'auto' : 'smooth' }); }
  });

  // ── languages (50 most spoken; the site is English for now) ──────────────
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
    modal.innerHTML = `<div class="bd" data-close></div><div class="pane">
      <div class="hd"><h2 id="lang-title">Choose your language</h2><button class="ibtn x" type="button" data-close aria-label="Close"><svg viewBox="0 0 24 24"><path d="M6 6l12 12M18 6L6 18"/></svg></button></div>
      <div class="search"><input type="search" id="lang-q" placeholder="Search 50 languages…" autocomplete="off" aria-label="Search languages"></div>
      <p class="note">The site reads in English for now. Your choice is remembered on this device; translations will follow it.</p>
      <ul class="lang-grid" id="lang-grid"></ul></div>`;
    document.body.appendChild(modal);
    const grid = $('#lang-grid', modal), q = $('#lang-q', modal);
    let current = store.get('mm-lang') || 'en';
    const flag = (c) => `https://flagcdn.com/h24/${c}.png`;
    const setBtn = () => { const l = LANGS.find((x) => x[0] === current) || LANGS[0]; langBtn.innerHTML = `<img alt="" src="${flag(l[3])}" width="18" height="13"><span>${l[0].toUpperCase().slice(0, 3)}</span>`; };
    const render = (f = '') => {
      const t = f.trim().toLowerCase();
      const rows = LANGS.filter((l) => !t || l.join(' ').toLowerCase().includes(t));
      grid.innerHTML = rows.length ? rows.map((l) => `<li><button type="button" data-l="${l[0]}" aria-pressed="${l[0] === current}"><img alt="" loading="lazy" src="${flag(l[3])}" width="28" height="20"><span class="nm">${l[1]}<small>${l[2]}</small></span></button></li>`).join('') : '<li class="empty">No language matches that. Try the English name.</li>';
    };
    let lastFocus = null;
    const open = () => { lastFocus = document.activeElement; render(''); q.value = ''; modal.hidden = false; document.body.classList.add('modal-open'); setTimeout(() => q.focus(), 30); };
    const close = () => { modal.hidden = true; document.body.classList.remove('modal-open'); lastFocus && lastFocus.focus(); };
    langBtn.addEventListener('click', open);
    modal.addEventListener('click', (e) => { if (e.target.closest('[data-close]')) close(); const b = e.target.closest('button[data-l]'); if (b) { current = b.dataset.l; store.set('mm-lang', current); setBtn(); render(q.value); setTimeout(close, 160); } });
    q.addEventListener('input', () => render(q.value));
    document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !modal.hidden) close(); });
    setBtn();
  }

  // ── reveals: sections + engravings "materialise" ─────────────────────────
  const io = new IntersectionObserver((es) => es.forEach((en) => { if (en.isIntersecting) { en.target.classList.add('in'); io.unobserve(en.target); } }), { rootMargin: '0px 0px -8% 0px', threshold: 0.08 });
  document.querySelectorAll('.reveal, .art').forEach((el) => io.observe(el));

  // ── hero typewriter ──────────────────────────────────────────────────────
  const type = $('#type');
  if (type) {
    const line = type.getAttribute('aria-label') || '';
    const cur = type.querySelector('.cur');
    if (reduced) type.insertBefore(document.createTextNode(line), cur);
    else { let i = 0; const node = document.createTextNode(''); type.insertBefore(node, cur); const tick = () => { node.data = line.slice(0, ++i); if (i < line.length) setTimeout(tick, line[i - 1] === '.' ? 320 : 28 + Math.random() * 40); }; setTimeout(tick, 500); }
  }

  // ── hero hands: gentle parallax to the pointer ───────────────────────────
  const hands = $('#hands img');
  if (hands && !reduced && matchMedia('(pointer:fine)').matches) {
    document.addEventListener('mousemove', (e) => { const x = (e.clientX / innerWidth - .5) * 10, y = (e.clientY / innerHeight - .5) * 6; hands.style.transform = `translate(${x}px,${y}px)`; }, { passive: true });
  }

  // ── pointer glow on cards ────────────────────────────────────────────────
  document.querySelectorAll('.pill').forEach((c) => c.addEventListener('pointermove', (e) => { const r = c.getBoundingClientRect(); c.style.setProperty('--mx', (e.clientX - r.left) + 'px'); c.style.setProperty('--my', (e.clientY - r.top) + 'px'); }));

  // ── count-up ─────────────────────────────────────────────────────────────
  document.querySelectorAll('[data-count]').forEach((el) => {
    const end = +el.dataset.count; const fmt = (n) => n.toLocaleString('en-US');
    if (reduced) { el.textContent = fmt(end); return; }
    const o = new IntersectionObserver((es) => { if (!es[0].isIntersecting) return; o.disconnect(); const t0 = performance.now(); const d = 1800;
      const step = (t) => { const p = Math.min(1, (t - t0) / d); el.textContent = fmt(Math.round(end * (1 - Math.pow(1 - p, 3)))); if (p < 1) requestAnimationFrame(step); }; requestAnimationFrame(step); }, { threshold: .5 });
    o.observe(el);
  });
})();
