/* megamesh.sh — the deployer, browser side. Credentials live in this tab only. */
(() => {
  const $ = (id) => document.getElementById(id);
  const t = (k, fb, vars) => { let s = (window.MM && window.MM.t) ? window.MM.t(k, fb) : fb; if (vars) for (const [a, b] of Object.entries(vars)) s = s.split('{' + a + '}').join(b); return s; };
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
    let data; try { data = await res.json(); } catch { throw new Error(t('j.d.http_unexpected', 'The deployer returned something unexpected (HTTP {code}).', { code: res.status })); }
    if (!res.ok || !data.ok) throw new Error(data && data.error ? data.error : t('j.d.http_failed', 'Request failed (HTTP {code}).', { code: res.status }));
    return data;
  };

  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const kv = (el, pairs) => { el.innerHTML = pairs.map(([k, v, copy]) => `<span>${esc(k)}</span><b>${esc(v)}</b>${copy ? `<button type="button" class="cp" data-copy="${esc(v)}">${esc(t('j.copy', 'Copy'))}</button>` : '<i class="none"></i>'}`).join(''); };
  document.addEventListener('click', async (e) => {
    const b = e.target.closest('[data-copy]'); if (!b) return;
    try { await navigator.clipboard.writeText(b.dataset.copy); b.textContent = t('j.copied', 'Copied'); b.classList.add('did'); setTimeout(() => { b.textContent = t('j.copy', 'Copy'); b.classList.remove('did'); }, 1600); } catch { b.textContent = t('j.d.select_it', 'Select it'); }
  });

  // password eyes + generator
  document.querySelectorAll('[data-eye]').forEach((b) => b.addEventListener('click', () => { const i = $(b.dataset.eye); i.type = i.type === 'password' ? 'text' : 'password'; b.setAttribute('aria-label', i.type === 'password' ? t('j.d.show_pw', 'Show password') : t('j.d.hide_pw', 'Hide password')); }));
  $('gen').addEventListener('click', () => {
    const chars = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789-_.!%+';
    const a = new Uint32Array(24); crypto.getRandomValues(a);
    $('newpw').value = Array.from(a, (n) => chars[n % chars.length]).join(''); $('newpw').type = 'text'; $('newpw').focus();
  });

  // per-field validation
  const RULES = {
    ip: [(v) => /^(\d{1,3}\.)\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(v) && v.split('.').every((n) => +n <= 255), ['j.d.err_ip', 'Enter the server\'s public IPv4 address, like 203.0.113.10.']],
    port: [(v) => /^\d+$/.test(v) && +v >= 1 && +v <= 65535, ['j.d.err_port', 'SSH port must be 1–65535.']],
    pw: [(v) => v.length > 0 && v.length <= 256, ['j.d.err_pw', 'The current root password is required.']],
    newpw: [(v) => v === '' || /^[\x21-\x7E]{12,128}$/.test(v), ['j.d.err_newpw', '12–128 printable characters, no spaces.']],
    domain: [(v) => /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/.test(v) && v.length <= 253, ['j.d.err_domain', 'Enter a full domain name, like vpn.example.com.']],
    email: [(v) => /^[^\s@]+@[^\s@]+\.[a-z]{2,}$/i.test(v), ['j.d.err_email', 'Enter a valid email address.']],
    pubkey: [(v) => v === '' || /^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/=]+( [^\s'"]{0,120})?$/.test(v), ['j.d.err_pubkey', 'One line, starting with ssh-ed25519 or ssh-rsa.']],
  };
  const val = (id) => { const el = $(id); const v = id === 'pw' || id === 'newpw' ? el.value : el.value.trim(); const [ok, msg] = RULES[id]; const bad = !ok(id === 'domain' ? v.toLowerCase() : v); el.classList.toggle('bad', bad); $('h-' + id + '-err').textContent = bad ? t(msg[0], msg[1]) : ''; return !bad; };
  Object.keys(RULES).forEach((id) => $(id).addEventListener('blur', () => val(id)));

  // ── step 1 → check ───────────────────────────────────────────────────────
  $('f').addEventListener('submit', async (e) => {
    e.preventDefault();
    const err = $('f-err'); err.textContent = '';
    const okAll = Object.keys(RULES).map(val).every(Boolean);
    if (!okAll) { err.textContent = t('j.d.err_fields', 'Fix the highlighted fields.'); return; }
    creds.ip = $('ip').value.trim(); creds.port = ($('port').value.trim() || '22'); creds.pw = $('pw').value;
    creds.domain = $('domain').value.trim().toLowerCase(); creds.email = $('email').value.trim(); creds.pubkey = $('pubkey').value.trim();
    newpw = $('newpw').value; delete $('start').dataset.handover;
    if (newpw && newpw === creds.pw) newpw = '';
    const go = $('go'); go.disabled = true; go.innerHTML = '<span class="spin"></span>' + esc(t('j.d.connecting', 'Connecting…'));
    try {
      const r = await api('check');
      kv($('check-out'), [
        [t('j.d.k_os', 'OS'), r.os + (r.supported ? '' : '  — ' + t('j.d.not_supported', 'not supported'))],
        [t('j.d.k_arch', 'Architecture'), r.arch],
        [t('j.d.k_ram', 'RAM / CPU'), `${r.mem_mb} MB / ${r.cpus} vCPU`],
        [t('j.d.k_docker', 'Docker'), r.docker ? t('j.d.docker_present', 'present') : t('j.d.docker_install', 'will be installed')],
        [t('j.d.k_mm', 'Megamesh'), r.installed ? t('j.d.mm_installed', 'already installed — running again is safe') : t('j.d.mm_not', 'not installed')],
        [t('j.d.k_rootpw', 'Root password'), newpw ? t('j.d.pw_change', 'will be changed to yours') : t('j.d.pw_keep', 'kept as it is')],
      ]);
      $('plan').innerHTML = [
        [t('j.d.k_domain', 'Domain'), creds.domain + ' → ' + creds.ip], [t('j.d.k_email', 'Certificate email'), creds.email],
        [t('j.d.k_ssh', 'SSH'), creds.pubkey ? t('j.d.ssh_key', 'your key is installed; password login stays on until you turn it off') : t('j.d.ssh_nokey', 'password login stays on (no key given)')],
        [t('j.d.k_time', 'Time'), r.installed ? t('j.d.time_rerun', 'a few minutes (re-run)') : t('j.d.time_fresh', '10–30 minutes on 1 vCPU')],
      ].map(([k, v]) => `<div><b>${esc(k)}</b>${esc(v)}</div>`).join('');
      const note = $('check-note'); const start = $('start');
      if (!r.supported) { note.hidden = false; note.innerHTML = t('j.d.note_unsupported', '<b>Unsupported system.</b> The installer knows CentOS Stream / Rocky / Alma 9 and Debian / Ubuntu on x86_64. Reinstall the VPS with CentOS Stream 9 or Ubuntu 24.04 from your provider\'s panel and try again.'); start.dataset.blocked = '1'; }
      else if (r.finished && r.creds) { note.hidden = false; note.innerHTML = t('j.d.note_finished', '<b>A finished install is waiting for you.</b> The credentials file is still on the server — the button below reads it and shows the hand-over, nothing is installed again.'); delete start.dataset.blocked; start.dataset.handover = '1'; }
      else if (r.running) { note.hidden = false; note.innerHTML = t('j.d.note_running', '<b>An install is already running</b> on this server. Installing will attach to it rather than start another.'); delete start.dataset.blocked; }
      else if (!r.verified) { note.hidden = false; note.innerHTML = t('j.d.note_besteffort', '<b>Best-effort system.</b> Only CentOS Stream 9 and Ubuntu 24.04 have been verified end to end; this one takes a code path that has not been run yet. It will probably work — if it fails, the log will say where.'); delete start.dataset.blocked; }
      else if (r.mem_mb < 900) { note.hidden = false; note.innerHTML = t('j.d.note_small', '<b>Small box.</b> Under 1 GB visible RAM; the installer adds swap before updating, which is exactly the case it was built for.'); delete start.dataset.blocked; }
      else { note.hidden = true; delete start.dataset.blocked; }
      start.textContent = start.dataset.handover ? t('j.d.handover_btn', 'Show my hand-over →') : t('j.d.install_btn', 'Install Megamesh →');
      $('agree').checked = false; start.disabled = true;
      step(2);
    } catch (ex) { err.textContent = ex.message; }
    finally { go.disabled = false; go.textContent = t('j.d.check_btn', 'Check the server →'); }
  });
  $('agree').addEventListener('change', () => { $('start').disabled = !$('agree').checked || !!$('start').dataset.blocked; });
  $('back1').addEventListener('click', () => step(1));

  // ── step 2 → (passwd) → start → poll ─────────────────────────────────────
  const PH = [/Installer started|Downloading|Detected|swap/i, /Updating packages|Upgraded|Installed|Complete!|Installing (packages|Docker)|apt upgrade|dnf upgrade|Kernel modules/, /firewall|sshd|SSH hardening|fail2ban|sysctl/i, /Pulling|Pulled|Container |compose|wg-easy|caddy/i, /health|verif|Admin account|credentials|MEGAMESH_EXIT|✔ Done|Status:/i];
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
    log.innerHTML = html || esc(t('j.d.starting', 'Starting…')); if (stick) log.scrollTop = log.scrollHeight;
  };
  const tickElapsed = () => { const s = Math.floor((Date.now() - startedAt) / 1000); $('elapsed').textContent = String(Math.floor(s / 60)).padStart(2, '0') + ':' + String(s % 60).padStart(2, '0'); };

  const poll = async () => {
    try {
      const r = await api('status'); failures = 0; $('run-err').textContent = ''; $('resume').hidden = true;
      renderLog(r.lines);
      if (r.done) {
        clearInterval(pollTimer); pollTimer = null; clearInterval(elapsedTimer);
        if (r.exit === 0) { setPhase(5); await handover(); }
        else { $('spin').style.display = 'none'; $('loading').textContent = t('j.d.stopped', 'Stopped'); $('run-title').textContent = t('j.d.stopped_hint', 'The install stopped with an error.'); $('run-hint').textContent = t('j.d.stopped_err', 'The last lines above say where. Fix the cause (or reinstall the VPS) and run the deployer again — the installer is idempotent.'); }
      }
    } catch (ex) {
      failures++;
      $('run-err').textContent = t('j.d.lost', 'Lost contact with the server: {msg}', { msg: ex.message }) + (failures < 6 ? t('j.d.retrying', ' — retrying.') : t('j.d.paused', ' — paused after several failures.'));
      if (failures >= 6) { clearInterval(pollTimer); pollTimer = null; $('resume').hidden = false; }
    }
  };
  const startPolling = () => { if (pollTimer) clearInterval(pollTimer); failures = 0; pollTimer = setInterval(poll, 8000); };
  $('resume').addEventListener('click', () => { $('resume').hidden = true; poll(); startPolling(); });

  $('start').addEventListener('click', async () => {
    const b = $('start'); b.disabled = true; $('check-err').textContent = '';
    if (b.dataset.handover) { delete b.dataset.handover; b.innerHTML = '<span class="spin"></span>' + esc(t('j.d.reading', 'Reading…')); step(3); setPhase(5); try { await handover(); } catch (ex) { $('check-err').textContent = ex.message; } b.disabled = false; b.textContent = t('j.d.install_btn', 'Install Megamesh →'); return; }
    try {
      if (newpw) {
        b.innerHTML = '<span class="spin"></span>' + esc(t('j.d.changing_pw', 'Changing root password…'));
        await api('passwd', { newpw });
        creds.pw = newpw;     // every call from here on uses the new one — the next call proves it took
      }
      b.innerHTML = '<span class="spin"></span>' + esc(t('j.d.starting', 'Starting…'));
      await api('start');
      startedAt = Date.now(); tickElapsed(); elapsedTimer = setInterval(tickElapsed, 1000);
      step(3); setPhase(0);
      renderLog(['▶ ' + t('j.d.log_started', 'Connected. {pw}Installer started on your server — downloading the release and updating packages…', { pw: newpw ? t('j.d.log_pw_changed', 'Root password changed. ') : '' })]);
      startPolling();
    } catch (ex) {
      $('check-err').textContent = ex.message + (creds.pw === newpw && newpw ? t('j.d.pw_changed_note', ' (Note: the root password HAS been changed to the new one you chose.)') : '');
      b.disabled = false; b.textContent = t('j.d.install_btn', 'Install Megamesh →');
    }
  });

  // ── step 4 ───────────────────────────────────────────────────────────────
  let hand = null;   // last hand-over payload, re-rendered when the language changes
  const renderHand = () => {
    if (!hand) return; const r = hand;
    const pairs = [[t('j.d.h_url', 'Admin URL'), 'https://' + creds.domain + '/', true]];
    if (r.username) pairs.push([t('j.d.h_user', 'Admin user'), r.username, true], [t('j.d.h_pw', 'Admin password'), r.password, true]);
    else pairs.push([t('j.d.h_account', 'Admin account'), t('j.d.h_account_earlier', 'was created on an earlier run — use the credentials you saved then')]);
    if (newpw) pairs.push([t('j.d.h_root', 'Root password'), newpw, true]); else pairs.push([t('j.d.h_root', 'Root password'), t('j.d.h_root_unchanged', 'unchanged')]);
    pairs.push([t('j.d.h_ssh', 'SSH'), `ssh -p ${creds.port} root@${creds.ip}`, true]);
    kv($('cred'), pairs);
    $('h-ip').textContent = r.public_ip || creds.ip;
    const parts = creds.domain.split('.'); $('h-host').textContent = parts.length > 2 ? parts.slice(0, -2).join('.') : '@';
    $('h-url').textContent = 'https://' + creds.domain + '/'; $('h-url').href = 'https://' + creds.domain + '/';
    if (!r.username) { $('forget').hidden = true; $('done-note').hidden = true; }
  };
  document.addEventListener('mm:lang', renderHand);
  const handover = async () => {
    try {
      hand = await api('handover');
      renderHand();
      step(4);
    } catch (ex) { $('run-err').textContent = t('j.d.h_read_failed', 'Installed, but reading the credentials failed: {msg}. On the server: cat /root/megamesh-admin-credentials', { msg: ex.message }); }
  };

  $('forget').addEventListener('click', async () => {
    const b = $('forget'); b.disabled = true; $('done-err').textContent = '';
    try { await api('forget'); $('done-msg').textContent = t('j.d.forgot', 'Deleted from the server. Only your password manager has them now.'); b.hidden = true; }
    catch (ex) { $('done-err').textContent = ex.message; b.disabled = false; }
  });

  window.addEventListener('beforeunload', (e) => { if (pollTimer) { e.preventDefault(); e.returnValue = ''; } });
})();
