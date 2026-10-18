#!/usr/bin/env python3
"""Tag every user-facing string in the megamesh.sh pages with data-i18n keys and emit the English master.

Usage:  python3 tools/i18n_extract.py            (rewrites index.html, deploy/index.html, writes assets/i18n/en.json)

Rules
- A translation unit is an element whose descendants contain no block-level element and whose text has letters.
- Inline children (a, b, strong, em, code, small, span, i, br, svg) are kept as-is inside the unit's innerHTML.
- Attributes title / aria-label / placeholder / alt become units too (data-i18n-attrs="title:key,aria-label:key").
- <title> and meta description / og:* become m.* keys applied at runtime.
- Skip: aria-hidden decoration, pure code/numbers, brand names, anything with data-i18n-skip.
- JS strings (ui.js, deploy.js) are listed by hand in JS_STRINGS below and emitted as j.* keys.
"""
import json, re, sys, pathlib
from bs4 import BeautifulSoup, NavigableString, Tag
from bs4.formatter import HTMLFormatter

class Keep(HTMLFormatter):
    def __init__(self): super().__init__(entity_substitution=None)
    def attributes(self, tag): return list(tag.attrs.items())


ROOT = pathlib.Path(__file__).resolve().parent.parent
BLOCK = {'div','p','h1','h2','h3','h4','h5','h6','ul','ol','li','section','form','fieldset','label','button','nav',
         'header','footer','main','table','tr','td','th','textarea','input','select','legend','details','summary','blockquote','pre','dl','dt','dd'}
ATTRS = ('title', 'aria-label', 'placeholder', 'alt')
SKIP_TEXT = {'megamesh.sh','PROMPT.md','MIT','GitHub','LinkedIn','megastack.sh','Paul Fleury','PF','paulfleury.network','egress.json',
             'EN','script','agent','status','~/megamesh','—','0','3','1 GB','8–12','5–6','01','02','03','04','05','06','07','ssh · wireguard · https',
             'ssh · wg · https','wg + ssh + web + docker leaks','megamesh .sh','megamesh.sh · MIT','151.243.225.214','hi@megastack.sh','22','@','00:00','SSH','TLS','megamesh.sh · MIT',
             'curl -fsSLO https://megamesh.sh/megamesh.sh','https://','/root/megamesh-admin-credentials','DROP','IPv4'}
HAS_LETTERS = re.compile(r'[A-Za-z]{2,}')

def has_direct_text(el: Tag) -> bool:
    return any(isinstance(c, NavigableString) and HAS_LETTERS.search(str(c)) for c in el.contents)

def is_unit(el: Tag) -> bool:
    if el.name in ('script','style','svg','path','circle','rect','defs','linearGradient','stop','input','textarea','i','img','br','meta','link','title','head','html','body'):
        return False
    if el.has_attr('data-i18n-unit'):
        return True
    if el.has_attr('data-i18n-skip') or el.find_parent(attrs={'data-i18n-skip': True}) is not None:
        return False
    if any(d.name in BLOCK for d in el.find_all(True)):
        return False
    txt = el.get_text(' ', strip=True)
    if not txt or not HAS_LETTERS.search(txt) or txt in SKIP_TEXT:
        return False
    if el.name == 'code' or (el.get('class') and 'mono' in el.get('class')):
        return False
    # a wrapper with no text of its own around links/buttons: let the children be the units
    if not has_direct_text(el) and el.find_all(['a', 'button']):
        return False
    return True

def inner_html(el: Tag) -> str:
    h = ''.join(c.decode(formatter=Keep()) if isinstance(c, Tag) else str(c) for c in el.contents).strip()
    for a, b in (('viewbox=', 'viewBox='), ('preserveaspectratio=', 'preserveAspectRatio=')):
        h = h.replace(a, b)
    return h

