<?php
/**
 * megamesh.sh deployer — server side.
 *
 * Stateless: every request carries the target's SSH credentials, opens one SSH session, does one thing, returns.
 * Nothing is written to disk except a per-client-IP rate-limit counter (no credentials in it) and nothing is logged.
 * `passwd` changes root's password to one the user chose (optional, before `start`); the new one is never echoed back.
 *
 * Actions: check | start | status | handover | forget
 */
declare(strict_types=1);
error_reporting(0);
ini_set('display_errors', '0');
ini_set('log_errors', '0');
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: no-referrer');

const MEGAMESH_RELEASE = '1.5.7';                 // tag of the release the deployer installs
const MEGAMESH_TARBALL = 'https://github.com/paulfxyz/megamesh/archive/refs/tags/v' . MEGAMESH_RELEASE . '.tar.gz';
const LOGFILE   = '/root/megamesh-install.log';
const CREDFILE  = '/root/megamesh-admin-credentials';
const WORKDIR   = '/root/megamesh';
const RL_WINDOW = 600;   // seconds
const RL_MAX_LOGIN_ACTIONS = 12;   // check/start per client IP per window (status polls are not limited)

function out(array $o, int $code = 200): never { http_response_code($code); echo json_encode($o, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE); exit; }
function fail(string $msg, int $code = 400): never { out(['ok' => false, 'error' => $msg], $code); }

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') fail('POST only', 405);
if (!isset($_SERVER['HTTPS']) || $_SERVER['HTTPS'] === 'off') fail('HTTPS required', 400);
$raw = file_get_contents('php://input', false, null, 0, 16384);
$in = json_decode((string)$raw, true);
if (!is_array($in)) fail('Bad request body');
if (!empty($in['website'])) fail('Bad request');               // honeypot

require __DIR__ . '/lib/autoload.php';
use phpseclib4\Net\SSH2;

// ── validation ───────────────────────────────────────────────────────────────
$action = (string)($in['action'] ?? '');
if (!in_array($action, ['check', 'passwd', 'start', 'status', 'handover', 'forget'], true)) fail('Unknown action');

$ip = (string)($in['ip'] ?? '');
if (filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4 | FILTER_FLAG_NO_PRIV_RANGE | FILTER_FLAG_NO_RES_RANGE) === false)
    fail('Server IP must be a public IPv4 address.');
$port = (int)($in['port'] ?? 22);
if ($port < 1 || $port > 65535) fail('SSH port out of range.');
$pw = (string)($in['pw'] ?? '');
if ($pw === '' || strlen($pw) > 256) fail('Root password missing.');
$domain = strtolower(trim((string)($in['domain'] ?? '')));
if (!preg_match('/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/', $domain) || strlen($domain) > 253) fail('Domain is not a valid hostname.');
$email = trim((string)($in['email'] ?? ''));
if (filter_var($email, FILTER_VALIDATE_EMAIL) === false || strlen($email) > 254 || strpbrk($email, "'\"\\$`") !== false) fail('Email address is not valid.');
$pubkey = trim((string)($in['pubkey'] ?? ''));
if ($pubkey !== '' && !preg_match('/^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+\/=]+( [^\s\'"\\\\]{0,120})?$/', $pubkey))
    fail('SSH public key is not a single OpenSSH line.');
$newpw = (string)($in['newpw'] ?? '');
if ($action === 'passwd' && !preg_match('/^[\x21-\x7E]{12,128}$/', $newpw)) fail('New root password: 12–128 printable characters, no spaces.');

// ── rate limit on credential-bearing connection attempts ─────────────────────
if (in_array($action, ['check', 'passwd', 'start'], true)) {
    $client = $_SERVER['REMOTE_ADDR'] ?? '0';
    $f = sys_get_temp_dir() . '/megamesh-rl-' . hash('sha256', 'mm|' . $client);
    $hits = array_filter(array_map('intval', @file($f, FILE_IGNORE_NEW_LINES) ?: []), fn($t) => $t > time() - RL_WINDOW);
    if (count($hits) >= RL_MAX_LOGIN_ACTIONS) fail('Too many attempts from your address. Try again in ten minutes.', 429);
    $hits[] = time();
    @file_put_contents($f, implode("\n", $hits) . "\n", LOCK_EX);
}

