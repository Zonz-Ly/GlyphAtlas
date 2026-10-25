#!/usr/bin/env python3
"""Additional own-engine conformance checks; CLI only, no external shaper needed."""
import json, random, subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
CLI=ROOT/'.build/gsub-cli';F=ROOT/'Tests/Fixtures'
checks=0

def run(font,text,*options):
    return json.loads(subprocess.check_output([str(CLI),'--font',str(font),'--text',text,*options],timeout=20))
def check(value,reason):
    global checks
    checks+=1
    assert value,reason
for case in json.loads((F/'aat-extra-cases.json').read_text()):
    result=run(F/case['font'],case['text'],'--shape')
    check(result['ok'] and result['glyphs']==case['want'],(case['font'],result))
for case in json.loads((F/'position-cases.json').read_text()):
    result=run(F/case['font'],case['text'],'--shape')
    check(result['ok'] and result['positions']==case['positions'],case['font']+' positioning')
for name,want in [('context-expand',[18,20,21]),('context-delete',[21])]:
    result=run(F/(name+'.ttf'),'ab','--shape','--feature','test')
    check(result['ok'] and result['glyphs']==want,name+' sequence index')
    native=run(F/(name+'.ttf'),'ab','--reference-coretext','--feature','test')
    # CoreText retains its deleted-glyph sentinel in CTRun's raw output.
    check([gid for gid in native['glyphs'] if gid!=65535]==want,name+' independent CoreText oracle')
for axis,offset in [(400,0),(650,100),(900,200)]:
    result=run(F/'pos-variable.ttf','a','--shape','--axis',f'wght={axis}')
    check(result['ok'] and len(result['positions'])==1 and all(abs(a-b)<0.02 for a,b in zip(result['positions'][0],[600,0,offset,0])),'variable GPOS offset')
for axis,offset in [(100,30),(400,40),(900,50)]:
    result=run(F/'pos-feature-variations.ttf','a','--shape','--axis',f'wght={axis}')
    check(result['ok'] and len(result['positions'])==1 and all(abs(a-b)<0.02 for a,b in zip(result['positions'][0],[600,0,offset,0])),'GPOS FeatureVariations condition selection')
for font in ('unencoded-neighbor.ttf','morx-unencoded-neighbor.ttf','mort-unencoded-neighbor.ttf'):
    text='ab' if font.startswith('unencoded') else 'ai'
    plain=run(F/font,text)
    check(not any(m['glyphs']==[22] for m in plain['matches']),'ordinary text does not reach unencoded rule')
    literal=run(F/font,text,'--seed','0:1=19')
    check(any(m['glyphs']==[22] and m['range']==[0,2] for m in literal['matches']),'literal seed crosses into neighbor')
for glyph,want in [(2,None),(3,20)]:
    check(run(F/'vertical-only.ttf','','--vertical',str(glyph))['glyph']==want,'vertical lookup excludes ccmp and finds kana script')
check(run(F/'morx4.ttf','','--vertical','2')['glyph'] is None,'horizontal stylistic AAT is not a vertical form')
check(run(F/'morx-vertical-only.ttf','','--vertical','2')['glyph']==18,'vertical-only AAT form')
random.seed(1729)
texts=[''.join(random.choices('abcdefilnorstuvyzAWQ -',k=random.randint(1,45))) for _ in range(70)]
texts+=['office affinity affluent waffle staff flower Swift Objective-C','Áéa\u0301 ffi fi f\u0301fi','ffi'*12,'fj fffl ft ct ck st TT Th Ch']
real=[]
for name,font in [('Zapfino','/System/Library/Fonts/Supplemental/Zapfino.ttf'),('LucidaSubmono','/Users/zonz/Library/Fonts/LucidaSubmono.otf')]:
    if not Path(font).exists():continue
    compared=0;fallback=0
    for text in texts:
        own=run(font,text,'--shape');native=run(font,text,'--reference-coretext')
        check(own['ok'],(name,text,own))
        if native['fallback']:
            fallback+=1
            continue
        check(own['glyphs']==native['glyphs'],(name,text,own,native))
        compared+=1
    check(not run(font,'office ffi Objective-C')['diagnostics'],name+' clean discovery diagnostics')
    real.append({'font':name,'strings':compared,'native_fallback_excluded':fallback})
for kind in ('truncated','bad-offset'):
    result=run(F/('malformed-'+kind+'.ttf'),'ab')
    check(bool(result['diagnostics']),'malformed '+kind+' emits diagnostics')
report={'assertions':checks,'position_fixtures':len(json.loads((F/'position-cases.json').read_text())),'real_fonts':real}
(ROOT/'.build/own-layout-results.json').write_text(json.dumps(report,indent=2)+'\n')
print('OK:',checks,'additional layout assertions; GPOS 1–9, variable positioning, nested edits, real-font differential')
