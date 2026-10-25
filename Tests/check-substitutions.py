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
r=run(F/'ignore-base.ttf','a');check(not any(x['glyphs']==[18] for x in r['matches']),'family index respects GDEF flags')
for kind in ('truncated','bad-offset','recursive'):
    r=run(F/('malformed-'+kind+'.ttf'),'aba');check('matches' in r,'malformed table handled safely')

for seed in ('18','19'):
    r=run(F/'alternate.ttf','','--gids',seed)
    check(any(x['glyphs']==[19 if seed=='18' else 18] for x in r['matches']),'alternate-output sibling family')
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
    if name=='Zapfino':
        scan=run(path,'ffi');found={(tuple(x['range']),tuple(x['names'])) for x in scan['matches']}
        check(((0,3),('ffi',)) in found and ((0,2),('ff',)) in found and ((1,2),('fi',)) in found,'Zapfino overlapping ligatures')
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