// ── SSH ──────────────────────────────────────────────────────────────────────
set_time_limit(110);
$ssh = new SSH2($ip, $port, 12);
$ssh->setTimeout(90);
try {
    if (!$ssh->login('root', $pw)) fail('SSH login as root failed — check the IP, port and root password. (Key-only servers cannot use the deployer; use the script instead.)', 401);
} catch (\Throwable $e) {
    fail('Could not reach ' . $ip . ':' . $port . ' over SSH — is the server up and is port ' . $port . ' open?', 502);
}
$run = function (string $cmd) use ($ssh): string { return (string)$ssh->exec($cmd); };
$strip = fn(string $s) => preg_replace('/\x1b\[[0-9;]*[A-Za-z]/', '', $s);

switch ($action) {
    case 'check': {
        $o = $run('. /etc/os-release 2>/dev/null; echo "ID=$ID"; echo "PRETTY=$PRETTY_NAME"; echo "VERSION_ID=$VERSION_ID"; echo "LIKE=$ID_LIKE"; echo "ARCH=$(uname -m)"; echo "MEM=$(awk \'/MemTotal/ {print int($2/1024)}\' /proc/meminfo)"; echo "CPU=$(nproc)"; echo "DOCKER=$(command -v docker >/dev/null && echo 1 || echo 0)"; echo "INSTALLED=$(test -f /etc/megamesh.conf && echo 1 || echo 0)"; echo "RUNNING=$(test -f ' . LOGFILE . ' && ! grep -q MEGAMESH_EXIT= ' . LOGFILE . ' && echo 1 || echo 0)"; echo "FINISHED=$(grep -q MEGAMESH_EXIT=0 ' . LOGFILE . ' 2>/dev/null && echo 1 || echo 0)"; echo "CREDS=$(test -f ' . CREDFILE . ' && echo 1 || echo 0)"; echo "UID=$(id -u)"');
        $kv = [];
        foreach (explode("\n", $o) as $l) if (str_contains($l, '=')) { [$k, $v] = explode('=', $l, 2); $kv[$k] = trim($v); }
        if (($kv['UID'] ?? '') !== '0') fail('Logged in, but not as root.');
        $id = $kv['ID'] ?? ''; $like = $kv['LIKE'] ?? '';
        $supported = in_array($id, ['centos', 'rocky', 'almalinux', 'rhel', 'debian', 'ubuntu'], true) || preg_match('/rhel|fedora|debian/', $like);
        $verified = ($id === 'centos' && str_contains($kv['PRETTY'] ?? '', '9')) || ($id === 'ubuntu' && str_starts_with($kv['VERSION_ID'] ?? '', '24.04'));
        if (($kv['ARCH'] ?? '') !== 'x86_64') $supported = false;
        out(['ok' => true, 'os' => $kv['PRETTY'] ?: 'unknown', 'arch' => $kv['ARCH'] ?? '?', 'mem_mb' => (int)($kv['MEM'] ?? 0), 'cpus' => (int)($kv['CPU'] ?? 0),
             'docker' => ($kv['DOCKER'] ?? '0') === '1', 'installed' => ($kv['INSTALLED'] ?? '0') === '1', 'running' => ($kv['RUNNING'] ?? '0') === '1',
             'finished' => ($kv['FINISHED'] ?? '0') === '1', 'creds' => ($kv['CREDS'] ?? '0') === '1',
             'supported' => $supported, 'verified' => $verified]);
    }

    case 'passwd': {
        // change root's password before anything else; the client switches to it and the next login proves it took
        $o = $run('printf %s ' . escapeshellarg(base64_encode("root:" . $newpw . "\n")) . ' | base64 -d | chpasswd 2>&1 && echo PWOK');
        if (!str_contains($o, 'PWOK')) fail('Could not change the root password: ' . trim($strip($o)), 500);
        out(['ok' => true, 'changed' => true]);
    }

    case 'start': {
        $running = trim($run('test -f ' . LOGFILE . ' && ! grep -q MEGAMESH_EXIT= ' . LOGFILE . ' && echo 1 || echo 0'));
        if ($running === '1') out(['ok' => true, 'already_running' => true]);
        // values are validated above; single-quote them anyway (no single quotes can be present)
        $env = "MEGAMESH_DOMAIN='{$domain}'\nMEGAMESH_EMAIL='{$email}'\nMEGAMESH_LOCK_SSH='no'\nMEGAMESH_SKIP_UPDATE='0'\n";
        if ($pubkey !== '') $env .= "MEGAMESH_SSH_PUBKEY='{$pubkey}'\n";
        $envB64 = base64_encode($env);
        $cmd = 'set -e; export DEBIAN_FRONTEND=noninteractive; '
             . 'command -v curl >/dev/null 2>&1 || { command -v dnf >/dev/null && dnf -y -q install curl || { apt-get -qq update && apt-get -qq -y install curl; }; } >/dev/null 2>&1; '
             . 'command -v tar >/dev/null 2>&1 || { command -v dnf >/dev/null && dnf -y -q install tar || apt-get -qq -y install tar; } >/dev/null 2>&1; '
             . 'rm -rf ' . WORKDIR . ' && mkdir -p ' . WORKDIR . ' && curl -fsSL ' . escapeshellarg(MEGAMESH_TARBALL) . ' | tar xz -C ' . WORKDIR . ' --strip-components=1; '
             . 'umask 077; echo ' . $envB64 . ' | base64 -d > ' . WORKDIR . '/.deploy.env; '
             . 'rm -f ' . LOGFILE . '; '
             . 'nohup setsid bash -c \'set -a; . ' . WORKDIR . '/.deploy.env; set +a; cd ' . WORKDIR . '; bash megamesh.sh; echo "MEGAMESH_EXIT=$?"\' > ' . LOGFILE . ' 2>&1 < /dev/null & '
             . 'sleep 1; echo STARTED';
        $o = $run($cmd);
        if (!str_contains($o, 'STARTED')) fail('Could not start the installer on the server: ' . trim($strip($o)), 500);
        out(['ok' => true]);
    }

    case 'status': {
        $o = $run('test -f ' . LOGFILE . ' && tail -c 12000 ' . LOGFILE . ' || echo "(no log yet)"');
        $txt = $strip($o);
        $exit = null;
        if (preg_match('/MEGAMESH_EXIT=(\d+)/', $txt, $m)) $exit = (int)$m[1];
        $lines = [];
        foreach (explode("\n", $txt) as $l) {
            $l = rtrim($l);
            if ($l === '' || str_starts_with($l, 'MEGAMESH_EXIT=')) continue;
            if (preg_match('/^(✔|▶|⚠|✖)/u', $l) || preg_match('/^\s*(Upgraded|Installed|Complete!|Pulling|Pulled|Container |Status:|  [0-9]\. |─)/', $l) || $exit !== null && $exit !== 0) $lines[] = $l;
        }
        if (!$lines) $lines = ['▶ Working… (package updates on a 1 vCPU box take a while)'];
        out(['ok' => true, 'done' => $exit !== null, 'exit' => $exit, 'lines' => array_slice($lines, -60)]);
    }

    case 'handover': {
        $o = $run('cat ' . CREDFILE . ' 2>/dev/null; echo "---MM---"; curl -s -4 --max-time 5 https://ifconfig.me || echo ""');
        [$cred, $pub] = array_pad(explode("---MM---", $o, 2), 2, '');
        $user = $pass = null;
        if (preg_match('/^Username:\s*(.+)$/m', $cred, $m)) $user = trim($m[1]);
        if (preg_match('/^Password:\s*(.+)$/m', $cred, $m)) $pass = trim($m[1]);
        $pub = trim($pub);
        out(['ok' => true, 'username' => $user, 'password' => $pass, 'public_ip' => filter_var($pub, FILTER_VALIDATE_IP) ? $pub : $ip]);
    }

    case 'forget': {
        $run('shred -u ' . CREDFILE . ' 2>/dev/null || rm -f ' . CREDFILE . '; rm -f ' . WORKDIR . '/.deploy.env; echo OK');
        out(['ok' => true]);
    }
}
fail('Unhandled');
