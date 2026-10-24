#!/usr/bin/env python3
"""Deterministic, original test fonts. Requires fontTools (tests only).
Every GSUB format is assembled explicitly, so the compiler cannot silently
choose a different format and leave a branch of our range index untested.
"""
import json, struct
from pathlib import Path
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import newTable
from fontTools.ttLib.tables.DefaultTable import DefaultTable
from fontTools.ttLib.tables._f_v_a_r import Axis, NamedInstance
P=Path(__file__).parent/'Fixtures'; P.mkdir(exist_ok=True)
u16=lambda *v:struct.pack('>'+'H'*len(v),*v)
u32=lambda *v:struct.pack('>'+'I'*len(v),*v)
names=['.notdef','space','a','b','c','d','e','f','i','x','y','z','A','B','acutecomb','alef','beh','smile','a.alt','a.alt2','b.alt','c.alt','f_i','f_f_i']
gid={n:i for i,n in enumerate(names)}
G=lambda *n:u16(*(gid[x] for x in n))
def cov(*n):return u16(1,len(n))+G(*n)
def cdef(mapping):return u16(2,len(mapping))+b''.join(u16(gid[k],gid[k],v) for k,v in sorted(mapping.items(),key=lambda kv:gid[kv[0]]))
def single(src='a',dst='a.alt',fmt=2):
    return (u16(1,6,(gid[dst]-gid[src])&65535) if fmt==1 else u16(2,8,1)+G(dst))+cov(src)
def sequence(out):return u16(1,8,1,14)+cov('a')+u16(len(out))+G(*out)
def alternate():return u16(1,8,1,14)+cov('a')+u16(2)+G('a.alt','a.alt2')
def ligature():return u16(1,8,1,14)+cov('f')+u16(1,4)+G('f_f_i')+u16(3)+G('f','i')
def context(fmt):
    # a b -> a b.alt, nested lookup 1 at input index 1
    rule=u16(2,1)+G('b')+u16(1,1)
    if fmt==1:return u16(1,8,1,14)+cov('a')+u16(1,4)+rule
    if fmt==2:
        cls=cdef({'a':1,'b':2}); rule=u16(2,1,2,1,1); sets=u16(1,4)+rule
        head=u16(2,12,18,2,0,18+len(cls));return head+cov('a')+cls+sets
    return u16(3,2,1,14,20,1,1)+cov('a')+cov('b')
def chain(fmt):
    # x a b y -> x a b.alt y (one before, two input, one after)
    rule=u16(1)+G('x')+u16(2)+G('b')+u16(1)+G('y')+u16(1,1,1)
    if fmt==1:return u16(1,8,1,14)+cov('a')+u16(1,4)+rule
    if fmt==2:
        back=cdef({'x':1}); inp=cdef({'a':1,'b':2}); look=cdef({'y':1})
        headlen=16;covpos=headlen;backpos=covpos+6;inpos=backpos+len(back);lookpos=inpos+len(inp);setpos=lookpos+len(look)
        rule=u16(1,1,2,2,1,1,1,1,1)
        return u16(2,covpos,backpos,inpos,lookpos,2,0,setpos)+cov('a')+back+inp+look+u16(1,4)+rule
    return u16(3,1,22,2,28,34,1,40,1,1,1)+cov('x')+cov('a')+cov('b')+cov('y')
def reverse():return u16(1,16,1,22,1,28,1)+G('a.alt')+cov('a')+cov('x')+cov('y')
def extension(typ,sub):return u16(1,typ)+u32(8)+sub
def lookup(typ,sub,flags=0,markset=0):return u16(typ,flags,1,10 if flags&16 else 8)+(u16(markset) if flags&16 else b'')+sub
def gsub(lookups,features=None,fv=False):
    features=features or [('test',[0])]
    lang=u16(0,65535,len(features),*range(len(features)))
    scripts=u16(1)+b'DFLT'+u16(8)+u16(4,0)+lang
    records=b'';ft=b''
    for tag,idx in features:
        records+=tag.encode()+u16(2+6*len(features)+len(ft));ft+=u16(0,len(idx),*idx)
    fl=u16(len(features))+records+ft
    ll=u16(len(lookups));o=2+len(lookups)*2
    for l in lookups:ll+=u16(o);o+=len(l)
    ll+=b''.join(lookups)
    head=14 if fv else 10
    result=u32(0x10001 if fv else 0x10000)+u16(head,head+len(scripts),head+len(scripts)+len(fl))
    if fv:result+=u32(head+len(scripts)+len(fl)+len(ll))
    result+=scripts+fl+ll
    if fv:
        # Three disjoint ranges. Alternate feature tables point at lookup 1..3.
        payload=b'';records=b'';base=8+3*8
        for i,(lo,hi) in enumerate([(-16384,-4000),(-3000,3000),(4000,16384)]):
            condition=u16(1)+u32(6)+u16(1,0,lo&65535,hi&65535)
            alt=u16(1,0,1,0)+u32(12)+u16(0,1,i+1)
            records+=u32(base+len(payload),base+len(payload)+len(condition));payload+=condition+alt
        result+=u16(1,0)+u32(3)+records+payload
    return result

