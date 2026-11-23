// Integration test proposal for GlyphAtlas's real public OpenType::position().
// NOT executed in the review container. Requires the repository sources.
// Expected to FAIL on f4acc1c92366b4210f2aaecdcd1cd2a2ad9368e1.
#include "GAOpenType.h"
#include <cmath>
#include <iostream>
using namespace ga::layout;
using Bytes = std::vector<uint8_t>;
static void word(Bytes &b, unsigned n) { b.push_back(uint8_t(n >> 8)); b.push_back(uint8_t(n)); }
static void put(Bytes &b, size_t p, unsigned n) { b.at(p)=uint8_t(n >> 8); b.at(p+1)=uint8_t(n); }
static Bytes words(std::initializer_list<unsigned> v) { Bytes b; for (auto n:v) word(b,n); return b; }
static size_t append(Bytes &b,const Bytes &t) { size_t p=b.size(); b.insert(b.end(),t.begin(),t.end()); return p; }
static Bytes coverage(const std::vector<Glyph> &g) {
    Bytes b=words({1,unsigned(g.size())}); for (auto x:g) word(b,x); return b;
}
static Bytes markSubtable(bool filtering) {
    Bytes b=words({1,0,0,1,0,0});
    put(b,2,append(b,coverage({12})));
    const std::vector<Glyph> targets=filtering?std::vector<Glyph>{10,11}:std::vector<Glyph>{10};
    put(b,4,append(b,coverage(targets)));
    put(b,8,b.size());
    append(b,words({1,0,6,1,0,0})); // MarkArray count=1, class=0, anchor=(0,0).
    const size_t array=b.size(); put(b,10,array);
    word(b,unsigned(targets.size())); b.resize(b.size()+2*targets.size());
    for (size_t i=0;i<targets.size();++i) {
        put(b,array+2+2*i,b.size()-array);
        append(b,words({1,0,targets[i]==10?500u:900u}));
    }
    return b;
}
static Bytes gpos(bool filtering) {
    Bytes b=words({1,0,10,0,0});
    // ScriptList: DFLT -> default LangSys -> feature 0.
    append(b,words({1,0x4446,0x4c54,8,4,0,0,0xffff,1,0}));
    put(b,6,b.size());
    // FeatureList: mkmk -> lookup 0.
    append(b,words({1,0x6d6b,0x6d6b,8,0,1,0}));
    put(b,8,b.size()); append(b,words({1,4}));
    append(b,words({6,filtering?16u:0u,1,filtering?10u:8u}));
    if (filtering) word(b,0); // markFilteringSet index.
    append(b,markSubtable(filtering)); return b;
}
static GDEF definitions(bool filtering) {
    GDEF d;
    Bytes classes=words({1,1,12});
    for (unsigned g=1;g<=12;++g) word(classes,g==1?1:(g>=10?3:0));
    d.glyphClasses=ClassDef(View(std::move(classes)));
    if (filtering) d.markSets.emplace_back(View(coverage({10,12})));
    return d;
}
int main() {
    unsigned failures=0;
    for (bool filtering:{false,true}) {
        OpenType ot{View(gpos(filtering)),true};
        Buffer items;
        for (Glyph glyph:{Glyph(1),Glyph(10),Glyph(11),Glyph(12)}) {
            Item i; i.glyph=glyph; i.source={uint32_t(items.size()),uint32_t(items.size()+1)};
            i.identity=items.size()+1; items.push_back(i);
        }
        Metrics metrics;
        metrics.horizontalAdvance=[](Glyph){return 600.0;};
        metrics.verticalAdvance=[](Glyph){return 1000.0;};
        ot.position(items,definitions(filtering),Settings{},metrics);
        const double expected=filtering?500:0;
        const double actual=items.back().yOffset;
        const bool pass=std::abs(actual-expected)<1e-9;
        std::cout<<(filtering?"mark filtering":"uncovered adjacent mark")
                 <<": yOffset="<<actual<<", expected="<<expected
                 <<(pass?" PASS":" FAIL")<<'\n';
        failures+=!pass;
    }
    return failures?1:0;
}
