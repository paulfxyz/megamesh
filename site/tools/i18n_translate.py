#!/usr/bin/env python3
"""Translate assets/i18n/en.json into the other 49 languages through OpenRouter.

Run inside the credential proxy:  pplx credentials run <handle> -- python3 tools/i18n_translate.py [codes...] [--review] [--force]

- One request per language (the whole master, ~250 strings) so terminology stays consistent within a language.
- Inline markup is kept; <svg>…</svg> blocks are swapped for ⟦svgN⟧ tokens before sending and restored after.
- Deterministic checks: same keys, same tags (names and count), same {placeholders}, same ⟦tokens⟧, same URLs, same digits-sequences.
- Failed keys are retried alone (up to 2×) with the validator's complaint; a key that still fails keeps English and is reported.
- --review runs an independent model over the strings generated in this run (whole file with --force) and applies only the corrections that pass the same checks.
- Results are cached in assets/i18n/<code>.json with a _meta.source_hash; a language is skipped when its hash matches (use --force).
"""
import json, os, re, ssl, sys, hashlib, time, pathlib, unicodedata
import requests
from requests.adapters import HTTPAdapter

ROOT = pathlib.Path(__file__).resolve().parent.parent
I18N = ROOT / 'assets' / 'i18n'
GEN_MODEL = os.environ.get('MM_GEN_MODEL', 'google/gemini-3.6-flash')
REV_MODEL = os.environ.get('MM_REV_MODEL', 'openai/gpt-5-mini')
API = 'https://openrouter.ai/api/v1/chat/completions'
BATCH = 64

LANGS = {  # code: (English name, script/variety instruction)
 'zh': ('Mandarin Chinese', 'Simplified Chinese characters, mainland register'),
 'hi': ('Hindi', 'Devanagari'), 'es': ('Spanish', 'neutral international Spanish'), 'fr': ('French', 'France French, tutoiement avoided: use vous'),
 'ar': ('Arabic', 'Modern Standard Arabic'), 'bn': ('Bengali', 'Bengali script, Bangladesh standard'), 'pt': ('Portuguese', 'Brazilian Portuguese'),
 'ru': ('Russian', 'Cyrillic'), 'ur': ('Urdu', 'Nastaliq-compatible Urdu script (Perso-Arabic)'), 'id': ('Indonesian', 'Bahasa Indonesia'),
 'de': ('German', 'Germany, Sie form'), 'ja': ('Japanese', 'standard polite です/ます'), 'pcm': ('Nigerian Pidgin', 'as written on BBC News Pidgin; keep technical terms in English'),
 'mr': ('Marathi', 'Devanagari'), 'te': ('Telugu', 'Telugu script'), 'tr': ('Turkish', 'standard Turkish'), 'ta': ('Tamil', 'Tamil script'),
 'yue': ('Cantonese', 'written Cantonese in Traditional Chinese characters as used in Hong Kong'), 'vi': ('Vietnamese', 'standard Vietnamese'),
 'wuu': ('Wu Chinese', 'Shanghainese written in Chinese characters; where no established written form exists, use Traditional/Simplified-neutral Mandarin-readable wording with Wu vocabulary where natural'),
 'tl': ('Filipino', 'Filipino / Tagalog, Taglish acceptable for technical terms'), 'ko': ('Korean', 'standard polite 합니다체'), 'fa': ('Persian', 'Iranian Persian (Farsi)'),
 'ha': ('Hausa', 'Boko Latin script, Nigerian standard'), 'sw': ('Swahili', 'standard Kiswahili'), 'jv': ('Javanese', 'Latin script, ngoko-alus register'),
 'it': ('Italian', 'standard Italian'), 'pa': ('Punjabi', 'Gurmukhi script only (ਪੰਜਾਬੀ), standard Indian Punjabi — never Shahmukhi/Perso-Arabic letters'), 'gu': ('Gujarati', 'Gujarati script'),
 'th': ('Thai', 'standard Thai'), 'kn': ('Kannada', 'Kannada script'), 'am': ('Amharic', 'Ge\'ez script'), 'bho': ('Bhojpuri', 'Devanagari'),
 'nan': ('Min Nan (Taiwanese Hokkien)', 'Taiwanese Hokkien written in Traditional Chinese characters (Hàn-jī), as recommended by Taiwan MOE'),
 'yo': ('Yoruba', 'with tone marks'), 'my': ('Burmese', 'Myanmar script, Unicode'), 'pl': ('Polish', 'standard Polish'), 'or': ('Odia', 'Odia script'),
 'ln': ('Lingala', 'Latin script, Kinshasa standard'), 'uk': ('Ukrainian', 'standard Ukrainian'), 'ig': ('Igbo', 'standard Igbo with diacritics'),
 'ml': ('Malayalam', 'Malayalam script'), 'ms': ('Malay', 'Bahasa Melayu, Malaysia'), 'nl': ('Dutch', 'Netherlands Dutch'), 'ne': ('Nepali', 'Devanagari'),
 'si': ('Sinhala', 'Sinhala script'), 'sd': ('Sindhi', 'Perso-Arabic Sindhi script'), 'uz': ('Uzbek', 'Latin script'), 'ro': ('Romanian', 'with diacritics ș ț'),
}
RTL = {'ar', 'ur', 'fa', 'sd'}