def font(name,table,variable=False,gdef=None,position=False,aat=None):
    fb=FontBuilder(1000,isTTF=True);fb.setupGlyphOrder(names)
    cmap={ord(x):x for x in 'abcdefixyzAB'};cmap.update({32:'space',0x301:'acutecomb',0x627:'alef',0x628:'beh',0x1f600:'smile',0xe000:'a.alt'})
    fb.setupCharacterMap(cmap);glyphs={}
    for n in names:
        pen=TTGlyphPen(None)
        if n!='space':pen.moveTo((40,0));pen.lineTo((500,0));pen.lineTo((500,700));pen.lineTo((40,700));pen.closePath()
        glyphs[n]=pen.glyph()
    fb.setupGlyf(glyphs);fb.setupHorizontalMetrics({n:(0 if n=='acutecomb' else 600,0) for n in names});fb.setupHorizontalHeader(ascent=800,descent=-200)
    fb.setupNameTable({'familyName':'GA GSUB '+name,'styleName':'Regular','uniqueFontIdentifier':'GA GSUB '+name,'fullName':'GA GSUB '+name,'psName':'GAGSUB-'+name})
    fb.setupOS2(sTypoAscender=800,sTypoDescender=-200,usWinAscent=800,usWinDescent=200);fb.setupPost();fb.setupMaxp()
    if table is not None:t=DefaultTable('GSUB');t.data=table;fb.font['GSUB']=t
    if gdef is not None:t=DefaultTable('GDEF');t.data=gdef;fb.font['GDEF']=t
    if aat is not None:tag,data=aat;t=DefaultTable(tag);t.data=data;fb.font[tag]=t
    if position:
        from fontTools.feaLib.builder import addOpenTypeFeaturesFromString
        # Preserve the hand-built GSUB; this source adds positioning only.
        addOpenTypeFeaturesFromString(fb.font,'languagesystem DFLT dflt; markClass acutecomb <anchor 100 600> @TOP; feature mark { pos base a <anchor 300 700> mark @TOP; } mark;')
    if variable:
        fb.font['fvar']=fvar=newTable('fvar');axis=Axis();axis.axisTag='wght';axis.minValue=100;axis.defaultValue=400;axis.maxValue=900;axis.flags=0;axis.axisNameID=256;fvar.axes=[axis];fvar.instances=[]
        fb.font['name'].setName('Weight',256,3,1,0x409)
        fb.font['gvar']=gvar=newTable('gvar');gvar.variations={n:[] for n in names}
        from fontTools.ttLib.tables.TupleVariation import TupleVariation
        gvar.variations['a.alt']=[TupleVariation({'wght':(0,1,1)},[(0,0)]*4+[(0,0),(200,0),(0,0),(0,0)])]
    fb.font['head'].created=fb.font['head'].modified=2082844800
    fb.font.recalcTimestamp=False
    fb.font.save(P/(name+'.ttf'))

cases=[]
def case(name,lookups,text,want,**kw):
    font(name,gsub(lookups,kw.pop('features',None)),**kw);cases.append({'font':name+'.ttf','text':text,'want':want})
