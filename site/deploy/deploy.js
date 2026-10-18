/* megamesh.sh deployer — browser side. Credentials live in this tab only. */
(() => {
  const $ = (id) => document.getElementById(id);
  const creds = {};           // ip, port, pw, domain, email, pubkey — never persisted
  let pollTimer = null;

  const step = (n) => {
    for (let i = 1; i <= 4; i++) {
      const el = $('s' + i);
      el.className = i < n ? 'done' : i === n ? 'on' : '';
    }
    ['p-form', 'p-check', 'p-run', 'p-done'].forEach((id, i) => { $(id).hidden = (i + 1) !== n; });
    window.scrollTo({ top: 0, behavior: 'smooth' });
  };

  const api = async (action, extra = {}) => {
    const res = await fetch('/api/deploy.php', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, cache: 'no-store',
      body: JSON.stringify({ action, ...creds, ...extra })
    });
    let data;
    try { data = await res.json(); } catch { throw new Error('The deployer returned something unexpected (HTTP ' + res.status + ').'); }
    if (!res.ok || !data.ok) throw new Error(data && data.error ? data.error : 'Request failed (HTTP ' + res.status + ').');
    return data;
  };

  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const kv = (el, pairs) => { el.innerHTML = pairs.map(([k, v]) => `<span>${esc(k)}</span><b>${esc(v)}</b>`).join(''); };

  // ── step 1 → check ───────────────────────────────────────────────────────
  $('f').addEventListener('submit', async (e) => {
    e.preventDefault();
    const err = $('f-err'); err.textContent = '';
    creds.ip = $('ip').value.trim(); creds.port = ($('port').value.trim() || '22');
    creds.pw = $('pw').value; creds.domain = $('domain').value.trim().toLowerCase();
    creds.email = $('email').value.trim(); creds.pubkey = $('pubkey').value.trim();
    if (!/^(\d{1,3}\.){3}\d{1,3}$/.test(creds.ip)) return err.textContent = 'Enter the server\'s IPv4 address.';
    if (!/^\d+$/.test(creds.port) || +creds.port < 1 || +creds.port > 65535) return err.textContent = 'SSH port must be 1–65535.';
    if (!creds.pw) return err.textContent = 'The root password is required.';
    if (!/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/.test(creds.domain)) return err.textContent = 'Enter a full domain name, like vpn.example.com.';
    if (!/^[^\s@]+@[^\s@]+\.[a-z]{2,}$/i.test(creds.email)) return err.textContent = 'Enter a valid email address.';
    if (creds.pubkey && !/^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/=]+( [^\s'"]{0,120})?$/.test(creds.pubkey)) return err.textContent = 'That does not look like an OpenSSH public key (one line, starting with ssh-ed25519 or ssh-rsa).';
    const go = $('go'); go.disabled = true; go.innerHTML = '<span class="spin"></span>Connecting…';
    try {
      const r = await api('check');
      kv($('check-out'), [
        ['OS', r.os + (r.supported ? '' : '  — not supported')],
        ['Architecture', r.arch],
        ['RAM / CPU', `${r.mem_mb} MB / ${r.cpus} vCPU`],
        ['Docker', r.docker ? 'present' : 'will be installed'],
        ['Megamesh', r.installed ? 'already installed — running again is safe' : 'not installed'],
      ]);
      const note = $('check-note');
      if (!r.supported) { note.hidden = false; note.innerHTML = '<b>Unsupported system.</b> The installer knows CentOS Stream / Rocky / Alma 9 and Debian / Ubuntu. Reinstall the VPS with CentOS Stream 9 from your provider\'s panel and try again.'; $('start').disabled = true; }
      else if (!r.verified) { note.hidden = false; note.innerHTML = '<b>Best-effort system.</b> Only CentOS Stream 9 has been verified end to end; this one takes a code path that has not been run yet. It will probably work — if it fails, the log will say where.'; $('start').disabled = false; }
      else if (r.mem_mb < 900) { note.hidden = false; note.innerHTML = '<b>Small box.</b> Under 1 GB visible RAM; the installer adds swap before updating, which is exactly the case it was built for.'; $('start').disabled = false; }
      else { note.hidden = true; $('start').disabled = false; }
      step(2);
    } catch (ex) { err.textContent = ex.message; }
    finally { go.disabled = false; go.textContent = 'Check the server →'; }
  });

  $('back1').addEventListener('click', () => step(1));

  // ── step 2 → start + poll ────────────────────────────────────────────────
  const renderLog = (lines) => {
    const html = lines.map((l) => {
      const c = l.startsWith('✔') ? 'ok' : l.startsWith('▶') ? 'step' : l.startsWith('⚠') ? 'warn' : l.startsWith('✖') ? 'bad' : '';
      return c ? `<span class="${c}">${esc(l)}</span>` : esc(l);
    }).join('\n');
    const log = $('log'); const stick = log.scrollTop + log.clientHeight >= log.scrollHeight - 20;
    log.innerHTML = html || 'Starting…'; if (stick) log.scrollTop = log.scrollHeight;
  };

  const poll = async () => {
    try {
      const r = await api('status');
      renderLog(r.lines);
      if (r.done) {
        clearInterval(pollTimer); pollTimer = null;
        if (r.exit === 0) { await handover(); }
        else { $('spin').style.display = 'none'; $('run-title').textContent = 'The install stopped with an error.'; $('run-hint').textContent = 'The last lines above say where. Fix the cause (or reinstall the VPS) and run the deployer again — the installer is idempotent.'; }
      }
    } catch (ex) { $('run-err').textContent = 'Lost contact with the server: ' + ex.message + ' — retrying.'; }
  };

  $('start').addEventListener('click', async () => {
    const b = $('start'); b.disabled = true; b.innerHTML = '<span class="spin"></span>Starting…'; $('check-err').textContent = '';
    try {
      await api('start');
      step(3); renderLog(['▶ Installer started on your server. Downloading the release and updating packages…']);
      pollTimer = setInterval(poll, 8000);
    } catch (ex) { $('check-err').textContent = ex.message; b.disabled = false; b.textContent = 'Install Megamesh →'; }
  });

  // ── step 4 ───────────────────────────────────────────────────────────────
  const handover = async () => {
    try {
      const r = await api('handover');
      const pairs = [['Admin URL', 'https://' + creds.domain + '/']];
      if (r.username) pairs.push(['Username', r.username], ['Password', r.password]);
      else pairs.push(['Admin account', 'was created on an earlier run — use the credentials you saved then']);
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
