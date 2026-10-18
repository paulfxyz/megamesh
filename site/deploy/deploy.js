/* megamesh.sh — the Operator, browser side. Credentials live in this tab only. */
(() => {
  const $ = (id) => document.getElementById(id);
  const creds = {};           // ip, port, pw, domain, email, pubkey — never persisted
  let newpw = '';             // the root password chosen by the user; becomes creds.pw once applied
  let pollTimer = null, startedAt = 0, elapsedTimer = null, failures = 0;
  const ss = { get: (k) => { try { return sessionStorage.getItem(k); } catch { return null; } }, set: (k, v) => { try { sessionStorage.setItem(k, v); } catch {} } };

  // non-secret fields survive a reload within the tab
  ['ip', 'port', 'domain', 'email'].forEach((k) => { const v = ss.get('mm-' + k); if (v && $(k)) $(k).value = v; $(k).addEventListener('change', () => ss.set('mm-' + k, $(k).value)); });

  const step = (n) => {
    for (let i = 1; i <= 4; i++) { const el = $('s' + i); el.className = i < n ? 'done' : i === n ? 'on' : ''; }
    ['p-form', 'p-check', 'p-run', 'p-done'].forEach((id, i) => { $(id).hidden = (i + 1) !== n; });
    window.scrollTo({ top: $('s1').getBoundingClientRect().top + window.scrollY - 90, behavior: 'smooth' });
  };

  const api = async (action, extra = {}) => {
    const res = await fetch('/api/deploy.php', { method: 'POST', headers: { 'Content-Type': 'application/json' }, cache: 'no-store', body: JSON.stringify({ action, ...creds, ...extra }) });
    let data; try { data = await res.json(); } catch { throw new Error('The Operator returned something unexpected (HTTP ' + res.status + ').'); }
    if (!res.ok || !data.ok) throw new Error(data && data.error ? data.error : 'Request failed (HTTP ' + res.status + ').');
    return data;
  };

  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const kv = (el, pairs) => { el.innerHTML = pairs.map(([k, v, copy]) => `<span>${esc(k)}</span><b>${esc(v)}</b>${copy ? `<button type="button" class="cp" data-copy="${esc(v)}">Copy</button>` : '<i class="none"></i>'}`).join(''); };
  document.addEventListener('click', async (e) => {
    const b = e.target.closest('[data-copy]'); if (!b) return;
    try { await navigator.clipboard.writeText(b.dataset.copy); b.textContent = 'Copied'; b.classList.add('did'); setTimeout(() => { b.textContent = 'Copy'; b.classList.remove('did'); }, 1600); } catch { b.textContent = 'Select it'; }
  });

  // password eyes + generator
  document.querySelectorAll('[data-eye]').forEach((b) => b.addEventListener('click', () => { const i = $(b.dataset.eye); i.type = i.type === 'password' ? 'text' : 'password'; b.setAttribute('aria-label', i.type === 'password' ? 'Show password' : 'Hide password'); }));
  $('gen').addEventListener('click', () => {
    const chars = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789-_.!%+';
    const a = new Uint32Array(24); crypto.getRandomValues(a);
    $('newpw').value = Array.from(a, (n) => chars[n % chars.length]).join(''); $('newpw').type = 'text'; $('newpw').focus();
  });

  // per-field validation
  const RULES = {
    ip: [(v) => /^(\d{1,3}\.)\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(v) && v.split('.').every((n) => +n <= 255), 'Enter the server\'s public IPv4 address.'],
    port: [(v) => /^\d+$/.test(v) && +v >= 1 && +v <= 65535, 'SSH port must be 1–65535.'],
    pw: [(v) => v.length > 0 && v.length <= 256, 'The current root password is required.'],
    newpw: [(v) => v === '' || /^[\x21-\x7E]{12,128}$/.test(v), '12–128 printable characters, no spaces.'],
    domain: [(v) => /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/.test(v) && v.length <= 253, 'Enter a full domain name, like vpn.example.com.'],
    email: [(v) => /^[^\s@]+@[^\s@]+\.[a-z]{2,}$/i.test(v), 'Enter a valid email address.'],
    pubkey: [(v) => v === '' || /^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/=]+( [^\s'"]{0,120})?$/.test(v), 'One line, starting with ssh-ed25519 or ssh-rsa.'],
  };
  const val = (id) => { const el = $(id); const v = id === 'pw' || id === 'newpw' ? el.value : el.value.trim(); const [ok, msg] = RULES[id]; const bad = !ok(id === 'domain' ? v.toLowerCase() : v); el.classList.toggle('bad', bad); $('h-' + id + '-err').textContent = bad ? msg : ''; return !bad; };
  Object.keys(RULES).forEach((id) => $(id).addEventListener('blur', () => val(id)));

  // ── step 1 → check ───────────────────────────────────────────────────────
  $('f').addEventListener('submit', async (e) => {
    e.preventDefault();
    const err = $('f-err'); err.textContent = '';
    const okAll = Object.keys(RULES).map(val).every(Boolean);
    if (!okAll) { err.textContent = 'Fix the highlighted fields.'; return; }
    creds.ip = $('ip').value.trim(); creds.port = ($('port').value.trim() || '22'); creds.pw = $('pw').value;
    creds.domain = $('domain').value.trim().toLowerCase(); creds.email = $('email').value.trim(); creds.pubkey = $('pubkey').value.trim();
    newpw = $('newpw').value;
    if (newpw && newpw === creds.pw) newpw = '';
    const go = $('go'); go.disabled = true; go.innerHTML = '<span class="spin"></span>Connecting…';
    try {
      const r = await api('check');
      kv($('check-out'), [
        ['OS', r.os + (r.supported ? '' : '  — not supported')],
        ['Architecture', r.arch],
        ['RAM / CPU', `${r.mem_mb} MB / ${r.cpus} vCPU`],
        ['Docker', r.docker ? 'present' : 'will be installed'],
        ['Megamesh', r.installed ? 'already installed — running again is safe' : 'not installed'],
        ['Root password', newpw ? 'will be changed to yours' : 'kept as it is'],
      ]);
      $('plan').innerHTML = [
        ['Domain', creds.domain + ' → ' + creds.ip], ['Certificate email', creds.email],
        ['SSH', creds.pubkey ? 'your key is installed; password login stays on until you turn it off' : 'password login stays on (no key given)'],
        ['Time', r.installed ? 'a few minutes (re-run)' : '10–30 minutes on 1 vCPU'],
      ].map(([k, v]) => `<div><b>${esc(k)}</b>${esc(v)}</div>`).join('');
      const note = $('check-note'); const start = $('start');
      if (!r.supported) { note.hidden = false; note.innerHTML = '<b>Unsupported system.</b> The installer knows CentOS Stream / Rocky / Alma 9 and Debian / Ubuntu on x86_64. Reinstall the VPS with CentOS Stream 9 from your provider\'s panel and try again.'; start.dataset.blocked = '1'; }
      else if (r.running) { note.hidden = false; note.innerHTML = '<b>An install is already running</b> on this server. Loading will attach to it rather than start another.'; delete start.dataset.blocked; }
      else if (!r.verified) { note.hidden = false; note.innerHTML = '<b>Best-effort system.</b> Only CentOS Stream 9 has been verified end to end; this one takes a code path that has not been run yet. It will probably work — if it fails, the log will say where.'; delete start.dataset.blocked; }
      else if (r.mem_mb < 900) { note.hidden = false; note.innerHTML = '<b>Small box.</b> Under 1 GB visible RAM; the installer adds swap before updating, which is exactly the case it was built for.'; delete start.dataset.blocked; }
      else { note.hidden = true; delete start.dataset.blocked; }
      $('agree').checked = false; start.disabled = true;
      step(2);
    } catch (ex) { err.textContent = ex.message; }
    finally { go.disabled = false; go.textContent = 'Check the server →'; }
  });
  $('agree').addEventListener('change', () => { $('start').disabled = !$('agree').checked || !!$('start').dataset.blocked; });
  $('back1').addEventListener('click', () => step(1));

  // ── step 2 → (passwd) → start → poll ─────────────────────────────────────
  const PH = [/Installer started|Downloading/, /Updating packages|Upgraded|Installed|Complete!|Installing (packages|Docker)/, /firewall|sshd|fail2ban|sysctl|swap/i, /Pulling|Pulled|Container |compose|wg-easy|caddy/i, /health|verify|Admin|credentials|MEGAMESH_EXIT|✔ Done|Status:/i];
  let phase = 0;
  const setPhase = (n) => { phase = Math.max(phase, n); for (let i = 0; i < 5; i++) $('ph' + i).className = i < phase ? 'done' : i === phase ? 'on' : ''; };
  let seen = 0;
  const renderLog = (lines) => {
    const html = lines.map((l, i) => {
      const c = l.startsWith('✔') ? 'ok' : l.startsWith('▶') ? 'step' : l.startsWith('⚠') ? 'warn' : l.startsWith('✖') ? 'bad' : '';
      const fresh = i >= seen ? ' new' : '';
      return `<span class="${c}${fresh}">${esc(l)}</span>`;
    }).join('\n');
    seen = lines.length;
    for (let p = PH.length - 1; p >= 0; p--) { if (lines.slice(-12).some((l) => PH[p].test(l))) { setPhase(p); break; } }
    const log = $('log'); const stick = log.scrollTop + log.clientHeight >= log.scrollHeight - 20;
    log.innerHTML = html || 'Starting…'; if (stick) log.scrollTop = log.scrollHeight;
  };
  const tickElapsed = () => { const s = Math.floor((Date.now() - startedAt) / 1000); $('elapsed').textContent = String(Math.floor(s / 60)).padStart(2, '0') + ':' + String(s % 60).padStart(2, '0'); };

  const poll = async () => {
    try {
      const r = await api('status'); failures = 0; $('run-err').textContent = ''; $('resume').hidden = true;
      renderLog(r.lines);
      if (r.done) {
        clearInterval(pollTimer); pollTimer = null; clearInterval(elapsedTimer);
        if (r.exit === 0) { setPhase(5); await handover(); }
        else { $('spin').style.display = 'none'; $('loading').textContent = 'Stopped'; $('run-title').textContent = 'The install stopped with an error.'; $('run-hint').textContent = 'The last lines above say where. Fix the cause (or reinstall the VPS) and run the Operator again — the installer is idempotent.'; }
      }
    } catch (ex) {
      failures++;
      $('run-err').textContent = 'Lost contact with the server: ' + ex.message + (failures < 6 ? ' — retrying.' : ' — paused after several failures.');
      if (failures >= 6) { clearInterval(pollTimer); pollTimer = null; $('resume').hidden = false; }
    }
  };
  const startPolling = () => { if (pollTimer) clearInterval(pollTimer); failures = 0; pollTimer = setInterval(poll, 8000); };
  $('resume').addEventListener('click', () => { $('resume').hidden = true; poll(); startPolling(); });

  $('start').addEventListener('click', async () => {
    const b = $('start'); b.disabled = true; $('check-err').textContent = '';
    try {
      if (newpw) {
        b.innerHTML = '<span class="spin"></span>Changing root password…';
        await api('passwd', { newpw });
        creds.pw = newpw;     // every call from here on uses the new one — the next call proves it took
      }
      b.innerHTML = '<span class="spin"></span>Starting…';
      await api('start');
      startedAt = Date.now(); tickElapsed(); elapsedTimer = setInterval(tickElapsed, 1000);
      step(3); setPhase(0);
      renderLog(['▶ Operator connected. ' + (newpw ? 'Root password changed. ' : '') + 'Installer started on your server — downloading the release and updating packages…']);
      startPolling();
    } catch (ex) {
      $('check-err').textContent = ex.message + (creds.pw === newpw && newpw ? ' (Note: the root password HAS been changed to the new one you chose.)' : '');
      b.disabled = false; b.textContent = 'Load the program →';
    }
  });

  // ── step 4 ───────────────────────────────────────────────────────────────
  const handover = async () => {
    try {
      const r = await api('handover');
      const pairs = [['Admin URL', 'https://' + creds.domain + '/', true]];
      if (r.username) pairs.push(['Admin user', r.username, true], ['Admin password', r.password, true]);
      else pairs.push(['Admin account', 'was created on an earlier run — use the credentials you saved then']);
      if (newpw) pairs.push(['Root password', newpw, true]); else pairs.push(['Root password', 'unchanged']);
      pairs.push(['SSH', `ssh -p ${creds.port} root@${creds.ip}`, true]);
      kv($('cred'), pairs);
      $('h-ip').textContent = r.public_ip || creds.ip;
      const parts = creds.domain.split('.'); $('h-host').textContent = parts.length > 2 ? parts.slice(0, -2).join('.') : '@';
      $('h-url').textContent = 'https://' + creds.domain + '/'; $('h-url').href = 'https://' + creds.domain + '/';
      if (!r.username) { $('forget').hidden = true; $('done-note').hidden = true; }
      step(4);
    } catch (ex) { $('run-err').textContent = 'Installed, but reading the credentials failed: ' + ex.message + '. On the server: cat /root/megamesh-admin-credentials'; }
  };

  $('forget').addEventListener('click', async () => {
    const b = $('forget'); b.disabled = true; $('done-err').textContent = '';
    try { await api('forget'); $('done-msg').textContent = 'Deleted from the server. Only your password manager has them now.'; b.hidden = true; }
    catch (ex) { $('done-err').textContent = ex.message; b.disabled = false; }
  });

  window.addEventListener('beforeunload', (e) => { if (pollTimer) { e.preventDefault(); e.returnValue = ''; } });
})();
