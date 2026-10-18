#!/usr/bin/env python3
"""Audit the translation files for terminology and script consistency; optionally fix through OpenRouter.

  python3 tools/i18n_audit.py            report only
  pplx credentials run <handle> -- python3 tools/i18n_audit.py --fix [codes]

Checks
- script: letters outside the language's expected script (and Latin, which brands need) → stray glyphs from a neighbouring script
- consistency: identical English strings (nav labels, button texts, phase names…) must have one translation per language
- brands: product names present in the source must survive in the target
- english: long strings that still read as English in a language that should not
Fixes retranslate only the flagged keys, with the complaint in the prompt, through the same validator as the main run.
"""
import json, re, sys, glob, unicodedata, collections, pathlib, importlib.util
ROOT = pathlib.Path(__file__).resolve().parent.parent
I18N = ROOT / 'assets' / 'i18n'
spec = importlib.util.spec_from_file_location('tr', ROOT / 'tools' / 'i18n_translate.py'); tr = importlib.util.module_from_spec(spec); spec.loader.exec_module(tr)

EXPECT = {'zh': 'CJK', 'yue': 'CJK', 'wuu': 'CJK', 'nan': 'CJK', 'ja': 'CJK|HIRAGANA|KATAKANA', 'ko': 'HANGUL|CJK', 'hi': 'DEVANAGARI', 'mr': 'DEVANAGARI', 'bho': 'DEVANAGARI', 'ne': 'DEVANAGARI',
          'ar': 'ARABIC', 'ur': 'ARABIC', 'fa': 'ARABIC', 'sd': 'ARABIC', 'pa': 'GURMUKHI', 'bn': 'BENGALI', 'te': 'TELUGU', 'ta': 'TAMIL', 'gu': 'GUJARATI', 'kn': 'KANNADA', 'ml': 'MALAYALAM', 'or': 'ORIYA',
          'th': 'THAI', 'my': 'MYANMAR', 'am': 'ETHIOPIC', 'si': 'SINHALA', 'ru': 'CYRILLIC', 'uk': 'CYRILLIC'}
LATIN_LANGS = {'pcm', 'tl', 'jv', 'ha', 'yo', 'ig', 'sw', 'ln', 'ms', 'id', 'uz', 'vi', 'tr', 'pl', 'ro', 'nl', 'de', 'fr', 'es', 'pt', 'it'}
BRANDS = ['Megamesh', 'megamesh.sh', 'WireGuard', 'wg-easy', 'Caddy', 'Docker', 'firewalld', 'fail2ban', 'topgrade', 'CentOS', 'Ubuntu', 'GitHub', 'PROMPT.md', 'MIT', 'Paul Fleury', 'paulfleury.network', 'egress.json']
ENGLISH = re.compile(r'\b(the|and|your|with|that|this|from|server|password|install|once|before|after|which|mine|deploy)\b')
strip = lambda s: re.sub(r'<[^>]+>', '', s).strip()

def groups(en):
    g = collections.defaultdict(list)
    for k, v in en.items():
        if k.startswith('m.'): continue
        t = strip(v).lower()
        if len(t) >= 3 and re.search('[a-z]', t): g[t].append(k)
    return {t: ks for t, ks in g.items() if len(ks) > 1}