SYSTEM = """You are a senior technical translator localising the website of Megamesh (megamesh.sh), an open-source tool that turns a cheap VPS into a hardened personal WireGuard VPN. The audience is mixed: sysadmins, developers, and ordinary people who just want a VPN.

You receive a JSON object of English strings keyed by id. Return a JSON object with exactly the same keys and the translation of each value into {lang} ({variant}). Rules:
1. Keep every HTML tag exactly as given (same tag names, attributes, order, nesting); translate only the human text between tags. Keep ⟦svgN⟧ tokens, {placeholders}, URLs, email addresses, IP addresses, port numbers, file paths, shell commands, product names (Megamesh, megamesh.sh, WireGuard, wg-easy, Caddy, Docker, firewalld, fail2ban, topgrade, CentOS Stream, Ubuntu, Rocky, Alma, Debian, Let's Encrypt, GitHub, LinkedIn, MIT), and the person name Paul Fleury unchanged.
2. Technical terms that practitioners use in English (SSH, TLS, VPN, VPS, DNS, PTR, root, swap, port, firewall, QR code, 2FA, HSTS, IPv4) may stay in English where that is what a native technical reader expects; otherwise use the established local term.
3. Match the register of the source: short, confident, plain. Headlines stay short. Button labels stay short and imperative. Preserve the arrows → and ← and the separators · and —, and the ellipsis ….
4. Do not add explanations, notes or extra keys. Do not translate the keys. Never leave a value empty. Keep "megamesh.sh" lowercase. Keep numbers, units and digits as in the source.
5. Where the source is a single word used as a label (e.g. "Verify", "Copy"), translate as a UI label, not a sentence.
Output only the JSON object."""

def session():
    class A(HTTPAdapter):
        def _ctx(self):
            ctx = ssl.create_default_context(cafile=os.environ.get('REQUESTS_CA_BUNDLE')); ctx.verify_flags &= ~ssl.VERIFY_X509_STRICT; return ctx
        def init_poolmanager(self, *a, **k): k['ssl_context'] = self._ctx(); return super().init_poolmanager(*a, **k)
        def proxy_manager_for(self, *a, **k): k['ssl_context'] = self._ctx(); return super().proxy_manager_for(*a, **k)
    s = requests.Session(); s.mount('https://', A()); return s

S = session()
USAGE = {'calls': 0, 'prompt': 0, 'completion': 0, 'cost': 0.0}

def chat(model, system, user, effort=None, max_tokens=16000):
    body = {'model': model, 'messages': [{'role': 'system', 'content': system}, {'role': 'user', 'content': user}],
            'response_format': {'type': 'json_object'}, 'temperature': 0.2, 'max_tokens': max_tokens, 'usage': {'include': True}}
    body['reasoning'] = {'effort': effort or 'low'}
    for attempt in range(3):
        try:
            r = S.post(API, json=body, timeout=600, headers={'HTTP-Referer': 'https://megamesh.sh', 'X-Title': 'megamesh i18n'})
            if r.status_code >= 500 or r.status_code == 429: raise RuntimeError(f'HTTP {r.status_code}: {r.text[:200]}')
            j = r.json()
            if 'error' in j: raise RuntimeError(j['error'])
            u = j.get('usage') or {}
            USAGE['calls'] += 1; USAGE['prompt'] += u.get('prompt_tokens', 0); USAGE['completion'] += u.get('completion_tokens', 0); USAGE['cost'] += float(u.get('cost') or 0)
            txt = j['choices'][0]['message']['content'].strip()
            txt = re.sub(r'^```(?:json)?\s*|\s*```$', '', txt)
            return json.loads(txt)
        except Exception as e:
            if attempt == 2: raise
            print(f'   retry ({e})', file=sys.stderr); time.sleep(3 + 5 * attempt)

