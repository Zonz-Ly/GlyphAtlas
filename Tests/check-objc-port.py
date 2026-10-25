#!/usr/bin/env python3
"""One-off language-port comparison against the saved pre-port CLI; no native shaper."""
import json,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
FIXTURES=ROOT/'Tests/Fixtures'
OLD=ROOT/'.build/cpp-reference-cli';NEW=ROOT/'.build/gsub-cli'
if not OLD.exists():
    raise SystemExit('Optional port comparison requires the saved pre-port CLI from a5ebe1a at .build/cpp-reference-cli.')

def output(cli,font,text,options):
    data=json.loads(subprocess.check_output([str(cli),'--font',str(font),'--text',text,*options],timeout=60))
    data.pop('milliseconds',None)
    def normalize(value):
        if isinstance(value,dict):
            return {key:normalize(item) for key,item in value.items()}
        if isinstance(value,list):
            items=[normalize(item) for item in value]
            # Candidate identity/provenance matters; collection iteration order does not.
            if items and isinstance(items[0],dict) and ('glyphs' in items[0] or 'base' in items[0]):
                return sorted(items,key=lambda item:json.dumps(item,sort_keys=True))
            return items
        if isinstance(value,float):return round(value,5)
        return value
    return normalize(data)

cases=[]
for group in ('cases','aat-cases','aat-extra-cases','position-cases'):
    for case in json.loads((FIXTURES/(group+'.json')).read_text()):
        options=['--shape']+(['--feature','test'] if group=='cases' else [])
        cases.append((FIXTURES/case['font'],case['text'],options))
for name,text,options in [
    ('nested.ttf','aby',[]),('context3.ttf','aby',[]),('ignore-marks.ttf','f\u0301i',[]),
    ('ligature.ttf','ffi fi',[]),('feature-variations.ttf','ab',[]),
    ('unencoded-neighbor.ttf','ab',['--seed','0:1=9,19','--model']),
    ('morx-unencoded-neighbor.ttf','ai',['--seed','0:1=9,19','--model']),
    ('mort-unencoded-neighbor.ttf','ai',['--seed','0:1=9,19','--model']),
    ('morx-eot-ligature.ttf','fi fi',[]),('mort-eot-ligature.ttf','fi fi',[])]:
    cases.append((FIXTURES/name,text,options))
for path,text,options in [
    ('/Users/zonz/Library/Fonts/LucidaSubmono.otf','Wi Objective-C',[]),
    ('/System/Library/Fonts/Supplemental/Zapfino.ttf','ffi fi st',[]),
    ('/Users/zonz/Library/Fonts/ThemeX Hiragino Sans.ttc','邊骨漢字',[]),
    ('/Users/zonz/Library/Fonts/Futura100CHI-Var.ttf','QrekӘеж，',['--shape','--axis','wght=300']),
    ('/Users/zonz/Library/Fonts/Futura100CHI-Var.ttf','QrekӘеж，',['--shape','--axis','wght=700'])]:
    if Path(path).exists():cases.append((Path(path),text,options))
failures=[]
for font,text,options in cases:
    before=output(OLD,font,text,options);after=output(NEW,font,text,options)
    if before!=after:failures.append({'font':str(font),'text':text,'options':options,'before':before,'after':after})
report={'cases':len(cases),'differences':failures}
(ROOT/'.build/objc-port-comparison.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
assert not failures,[(Path(case['font']).name,case['text'],case['options']) for case in failures]
print('OK:',len(cases),'pre/post Objective-C port cases; same GIDs, spans, provenance and positions')
