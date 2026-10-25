#!/usr/bin/env python3
"""CLI-only conformance, discovery, literal-GID, range and real-font checks.
Committed fixtures are original fonts, so normal runs need only Python stdlib.
CoreText is an independent test oracle, never a production discovery fallback.
"""
import json, os, subprocess, time
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
CLI=ROOT/'.build/gsub-cli'
F=ROOT/'Tests/Fixtures'
checks=0;report={'fixtures':[],'real_fonts':[],'benchmarks':[]}
def run(font,text='',*options):
    return json.loads(subprocess.check_output([str(CLI),'--font',str(font),'--text',text,*options],timeout=60))
def check(value,message):
    global checks
    checks+=1
    if not value:raise AssertionError(message)
def utf16(s):return len(s.encode('utf-16-le'))//2
cmap={ord(c):i for c,i in zip('abcdefixyzAB',[2,3,4,5,6,7,8,9,10,11,12,13])};cmap.update({32:1,0x301:14,0x627:15,0x628:16,0x1f600:17,0xe000:18})
def clusters(shaped,text):
    result={};starts=sorted(set(shaped['clusters']))
    ends=dict(zip(starts,starts[1:]+[utf16(text)]))
    for gid,start in zip(shaped['glyphs'],shaped['clusters']):result.setdefault((start,ends[start]-start),[]).append(gid)
    return result
for group in ('cases','aat-cases'):
    for c in json.loads((F/(group+'.json')).read_text()):
        font=F/c['font'];options=['--feature','test'] if group=='cases' else []
        shaped=run(font,c['text'],'--shape',*options)
        check(shaped['ok'] and shaped['names']==c['want'],c['font']+' execution')
        scan=run(font,c['text']);found={(tuple(m['range']),tuple(m['glyphs'])) for m in scan['matches']}
        for r,g in clusters(shaped,c['text']).items():check((r,tuple(g)) in found,c['font']+' discovery '+str((r,g)))
        if not shaped['glyphs']:check(((0,utf16(c['text'])),()) in found,'explicit deletion')
        gids=[cmap[ord(char)] for char in c['text']]
        seed=run(font,'','--gids',','.join(map(str,gids)))
        check(any(m['glyphs']==shaped['glyphs'] for m in seed['matches']),c['font']+' full literal GID seed')
        if group=='aat-cases':
            off=run(font,c['text'],'--shape','--branch','2')
            check(off['glyphs']==gids,c['font']+' selector disable flags')
            for r,g in clusters(off,c['text']).items():check((r,tuple(g)) in found,c['font']+' disabled selector discovery')
        report['fixtures'].append(c['font'])
print('OK: all GSUB types/formats and morx/mort subtable types 0/1/2/4/5',flush=True)
r=run(F/'nested-alternate.ttf','ab','--shape','--feature','test=2');check(r['glyphs']==[19,3],'nested alternate value two')
r=run(F/'nested-alternate.ttf','ab');check(any(x['glyphs']==[19] and x['range']==[0,1] for x in r['matches']),'discovers second nested alternate')
# Context inventory belongs to the affected glyph, independent of typed witnesses.
for name in ('chain1','chain2','chain3'):
    r=run(F/(name+'.ttf'),'b')
    check(any(m['glyphs']==[20] and m['sources']==['test'] for m in r['matches']),name+' context-free affected glyph')
    check(not any(m['glyphs']==[20] for m in run(F/(name+'.ttf'),'a')['matches']),name+' excludes neighboring output')
    check(run(F/(name+'.ttf'),'aby','--shape','--feature','test')['glyphs']==[2,3,10],name+' catalogue does not change actual execution')
for name in ('context-expand','context-delete'):
    check(any(m['glyphs']==[21] and 'test' in m['sources'] for m in run(F/(name+'.ttf'),'b')['matches']),name+' catalogue follows shifted sequence index')
r=run(F/'nested-alternate.ttf','a')
check(any(m['glyphs']==[19] and m['sources']==['test 2'] for m in r['matches']),'nested alternate without neighboring text')
r=run(F/'reverse.ttf','a')
check(any(m['glyphs']==[18] and m['sources']==['test'] for m in r['matches']),'reverse context without neighboring text')
# Ligatures, unlike per-glyph contextual forms, require every consumed input.
for name in ('ligature','extension'):
    for text in ('f','i','ff','fi'):
        check(not any(m['glyphs']==[23] for m in run(F/(name+'.ttf'),text)['matches']),name+' incomplete ligature '+text)
    r=run(F/(name+'.ttf'),'ffi')
    check(any(m['glyphs']==[23] and m['range']==[0,3] for m in r['matches']),name+' complete ligature input')
    check(not any(m['glyphs']==[23] and m['range'][1]<3 for m in r['matches']),name+' no ligature on an individual component')