for fmt in (1,2):case('single'+str(fmt),[lookup(1,single(fmt=fmt))],'a',['a.alt'])
case('multiple',[lookup(2,sequence(['a.alt','b.alt']))],'a',['a.alt','b.alt'])
case('deletion',[lookup(2,sequence([]))],'a',[])
case('alternate',[lookup(3,alternate())],'a',['a.alt'])
case('ligature',[lookup(4,ligature())],'ffi',['f_f_i'])
for fmt in (1,2,3):
    case('context'+str(fmt),[lookup(5,context(fmt)),lookup(1,single('b','b.alt'))],'ab',['a','b.alt'])
    case('chain'+str(fmt),[lookup(6,chain(fmt)),lookup(1,single('b','b.alt'))],'xaby',['x','a','b.alt','y'])
case('extension',[lookup(7,extension(4,ligature()))],'ffi',['f_f_i'])
case('reverse',[lookup(8,reverse())],'xay',['x','a.alt','y'])
gdef=u32(0x10000)+u16(12,0,0,0)+cdef({'a':1,'b':1,'f':1,'i':1,'acutecomb':3,'f_f_i':2})
case('ignore-marks',[lookup(4,ligature(),8)],'f\u0301fi',['f_f_i','acutecomb'],gdef=gdef)
case('nested',[lookup(6,chain(3)),lookup(5,context(3)),lookup(1,single('b','b.alt'))],'xaby',['x','a','b.alt','y'])
# Correct nested contextual record to lookup 2 rather than recurse to itself.
p=P/'nested.ttf';from fontTools.ttLib import TTFont
f=TTFont(p);data=gsub([lookup(6,chain(3)[:18]+u16(0)+chain(3)[20:]),lookup(5,context(3)[:12]+u16(2)+context(3)[14:]),lookup(1,single('b','b.alt'))]);t=DefaultTable('GSUB');t.data=data;f['GSUB']=t;f.recalcTimestamp=False;f.save(p)
font('feature-variations',gsub([lookup(1,single('a','a.alt')),lookup(1,single('a','a.alt2')),lookup(1,single('a','b.alt')),lookup(1,single('a','c.alt'))],fv=True),variable=True)
font('position',None,position=True)
font('plain',None)
(P/'cases.json').write_text(json.dumps(cases,indent=2,ensure_ascii=False)+'\n')
print('Generated',len(cases)+3,'original fixtures')

# Original AAT fixtures: each legal state-machine subtable, in both encodings.
def aat_table(extended,typ,body):
    features=u16(18,0)+u32(1,0xffffffff)+u16(18,1)+u32(0,0xfffffffe)
    sub=(u32(12+len(body),0x20000000|typ,1) if extended else u16(8+len(body),0x2000|typ)+u32(1))+body
    chain=(u32(1,16+len(features)+len(sub),2,1) if extended else u32(1,12+len(features)+len(sub))+u16(2,1))+features+sub
    return u32(0x20000 if extended else 0x10000,1)+chain

