/* megamesh.sh — "View demo": a scripted, fake walk-through of the deployer. Nothing here talks to a server. */
(() => {
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const t = (k, fb) => (window.MM && window.MM.t) ? window.MM.t(k, fb) : fb;
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const CANCEL = { cancelled: true };

  // ── fake data (RFC 5737 documentation address; example.com domain) ─────────
  const F = { ip: '203.0.113.10', port: '22', pw: 'demo-current-root', newpw: 'demo-new-root-pw-9', domain: 'vpn.example.com', email: 'you@example.com', admin: 'admin', adminpw: 'DEMO-not-real-4f9QxL2mPz8vK1tN' };

  // real lines from a real run (Rocky Linux 9.5, 1 vCPU / 700 MB), condensed. [phase, class, text, tick-checklist-index|-1, pause-after-ms]
  const LOG = [
    [0, 'step', 'Connecting to root@203.0.113.10:22 over SSH', -1, 500],
    [0, 'ok', 'Logged in. Root password changed to the one you chose.', -1, 600],
    [0, 'step', 'Detected Rocky Linux 9.5 (Blue Onyx) (el)', -1, 500],
    [0, 'step', 'RAM is 699 MB with no swap - creating 1024 MB swap (package updates OOM on small VPS otherwise)', -1, 500],
    [0, 'ok', 'Swap active', 0, 500],
    [1, 'step', 'dnf update (this is the slow part on 1 vCPU)', -1, 2600],
    [1, 'ok', 'Packages present', 1, 400],
    [1, 'step', 'Installing Docker CE from download.docker.com (signed repository)', -1, 1400],
    [1, 'ok', 'Docker CE installed', 2, 400],
    [2, 'step', 'Kernel modules', -1, 300],
    [2, 'ok', 'Modules loaded and persisted - the container does not need SYS_MODULE', -1, 300],
    [2, 'ok', 'sysctl applied', -1, 300],
    [2, 'step', 'firewalld public zone', -1, 400],
    [2, 'ok', 'Public zone (eth0): DROP everything except tcp/22, udp/51820, tcp/443', 3, 500],
    [2, 'step', 'SSH hardening', -1, 400],
    [2, 'ok', 'sshd restarted - keep this session open and test a NEW login before you log out', -1, 300],
    [2, 'ok', 'fail2ban sshd jail active', 4, 500],
    [3, 'step', 'Writing /opt/megamesh/compose.yml, Caddyfile, wg-easy.env', -1, 700],
    [3, 'ok', "Admin account 'admin' created unattended", -1, 400],
    [3, 'ok', 'Containers up', 5, 900],
    [3, 'ok', 'Certificate issued by Let\'s Encrypt for vpn.example.com (TLS-ALPN, port 80 stays closed)', 6, 500],
    [3, 'step', 'Installing topgrade 17.13.1 (pinned, checksum-verified)', -1, 600],
    [3, 'ok', 'megamesh-upgrade timer: weekly, with rollback', 7, 500],
    [4, 'step', 'Verification', -1, 500],
    [4, 'ok', 'wg0 is up inside wg-easy', -1, 400],
    [4, 'ok', 'wg-easy UI answers internally and the admin account exists (login page)', -1, 500],
    [4, 'ok', 'megamesh is installed.', -1, 400],
  ];

  let root = null, cur = 0, run = 0, paused = false, speed = 1, waiters = [], lastFocus = null, doneState = false;

  const sleep = async (ms, id) => {
    let left = ms / speed;
    while (left > 0) {
      if (id !== run) throw CANCEL;
      if (paused) { await new Promise((r) => waiters.push(r)); continue; }
      const d = Math.min(left, 40); await new Promise((r) => setTimeout(r, d)); left -= d;
    }
    if (id !== run) throw CANCEL;
  };
  const setPaused = (p) => { paused = p; if (!p) { const w = waiters; waiters = []; w.forEach((r) => r()); } syncCtl(); };

  const $ = (s, el = root) => el && el.querySelector(s);

  // ── chrome ────────────────────────────────────────────────────────────────
  const STEPS = () => [t('j.demo.s1', 'Server'), t('j.demo.s2', 'Check'), t('j.demo.s3', 'Install'), t('j.demo.s4', 'Hand over')];
  const CHECK = () => [
    t('j.demo.c0', 'Swap added so updates do not run out of memory'),
    t('j.demo.c1', 'System packages updated'),
    t('j.demo.c2', 'Docker installed from the signed official repository'),
    t('j.demo.c3', 'Firewall: everything dropped except SSH, HTTPS and WireGuard'),
    t('j.demo.c4', 'SSH hardened, brute-force bans on'),
    t('j.demo.c5', 'WireGuard and its web admin running'),
    t('j.demo.c6', 'HTTPS certificate issued for your domain'),
    t('j.demo.c7', 'Weekly upgrades with automatic rollback'),
  ];
  const SAY = () => [
    [t('j.demo.say1.t', 'You give four things'), t('j.demo.say1.p', 'The server IP, its current root password, a domain you control and your email. You also choose the new root password it will switch to. Everything shown here is invented: a documentation IP, a made-up password, no real server.')],
    [t('j.demo.say2.t', 'It looks before it touches'), t('j.demo.say2.p', 'The deployer logs in once, reads the server and shows its plan. Nothing changes until you tick the box and press install.')],
    [t('j.demo.say3.t', 'Then it works, in the open'), t('j.demo.say3.p', 'The log is the real install script talking, line by line. On a small server the system update alone takes most of the 10 to 30 minutes, so this is a time-lapse. Each result ticks off on the right.')],
    [t('j.demo.say4.t', 'You get the keys, once'), t('j.demo.say4.p', 'The admin login appears here and nowhere else. Point your domain at the server, open the admin page and add your first device. The root password is the one you chose, the deployer keeps nothing.')],
  ];

  const build = () => {
    const names = STEPS(), chk = CHECK();
    root.innerHTML = `
      <div class="dm-top">
        <div class="dm-id"><span class="dm-pill">${esc(t('j.demo.pill', 'Demo'))}</span><span class="dm-fake">${esc(t('j.demo.fake', 'Fake IP, fake password. Nothing is sent anywhere.'))}</span></div>
        <ol class="dm-steps" role="tablist">${names.map((n, i) => `<li><button type="button" role="tab" data-go="${i}" aria-selected="${i === cur}"><b>${i + 1}</b><span>${esc(n)}</span></button></li>`).join('')}</ol>
        <div class="dm-ctl">
          <button type="button" class="dm-b" data-act="pause" aria-label="${esc(t('j.demo.pause', 'Pause'))}"></button>
          <button type="button" class="dm-b dm-b--txt" data-act="speed" aria-label="${esc(t('j.demo.speed', 'Speed'))}">1×</button>
          <button type="button" class="dm-b" data-act="restart" aria-label="${esc(t('j.demo.restart', 'Restart'))}"><svg viewBox="0 0 24 24"><path d="M4 12a8 8 0 1 0 2.5-5.8M4 4v4.5h4.5"/></svg></button>
          <button type="button" class="dm-b" data-act="close" aria-label="${esc(t('j.lang.close', 'Close'))}"><svg viewBox="0 0 24 24"><path d="M6 6l12 12M18 6L6 18"/></svg></button>
        </div>
      </div>
      <div class="dm-bar"><i id="dm-prog"></i></div>
      <div class="dm-body">
        <aside class="dm-say" aria-live="polite"><div class="dm-eyebrow" id="dm-eyebrow"></div><h2 id="dm-sayt"></h2><p id="dm-sayp"></p><div class="dm-end" id="dm-end" hidden>
          <a class="btn btn--solid" href="/deploy/" id="dm-deploy">${esc(t('j.demo.deploy', 'Deploy mine'))}<svg viewBox="0 0 24 24"><path d="M5 12h14M13 6l6 6-6 6"/></svg></a>
          <button type="button" class="btn btn--ghost" data-act="restart">${esc(t('j.demo.replay', 'Replay'))}</button></div></aside>
        <main class="dm-stage" id="dm-stage"></main>
        <aside class="dm-chk"><div class="dm-eyebrow">${esc(t('j.demo.chk', 'What ends up on your server'))}</div><ul id="dm-chk">${chk.map((c, i) => `<li data-i="${i}"><i></i><span>${esc(c)}</span></li>`).join('')}</ul></aside>
      </div>`;
    syncCtl();
  };
  const syncCtl = () => {
    if (!root) return;
    const pb = $('[data-act=pause]'); if (pb) { pb.innerHTML = paused ? '<svg viewBox="0 0 24 24"><path d="M7 5l12 7-12 7z"/></svg>' : '<svg viewBox="0 0 24 24"><path d="M8 5v14M16 5v14"/></svg>'; pb.setAttribute('aria-label', paused ? t('j.demo.play', 'Play') : t('j.demo.pause', 'Pause')); }
    const sb = $('[data-act=speed]'); if (sb) sb.textContent = speed + '×';
  };
  const setStep = (n) => {
    cur = n;
    root.querySelectorAll('.dm-steps button').forEach((b, i) => { b.setAttribute('aria-selected', String(i === n)); b.parentElement.className = i < n ? 'done' : i === n ? 'on' : ''; });
    $('#dm-prog').style.width = ((n + 1) / 4 * 100) + '%';
    const [tt, pp] = SAY()[n];
    $('#dm-eyebrow').textContent = t('j.demo.stepof', 'Step {n} of 4').replace('{n}', n + 1);
    $('#dm-sayt').textContent = tt; $('#dm-sayp').textContent = pp;
    $('#dm-end').hidden = n !== 3;
  };
  const tick = (i, on = true) => { const li = $('#dm-chk li[data-i="' + i + '"]'); if (li) li.classList.toggle('ok', on); };
  const tickAll = (upto) => { for (let i = 0; i < 8; i++) tick(i, i <= upto); };

  // ── helpers for the scenes ───────────────────────────────────────────────
  const typeInto = async (el, text, id, mask) => {
    el.textContent = '';
    if (reduced) { el.textContent = mask ? '•'.repeat(text.length) : text; return; }
    for (let i = 1; i <= text.length; i++) { el.textContent = mask ? '•'.repeat(i) : text.slice(0, i); await sleep(34 + Math.random() * 40, id); }
  };
  const field = (cls, label, hint) => `<div class="dm-f ${cls}"><label>${esc(label)}${hint ? ` <small>${esc(hint)}</small>` : ''}</label><div class="dm-in"><span class="v"></span><i class="caret"></i></div></div>`;
  const setFocus = (el) => { root.querySelectorAll('.dm-in.on').forEach((e) => e.classList.remove('on')); if (el) el.classList.add('on'); };

  // ── scenes ───────────────────────────────────────────────────────────────
  const scene = [
    async (id, anim) => {
      const st = $('#dm-stage'); st.innerHTML = `<section class="dm-panel"><h3>${esc(t('j.demo.f.title', 'Your server'))}</h3>
        <div class="dm-row">${field('ip', t('j.demo.f.ip', 'Server IP'))}${field('port', t('j.demo.f.port', 'SSH port'))}</div>
        ${field('pw', t('j.demo.f.pw', 'Current root password'), t('j.demo.f.pwh', 'from your provider'))}
        ${field('npw', t('j.demo.f.npw', 'New root password'), t('j.demo.f.npwh', 'the one it will switch to'))}
        <div class="dm-row">${field('dom', t('j.demo.f.dom', 'Domain for the VPN'))}${field('em', t('j.demo.f.em', 'Your email'), t('j.demo.f.emh', 'certificate notices only'))}</div>
        <div class="dm-act"><span class="dm-btn" id="dm-b1">${esc(t('j.demo.f.go', 'Check the server'))} →</span></div></section>`;
      const seq = [['ip', F.ip, 0], ['port', F.port, 0], ['pw', F.pw, 1], ['npw', F.newpw, 1], ['dom', F.domain, 0], ['em', F.email, 0]];
      for (const [k, v, mask] of seq) {
        const box = $('.dm-f.' + k + ' .dm-in'), sp = box.querySelector('.v');
        if (anim) { setFocus(box); await sleep(250, id); await typeInto(sp, v, id, mask); await sleep(180, id); }
        else sp.textContent = mask ? '•'.repeat(v.length) : v;
      }
      setFocus(null);
      if (anim) { await sleep(500, id); $('#dm-b1').classList.add('press'); await sleep(700, id); }
    },
    async (id, anim) => {
      const st = $('#dm-stage'); st.innerHTML = `<section class="dm-panel"><h3>${esc(t('j.demo.k.title', 'Server check'))}</h3>
        <div class="dm-kv">
          <span>${esc(t('j.demo.k.os', 'System'))}</span><b>Rocky Linux 9.5 (Blue Onyx)</b>
          <span>${esc(t('j.demo.k.ram', 'Memory'))}</span><b>699 MB · ${esc(t('j.demo.k.noswap', 'no swap'))}</b>
          <span>${esc(t('j.demo.k.docker', 'Docker'))}</span><b>${esc(t('j.demo.k.notyet', 'not installed'))}</b>
          <span>SSH</span><b>${F.ip}:${F.port}</b>
          <span>${esc(t('j.demo.k.dns', 'Domain'))}</span><b>${F.domain}</b></div>
        <div class="dm-plan">
          <div><b>${esc(t('j.demo.p1', 'Firewall'))}</b>${esc(t('j.demo.p1t', 'Public zone set to DROP. Only 22/tcp, 443/tcp and 51820/udp stay open.'))}</div>
          <div><b>SSH</b>${esc(t('j.demo.p2t', 'Root password switched to yours. Brute-force bans on. Password login stays until you lock it yourself.'))}</div>
          <div><b>${esc(t('j.demo.p3', 'Containers'))}</b>${esc(t('j.demo.p3t', 'WireGuard with its web admin, and Caddy for HTTPS, from pinned images.'))}</div>
          <div><b>${esc(t('j.demo.p4', 'Updates'))}</b>${esc(t('j.demo.p4t', 'A weekly upgrade timer that rolls back by itself if something breaks.'))}</div></div>
        <label class="dm-agree"><span class="bx" id="dm-bx"></span><span>${esc(t('j.demo.agree', 'I understand the install takes 10 to 30 minutes and my root password is not stored.'))}</span></label>
        <div class="dm-act"><span class="dm-btn dm-btn--acc" id="dm-b2">${esc(t('j.demo.k.go', 'Install Megamesh'))} →</span></div></section>`;
      if (anim) {
        const rows = [...st.querySelectorAll('.dm-kv > *, .dm-plan > div')]; rows.forEach((r) => r.classList.add('hid'));
        for (const r of rows) { r.classList.remove('hid'); r.classList.add('in'); await sleep(110, id); }
        await sleep(700, id); $('#dm-bx').classList.add('on'); await sleep(600, id); $('#dm-b2').classList.add('press'); await sleep(700, id);
      } else $('#dm-bx').classList.add('on');
    },
    async (id, anim) => {
      const st = $('#dm-stage'); st.innerHTML = `<section class="dm-panel"><h3><span class="dm-spin" id="dm-spin"></span>${esc(t('j.demo.i.title', 'Installing'))}</h3>
        <div class="dm-phases">${[t('j.demo.ph0', 'Connect'), t('j.demo.ph1', 'Update'), t('j.demo.ph2', 'Harden'), t('j.demo.ph3', 'Containers'), t('j.demo.ph4', 'Verify')].map((p, i) => `<div data-p="${i}">${esc(p)}</div>`).join('')}</div>
        <div class="dm-log" id="dm-log" aria-hidden="true"></div>
        <div class="dm-meta"><span>${esc(t('j.demo.i.lapse', 'Time-lapse'))}</span><span id="dm-clock">00:00</span></div></section>`;
      const log = $('#dm-log'), total = LOG.length;
      const setP = (n) => st.querySelectorAll('.dm-phases div').forEach((d, i) => { d.className = i < n ? 'done' : i === n ? 'on' : ''; });
      const clock = (f) => { const s = Math.round(f * 1620); $('#dm-clock').textContent = String(Math.floor(s / 60)).padStart(2, '0') + ':' + String(s % 60).padStart(2, '0'); };
      for (let i = 0; i < total; i++) {
        const [ph, cl, tx, tk, wait] = LOG[i];
        setP(ph); const d = document.createElement('div'); d.className = cl + ' new'; d.textContent = (cl === 'ok' ? '✔ ' : '▶ ') + tx; log.appendChild(d); log.scrollTop = log.scrollHeight;
        if (tk >= 0) tick(tk); clock((i + 1) / total);
        if (anim) await sleep(wait, id);
      }
      setP(5); tickAll(7); $('#dm-spin').classList.add('stop');
      if (anim) await sleep(900, id);
    },
    async (id, anim) => {
      const st = $('#dm-stage'); tickAll(7);
      st.innerHTML = `<section class="dm-panel"><h3>${esc(t('j.demo.h.title', 'Your VPN is ready'))}</h3>
        <div class="dm-kv dm-kv--cred">
          <span>${esc(t('j.demo.h.url', 'Admin page'))}</span><b>https://${F.domain}/</b>
          <span>${esc(t('j.demo.h.user', 'Username'))}</span><b>${F.admin}</b>
          <span>${esc(t('j.demo.h.pw', 'Password'))}</span><b>${F.adminpw}</b>
          <span>${esc(t('j.demo.h.root', 'Root password'))}</span><b>${esc(t('j.demo.h.rootv', 'the one you chose'))}</b></div>
        <ol class="dm-next">
          <li><b>${esc(t('j.demo.n1', 'Point your domain at the server.'))}</b> ${esc(t('j.demo.n1t', 'At your DNS provider, create an A record:'))} <code>${F.domain}</code> → <code>${F.ip}</code></li>
          <li><b>${esc(t('j.demo.n2', 'Log in.'))}</b> ${esc(t('j.demo.n2t', 'Open the admin page and sign in with the login above. Save it in your password manager.'))}</li>
          <li><b>${esc(t('j.demo.n3', 'Add a device.'))}</b> ${esc(t('j.demo.n3t', 'Create a client, scan the QR code with the WireGuard app, and you are on your own exit.'))}</li></ol>
        <div class="dm-note">${esc(t('j.demo.h.note', 'A copy of the admin login sits on the server until you delete it. One button on the real page does that.'))}</div></section>`;
      if (anim) { const items = [...st.querySelectorAll('.dm-kv > *, .dm-next li, .dm-note')]; items.forEach((r) => r.classList.add('hid')); for (const r of items) { r.classList.remove('hid'); r.classList.add('in'); await sleep(140, id); } }
    },
  ];

  const play = async (from) => {
    const id = ++run; doneState = false;
    if (reduced) { setStep(from); if (from < 2) tickAll(-1); await scene[from](id, false); return; }
    try {
      for (let n = from; n < 4; n++) {
        setStep(n); if (n < 2) tickAll(-1);
        await scene[n](id, !reduced);
        if (n === 3) break;
        await sleep(reduced ? 0 : 500, id);
      }
      doneState = true;
    } catch (e) { if (e !== CANCEL) throw e; }
  };
  const jump = (n) => { run++; setPaused(false); setStep(n); tickAll(-1); scene[n](run, false); };
  const jumpAnim = (n) => { setPaused(false); play(n); };

  // ── open / close ─────────────────────────────────────────────────────────
  const open = () => {
    if (root) return;
    lastFocus = document.activeElement;
    root = document.createElement('div'); root.className = 'demo'; root.setAttribute('role', 'dialog'); root.setAttribute('aria-modal', 'true'); root.setAttribute('aria-label', t('j.demo.aria', 'Deployer demo'));
    document.body.appendChild(root); document.body.classList.add('modal-open');
    cur = 0; paused = false; build(); play(0);
    const c = $('[data-act=close]'); c && c.focus();
  };
  const close = () => {
    if (!root) return;
    run++; setPaused(false); root.remove(); root = null; document.body.classList.remove('modal-open');
    if (location.hash === '#demo') history.replaceState(null, '', location.pathname + location.search);
    lastFocus && lastFocus.focus && lastFocus.focus();
  };

  document.addEventListener('click', (e) => {
    const trig = e.target.closest('[data-demo]'); if (trig) { e.preventDefault(); open(); return; }
    if (!root || !root.contains(e.target)) return;
    const go = e.target.closest('[data-go]'); if (go) { const n = +go.dataset.go; reduced ? jump(n) : jumpAnim(n); return; }
    const a = e.target.closest('[data-act]'); if (a) {
      const k = a.dataset.act;
      if (k === 'close') close();
      else if (k === 'pause') setPaused(!paused);
      else if (k === 'speed') { speed = speed === 1 ? 2 : speed === 2 ? 4 : 1; syncCtl(); }
      else if (k === 'restart') { tickAll(-1); reduced ? jump(0) : jumpAnim(0); }
      return;
    }
    if (e.target.closest('#dm-deploy')) {
      const ip = document.getElementById('ip');
      if (ip) { e.preventDefault(); close(); ip.focus(); ip.scrollIntoView({ block: 'center', behavior: reduced ? 'auto' : 'smooth' }); }
    }
  });
  document.addEventListener('keydown', (e) => {
    if (!root) return;
    if (e.key === 'Escape') { close(); return; }
    if (e.key === ' ' && !e.target.closest('button,a')) { e.preventDefault(); setPaused(!paused); return; }
    if (e.key === 'Tab') {
      const f = [...root.querySelectorAll('button,a[href]')].filter((x) => !x.closest('[hidden]')); if (!f.length) return;
      const first = f[0], last = f[f.length - 1];
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    }
  });
  // language switch while open: rebuild the chrome and show the current scene
  document.addEventListener('mm:lang', () => { if (!root) return; const n = cur; run++; build(); jump(n); });

  // deep links: /deploy/?demo or #demo
  const want = () => /(^|[?&])demo(=|&|$)/.test(location.search) || location.hash === '#demo';
  const auto = () => { if (want()) setTimeout(open, 400); };
  if (document.readyState === 'complete') auto(); else addEventListener('load', auto);
})();
