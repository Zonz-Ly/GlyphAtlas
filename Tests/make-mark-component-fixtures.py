"""Regenerate the tiny original test fonts. Requires fontTools; tests use the saved TTFs."""
from pathlib import Path
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.feaLib.builder import addOpenTypeFeaturesFromString
from fontTools.ttLib import newTable
from fontTools.ttLib.tables._f_v_a_r import Axis

out=Path(__file__).resolve().parent/'Fixtures'
out.mkdir(exist_ok=True)
for ambiguous in (False,True):
    names=['.notdef','f','i','fi','acute']
    fb=FontBuilder(1000,isTTF=True); fb.setupGlyphOrder(names)
    fb.setupCharacterMap({0x66:'f',0x69:'i',0x301:'acute'})
    glyphs={}
    for name in names:
        pen=TTGlyphPen(None); pen.moveTo((0,0)); pen.lineTo((100,0)); pen.lineTo((100,100)); pen.closePath()
        glyphs[name]=pen.glyph()
    fb.setupGlyf(glyphs); fb.setupHorizontalMetrics({n:(0 if n=='acute' else 600,0) for n in names})
    fb.setupHorizontalHeader(ascent=800,descent=-200)
    ps='GAMarkComponentRegression'+('Paths' if ambiguous else '')
    fb.setupNameTable({'familyName':ps,'styleName':'Regular','uniqueFontIdentifier':ps,
                      'fullName':ps,'psName':ps})
    fb.setupOS2(sTypoAscender=800,sTypoDescender=-200,usWinAscent=800,usWinDescent=200)
    fb.setupPost(); fb.setupMaxp()
    features='languagesystem DFLT dflt; languagesystem latn dflt;\n'
    if ambiguous: features+='lookup Expand { sub f by f f; } Expand;\n'
    features+='lookup L { lookupflag IgnoreMarks; '+('sub f f i by fi; ' if ambiguous else '')+'sub f i by fi; } L;\n'
    if ambiguous: features+='feature salt { lookup Expand; } salt;\n'
    features+='''feature liga { lookup L; } liga;
markClass acute <anchor 0 0> @top;
feature mark { pos ligature fi <anchor 100 500> mark @top ligComponent <anchor 900 500> mark @top; } mark;
table GDEF { GlyphClassDef [f i], [fi], [acute], []; } GDEF;'''
    addOpenTypeFeaturesFromString(fb.font,features)
    fb.font['fvar']=newTable('fvar'); axis=Axis()
    axis.axisTag='wght'; axis.minValue=100; axis.defaultValue=400; axis.maxValue=900
    axis.flags=0; axis.axisNameID=256
    fb.font['fvar'].axes=[axis]; fb.font['fvar'].instances=[]
    fb.font['name'].setName('Weight',256,3,1,0x409)
    fb.font['gvar']=newTable('gvar'); fb.font['gvar'].version=1; fb.font['gvar'].reserved=0
    fb.font['gvar'].variations={g:[] for g in names}
    fb.save(out/('mark-component-paths.ttf' if ambiguous else 'mark-components.ttf'))