# ── protect / restore ───────────────────────────────────────────────────────
SVG = re.compile(r'<svg\b.*?</svg>', re.S)
def protect(d):
    toks = {}
    out = {}
    for k, v in d.items():
        def rep(m):
            t = f'⟦svg{len(toks) + 1}⟧'; toks[t] = m.group(0); return t
        out[k] = SVG.sub(rep, v)
    return out, toks
def restore(v, toks):
    for t, s in toks.items(): v = v.replace(t, s)
    return v

# ── validation ──────────────────────────────────────────────────────────────
TAG = re.compile(r'<(/?)([a-zA-Z][a-zA-Z0-9]*)([^>]*)>')
PH = re.compile(r'\{[a-z]+\}|⟦svg\d+⟧')
URL = re.compile(r'https?://[^\s"<>]+|[a-z0-9.-]+\.(?:sh|md|json|com|network|eu)(?![A-Za-z0-9])|/root/[^\s<]+')
NUM = re.compile(r'\d[\d.,/–-]*')
def sig_tags(s):
    return [(m.group(1), m.group(2).lower(), re.sub(r'\s+', ' ', m.group(3)).strip()) for m in TAG.finditer(s)]
def check(src, dst):
    if not isinstance(dst, str) or not dst.strip(): return 'empty'
    if sig_tags(src) != sig_tags(dst): return 'tags differ'
    if sorted(PH.findall(src)) != sorted(PH.findall(dst)): return 'placeholders differ'
    if sorted(URL.findall(src)) != sorted(URL.findall(dst)): return 'URLs/paths differ'
    asc = lambda t: ''.join(str(unicodedata.digit(c)) if c.isdecimal() and not c.isascii() else c for c in t)   # Burmese/Devanagari digits count as digits
    sn, dn = re.findall(r'\d+', src), re.findall(r'\d+', asc(dst))
    for n in sn:
        if n in dn: dn.remove(n)
        else: return f'number {n} missing'
    if dst.strip() == src.strip() and len(re.findall(r'[A-Za-z]{4,}', re.sub(r'<[^>]+>', ' ', src))) >= 5:
        return 'untranslated'
    return None

def translate(code, master, force=False, review=False):
    name, variant = LANGS[code]
    src_hash = hashlib.sha256(json.dumps(master, sort_keys=True, ensure_ascii=False).encode()).hexdigest()[:16]
    out_path = I18N / f'{code}.json'
    existing = json.loads(out_path.read_text(encoding='utf-8')) if out_path.exists() else None
    kept = {n.split(':')[0] for n in (existing or {}).get('_meta', {}).get('notes', []) if 'kept English' in n}
    if existing and existing.get('_meta', {}).get('source_hash') == src_hash and not kept and not force and not review:
        print(f'{code}: up to date'); return
    # translate only what is missing/changed vs the existing file (plus anything that fell back to English last time)
    todo = {k: v for k, v in master.items()} if not existing or force else {k: v for k, v in master.items() if existing.get(k) is None or existing['_meta'].get('src', {}).get(k) != hashlib.sha1(v.encode()).hexdigest()[:8] or k in kept}
    result = {k: v for k, v in (existing or {}).items() if not k.startswith('_') and k in master} if existing and not force else {}
    report = []
    if todo:
        prot, toks = protect(todo)
        sysmsg = SYSTEM.replace('{lang}', name).replace('{variant}', variant)
        t0 = time.time()
        keys = list(prot); got = {}
        for i in range(0, len(keys), BATCH):
            chunk = {k: prot[k] for k in keys[i:i + BATCH]}
            got.update(chat(GEN_MODEL, sysmsg, json.dumps(chunk, ensure_ascii=False, indent=0)))
        bad = {}
        for k, v in prot.items():
            g = got.get(k)
            err = check(v, g)
            if err: bad[k] = err
            else: result[k] = restore(g, toks)
        # retry bad ones individually with the complaint
        for k, err in list(bad.items()):
            for attempt in range(2):
                g = chat(GEN_MODEL, sysmsg, json.dumps({k: prot[k]}, ensure_ascii=False) + f'\n\nYour previous attempt failed validation: {err}. Keep markup, placeholders, numbers and URLs byte-identical to the source and translate only the human words.').get(k)
                err = check(prot[k], g)
                if not err: result[k] = restore(g, toks); bad.pop(k); break
            if k in bad:
                result[k] = master[k]; report.append(f'{k}: kept English ({bad[k]})')
        print(f'{code}: {len(todo)} strings in {time.time() - t0:.0f}s, {len(bad)} kept English')
    if review and (todo or force):
        # review only what was (re)generated this run: accepted strings are never reopened
        rev = review_file(code, name, variant, master, result, keys=set(todo) if not force else None)
        report += rev
    meta = {'lang': code, 'name': name, 'dir': 'rtl' if code in RTL else 'ltr', 'source_hash': src_hash, 'model': GEN_MODEL,
            'reviewed_by': REV_MODEL if review else (existing or {}).get('_meta', {}).get('reviewed_by'), 'generated': time.strftime('%Y-%m-%d'),
            'src': master, 'notes': report}
    out = {'_meta': {k: v for k, v in meta.items() if k != 'src'}}
    out['_meta']['src'] = {k: hashlib.sha1(v.encode()).hexdigest()[:8] for k, v in master.items()}
    out.update({k: result[k] for k in master})
    out_path.write_text(json.dumps(out, ensure_ascii=False, indent=0), encoding='utf-8')
    for r in report: print('   ', r)