for name in ('morx2','mort2'):
    for text in ('f','i'):
        check(not any(m['glyphs']==[22] for m in run(F/(name+'.ttf'),text)['matches']),name+' incomplete ligature '+text)
    check(any(m['glyphs']==[22] and m['range']==[0,2] for m in run(F/(name+'.ttf'),'fi')['matches']),name+' full ligature input')
for ids in ('7','8','7,7','7,8'):
    check(not any(m['glyphs']==[23] for m in run(F/'ligature.ttf','','--gids',ids)['matches']),'literal ligature requires full sequence '+ids)
check(any(m['glyphs']==[23] for m in run(F/'ligature.ttf','','--gids','7,7,8')['matches']),'full literal sequence yields ligature')
r=run(F/'unencoded-neighbor.ttf','ab','--seed','0:1=19')
check(any(m['glyphs']==[22] and m['range']==[0,2] and m['sources']==['liga'] for m in r['matches']),'default ligature retains actual feature provenance')
r=run(F/'ignore-base.ttf','a');check(not any(x['glyphs']==[18] for x in r['matches']),'family index respects GDEF flags')
for kind in ('truncated','bad-offset','recursive'):
    r=run(F/('malformed-'+kind+'.ttf'),'aba');check('matches' in r,'malformed table handled safely')

for seed in ('18','19'):
    r=run(F/'alternate.ttf','','--gids',seed)
    check(any(x['glyphs']==[19 if seed=='18' else 18] for x in r['matches']),'alternate-output sibling family')
r=run(F/'alternate.ttf','ab','--seed','0:1=9,19')
check(any(m['glyphs']==[9,18] and m['range']==[0,1] and m['sources']==['test'] for m in r['matches']),'multi-GID text seed preserves prefix while finding alternate sibling')
r=run(F/'alternate.ttf','a');check(any(x['names']==['a.alt2'] and 'test 2' in x['sources'] for x in r['matches']),'all alternate indices')
for axis in (100,400,900):
    r=run(F/'feature-variations.ttf','a','--axis',f'wght={axis}')
    check({18,19,20,21}<={x['glyphs'][0] for x in r['matches'] if x['glyphs']},'union of all three FeatureVariations branches')
    for branch,want in enumerate([18,19,20,21]):check(run(F/'feature-variations.ttf','a','--shape','--feature','test','--branch',str(branch),'--axis',f'wght={axis}')['glyphs']==[want],'forced FV branch')
r=run(F/'position.ttf','á','--positions','2,14');check(r['positions']==[[0,0],[40,20]],'literal GPOS mark attachment')
r=run(F/'plain.ttf','אב','--positions','15,16');check(len(r['positions'])==2,'RTL literal identity')
r=run(F/'ligature.ttf','😀ffi😀ffi');check(any(x['glyphs']==[23] and x['range']==[2,3] for x in r['matches']) and any(x['glyphs']==[23] and x['range']==[7,3] for x in r['matches']),'supplementary UTF-16 positions')
for n in (100,1000):
    r=run(F/'plain.ttf',''.join(chr(0x4e00+i) for i in range(n)),'--model');check(r['tasks']==n+1,'paragraph task count');report['benchmarks'].append({'font':'plain fixture','characters':n,'tasks':r['tasks'],'milliseconds':r['milliseconds']})