def audit(code, en, d):
    issues = []   # (kind, keys, detail)
    pat = re.compile(EXPECT[code]) if code in EXPECT else None
    for k, v in d.items():
        if k.startswith('_'): continue
        txt = strip(v)
        if pat:
            foreign = {unicodedata.name(ch, '?').split(' ')[0] for ch in txt if ch.isalpha() and not unicodedata.name(ch, 'LATIN').startswith('LATIN') and not pat.search(unicodedata.name(ch, ''))}
            if foreign: issues.append(('script', [k], f'stray {"/".join(sorted(foreign))} letters'))
        for b in BRANDS:
            if b in en[k] and b.lower() not in v.lower(): issues.append(('brand', [k], f'"{b}" missing'))
        if re.search(r'Megamesh\.sh', v): issues.append(('brand', [k], 'megamesh.sh must stay lowercase'))
        if code not in LATIN_LANGS and len(ENGLISH.findall(txt.lower())) >= 3 and not k.startswith('m.'):
            issues.append(('english', [k], 'still English'))
        if code != 'pcm' and code not in LATIN_LANGS and '@' not in en[k] and len(re.findall(r'[A-Za-z]{3,}', strip(en[k]))) >= 4 and txt.lower() == strip(en[k]).lower():
            issues.append(('english', [k], 'identical to source'))
    for t, ks in groups(en).items():
        vals = {strip(d[k]).lower() for k in ks}
        if len(vals) > 1: issues.append(('inconsistent', ks, ' | '.join(sorted(vals))))
    # dedupe keys that appear in several issues
    return issues

FIX = """You are fixing specific entries of the {lang} ({variant}) translation of the Megamesh website (an open-source personal WireGuard VPN installer). For each key you get the English source, the current translation and the problem. Return a JSON object with the same keys and corrected translations only.
Rules: keep every HTML tag, ⟦svgN⟧ token, {placeholder}, URL, path, number and product name exactly as in the English source; translate only the human words; write {lang} in {variant} only — never mix in letters from another script; where several keys share the same English term, give them the same translation (differences in markup aside); UI labels stay short. Output only the JSON object."""

def fix(code, en, d, issues):
    name, variant = tr.LANGS[code]
    todo = {}
    for kind, keys, detail in issues:
        for k in keys:
            todo.setdefault(k, []).append(f'{kind}: {detail}')
    if not todo: return 0
    prot_en, toks = tr.protect({k: en[k] for k in todo})
    payload = {k: {'en': prot_en[k], 'current': tr.SVG.sub(lambda m: next((t for t, s in toks.items() if s == m.group(0)), m.group(0)), d[k]), 'problem': '; '.join(sorted(set(todo[k])))} for k in todo}
    sysmsg = FIX.replace('{lang}', name).replace('{variant}', variant)
    got = {}
    keys = list(payload)
    for i in range(0, len(keys), 40):
        got.update(tr.chat(tr.GEN_MODEL, sysmsg, json.dumps({k: payload[k] for k in keys[i:i + 40]}, ensure_ascii=False, indent=0)) or {})
    applied = 0
    for k in todo:
        v = got.get(k)
        if isinstance(v, dict): v = v.get('tr') or v.get('fixed') or v.get('translation')
        err = tr.check(prot_en[k], v)
        if err: print(f'   {k}: fix rejected ({err})'); continue
        nv = tr.restore(v, toks)
        if nv != d[k]: d[k] = nv; applied += 1
    return applied

def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]; do_fix = '--fix' in sys.argv
    en = json.loads((I18N / 'en.json').read_text(encoding='utf-8'))
    codes = args or [p.stem for p in sorted(I18N.glob('*.json')) if p.stem != 'en']
    total = 0
    for code in codes:
        path = I18N / f'{code}.json'; d = json.loads(path.read_text(encoding='utf-8'))
        for rnd in range(3 if do_fix else 1):
            issues = audit(code, en, d)
            if not issues: break
            if not do_fix or rnd == 2: break
            n = fix(code, en, d, issues)
            print(f'{code}: round {rnd + 1}: {len(issues)} issues, {n} entries changed')
        kinds = collections.Counter(i[0] for i in issues)
        total += len(issues)
        print(f'{code}: {dict(kinds) if issues else "clean"}')
        if do_fix:
            d['_meta']['audit'] = {'remaining': [[i[0], i[1], i[2][:120]] for i in issues], 'date': __import__("time").strftime('%Y-%m-%d')}
            path.write_text(json.dumps(d, ensure_ascii=False, indent=0), encoding='utf-8')
    print(f'total remaining issues: {total}')
    if do_fix: print(f"usage: {tr.USAGE['calls']} calls · ${tr.USAGE['cost']:.3f} (OpenRouter-reported)")

if __name__ == '__main__':
    main()