REVIEW = """You are an independent reviewer of a machine translation into {lang} ({variant}) of the Megamesh website (an open-source personal WireGuard VPN installer). You get a JSON object whose values are {"en": source, "tr": translation}. Check every entry for: wrong meaning, omissions, untranslated passages that a native reader would expect translated, wrong technical term, awkward or unnatural phrasing, grammar, inconsistent terminology across entries, and UI labels that are too long. Ignore: product names, English technical acronyms, markup, URLs and numbers (those must stay as they are).
Return a JSON object containing ONLY the keys that need a change, each mapped to the full corrected translation (same markup, placeholders, numbers and URLs as the source). If nothing needs to change, return {}. Do not add commentary."""

def review_file(code, name, variant, master, result, keys=None):
    pairs = {k: {'en': master[k], 'tr': result[k]} for k in master if k in result and (keys is None or k in keys)}
    prot_master, toks = protect(master)
    prot_pairs = {k: {'en': prot_master[k], 'tr': SVG.sub(lambda m: next((t for t, s in toks.items() if s == m.group(0)), m.group(0)), v['tr'])} for k, v in pairs.items()}
    fixes = {}
    pk = list(prot_pairs)
    for i in range(0, len(pk), BATCH):
        fixes.update(chat(REV_MODEL, REVIEW.replace('{lang}', name).replace('{variant}', variant), json.dumps({k: prot_pairs[k] for k in pk[i:i + BATCH]}, ensure_ascii=False, indent=0), effort='low', max_tokens=16000) or {})
    applied, rejected = 0, []
    for k, v in (fixes or {}).items():
        if k not in master: continue
        if isinstance(v, dict): v = v.get('tr') or v.get('fix') or v.get('corrected')
        if v is None: continue   # reviewer explicitly says "fine as is"
        err = check(prot_master[k], v)
        if err: rejected.append(f'{k}: review fix rejected ({err})'); continue
        if restore(v, toks) != result[k]: result[k] = restore(v, toks); applied += 1
    print(f'   review: {applied} corrections applied, {len(rejected)} rejected')
    return rejected

def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    force = '--force' in sys.argv; review = '--review' in sys.argv
    master = json.loads((I18N / 'en.json').read_text(encoding='utf-8'))
    codes = args or list(LANGS)
    for c in codes:
        try: translate(c, master, force=force, review=review)
        except Exception as e: print(f'{c}: FAILED {e}', file=sys.stderr)
    print(f"usage: {USAGE['calls']} calls · {USAGE['prompt']} prompt tok · {USAGE['completion']} completion tok · ${USAGE['cost']:.3f} (OpenRouter-reported)")

if __name__ == '__main__':
    main()