# These paths match this machine but can be overridden for another installation.
fonts=[('Hiragino Sans',os.environ.get('GA_HIRAGINO','/Users/zonz/Library/Fonts/ThemeX Hiragino Sans.ttc'),[('邊',['--feature','aalt=2']),('骨令0',['--feature','aalt=1']),('漢字',['--feature','jp78=1'])]),('LucidaSubmono',os.environ.get('GA_LUCIDA','/Users/zonz/Library/Fonts/LucidaSubmono.otf'),[(x,[]) for x in ['Objective-C','IlMWrt','MWMW','Hello world']]),('Zapfino',os.environ.get('GA_ZAPFINO','/System/Library/Fonts/Supplemental/Zapfino.ttf'),[(x,[]) for x in ['ffi fi st','office affine flower','Zapfino','ffl fl ct']])]
for name,path,cases in fonts:
    if not Path(path).exists():report['real_fonts'].append({'font':name,'skipped':'not installed'});continue
    results=[]
    for text,options in cases:
        shaped=run(path,text,'--shape',*options);ct=run(path,text,'--reference-coretext',*options)
        check(shaped['glyphs']==ct['glyphs'],name+' CoreText reference '+text)
        scan=run(path,text);found={(tuple(m['range']),tuple(m['glyphs'])) for m in scan['matches']}
        for r,g in clusters(shaped,text).items():check((r,tuple(g)) in found,name+' discovers reference output '+str((r,g)))
        results.append({'text':text,'glyphs':shaped['glyphs'],'names':shaped['names'],'milliseconds':scan['milliseconds']})
    if name=='Hiragino Sans':
        scan=run(path,'邊');spec=next(x for x in scan['features'] if x['tag']=='aalt');found={tuple(x['glyphs']) for x in scan['matches']}
        # Check every declared aalt selector against execution, not just a sample.
        for index in range(1,spec['max']+1):check(tuple(run(path,'邊','--shape','--feature',f'aalt={index}')['glyphs']) in found,'Hiragino aalt '+str(index))
    if name=='LucidaSubmono':
        w=run(path,'W');i=run(path,'i');wi=run(path,'Wi')
        wforms={n for m in w['matches'] for n in m['names']}
        check({'W.w0','W.w1'}<=wforms and 'i.t1' not in wforms and 'W.w2' not in wforms,'W catalogue contains only its own contextual forms')
        check(not any(n.startswith('W.') for m in i['matches'] for n in m['names']),'i catalogue excludes W forms')
        check(all(m['sources']==['calt'] for m in w['matches'] if m['names'] in (['W.w0'],['W.w1'])),'context catalogue preserves calt')
        for names in (['W.w1'],['i.t1']):
            check(any(m['names']==names and m['sources']==['calt'] for m in wi['matches']),'default Wi preserves calt rather than synthetic actual')
        model=run(path,'Wi','--model')
        check(any(v['names']==['W.w1'] and v['sources']==['calt'] for g in model['groups'] for v in g['variants']),'production model preserves base feature provenance')
    if name=='Zapfino':
        scan=run(path,'ffi');found={(tuple(x['range']),tuple(x['names'])) for x in scan['matches']}
        check(((0,3),('ffi',)) in found and ((0,2),('ff',)) in found and ((1,2),('fi',)) in found,'Zapfino overlapping ligatures')
        for text in ('f','i'):
            check(not any(m['names']==['fi'] for m in run(path,text)['matches']),'Zapfino fi needs both components '+text)
        check(any(m['names']==['fi'] and m['range']==[0,2] for m in run(path,'fi')['matches']),'Zapfino fi appears for the complete input')
    text=('Objective-C IlMWrt '*10 if name=='LucidaSubmono' else 'office affine flower '*5 if name=='Zapfino' else '漢字邊骨令零'*10)
    model=run(path,text,'--model');report['benchmarks'].append({'font':name,'characters':len(text),'tasks':model['tasks'],'milliseconds':model['milliseconds']})
    report['real_fonts'].append({'font':name,'path':path,'cases':results});print('OK:',name,'reference, discovery and paragraph model',flush=True)
# The selected CTFont resource supplies its own table bytes inside a TTC.
for face,want in [(0,[18]),(1,[18,20])]:check(run(F/'multi-vf.ttc','a','--face',str(face),'--shape','--feature','test')['glyphs']==want,'multiple VF resources in TTC')
for face,want in [(0,[7,7,8]),(1,[23])]:check(run(F/'static-resources.ttc','ffi','--face',str(face),'--shape','--feature','test')['glyphs']==want,'static TTC resources')
vf=Path(os.environ.get('GA_FUTURA','/Users/zonz/Library/Fonts/Futura100CHI-Var.ttf'))
if vf.exists():
    text='QrekӘеж，';signatures=[];shapes=[]
    for weight in (300,400,700):
        scan=run(vf,text,'--axis',f'wght={weight}')
        signatures.append({(tuple(m['range']),tuple(m['glyphs'])) for m in scan['matches']})
        check(any('k.jump' in m['names'] for m in scan['matches']),'Futura conditional k')
        check(any('uni04D8.jump' in m['names'] for m in scan['matches']),'Futura conditional Cyrillic')
    check(signatures[0]==signatures[1]==signatures[2],'real VF discovery union remains invariant across axes')
    for branch in range(4):
        shaped=run(vf,text,'--shape','--branch',str(branch));shapes.append(shaped['glyphs'])
        for r,g in clusters(shaped,text).items():check((r,tuple(g)) in signatures[0],'real FV branch result is discoverable')
    check(len({tuple(s) for s in shapes})>=3,'real VF exercises distinct branches')
    report['real_fonts'].append({'font':'Futura100CHI-Var','path':str(vf),'text':text,'branch_glyphs':shapes,'axis_union_invariant':True})
    print('OK: Futura100CHI-Var three actual FeatureVariations records and axis-invariant union',flush=True)
report['assertions']=checks
out=ROOT/'.build/substitution-results.json';out.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(f'OK: {checks} assertions; results: {out}')
