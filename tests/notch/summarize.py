#!/usr/bin/env python3
"""Summarize notch-guard driver reports into a Markdown matrix.
   python3 tests/notch/summarize.py <results-dir> [--expect]"""
import json, os, sys

# Expected cold-load decision for each fixture (None = documented limitation, not scored).
EXPECT = {
    'fixed-centered-nav': True, 'centered-search': True, 'no-overlap-header': False,
    'sticky-nav': True,  # predicted at load: the sub-nav will stick under the housing
    'absolute': True, 'spa': True,  # engaged after the post-load SPA mutation (decided ≥ 2500 ms)
    'shadow-dom': True, 'shadow-dom-closed': None, 'hero-link': False, 'fixed-title': True,
    'iframe-ad': False, 'late-header': True, 'responsive': True,
}
LATE = {}

def shift_after_fcp(page):
    """ms between first contentful paint and a viewport-height change, i.e. a
    visible shift caused by the guard during load (None = no shift)."""
    if not page: return None
    fcp = page.get('fcp')
    hs = [t for t, _ in page.get('heights') or []]
    if fcp is None or not hs: return None
    after = [t - fcp for t in hs if t >= fcp]
    return after[0] if after else None

def hitlabel(page):
    hits = (page or {}).get('firstHits') or []
    if not hits: return '—'
    h = hits[0]
    return f"{h['kind']} <{h['tag']}{'#'+h['id'] if h.get('id') else ''}> {h.get('position','')}" + (f" {len(hits)}×" if len(hits) > 1 else '')

def main():
    d = sys.argv[1]
    rows = []
    for f in sorted(os.listdir(d)):
        if not f.endswith('.json'): continue
        r = json.load(open(os.path.join(d, f)))
        name = r['name']; cold = r.get('cold') or {}; warm = r.get('warm') or {}
        cp = cold.get('page') or {}; wp = warm.get('page') or {}
        sc = r.get('scroll') or {}; ck = r.get('click') or {}
        res = ck.get('result') or {}
        click = 'skipped' if 'skipped' in ck else (('✓' if res.get('reachedTarget') else '✗') + f" {ck.get('target',{}).get('tag','?')} ({ck.get('why','')})")
        if ck.get('typing'): click += ' · typed ' + ('✓' if ck['typing'].get('ok') else '✗')
        s = shift_after_fcp(cp)
        cold_shift = 'none' if s is None else f'{s} ms'
        wshift = shift_after_fcp(wp)
        warm_first = wp.get('firstLayoutHeight'); warm_ins = warm.get('insetTop')
        warm_txt = f"inset {warm_ins:g} · " if warm_ins is not None else ''
        warm_txt += 'no shift' if wshift is None else f'shift {wshift} ms'
        sp = sc.get('page') or {}
        if not sc.get('scrolled') and sc.get('scrollable') is False:
            scroll = 'n/a (page not scrollable)'
        else:
            scroll = ('✓' if sc.get('scrolled') else '✗') + f" y={int(sc.get('scrollYAfter') or 0)}"
        if sc.get('engagedAfter') != sc.get('engagedBefore'): scroll += f" (engaged {sc.get('engagedBefore')}→{sc.get('engagedAfter')})"
        extra = []
        for k in ('zoom', 'unzoom', 'resized', 'restored'):
            if k in r: extra.append(f"{k}:{'on' if r[k].get('engaged') else 'off'}")
        exp = EXPECT.get(name)
        engaged = cold.get('engaged')
        ok = '' if '--expect' not in sys.argv else ('n/a' if exp is None else ('PASS' if engaged == exp else 'FAIL'))
        if '--expect' in sys.argv and name in LATE:
            late_ok = (LATE[name] == 'scroll' and sc.get('engagedAfter')) or (LATE[name] == 'mutation' and warm.get('engaged'))
            ok = 'PASS' if engaged == exp and late_ok else 'FAIL'
        rows.append([name, ('**on**' if engaged else 'off'), hitlabel(cp),
                     str(cp.get('decidedAt', '—')), str(cp.get('fcp', '—')), cold_shift, warm_txt, click, scroll,
                     f"{cp.get('evals', 0)} / {cp.get('avgEvalMs', 0)} / {cp.get('maxEvalMs', 0)}",
                     ' '.join(extra) or '', cold.get('title', '')[:28].replace('|', '/'), ok, r.get('error', '')])
    hdr = ['page', 'inset (cold)', 'trigger', 'decided ms', 'FCP ms', 'shift after FCP', 'warm visit',
           'native click/keys', 'native scroll', 'evals / avg / max ms', 'zoom/resize', 'title', 'expect', 'error']
    print('| ' + ' | '.join(hdr) + ' |'); print('|' + '---|' * len(hdr))
    for r in rows: print('| ' + ' | '.join(x if x else '' for x in r) + ' |')

main()