def aat_machine(extended,typ):
    word=u32 if extended else u16;w=4 if extended else 2
    src=('f','i') if typ==2 else ('a','b')
    cls=(u16(8,gid[src[0]],2,4,5) if extended else u16(gid[src[0]],2)+bytes([4,5]))
    head=w*(4+(3 if typ==2 else 0 if typ==0 else 1))
    states=[[0,0,0,0,1,0],[0,0,0,0,1,0],[0,0,0,0,1,2]]
    if typ==5:states=[[0,0,0,0,1,0]]*3
    arr=(b''.join(u16(*row) for row in states) if extended else bytes(sum(states,[])))
    statepos=head+len(cls);entrypos=statepos+len(arr)
    nextstate=lambda n:n if extended else statepos+n*6
    pad=b'';tail=b''
    if typ==0:
        entries=u16(nextstate(0),0,nextstate(2),0x8000,nextstate(0),0x2003);extra=b''
    elif typ==1:
        subpos=entrypos+24
        entries=u16(nextstate(0),0,65535 if extended else 0,65535 if extended else 0,nextstate(2),0x8000,65535 if extended else 0,65535 if extended else 0,nextstate(0),0,0 if extended else subpos//2-gid['a'],65535 if extended else 0)
        extra=word(subpos);tail=u32(4)+u16(8,gid['a'],1,gid['a.alt']) if extended else G('a.alt')
    elif typ==5:
        subpos=entrypos+24;entries=u16(nextstate(0),0,65535,65535,nextstate(0),0x20,0,65535,nextstate(0),0,65535,65535)
        extra=word(subpos);tail=G('a.alt')
    else:
        entrylen=18 if extended else 12;actpos=(entrypos+entrylen+3)//4*4;pad=bytes(actpos-entrypos-entrylen);comppos=actpos+8;ligpos=comppos+4
        flags=0xa000 if extended else 0x8000|actpos
        entries=(u16(nextstate(0),0,0,nextstate(2),0x8000,0,nextstate(0),flags,0) if extended else u16(nextstate(0),0,nextstate(2),0x8000,nextstate(0),flags))
        extra=word(actpos,comppos,ligpos)
        a=(1-gid['i']) if extended else comppos//2+1-gid['i'];b=(-gid['f']) if extended else comppos//2-gid['f']
        tail=u32(a&0x3fffffff,(b&0x3fffffff)|0x80000000)+u16(0 if extended else ligpos,0)+G('f_i')
    return word(6,head,statepos,entrypos)+extra+cls+arr+entries+pad+tail

aat_cases=[]
for extended in (True,False):
    tag='morx' if extended else 'mort'
    for typ,text,want in [(0,'ab',['b','a']),(1,'ab',['a.alt','b']),(2,'fi',['f_i']),(4,'a',['a.alt']),(5,'a',['a','a.alt'])]:
        body=u16(8,gid['a'],1,gid['a.alt']) if typ==4 else aat_machine(extended,typ)
        name=tag+str(typ);font(name,None,aat=(tag,aat_table(extended,typ,body)))
        aat_cases.append({'font':name+'.ttf','text':text,'want':want})
(P/'aat-cases.json').write_text(json.dumps(aat_cases,indent=2)+'\n')
print('Generated',len(aat_cases),'AAT fixtures')

font('variation-metrics',gsub([lookup(2,sequence(['a.alt','b.alt']))]),variable=True)

more=[]
def extra(name,lookups,text,want,gdef=None):
    font(name,gsub(lookups),gdef=gdef);more.append({'font':name+'.ttf','text':text,'want':want})
# Nested lookup 3 must receive every parent feature value, not just value 1.
nested=context(3)[:10]+u16(0,1)+context(3)[14:]
extra('nested-alternate',[lookup(5,nested),lookup(3,alternate())],'ab',['a.alt','b'])
extra('ignore-base',[lookup(1,single(),2)],'a',['a'],gdef=gdef)
classdef=gdef[12:]
markset=u16(1,1)+u32(8)+cov()
filterdef=u32(0x10002)+u16(14,0,0,0,14+len(classdef))+classdef+markset
extra('mark-filter',[lookup(4,ligature(),16)],'f\u0301fi',['f_f_i','acutecomb'],gdef=filterdef)
attach=cdef({'acutecomb':2});attachdef=u32(0x10000)+u16(12,0,0,12+len(classdef))+classdef+attach
extra('mark-attachment',[lookup(4,ligature(),0x100)],'f\u0301fi',['f_f_i','acutecomb'],gdef=attachdef)
cases+=more;(P/'cases.json').write_text(json.dumps(cases,indent=2,ensure_ascii=False)+'\n')
# Table corruption cases are kept readable and reproducible, not downloaded.
for name,data in [('truncated',gsub([lookup(6,chain(3))])[:13]),('bad-offset',u32(0x10000)+u16(65535,65535,65535)),('recursive',gsub([lookup(5,context(3)[:12]+u16(0)+context(3)[14:])]))]:font('malformed-'+name,data)

# Two different input spans deliberately share the final character's own GID.
# They must remain two combination rows rather than disappear into that base.
shared=u16(1,8,1,14)+cov('f')+u16(2,6,14)+G('i')+u16(3)+G('f','i')+G('i')+u16(2)+G('i')
font('shared-output-ligatures',gsub([lookup(4,shared)]))

cases.append({'font':'shared-output-ligatures.ttf','text':'ffi','want':['i']})
(P/'cases.json').write_text(json.dumps(cases,indent=2,ensure_ascii=False)+'\n')
from fontTools.ttLib import TTCollection
for filename,fonts in [('multi-vf.ttc',['feature-variations.ttf','variation-metrics.ttf']),('static-resources.ttc',['plain.ttf','ligature.ttf'])]:
    collection=TTCollection();collection.fonts=[TTFont(P/name,recalcTimestamp=False) for name in fonts];collection.save(P/filename)
