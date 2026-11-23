"""Original synthetic fonts for component entry-point and boundary regressions."""
from pathlib import Path
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.feaLib.builder import addOpenTypeFeaturesFromString
from fontTools.ttLib import newTable
from fontTools.ttLib.tables._f_v_a_r import Axis
out=Path(__file__).resolve().parent/'Fixtures'
for boundary in (False,True):
    names=['.notdef','f','i','fi','acute','grave']
    fb=FontBuilder(1000,isTTF=True); fb.setupGlyphOrder(names)
    fb.setupCharacterMap({0x66:'f',0x69:'i',0x301:'acute',0x300:'grave'})
    glyphs={}
    for name in names:
        pen=TTGlyphPen(None); pen.moveTo((0,0)); pen.lineTo((100,0)); pen.lineTo((100,100)); pen.closePath(); glyphs[name]=pen.glyph()
    fb.setupGlyf(glyphs); fb.setupHorizontalMetrics({n:(0 if n in ['acute','grave'] else 600,0) for n in names})
    fb.setupHorizontalHeader(ascent=800,descent=-200)
    ps='GAV6Boundary' if boundary else 'GAV6Entry'
    fb.setupNameTable({'familyName':ps,'styleName':'Regular','uniqueFontIdentifier':ps,'fullName':ps,'psName':ps})
    fb.setupOS2(sTypoAscender=800,sTypoDescender=-200,usWinAscent=800,usWinDescent=200); fb.setupPost(); fb.setupMaxp()
    fea='languagesystem DFLT dflt; languagesystem latn dflt;\n'
    fea+='lookup L { lookupflag IgnoreMarks; sub '+('f i f' if boundary else 'f i')+' by fi; } L; feature liga { lookup L; } liga;\n'
    fea+='markClass [acute grave] <anchor 0 0> @top; feature mark { pos ligature fi <anchor 100 500> mark @top ligComponent <anchor '+('500' if boundary else '900')+' 500> mark @top '+('ligComponent <anchor 900 500> mark @top' if boundary else '')+'; } mark;\n'
    if boundary: fea+='markClass grave <anchor 0 0> @stack; feature mkmk { pos mark acute <anchor 0 200> mark @stack; } mkmk;'
    else: fea+='feature ss01 { sub acute by grave; } ss01; feature ss02 { sub acute by grave acute; } ss02; feature ss03 { sub acute by NULL; } ss03;'
    fea+=' table GDEF { GlyphClassDef [f i], [fi], [acute grave], []; } GDEF;'
    addOpenTypeFeaturesFromString(fb.font,fea)
    fb.font['fvar']=newTable('fvar'); a=Axis(); a.axisTag='wght'; a.minValue=100; a.defaultValue=400; a.maxValue=900; a.flags=0; a.axisNameID=256
    fb.font['fvar'].axes=[a]; fb.font['fvar'].instances=[]; fb.font['name'].setName('Weight',256,3,1,0x409)
    fb.font['gvar']=newTable('gvar'); fb.font['gvar'].version=1; fb.font['gvar'].reserved=0; fb.font['gvar'].variations={g:[] for g in names}
    fb.save(out/('v6-boundary.ttf' if boundary else 'v6-entry.ttf'))