def process(path: pathlib.Path, prefix: str, master: dict, loose: list):
    html = path.read_text(encoding='utf-8')
    soup = BeautifulSoup(html, 'html.parser')
    n = 0
    # head: title + metas
    t = soup.find('title')
    if t: master[f'm.{prefix}.title'] = t.get_text(strip=True)
    for m in soup.find_all('meta'):
        name = m.get('name') or m.get('property')
        if name in ('description','og:title','og:description') and m.get('content'):
            master[f'm.{prefix}.{name.replace(":", "_")}'] = m['content']
    body = soup.body
    used = set(re.findall(rf'data-i18n="({prefix}\.\d+)"', html)) | {k for pair in re.findall(r'data-i18n-attrs="([^"]+)"', html) for k in re.findall(rf'{prefix}\.\d+', pair)}
    nums = [int(k.split('.')[1]) for k in used]
    nxt = max(nums) + 1 if nums else 1
    def fresh():
        nonlocal nxt
        k = f'{prefix}.{nxt:03d}'; nxt += 1; return k
    # walk in document order; existing keys are kept so translations stay attached to their element
    for el in body.find_all(True):
        if el.has_attr('data-i18n'):
            n += 1; master[el['data-i18n']] = inner_html(el); continue
        if is_unit(el):
            if el.find_parent(attrs={'data-i18n': True}):
                continue
            n += 1
            key = fresh()
            el['data-i18n'] = key
            master[key] = inner_html(el)
    # second pass: attributes
    for el in body.find_all(True):
        have = dict(p.split(':') for p in el.get('data-i18n-attrs', '').split(',') if ':' in p)
        pairs = []
        for a in ATTRS:
            v = el.get(a)
            if v and HAS_LETTERS.search(v) and v not in SKIP_TEXT:
                key = have.get(a) or fresh()
                master[key] = v
                pairs.append(f'{a}:{key}')
        if pairs:
            el['data-i18n-attrs'] = ','.join(pairs)
    # report loose text nodes not inside a unit (block elements with direct text)
    for el in body.find_all(True):
        if el.name in BLOCK and not el.has_attr('data-i18n') and not el.find_parent(attrs={'data-i18n': True}):
            for c in el.contents:
                if isinstance(c, NavigableString) and HAS_LETTERS.search(str(c)) and not isinstance(c, type(soup.comment)) if hasattr(soup,'comment') else isinstance(c, NavigableString) and HAS_LETTERS.search(str(c)):
                    s = str(c).strip()
                    if s and s not in SKIP_TEXT and not s.startswith('<!--'):
                        loose.append((path.name, el.name, s[:80]))
    out = soup.decode(formatter=Keep()).replace('<!DOCTYPE html>\n\n', '<!doctype html>\n', 1)
    for a, b in (('viewbox=', 'viewBox='), ('preserveaspectratio=', 'preserveAspectRatio='), ('lineargradient', 'linearGradient')):
        out = out.replace(a, b)
    path.write_text(out, encoding='utf-8')
    return n

JS_RE = re.compile(r"""(?:(?:\bt|MM\.t)\(|\[)\s*'(j\.[a-z0-9_.]*)'\s*,\s*'((?:[^'\\]|\\.)*)'""")

def js_strings() -> dict:
    """Every t('key', 'English fallback') / MM.t(...) in the two scripts. The fallback is the English master."""
    out = {}
    for f in (ROOT / 'assets' / 'ui.js', ROOT / 'deploy' / 'deploy.js'):
        for k, v in JS_RE.findall(f.read_text(encoding='utf-8')):
            v = v.replace("\\'", "'")
            if k in out and out[k] != v:
                print(f'WARNING: {k} has two different fallbacks', file=sys.stderr)
            out[k] = v
    return out

def main():
    master = {}
    loose = []
    a = process(ROOT / 'index.html', 'i', master, loose)
    b = process(ROOT / 'deploy' / 'index.html', 'd', master, loose)
    JS_STRINGS = js_strings()
    master.update(JS_STRINGS)
    (ROOT / 'assets' / 'i18n').mkdir(exist_ok=True)
    (ROOT / 'assets' / 'i18n' / 'en.json').write_text(json.dumps(master, ensure_ascii=False, indent=1), encoding='utf-8')
    print(f'index: {a} units · deploy: {b} units · js: {len(JS_STRINGS)} · total {len(master)}')
    if loose:
        print('LOOSE TEXT (not covered):')
        for l in loose: print('  ', l)

if __name__ == '__main__':
    main()
