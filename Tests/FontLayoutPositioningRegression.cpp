#include "GAOpenType.h"
#include "FontLayoutPositioningFixtures.h"
#include <cassert>
#include <cmath>
#include <iostream>

using namespace ga::layout;
using Bytes = std::vector<uint8_t>;

static void word(Bytes &b, unsigned n) { b.push_back(uint8_t(n >> 8)); b.push_back(uint8_t(n)); }
static Bytes words(std::initializer_list<unsigned> v) { Bytes b; for (auto n : v) word(b,n); return b; }
static void put16(Bytes &b, size_t at, unsigned n) { b.at(at)=uint8_t(n >> 8); b.at(at+1)=uint8_t(n); }
static void put32(Bytes &b, size_t at, uint32_t n) { put16(b,at,n >> 16); put16(b,at+2,n); }
static size_t append(Bytes &b, const Bytes &v) { size_t at=b.size(); b.insert(b.end(),v.begin(),v.end()); return at; }
static Buffer items(const std::vector<Glyph> &glyphs) {
    Buffer b;
    for (auto g : glyphs) {
        Item i; i.glyph=g; i.identity=b.size()+1;
        i.source={uint32_t(b.size()),uint32_t(b.size()+1)}; b.push_back(i);
    }
    return b;
}
static Metrics metrics() {
    Metrics m;
    m.horizontalAdvance=[](Glyph g) { return g==1 || g==2 ? 600.0 : 0.0; };
    m.verticalAdvance=[](Glyph) { return 1000.0; };
    return m;
}
static Bytes variationTable(bool positioning, bool universalFirst) {
    Bytes b(14); put32(b,0,0x10001); put16(b,4,14);
    append(b,words({1,0x6c61,0x746e,8,4,0,0,0xffff,1,0}));
    put16(b,6,b.size());
    append(b,positioning ? words({1,0x6d61,0x726b,8,0,1,0})
                         : words({1,0x6c69,0x6761,8,0,1,0}));
    size_t list=b.size(); put16(b,8,list); append(b,words({2,6,28}));
    for (unsigned value : {positioning ? 40u : 10u, positioning ? 80u : 20u}) {
        append(b,words({1,0,1,8}));
        append(b,positioning ? words({1,8,2,value}) : words({2,8,1,value}));
        append(b,words({1,1,4}));
    }
    size_t fv=b.size(); put32(b,10,fv); b.resize(fv+24);
    put32(b,fv,0x10000); put32(b,fv+4,2);
    if (!universalFirst) {
        put32(b,fv+8,b.size()-fv);
        append(b,words({1,0,6,1,0,0xe000,0x2000})); // axis 0, [-0.5,0.5]
    }
    // First substitution is NULL. The second record is an unconditional +80
    // (GPOS) or GID 20 (GSUB), so dropping/skipping the first record is visible.
    put32(b,fv+20,b.size()-fv);
    append(b,words({1,0,1,0,0,12,0,1,1}));
    return b;
}
static void checkVariations() {
    for (bool positioning : {false,true}) for (bool universal : {false,true}) {
        Bytes bytes=variationTable(positioning,universal);
        OpenType ot{View(bytes),positioning};
        assert(ot.branchCount()==3);
        assert(ot.features(0).front().lookups==ot.features(1).front().lookups);
        assert((ot.features(2).front().lookups==std::vector<unsigned>{1}));
        for (double coordinate : {0.0,1.0}) {
            size_t branch=ot.variationBranch({coordinate});
            assert(branch==(universal || coordinate==0 ? 1u : 2u));
            Buffer b=items({4});
            if (positioning) {
                ot.position(b,GDEF{},Settings{},metrics(),branch);
                assert(b[0].yOffset==(branch==1 ? 40 : 80));
            } else {
                ot.substitute(b,GDEF{},Settings{},branch);
                assert(b[0].glyph==(branch==1 ? 10 : 20));
            }
        }
        // A nonzero offset that points to EOF is malformed, not a NULL record.
        uint32_t fv=View(bytes).u32(10);
        put32(bytes,fv+12,bytes.size()-fv);
        bool rejected=false;
        try { OpenType bad{View(bytes),positioning}; }
        catch (const InvalidTable &) { rejected=true; }
        assert(rejected);
        std::cout << "FV " << positioning << '/' << universal << " PASS\n";
    }
}
int main() {
    unsigned failures=0;
    // Add confirmed regressions with each separately committed correction.
    const std::set<std::string> covered={"null_feature_substitution", "mkmk_direct",
        "mkmk_base_barrier", "single_then_attachment"};
    for (const auto &test : reviewCases()) {
        if (!covered.count(test.name)) continue;
        std::cout << test.name << ": ";
        bool good=false;
        try {
            OpenType ot{View(test.gpos),true};
            Buffer b=items(test.glyphs);
            Settings settings; settings.script=tag('l','a','t','n');
            bool kern=ot.position(b,GDEF{View(test.gdef)},settings,metrics(),ot.variationBranch({0}));
            good=!b.empty() && b.back().yOffset==test.y;
            if (test.kern>=0) good=good && kern==bool(test.kern) && b.front().xAdvance==550;
            std::cout << "y=" << b.back().yOffset;
        } catch (const std::exception &e) { std::cout << e.what(); }
        std::cout << (good ? " PASS\n" : " FAIL\n"); failures+=!good;
    }
    try { checkVariations(); }
    catch (const std::exception &e) { std::cout << "FV ERROR: " << e.what() << '\n'; ++failures; }
    return failures ? 1 : 0;
}
